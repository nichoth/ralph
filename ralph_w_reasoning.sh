#!/bin/bash

# Config
PROMPT_FILE="PROMPT.md"
MAX_ITERATIONS=${1:-10}
STALEMATE_THRESHOLD=2  # Escalate if 2 iterations pass with NO file changes
ITERATION=0
STALLED_COUNT=0

echo "Starting Ralph Loop with Dynamic Reasoning & Stall Detection..."

# Ensure we are in a git repo to track changes
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: This script requires a git repository to track progress."
    exit 1
fi

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # 1. Determine Reasoning Level
    # Escalate if STALEMATE_THRESHOLD hits the threshold
    if [ $STALLED_COUNT -ge $STALEMATE_THRESHOLD ]; then
        REASONING_LEVEL="high"
        COLOR="\033[1;33m" # Yellow for escalation
        echo -e "${COLOR}>>> STALL DETECTED ($STALLED_COUNT iterations with no changes). Escalating to HIGH reasoning... \033[0m"
    else
        REASONING_LEVEL="medium"
        COLOR="\033[1;34m" # Blue for standard
    fi

    echo -e "\n${COLOR}--- Iteration $ITERATION ($REASONING_LEVEL reasoning) --- \033[0m"

    # # 2. Codex CLI
    # # We pass the reasoning level into the config flag
    # RESPONSE=$(cat "$PROMPT_FILE" | codex exec \
    #     --yolo \
    #     --config model_reasoning_effort="\"$REASONING_LEVEL\"" \
    #     -)

    # 2. Execute Claude and STREAM output to terminal
    # We use 'tee' to show output live while saving it to a temp file
    tmp_response=$(mktemp)
    
    cat "$PROMPT_FILE" | claude \
        --effort "$REASONING_LEVEL" \
        --dangerously-skip-permissions \
        -p | tee "$tmp_response"

    RESPONSE=$(cat "$tmp_response")
    rm "$tmp_response"

    # 3. Stall Detection: Check if files were modified
    # If 'git status' is empty, nothing changed.
    if [[ -z $(git status --porcelain) ]]; then
        STALLED_COUNT=$((STALLED_COUNT + 1))
    else
        STALLED_COUNT=0 # Reset stall count if progress is made
    fi

    # 4. Check for completion signal
    if [[ "$RESPONSE" == *"<promise>COMPLETE</promise>"* ]]; then
        echo -e "\n\033[1;32m✅ SUCCESS: Mission accomplished at $REASONING_LEVEL reasoning.\033[0m"
        exit 0
    fi

    sleep 2
done

echo -e "\n\033[1;31m⚠️ Loop reached max iterations without completion signal.\033[0m"



