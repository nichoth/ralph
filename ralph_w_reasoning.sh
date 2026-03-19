#!/bin/bash

# Configuration
PROMPT_FILE="PROMPT.md"
MAX_ITERATIONS=${1:-10}
STALEMATE_THRESHOLD=3  # Increase reasoning after this many iterations
ITERATION=0

echo "Starting Ralph Loop with Dynamic Reasoning..."

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # 1. Determine Reasoning Level
    # Default to medium, but escalate if we hit the threshold
    REASONING_LEVEL="medium"
    if [ $ITERATION -ge $STALEMATE_THRESHOLD ]; then
        REASONING_LEVEL="high"
        COLOR="\033[1;33m" # Yellow for caution/escalation
    else
        COLOR="\033[1;34m" # Blue for standard
    fi

    echo -e "\n${COLOR}--- Iteration $ITERATION ($REASONING_LEVEL reasoning) --- \033[0m"

    # 2. Codex CLI
    # We pass the reasoning level into the config flag
    RESPONSE=$(cat "$PROMPT_FILE" | codex exec \
        --yolo \
        --config model_reasoning_effort="\"$REASONING_LEVEL\"" \
        -)

    # Claude CLI in headless mode
    # `--effort`` sets the reasoning depth for the session
    # RESPONSE=$(cat "$PROMPT_FILE" | claude \
    #     --effort "$REASONING_LEVEL" \
    #     --dangerously-skip-permissions \
    #     -p)

    # Print response for visibility
    echo "$RESPONSE"

    # 3. Check for completion signal
    if [[ "$RESPONSE" == *"<promise>COMPLETE</promise>"* ]]; then
        echo -e "\n\033[1;32m✅ SUCCESS: Mission accomplished at $REASONING_LEVEL reasoning.\033[0m"
        exit 0
    fi

    sleep 2
done

echo -e "\n\033[1;31m⚠️ Loop reached max iterations without completion signal.\033[0m"
