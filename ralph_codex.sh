#!/bin/bash
set -o pipefail

# Config
PROMPT_FILE="PROMPT.md"
MAX_ITERATIONS=${1:-10}
STALEMATE_THRESHOLD=3
ITERATION=0
STALLED_COUNT=0
REASONING_LEVEL="medium" # Start at medium

echo "Starting Ralph Loop with Improved Stall Detection..."

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: This script requires a git repository."
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: Prompt file '$PROMPT_FILE' not found."
    exit 1
fi

# Hash of actual repo *content*, not just the porcelain status string.
# Captures: committed state (HEAD), staged+unstaged edits to tracked files,
# the set of changed/new/removed paths, and the *contents* of untracked files.
# This is the key fix: it detects progress whether or not the agent commits,
# and it won't false-stall when the same already-modified file is edited again.
# `xargs -r` (--no-run-if-empty) prevents sha256sum from hanging on stdin
# when there are no untracked files.
state_hash() {
    {
        git rev-parse HEAD 2>/dev/null
        git diff HEAD 2>/dev/null
        git status --porcelain
        git ls-files --others --exclude-standard -z \
            | xargs -0 -r sha256sum 2>/dev/null
    } | sha256sum
}

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # 1. Determine Reasoning Level
    if [ $STALLED_COUNT -ge $STALEMATE_THRESHOLD ]; then
        REASONING_LEVEL="high"
        COLOR="\033[1;33m" # Yellow
        echo -e "${COLOR}>>> STALL DETECTED ($STALLED_COUNT rounds). Escalating to HIGH... \033[0m"
    else
        # Stay at whatever level we were (medium unless just reset).
        COLOR="\033[1;34m" # Blue
    fi

    echo -e "\n${COLOR}--- Iteration $ITERATION ($REASONING_LEVEL reasoning) --- \033[0m"

    # 2. Capture content state BEFORE the run
    PRE_STATE=$(state_hash)

    # 3. Codex CLI
    # Stream codex output to the terminal (tee) while capturing it for the
    # completion-marker check. PIPESTATUS[0] holds codex's *real* exit code;
    # a plain $? after this pipe would report tee's status instead.
    CODEX_OUT=$(mktemp)
    codex exec --yolo --config model_reasoning_effort="\"$REASONING_LEVEL\"" - \
        < "$PROMPT_FILE" | tee "$CODEX_OUT"
    CODEX_STATUS=${PIPESTATUS[0]}
    RESPONSE=$(cat "$CODEX_OUT")
    rm -f "$CODEX_OUT"

    if [ "$CODEX_STATUS" -ne 0 ]; then
        echo -e "\033[0;31m[!] Codex command failed (exit $CODEX_STATUS). Sleeping and retrying...\033[0m"
        sleep 5
        continue
    fi

    # 4. Capture content state AFTER the run
    POST_STATE=$(state_hash)

    # 5. Stall Detection Logic
    if [ "$PRE_STATE" == "$POST_STATE" ]; then
        STALLED_COUNT=$((STALLED_COUNT + 1))
        echo -e "\033[0;31m[!] No content changes detected this round.\033[0m"
    else
        echo -e "\033[0;32m[+] Progress detected! Resetting effort level.\033[0m"
        STALLED_COUNT=0
        # Reset to medium to save tokens/credits now that we're moving again.
        REASONING_LEVEL="medium"
    fi

    # 6. Completion Signal
    if [[ "$RESPONSE" == *"<promise>COMPLETE</promise>"* ]]; then
        echo -e "\n\033[1;32m✅ SUCCESS: Mission accomplished.\033[0m"
        exit 0
    fi

    sleep 2
done

echo -e "\n\033[1;31m⚠️ Loop reached max iterations.\033[0m"
exit 1
