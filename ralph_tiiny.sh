#!/usr/bin/env bash
# ralph_tiiny.sh -- command line and preflight for the Tiiny task loop.
# Pattern: Imperative Shell. Parse inputs, then check the local environment.
set -uo pipefail

PROMPT_FILE="PROMPT.md"
PRD_FILE="specs/prd.json"
LOG_FILE="progress.log"
MODEL=""
MAX_ITERATIONS=10
MAX_TURNS_PER_SESSION=80

usage() {
    printf '%s\n' \
        'Usage: ./ralph_tiiny.sh [OPTIONS] [MAX_ITERATIONS]' \
        '                        [MAX_TURNS_PER_SESSION]' \
        '' \
        'Arguments:' \
        '  MAX_ITERATIONS          Positive integer (default: 10).' \
        '  MAX_TURNS_PER_SESSION   Positive integer (default: 80).' \
        '' \
        'Options (may appear before or after positional arguments):' \
        '  --model MODEL_ID, -m MODEL_ID' \
        '      Request an exact ID from the currently loaded Tiiny models.' \
        '      Without this flag, automatically use the sole loaded model.' \
        '      Zero loaded models is an error; multiple require --model.' \
        '  --help, -h              Show this help and exit.' \
        '' \
        'Requires pi, tiiny, jq, Git, and a working Git repository.' \
        'Reads PROMPT.md and specs/prd.json from the current directory.' \
        'Creates progress.log in the current directory if needed.'
}

usage_error() {
    printf 'error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

preflight_error() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

# Validate limits as decimal strings, avoiding octal and overflow in parsing.
POSITIONAL_COUNT=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --model|-m)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
                usage_error "$1 requires a model ID"
            fi
            MODEL="$2"
            shift 2
            continue
            ;;
        -[0-9]*)
            # Negative limits get the same diagnostic as other bad numbers.
            ;;
        -*)
            usage_error "unknown option: $1"
            ;;
    esac

    [ "$POSITIONAL_COUNT" -lt 2 ] ||
        usage_error 'too many positional arguments'
    if [ "$POSITIONAL_COUNT" -eq 0 ]; then
        LIMIT_NAME=MAX_ITERATIONS
    else
        LIMIT_NAME=MAX_TURNS_PER_SESSION
    fi
    [[ "$1" =~ ^[0-9]+$ && "$1" =~ [1-9] ]] ||
        usage_error "$LIMIT_NAME must be a positive integer"
    # Strip leading zeroes so later arithmetic treats limits as decimal.
    LIMIT="${1#"${1%%[!0]*}"}"
    if [ "$POSITIONAL_COUNT" -eq 0 ]; then
        MAX_ITERATIONS="$LIMIT"
    else
        MAX_TURNS_PER_SESSION="$LIMIT"
    fi
    POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
    shift
done

for bin in pi tiiny jq git; do
    command -v "$bin" >/dev/null 2>&1 ||
        preflight_error "required command '$bin' not found in PATH"
done

if ! IN_WORK_TREE=$(git rev-parse --is-inside-work-tree 2>/dev/null) ||
    [ "$IN_WORK_TREE" != true ]; then
    preflight_error 'run from inside a working Git repository'
fi

for file in "$PROMPT_FILE" "$PRD_FILE"; do
    [ -f "$file" ] || preflight_error "missing required file: $file"
    [ -r "$file" ] || preflight_error "cannot read required file: $file"
done

if [ -e "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    preflight_error "$LOG_FILE must be a regular file"
fi
touch "$LOG_FILE" || preflight_error "cannot create or update $LOG_FILE"

printf 'Preflight passed: MAX_ITERATIONS=%s MAX_TURNS_PER_SESSION=%s\n' \
    "$MAX_ITERATIONS" "$MAX_TURNS_PER_SESSION"
printf 'Requested model: %s\n' "${MODEL:-automatic (sole loaded model)}"
# Model discovery and Pi sessions are added by subsequent PRD stories.
