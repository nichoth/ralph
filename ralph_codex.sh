#!/bin/bash

# Config
PROMPT_FILE="PROMPT.md"
PRD_FILE="specs/prd.json"
MAX_ITERATIONS=${1:-10}
STALL_LIMIT=${RALPH_STALL_LIMIT:-3}
ITERATION=0
STALLED_COUNT=0
REASONING_LEVEL="low"

get_reasoning_level() {
    if [ "$STALLED_COUNT" -ge "$STALL_LIMIT" ]; then
        echo "high"
    elif [ "$STALLED_COUNT" -gt 0 ]; then
        echo "medium"
    else
        echo "low"
    fi
}

count_pending() {
    jq -r '[.userStories[] | select(.passes != true)] | length' \
        "$PRD_FILE"
}

current_task() {
    jq -r '
        [.userStories[] | select(.passes != true)]
        | sort_by(.priority // 9999)
        | (.[0].id // empty)
    ' "$PRD_FILE"
}

has_non_log_commit() {
    local before="$1"
    local after="$2"

    [ "$before" = "$after" ] && return 1

    git diff --name-only "$before" "$after" -- |
        awk 'NF && $0 != "progress.log" { found=1 }
            END { exit(found ? 0 : 1) }'
}

stall() {
    STALLED_COUNT=$((STALLED_COUNT + 1))
    echo -e "\033[0;31m[!] No meaningful progress this round.\033[0m"

    if [ "$STALLED_COUNT" -ge "$STALL_LIMIT" ]; then
        echo -e "\033[1;31mStalled $STALL_LIMIT sessions on $CURRENT_TASK.\033[0m"
        echo "Stopping for human review."
        exit 2
    fi
}

echo "Starting Ralph Loop with PRD-aware progress detection..."

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: This script requires a git repository."
    exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
    echo "Error: This script requires jq."
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ] || [ ! -f "$PRD_FILE" ]; then
    echo "Error: Missing $PROMPT_FILE or $PRD_FILE."
    exit 1
fi

if ! jq -e 'has("userStories") and
    (.userStories | type == "array")' "$PRD_FILE" > /dev/null;
then
    echo "Error: $PRD_FILE is malformed."
    exit 1
fi

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
    ITERATION=$((ITERATION + 1))
    REASONING_LEVEL=$(get_reasoning_level)
    PENDING_BEFORE=$(count_pending)

    if [ "$PENDING_BEFORE" -eq 0 ]; then
        echo "All tasks in $PRD_FILE pass. Nothing left to do."
        exit 0
    fi

    CURRENT_TASK=$(current_task)
    HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)

    if [ "$REASONING_LEVEL" = "high" ]; then
        echo -e "\033[1;33m>>> Repeated stall on $CURRENT_TASK.\033[0m"
    elif [ "$REASONING_LEVEL" = "medium" ]; then
        echo -e "\033[1;34m>>> Stall detected. Escalating...\033[0m"
    fi

    echo -e "\n--- Iteration $ITERATION"
    echo "($REASONING_LEVEL reasoning, $CURRENT_TASK) ---"

    RESPONSE=$(codex -m gpt-5.6-luna exec --yolo \
        --config "model_reasoning_effort=\"$REASONING_LEVEL\"" \
        - < "$PROMPT_FILE")
    CODEX_STATUS=$?

    if [ "$CODEX_STATUS" -ne 0 ]; then
        echo "[!] Codex command failed."
        stall
        sleep 5
        continue
    fi

    PENDING_AFTER=$(count_pending)
    HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo none)
    MEANINGFUL_PROGRESS=0

    if [ "$PENDING_AFTER" -lt "$PENDING_BEFORE" ]; then
        MEANINGFUL_PROGRESS=1
    elif has_non_log_commit "$HEAD_BEFORE" "$HEAD_AFTER"; then
        MEANINGFUL_PROGRESS=1
    fi

    if [[ "$RESPONSE" == *"<promise>COMPLETE</promise>"* ]]; then
        if [ "$PENDING_AFTER" -eq 0 ]; then
            echo "SUCCESS: Mission accomplished."
            exit 0
        fi
        echo "[!] COMPLETE reported while stories remain pending."
    fi

    if [ "$MEANINGFUL_PROGRESS" -eq 1 ]; then
        echo "[+] Meaningful progress detected."
        STALLED_COUNT=0
    else
        stall
    fi

    sleep 2
done

echo "Loop reached max iterations with stories still pending."
exit 2
