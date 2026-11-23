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

prd_error() {
    printf 'error: %s\n' "$1" >&2
    exit 3
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

# Tiiny's read-only inventory command reports currently resident models. Keep
# this separate from the installed/downloaded model catalog: only entries in
# the running state are eligible for this runner.
MODEL_LIST=$(tiiny ls --json 2>/dev/null) ||
    preflight_error 'cannot discover loaded Tiiny models with tiiny ls --json'

MODEL_COUNT=$(printf '%s' "$MODEL_LIST" | jq -r '
    def models:
      if type == "array" then .
      elif (.models | type) == "array" then .models
      else error("missing models array") end;
    [models[] | select((.state // .status // "")
      | ascii_downcase == "running" or . == "loaded")
      | select((.id | type) == "string" and (.id | length) > 0)] | length
' 2>/dev/null) || preflight_error 'Tiiny returned malformed model data'

[ "$MODEL_COUNT" -gt 0 ] ||
    preflight_error 'no loaded Tiiny models found; load a model first'

SELECTED_MODEL=$(printf '%s' "$MODEL_LIST" | jq -r --arg requested "$MODEL" '
    def models:
      if type == "array" then .
      elif (.models | type) == "array" then .models
      else error("missing models array") end;
    [models[] | select((.state // .status // "")
      | ascii_downcase == "running" or . == "loaded")
      | select((.id | type) == "string" and (.id | length) > 0)]
    | if $requested != "" then map(select(.id == $requested))
      elif length == 1 then .
      else [] end
    | if length == 1 then .[0] else empty end
' 2>/dev/null) || true

if [ -z "$SELECTED_MODEL" ]; then
    if [ -n "$MODEL" ]; then
        preflight_error "model '$MODEL' is not currently loaded"
    fi
    printf 'Loaded model IDs:\n' >&2
    printf '%s' "$MODEL_LIST" | jq -r '
        def models: if type == "array" then . else .models end;
        models[] | select((.state // .status // "")
          | ascii_downcase == "running" or . == "loaded") | "  " + .id
    ' >&2 2>/dev/null || true
    preflight_error 'multiple loaded models; select one with --model or -m'
fi

SELECTED_ID=$(printf '%s' "$SELECTED_MODEL" | jq -r '.id')
SELECTED_NAME=$(printf '%s' "$SELECTED_MODEL" |
    jq -r '.name // .id')
printf 'Selected Tiiny model: %s (%s)\n' "$SELECTED_NAME" "$SELECTED_ID"

# The extension is deliberately process-local.  Pi loads it with -e for each
# fresh session, so registration never changes Pi's persistent model catalog.
PI_EXTENSION=""
cleanup_pi_extension() {
    if [ -n "$PI_EXTENSION" ] && [ -f "$PI_EXTENSION" ]; then
        /bin/rm -f "$PI_EXTENSION"
    fi
}
trap cleanup_pi_extension EXIT HUP INT TERM

TIINY_ENDPOINT=$(printf '%s' "$SELECTED_MODEL" | jq -r '
    def endpoint:
      (.endpoint // .baseUrl // .apiEndpoint // empty);
    if (endpoint | type) == "string" then endpoint
    elif endpoint == null or endpoint == "" then empty
    else error("endpoint is not a string") end
' 2>/dev/null) || preflight_error 'Tiiny returned malformed endpoint data'
if [ -n "$TIINY_ENDPOINT" ] && [ -n "${TIINY_BASE_URL:-}" ] &&
    [ "$TIINY_ENDPOINT" != "$TIINY_BASE_URL" ]; then
    preflight_error 'loaded model and Tiiny inference endpoints do not match'
fi
TIINY_ENDPOINT=${TIINY_ENDPOINT:-${TIINY_BASE_URL:-http://127.0.0.1:8000/v1}}

PI_EXTENSION="${TMPDIR:-/tmp}/ralph-tiiny-extension.$$.$RANDOM.ts"
: > "$PI_EXTENSION" || preflight_error 'cannot create temporary Pi extension'
export RALPH_PI_EXTENSION="$PI_EXTENSION"
export RALPH_TIINY_MODEL="$SELECTED_ID"
export RALPH_TIINY_ENDPOINT="$TIINY_ENDPOINT"
export RALPH_MAX_TURNS="$MAX_TURNS_PER_SESSION"
/bin/cat > "$PI_EXTENSION" <<'PI_EXTENSION_SOURCE'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const modelId = process.env.RALPH_TIINY_MODEL;
const endpoint = process.env.RALPH_TIINY_ENDPOINT;
const maxTurns = Number(process.env.RALPH_MAX_TURNS);

if (!modelId || !endpoint || !Number.isSafeInteger(maxTurns) || maxTurns < 1) {
  throw new Error("invalid Tiiny extension configuration");
}

export default function (pi: ExtensionAPI) {
  let modelTurns = 0;

  pi.registerProvider("tiiny", {
    name: "Tiiny",
    baseUrl: endpoint,
    apiKey: "$TIINY_API_KEY",
    api: "openai-completions",
    models: [{
      id: modelId,
      name: modelId,
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 131072,
      maxTokens: 16384,
    }],
  });

  pi.on("session_start", async () => {
    modelTurns = 0;
  });

  pi.on("turn_end", async (_event, ctx) => {
    modelTurns += 1;
    if (modelTurns >= maxTurns) {
      process.stderr.write(
        `Tiiny turn cap reached: ${modelTurns}/${maxTurns}\n`,
      );
      ctx.abort();
    }
  });
}
PI_EXTENSION_SOURCE

# Pi's TypeScript loader resolves the installed API package.  Keep this as a
# callable shell function so the session loop can load a fresh extension.
run_pi_session() {
    pi --no-session --mode json --extension "$PI_EXTENSION" \
        --model "tiiny/$SELECTED_ID" --thinking high -p
}

prd_ok() {
    jq -e 'has("userStories") and (.userStories | type == "array")' \
        "$PRD_FILE" >/dev/null 2>&1
}

count_pending() {
    jq -r '[.userStories[] | select(.passes == false or
        .passes == null or (.passes | not))] | length' "$PRD_FILE" \
        2>/dev/null
}

pending_list() {
    jq -r '.userStories[] | select(.passes == false or
        .passes == null or (.passes | not)) |
        "[\(.id)] \(.title)"' "$PRD_FILE" 2>/dev/null
}

current_task() {
    jq -r '[.userStories[] | select(.passes == false or
        .passes == null or (.passes | not))]
        | sort_by(.priority // 9999) | (.[0] // empty)
        | "[\(.id)] \(.title)"' "$PRD_FILE" 2>/dev/null
}

reasoning_hint() {
    case "$1" in
        0) : ;;
        1) printf '%s\n' 'REASONING: Think step by step before acting.' ;;
        2) printf '%s\n' 'REASONING: Re-read progress.log and question'
            printf '%s\n' 'your earlier assumptions before acting.' ;;
        *) printf '%s\n' 'REASONING: Think very hard and try a genuinely'
            printf '%s\n' 'different strategy if earlier attempts stalled.' ;;
    esac
}

TMP_CONTEXT=""
TMP_CAPTURE=""
cleanup_loop_files() {
    /bin/rm -f "${TMP_CONTEXT:-}" "${TMP_CAPTURE:-}" 2>/dev/null || true
    cleanup_pi_extension
}
trap cleanup_loop_files EXIT
trap 'exit 130' INT

ITERATION=0
while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
    ITERATION=$((ITERATION + 1))
    if ! prd_ok; then
        prd_error "$PRD_FILE is missing/malformed or has no "\
            "'userStories' array"
    fi

    TASK=$(current_task)
    if [ -z "$TASK" ]; then
        printf 'All tasks in %s pass. Nothing left to do.\n' "$PRD_FILE"
        exit 0
    fi

    TMP_CONTEXT=$(mktemp) || preflight_error 'cannot create session context'
    {
        cat "$PROMPT_FILE"
        printf '\n# THIS SESSION\n'
        printf 'Work on EXACTLY ONE task: %s\n' "$TASK"
        printf '%s\n' 'Complete it, update progress.log, set passes:true,'
        printf '%s\n' 'commit it, then stop. Do not start another task.'
        printf '\nRemaining tasks (context only):\n'
        pending_list
        printf '\nLAST_LOG_ENTRIES:\n'
        tail -n 8 "$LOG_FILE" 2>/dev/null
        HINT=$(reasoning_hint "${STALLED_COUNT:-0}")
        [ -z "$HINT" ] || printf '\n%s\n' "$HINT"
    } > "$TMP_CONTEXT"

    TMP_CAPTURE=$(mktemp) || preflight_error 'cannot create raw capture'
    run_pi_session < "$TMP_CONTEXT" > "$TMP_CAPTURE"
    PI_STATUS=$?
    cat "$TMP_CAPTURE"
    /bin/rm -f "$TMP_CONTEXT" "$TMP_CAPTURE"
    TMP_CONTEXT=""
    TMP_CAPTURE=""
    [ "$PI_STATUS" -eq 0 ] ||
        printf 'Pi session exited with status %s.\n' "$PI_STATUS" >&2
done

printf 'Reached MAX_ITERATIONS=%s with tasks still pending (%s left).\n' \
    "$MAX_ITERATIONS" "$(count_pending)"
exit 0
