#!/usr/bin/env bash
# ralph_tiiny.sh -- command line and preflight for the Tiiny task loop.
# Parse inputs, then check the local environment.
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

# Tiiny defaults to the catalog, so explicitly request resident models.
# CLI v0.0.7 prints a table even with --json. Normalize that verified format
# and JSON inventories once, before counting or selecting loaded models.
MODEL_LIST=$(tiiny ls --loaded --json 2>/dev/null) ||
    preflight_error 'cannot discover loaded Tiiny models (tiiny ls --loaded)'

MODEL_LIST=$(printf '%s' "$MODEL_LIST" | jq -Rs '
    def trim: gsub("^\\s+|\\s+$"; "");
    def columns: split("|")[1:-1] | map(trim);
    def border: test("^\\+(?:-+\\+)+$");
    def table:
      split("\n") | map(rtrimstr("\r"))
      | map(select(length > 0)) as $lines
      | if ($lines | length) < 4 or
           ($lines[0] | border | not) or
           ($lines[2] | border | not) or
           ($lines[-1] | border | not) or
           ($lines[1] | columns) != [
             "Name", "Model ID", "Type", "NPU Usage", "Source",
             "Started", "Last Used", "Aliases"
           ] then error("invalid loaded model table")
        else [
          $lines[3:-1][] | select(border | not)
          | if startswith("|") and endswith("|") then columns
            else error("invalid model row") end
          | if length == 8 and .[0] != "" and .[1] != "" then
              {name: .[0], id: .[1], state: "loaded"}
            else error("invalid model columns") end
        ] end;
    def models:
      if type == "array" then .
      elif (.models | type) == "array" then .models
      else error("missing models array") end;
    (if (ltrimstr("\n") | startswith("+")) then table
     else fromjson | models end)
    | [.[] | select((.state // .status // "")
      | ascii_downcase == "running" or . == "loaded")
      | select((.id | type) == "string" and (.id | length) > 0)]
' 2>/dev/null) || preflight_error 'Tiiny returned malformed model data'

MODEL_COUNT=$(printf '%s' "$MODEL_LIST" | jq 'length')
[ "$MODEL_COUNT" -gt 0 ] ||
    preflight_error 'no loaded Tiiny models found; load a model first'

SELECTED_MODEL=$(printf '%s' "$MODEL_LIST" | jq -r --arg requested "$MODEL" '
    if $requested != "" then map(select(.id == $requested))
      elif length == 1 then .
      else [] end
    | if length == 1 then .[0] else empty end
' 2>/dev/null) || true

if [ -z "$SELECTED_MODEL" ]; then
    if [ -n "$MODEL" ]; then
        preflight_error "model '$MODEL' is not currently loaded"
    fi
    printf 'Loaded model IDs:\n' >&2
    printf '%s' "$MODEL_LIST" | jq -r '.[] | "  " + .id' >&2
    preflight_error 'multiple loaded models; select one with --model or -m'
fi

SELECTED_ID=$(printf '%s' "$SELECTED_MODEL" | jq -r '.id')
SELECTED_NAME=$(printf '%s' "$SELECTED_MODEL" |
    jq -r '.name // .id')
printf 'Selected Tiiny model: %s (%s)\n' "$SELECTED_NAME" "$SELECTED_ID"

# The extension is deliberately process-local.  Pi loads it with -e for each
# fresh session, so registration never changes Pi's persistent model catalog.
PI_EXTENSION=""
# shellcheck disable=SC2317
cleanup_pi_extension() {
    if [ -n "$PI_EXTENSION" ] && [ -f "$PI_EXTENSION" ]; then
        /bin/rm -f "$PI_EXTENSION"
    fi
}
# shellcheck disable=SC2317
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
TIINY_ENDPOINT=${TIINY_ENDPOINT:-${TIINY_BASE_URL:-}}
# Inference runs on the device itself, so default to the address the Tiiny
# CLI is configured to reach. IPv6 hosts need brackets and an escaped zone.
if [ -z "$TIINY_ENDPOINT" ]; then
    TIINY_ENDPOINT=$(jq -r '
        .deviceAddress | select(type == "string" and length > 0)
        | if test(":") then "[" + gsub("%"; "%25") + "]" else . end
        | "http://" + . + "/v1"
    ' "$HOME/.local/tiiny/config.json" 2>/dev/null) || TIINY_ENDPOINT=""
fi
[ -n "$TIINY_ENDPOINT" ] ||
    preflight_error 'no Tiiny device address; set TIINY_BASE_URL'

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

render_events() {
    while IFS= read -r event; do
        printf '%s\n' "$event" | jq -r '
          if .type == "agent_start" then "session start"
          elif .type == "auto_retry_start" then
            "retry " + ((.attempt // 0) | tostring) + "/" +
            ((.maxAttempts // 0) | tostring) + " — " +
            (.errorMessage // "?")
          elif .type == "auto_retry_end" and .success == false then
            "retry failed: " + (.finalError // "?")
          elif .type == "compaction_end" then
            .errorMessage // "context compacted"
          elif .type == "message_end" and
               .message.role == "assistant" then
            (.message.content[]? | select(.type == "text") | .text),
            (if .message.errorMessage != null then
               "assistant error: " + .message.errorMessage
             elif .message.stopReason == "error" or
                  .message.stopReason == "aborted" or
                  .message.stopReason == "length" then
               "assistant stopped: " + .message.stopReason
             else empty end)
          elif .type == "tool_execution_start" then
            "tool " + (.toolName // "?") + ": " +
            ((.args // {}) | tostring | .[0:140])
          elif .type == "tool_execution_end" then
            "tool " + (.toolName // "?") +
            (if .isError then " failed" else " finished" end),
            (.result.content[]? | select(.type == "text") | .text)
          elif .type == "agent_end" then "session end"
          else empty end
        ' 2>/dev/null || true
    done
}

classify_capture() {
    local pending="$1" terminal assistant stop_reason model_error
    # agent_end includes the run messages. Inspect its final assistant so
    # recovered retries and intermediate tool calls do not count as failures.
    terminal=$(jq -cs '
      [.[] | select(.type == "agent_end")] | last // empty
    ' "$TMP_CAPTURE" 2>/dev/null) || {
        printf 'Pi terminal outcome: malformed JSON output\n' >&2
        return 1
    }
    if [ -z "$terminal" ]; then
        printf 'Pi terminal outcome: missing terminal output\n' >&2
        return 1
    fi
    assistant=$(printf '%s' "$terminal" | jq -c '
      [.messages[]? | select(.role == "assistant")] | last // empty
    ' 2>/dev/null)
    if [ -z "$assistant" ]; then
        printf 'Pi terminal outcome: missing assistant terminal output\n' >&2
        return 1
    fi
    stop_reason=$(printf '%s' "$assistant" | jq -r '.stopReason // "?"')
    model_error=$(printf '%s' "$assistant" | jq -r '.errorMessage // empty')
    if [ -n "$model_error" ]; then
        printf 'Pi terminal outcome: error: %s\n' "$model_error" >&2
        return 1
    fi
    if [ "$stop_reason" != stop ]; then
        printf 'Pi terminal outcome: %s\n' "$stop_reason" >&2
        return 1
    fi
    if ! printf '%s' "$assistant" | jq -e '
      any(.content[]?; .type == "text" and
        (.text | type == "string" and length > 0))
    ' >/dev/null 2>&1; then
        printf 'Pi terminal outcome: missing assistant terminal output\n' >&2
        return 1
    fi
    if printf '%s' "$assistant" | jq -e '
      any(.content[]?; .type == "text" and
        (.text | contains("<promise>COMPLETE</promise>")))
    ' >/dev/null 2>&1; then
        if [ "$pending" -eq 0 ]; then
            printf '%s\n' 'MISSION ACCOMPLISHED — COMPLETE reported and' \
                '0 tasks pending.'
            return 2
        fi
        printf 'ignoring COMPLETE: %s task(s) still pending\n' "$pending" >&2
    fi
    return 0
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
CAPTURE_OK=false
STALL_LIMIT=4
FAILED_SESSION_LIMIT=3
STALLED_COUNT=0
FAILED_SESSION_COUNT=0
# shellcheck disable=SC2317
finish_capture() {
    [ -n "$TMP_CAPTURE" ] || return 0
    if [ "$CAPTURE_OK" = true ]; then
        /bin/rm -f "$TMP_CAPTURE"
    else
        printf 'Retained Pi capture: %s\n' "$TMP_CAPTURE" >&2
    fi
    TMP_CAPTURE=""
}
# shellcheck disable=SC2317
cleanup_loop_files() {
    /bin/rm -f "${TMP_CONTEXT:-}" 2>/dev/null || true
    finish_capture
    cleanup_pi_extension
}
# shellcheck disable=SC2317
trap cleanup_loop_files EXIT
# shellcheck disable=SC2317
interrupt_cleanup() {
    trap - INT TERM
    jobs -pr | xargs -r kill 2>/dev/null || true
    exit 130
}
trap interrupt_cleanup INT TERM

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

    PENDING_BEFORE=$(count_pending)
    HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || printf 'none')
    if [ "$STALLED_COUNT" -eq 2 ] && [ -d ".wrangler/state/v3" ]; then
        printf '%s\n' 'Clearing stalled .wrangler/state/v3.' >&2
        /bin/rm -rf -- .wrangler/state/v3
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
    CAPTURE_OK=false
    set +o pipefail
    run_pi_session < "$TMP_CONTEXT" | tee "$TMP_CAPTURE" | render_events
    PIPE_STATUS=("${PIPESTATUS[@]}")
    set -o pipefail
    PI_STATUS="${PIPE_STATUS[0]:-1}"
    SESSION_STATUS="$PI_STATUS"
    if [ "$PI_STATUS" -ne 0 ]; then
        printf 'Pi process exited with status %s.\n' "$PI_STATUS" >&2
    fi
    if [ "${PIPE_STATUS[1]:-1}" -ne 0 ]; then
        SESSION_STATUS="${PIPE_STATUS[1]}"
        printf 'Failed to save Pi output (tee status %s).\n' \
            "$SESSION_STATUS" >&2
    fi
    PENDING_AFTER=$(count_pending)
    if [ "$SESSION_STATUS" -eq 0 ]; then
        classify_capture "$PENDING_AFTER"
        OUTCOME=$?
        if [ "$OUTCOME" -eq 0 ] || [ "$OUTCOME" -eq 2 ]; then
            CAPTURE_OK=true
        fi
        if [ "$OUTCOME" -eq 2 ]; then
            exit 0
        fi
        if [ "$OUTCOME" -ne 0 ]; then
            SESSION_STATUS=1
            printf '%s\n' \
                'Pi session failed validation (process status 0).' >&2
        fi
    fi

    if [ "$SESSION_STATUS" -ne 0 ]; then
        finish_capture
        FAILED_SESSION_COUNT=$((FAILED_SESSION_COUNT + 1))
        printf 'Pi failures in a row: %s/%s.\n' \
            "$FAILED_SESSION_COUNT" "$FAILED_SESSION_LIMIT" >&2
    else
        FAILED_SESSION_COUNT=0
    fi
    if [ "$FAILED_SESSION_COUNT" -ge "$FAILED_SESSION_LIMIT" ]; then
        printf 'Failed %s consecutive Pi sessions; stopping.\n' \
            "$FAILED_SESSION_LIMIT" >&2
        exit 4
    fi

    HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || printf 'none')
    if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ] ||
        [ "$PENDING_AFTER" -lt "$PENDING_BEFORE" ]; then
        DELTA=$((PENDING_BEFORE - PENDING_AFTER))
        if [ "$DELTA" -gt 1 ]; then
            printf 'Warning: session completed more than one task.\n' >&2
        fi
        printf 'Progress (commits: %s -> %s, pending: %s -> %s).\n' \
            "$HEAD_BEFORE" "$HEAD_AFTER" "$PENDING_BEFORE" \
            "$PENDING_AFTER"
        STALLED_COUNT=0
    else
        STALLED_COUNT=$((STALLED_COUNT + 1))
        printf 'No progress this session (stall %s/%s).\n' \
            "$STALLED_COUNT" "$STALL_LIMIT" >&2
    fi
    /bin/rm -f "$TMP_CONTEXT"
    finish_capture
    TMP_CONTEXT=""
    if [ "$STALLED_COUNT" -ge "$STALL_LIMIT" ]; then
        printf 'Stalled %s sessions; stopping.\n' "$STALL_LIMIT" >&2
        exit 2
    fi
done

printf 'Reached MAX_ITERATIONS=%s with tasks still pending (%s left).\n' \
    "$MAX_ITERATIONS" "$(count_pending)"
exit 0
