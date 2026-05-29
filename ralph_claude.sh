#!/usr/bin/env bash
#
# ralph_claude.sh — one-task-per-session agentic loop for Claude Code.
#
# Each loop iteration = exactly ONE Claude session = ideally ONE task + commit.
# The bash loop owns the cadence; Claude owns the work inside a single session.
#
# Usage:  ./ralph_claude.sh [MAX_ITERATIONS] [MAX_TURNS_PER_SESSION]
#         ./ralph_claude.sh 200 60
#
set -uo pipefail   # NOT -e: we want to handle per-iteration failures ourselves

# --- Config -----------------------------------------------------------------
PROMPT_FILE="PROMPT.md"
PRD_FILE="specs/prd.json"
LOG_FILE="progress.log"
MODEL="sonnet"
MAX_ITERATIONS=${1:-10}
MAX_TURNS_PER_SESSION=${2:-60}   # hard ceiling so a single session can't run away
STALL_LIMIT=3                    # give up after this many no-progress iterations
ITERATION=0
STALLED_COUNT=0

# Amp-ism fallback: your PROMPT.md references $AMP_CURRENT_THREAD_ID for the
# progress.log "Thread:" line. Claude won't set it, so give it something valid.
export AMP_CURRENT_THREAD_ID="${AMP_CURRENT_THREAD_ID:-claude-local-$(date +%Y%m%d-%H%M%S)}"

# --- UI Colors --------------------------------------------------------------
BLUE='\033[1;34m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; MAGENTA='\033[1;35m'; RED='\033[1;31m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_step()    { echo -e "${YELLOW}➔ $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${MAGENTA}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}✖ $1${NC}"; }

trap 'echo -e "\n${MAGENTA}Stopping Ralph Loop...${NC}"; exit 130' SIGINT

# --- Preflight --------------------------------------------------------------
for bin in claude jq git; do
    command -v "$bin" >/dev/null 2>&1 || { log_error "'$bin' not found in PATH."; exit 1; }
done
for f in "$PROMPT_FILE" "$PRD_FILE"; do
    [ -f "$f" ] || { log_error "Missing required file: $f"; exit 1; }
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log_error "Not inside a git repo."; exit 1; }
touch "$LOG_FILE"

# --- Helpers ----------------------------------------------------------------
# Count tasks not yet passing.
count_pending() {
    jq -r '[.userStories[] | select(.passes == false or .passes == null)] | length' "$PRD_FILE" 2>/dev/null || echo "-1"
}
# Pretty list of pending tasks (for visibility / context).
pending_list() {
    jq -r '.userStories[] | select(.passes == false or .passes == null) | "[\(.id)] \(.title)"' "$PRD_FILE"
}
# The single highest-priority pending task. Falls back to first if no priority field.
current_task() {
    jq -r '
        [.userStories[] | select(.passes == false or .passes == null)]
        | sort_by(.priority // 9999)
        | (.[0] // empty) | "[\(.id)] \(.title)"
    ' "$PRD_FILE"
}

# Reasoning hint injected into the prompt based on stall count.
# (Prompt-based escalation is version-proof — unlike a possibly-nonexistent CLI
#  flag. If your `claude` build has a real reasoning flag, see NOTE at bottom.)
reasoning_hint() {
    case "$1" in
        0|1) echo "" ;;
        2)   echo "REASONING: Think carefully and step by step before acting." ;;
        *)   echo "REASONING: This task has stalled across multiple sessions. Think very hard. Re-read the Codebase Patterns and recent learnings in progress.log, question your earlier assumptions, and try a genuinely different approach." ;;
    esac
}

# --- Main loop --------------------------------------------------------------
while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
    ITERATION=$((ITERATION + 1))

    # 1. Pick the one task for this session.
    TASK="$(current_task)"
    if [ -z "$TASK" ]; then
        log_success "All tasks in $PRD_FILE pass. Nothing left to do."
        exit 0
    fi
    PENDING_BEFORE="$(count_pending)"
    HEAD_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo none)"

    # 2. Stall-driven friction relief: wipe stale local wrangler state.
    if [ "$STALLED_COUNT" -eq 2 ] && [ -d ".wrangler/state/v3" ]; then
        log_warn "Friction detected — clearing .wrangler/state/v3 ..."
        rm -rf .wrangler/state/v3
    fi

    echo -e "${BLUE}------------------------------------------------------------${NC}"
    log_info "ITERATION $ITERATION/$MAX_ITERATIONS  |  PENDING: $PENDING_BEFORE  |  STALL: $STALLED_COUNT"
    log_step "TARGET: $TASK"
    echo -e "${BLUE}------------------------------------------------------------${NC}"

    # 3. Build the per-session context.
    #    Key to the ralph protocol: pin THIS task and forbid touching others.
    TMP_CONTEXT="$(mktemp)"
    {
        cat "$PROMPT_FILE"
        echo
        echo "# THIS SESSION"
        echo "Work on EXACTLY ONE task: $TASK"
        echo "Complete it (write failing tests first, implement, lint, run only the"
        echo "relevant tests, update progress.log, then commit). When that single task"
        echo "is done and committed, STOP. Do NOT start any other task this session."
        echo
        echo "Remaining tasks (context only — do not work on these now):"
        pending_list
        echo
        echo "LAST_LOG_ENTRIES:"
        tail -n 8 "$LOG_FILE" 2>/dev/null
        HINT="$(reasoning_hint "$STALLED_COUNT")"
        [ -n "$HINT" ] && { echo; echo "$HINT"; }
    } > "$TMP_CONTEXT"

    # 4. Execute one session. Stream events live (no more silent terminal),
    #    tee the RAW jsonl to a capture file for completion detection.
    TMP_CAPTURE="$(mktemp)"
    set +o pipefail  # don't let a downstream jq/tee quirk mask claude's exit
    cat "$TMP_CONTEXT" \
      | claude -p --verbose \
          --output-format stream-json \
          --model "$MODEL" \
          --max-turns "$MAX_TURNS_PER_SESSION" \
          --dangerously-skip-permissions \
      | tee "$TMP_CAPTURE" \
      | jq --unbuffered -r '
          if .type == "system" then "🟦 session start"
          elif .type == "assistant" then
            (.message.content[]? |
              if .type == "text"     then "💬 " + .text
              elif .type == "tool_use" then "🔧 " + .name + ": " + ((.input // {}) | tostring | .[0:140])
              else empty end)
          elif .type == "user" then
            (.message.content[]? | if .type == "tool_result" then "↩️  tool result" else empty end)
          elif .type == "result" then
            "✅ " + (.subtype // "done") + "  ($" + ((.total_cost_usd // 0) | tostring) + ")"
          else empty end
        ' 2>/dev/null
    set -o pipefail

    # 5. Detect completion signal (works regardless of which block carried it;
    #    the literal string survives intact inside the JSON).
    if grep -q '<promise>COMPLETE</promise>' "$TMP_CAPTURE"; then
        log_success "MISSION ACCOMPLISHED — Claude reported COMPLETE."
        rm -f "$TMP_CONTEXT" "$TMP_CAPTURE"
        exit 0
    fi

    # 6. Progress detection: a new commit, fewer pending tasks, or a dirty tree.
    HEAD_AFTER="$(git rev-parse HEAD 2>/dev/null || echo none)"
    PENDING_AFTER="$(count_pending)"
    DIRTY="$(git status --porcelain)"

    if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ] || [ "$PENDING_AFTER" -lt "$PENDING_BEFORE" ] || [ -n "$DIRTY" ]; then
        log_success "Activity detected (commits: $HEAD_BEFORE → $HEAD_AFTER, pending: $PENDING_BEFORE → $PENDING_AFTER)."
        STALLED_COUNT=0
    else
        STALLED_COUNT=$((STALLED_COUNT + 1))
        log_warn "No progress this session (stall $STALLED_COUNT/$STALL_LIMIT)."
    fi

    rm -f "$TMP_CONTEXT" "$TMP_CAPTURE"

    # 7. Bail if we're truly stuck — avoid burning 200 no-op iterations.
    if [ "$STALLED_COUNT" -ge "$STALL_LIMIT" ]; then
        log_error "Stalled $STALL_LIMIT sessions in a row with escalation exhausted. Stopping for human review."
        exit 2
    fi
done

log_warn "Reached MAX_ITERATIONS=$MAX_ITERATIONS with tasks still pending ($(count_pending) left)."
exit 0
