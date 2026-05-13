#!/bin/bash

# --- Config ---
PROMPT_FILE="PROMPT.md"
PRD_FILE="specs/prd.json"
LOG_FILE="progress.log"
MAX_ITERATIONS=${1:-10}
STALEMATE_THRESHOLD=2  # Escalate quickly for P0 tasks
ITERATION=0
STALLED_COUNT=0
REASONING_LEVEL="medium"

# --- UI Colors ---
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
MAGENTA='\033[1;35m'
NC='\033[0m'

log_header() { echo -e "\n${MAGENTA}🚀 [RALPH LOOP] $1${NC}"; }
log_info()   { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_step()   { echo -e "${YELLOW}➔ $1${NC}"; }
log_success(){ echo -e "${GREEN}✅ $1${NC}"; }
log_warn()   { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_err()    { echo -e "${RED}❌ $1${NC}"; }

# --- Initialization ---
log_header "Initializing Narrative Concierge Engine..."

if ! command -v jq >/dev/null 2>&1; then
    log_err "Error: 'jq' is required to parse specs/prd.json. Install via 'brew install jq'."
    exit 1
fi

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    log_err "Error: Not a git repository."
    exit 1
fi

# --- The Loop ---
while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))
    
    # 1. Extract Current Task from PRD
    CURRENT_TASK_ID=$(jq -r '.core_features[] | select(.passes == false or .passes == null) | .id' "$PRD_FILE" | head -n 1)
    CURRENT_TASK_DESC=$(jq -r '.core_features[] | select(.passes == false or .passes == null) | .description' "$PRD_FILE" | head -n 1)
    
    if [ -z "$CURRENT_TASK_ID" ]; then
        log_success "No incomplete tasks found in prd.json!"
        # We still run one last time to see if Claude emits <promise>COMPLETE</promise>
    fi

    # 2. Reasoning Escalation
    if [ $STALLED_COUNT -ge $STALEMATE_THRESHOLD ]; then
        REASONING_LEVEL="high"
        log_warn "STALL DETECTED ($STALLED_COUNT rounds). Escalating to HIGH REASONING..."
    else
        REASONING_LEVEL="medium"
    fi

    echo -e "${BLUE}------------------------------------------------------------${NC}"
    log_info "ITERATION $ITERATION/$MAX_ITERATIONS | LEVEL: $REASONING_LEVEL"
    log_step "TASK: [${YELLOW}$CURRENT_TASK_ID${NC}] - $CURRENT_TASK_DESC"
    echo -e "${BLUE}------------------------------------------------------------${NC}"

    # 3. Capture State (HEAD + Working Directory Content)
    PRE_COMMIT=$(git rev-parse HEAD)
    PRE_STATE=$( (git diff; git ls-files --others --exclude-standard | xargs -I {} cat {}) | sha256sum )

    # 4. Execute Autonomous Agent
    # We pipe to 'tee' so you see the stream, but we also capture for the STOP CONDITION
    tmp_response=$(mktemp)
    log_info "Claude is executing plan..."

    # claude --effort "$REASONING_LEVEL" --dangerously-skip-permissions "$(cat $PROMPT_FILE)"
    
    cat "$PROMPT_FILE" | claude --model sonet --effort "$REASONING_LEVEL" --dangerously-skip-permissions -p | tee "$tmp_response"
    
    RESPONSE=$(cat "$tmp_response")
    rm "$tmp_response"

    # 5. Post-Run Analysis
    POST_COMMIT=$(git rev-parse HEAD)
    POST_STATE=$( (git diff; git ls-files --others --exclude-standard | xargs -I {} cat {}) | sha256sum )

    # Determine if progress happened
    if [ "$PRE_COMMIT" != "$POST_COMMIT" ]; then
        LATEST_MSG=$(git log -1 --pretty=format:'%s')
        log_success "Commit detected: $LATEST_MSG"
        git diff --stat HEAD~1 HEAD
        STALLED_COUNT=0
    elif [ "$PRE_STATE" != "$POST_STATE" ]; then
        log_success "Uncommitted file changes detected."
        git diff --stat
        STALLED_COUNT=0
    else
        STALLED_COUNT=$((STALLED_COUNT + 1))
        log_warn "No state change. Stall $STALLED_COUNT/$STALEMATE_THRESHOLD"
    fi

    # 6. Check for Stop Condition
    if [[ "$RESPONSE" == *"<promise>COMPLETE</promise>"* ]]; then
        log_success "MISSION ACCOMPLISHED: Stop condition met."
        exit 0
    fi

    # 7. Check for AI-Logged Stalls
    if grep -q "STALL:" "$LOG_FILE"; then
        log_warn "AI explicitly reported a STALL in progress.log. Forcing High Reasoning next round."
        STALLED_COUNT=$STALEMATE_THRESHOLD
    fi

    sleep 2
done

log_err "Reached maximum iterations without completion signal."
exit 1
