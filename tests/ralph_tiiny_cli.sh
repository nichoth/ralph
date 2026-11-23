#!/usr/bin/env bash
# Offline integration tests; no Pi sessions or device commands may run.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/ralph_tiiny.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-tiiny-cli.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
REAL_GIT=$(command -v git)
REAL_BASH=$(command -v bash)
REAL_TOUCH=$(command -v touch)
REAL_MKTEMP=$(command -v mktemp)
REAL_CAT=$(command -v cat)
REAL_TEE=$(command -v tee)
REAL_TAIL=$(command -v tail)
REAL_JQ=$(command -v jq)
COUNT=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

new_case() {
    COUNT=$((COUNT + 1))
    CASE_DIR="$TEST_ROOT/case $COUNT"
    REPO="$CASE_DIR/work repo"
    BIN="$CASE_DIR/bin"
    mkdir -p "$REPO/specs" "$BIN"
    "$REAL_GIT" init -q "$REPO"
    printf 'test prompt\n' > "$REPO/PROMPT.md"
    printf '{"userStories": []}\n' > "$REPO/specs/prd.json"
    ln -s "$REAL_BASH" "$BIN/bash"
    ln -s "$REAL_TOUCH" "$BIN/touch"
    ln -s "$REAL_MKTEMP" "$BIN/mktemp"
    ln -s "$REAL_CAT" "$BIN/cat"
    ln -s "$REAL_TEE" "$BIN/tee"
    ln -s "$REAL_TAIL" "$BIN/tail"
    ln -s "$REAL_JQ" "$BIN/jq"
    ln -s "$REAL_GIT" "$BIN/git"
    for command in pi tiiny; do
        cat > "$BIN/$command" <<'STUB'
#!/usr/bin/env bash
case "$0" in
    */tiiny)
    case "${TIINY_STUB_MODE:-one}" in
        fail) exit 42 ;;
        malformed) printf '{"models":{}}\n'; exit 0 ;;
        zero) printf '{"models":[]}\n'; exit 0 ;;
        many)
            printf '{"models":[{"id":"one","name":"One",'
            printf '"state":"running"},{"id":"two",'
            printf '"name":"Two","state":"loaded"}]}\n'
            exit 0
            ;;
    esac
    printf '{"models":[{"id":"%s","name":"Test Model",' \
        "$TIINY_STUB_MODEL"
    printf '"state":"running"}]}\n'
    exit 0
    ;;
esac
printf 'unexpected external invocation\n' >> "$CALLS"
exit 97
STUB
        chmod +x "$BIN/$command"
    done
}

run_cli() {
    STATUS=0
    CLI_ARGS=("$@")
    STUB_MODEL=test/model
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --model|-m)
                STUB_MODEL="${2:-}"
                shift
                [ "$#" -gt 0 ] && shift
                continue
                ;;
        esac
        shift
    done
    (
        cd "$REPO"
        export PATH="$BIN" CALLS="$CASE_DIR/calls"
        export TIINY_STUB_MODEL="$STUB_MODEL"
        export TIINY_STUB_MODE="${TIINY_STUB_MODE:-one}"
        if [ "${#CLI_ARGS[@]}" -gt 0 ]; then
            "$RUNNER" "${CLI_ARGS[@]}"
        else
            "$RUNNER"
        fi
    ) > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr" || STATUS=$?
    OUTPUT=$(cat "$CASE_DIR/stdout" "$CASE_DIR/stderr")
    # Task-loop cases intentionally invoke the Pi stub; discovery remains the
    # only Tiiny call and is safe to exercise offline.
}

expect_status() {
    [ "$STATUS" -eq "$1" ] ||
        fail "expected exit $1, got $STATUS: $OUTPUT"
}

expect_text() {
    case "$OUTPUT" in
        *"$1"*) ;;
        *) fail "expected '$1' in: $OUTPUT" ;;
    esac
}

expect_config() {
    expect_status 0
    expect_text "MAX_ITERATIONS=$1"
    expect_text "MAX_TURNS_PER_SESSION=$2"
    expect_text "Requested model: $3"
}

run_loop_stub() {
    cat > "$BIN/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [ "${PI_MODE:-noop}" = fail ]; then
        printf '%s\n' '{"type":"result","subtype":"error"}'
        exit 9
elif [ "${PI_MODE:-noop}" = commit ]; then
        printf '%s\n' stub >> progress.log
        git add progress.log
        git commit -qm 'stub progress'
elif [ "${PI_MODE:-noop}" = complete_one ]; then
        jq '.userStories[0].passes = true' specs/prd.json \
            > specs/prd.tmp && /bin/mv specs/prd.tmp specs/prd.json
elif [ "${PI_MODE:-noop}" = complete_two ]; then
        jq '.userStories[0].passes = true | .userStories[1].passes = true' \
            specs/prd.json > specs/prd.tmp && \
            /bin/mv specs/prd.tmp specs/prd.json
fi
printf '%s\n' '{"type":"assistant","message":{"content":['\
    '{"type":"text","text":"done"}]}}'
printf '%s\n' '{"type":"result","subtype":"success"}'
STUB
    chmod +x "$BIN/pi"
}

# Start with the public help contract, independent of local prerequisites.
new_case
rm "$BIN/pi" "$BIN/tiiny" "$BIN/jq" "$BIN/git"
rm "$REPO/PROMPT.md" "$REPO/specs/prd.json"
run_cli --help
expect_status 0
for text in Usage: --model -m MAX_ITERATIONS MAX_TURNS_PER_SESSION \
    'default: 10' 'default: 80' loaded 'sole loaded model'; do
    expect_text "$text"
done
[ ! -e "$REPO/progress.log" ] || fail "help created progress.log"

new_case
run_cli
expect_config 10 80 'automatic (sole loaded model)'
[ -f "$REPO/progress.log" ] || fail "preflight did not create progress.log"
[ ! -s "$REPO/progress.log" ] || fail "new progress.log is not empty"

new_case
run_cli 7
expect_config 7 80 'automatic (sole loaded model)'

for mode in zero malformed fail; do
    new_case
    TIINY_STUB_MODE="$mode" run_cli
    expect_status 1
    case "$mode" in
        zero) expect_text 'no loaded Tiiny models' ;;
        malformed) expect_text 'malformed model data' ;;
        fail) expect_text 'cannot discover loaded Tiiny models' ;;
    esac
done

new_case
TIINY_STUB_MODE=many run_cli
expect_status 1
expect_text 'Loaded model IDs:'
expect_text 'one'
expect_text 'two'
expect_text 'multiple loaded models'

new_case
TIINY_STUB_MODE=many run_cli -m one
expect_status 0
expect_text 'Selected Tiiny model: One (one)'

new_case
TIINY_STUB_MODE=many run_cli -m absent
expect_status 1
expect_text "model 'absent' is not currently loaded"

for flag in --model -m; do
    for position in before between after; do
        new_case
        model='ornith-ai/Ornith-1.5-35B-A3B-Turbo'
        case "$position" in
            before) run_cli "$flag" "$model" 3 9 ;;
            between) run_cli 3 "$flag" "$model" 9 ;;
            after) run_cli 3 9 "$flag" "$model" ;;
        esac
        expect_config 3 9 "$model"
    done
done

new_case
run_cli -m 'custom/model with spaces'
expect_config 10 80 'custom/model with spaces'

new_case
run_cli 0008 0009
expect_config 8 9 'automatic (sole loaded model)'

for flag in --model -m; do
    for value in missing empty option; do
        new_case
        case "$value" in
            missing) run_cli "$flag" ;;
            empty) run_cli "$flag" '' ;;
            option) run_cli "$flag" --help ;;
        esac
        expect_status 2
        expect_text "$flag requires a model ID"
        expect_text Usage:
        [ ! -e "$REPO/progress.log" ] || fail "invalid CLI created log"
    done
done

for flag in --unknown -x --model=example; do
    new_case
    run_cli "$flag"
    expect_status 2
    expect_text 'unknown option'
    expect_text Usage:
done

new_case
run_cli 1 2 3
expect_status 2
expect_text 'too many positional arguments'

for value in 0 000 -1 1.5 abc 1e3 +2 '' ' 2' '2 ' '1+2'; do
    for position in first second; do
        new_case
        if [ "$position" = first ]; then
            run_cli "$value"
        else
            run_cli 1 "$value"
        fi
        expect_status 2
        expect_text 'positive integer'
        expect_text Usage:
    done
done

for command in pi tiiny jq git; do
    new_case
    rm "$BIN/$command"
    run_cli
    expect_status 1
    expect_text "required command '$command' not found in PATH"
    [ ! -e "$REPO/progress.log" ] || fail "missing command created log"
done

for file in PROMPT.md specs/prd.json; do
    new_case
    rm "$REPO/$file"
    run_cli
    expect_status 1
    expect_text "missing required file: $file"
    [ ! -e "$REPO/progress.log" ] || fail "missing file created log"
done

new_case
rm -rf "$REPO/.git"
run_cli
expect_status 1
expect_text 'working Git repository'

new_case
"$REAL_GIT" init -q --bare "$CASE_DIR/bare"
REPO="$CASE_DIR/bare"
run_cli
expect_status 1
expect_text 'working Git repository'

new_case
rm "$BIN/git"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/git"
chmod +x "$BIN/git"
run_cli
expect_status 1
expect_text 'working Git repository'

new_case
rm "$BIN/git"
printf '#!/usr/bin/env bash\nprintf "true\\n"\nexit 1\n' > "$BIN/git"
chmod +x "$BIN/git"
run_cli
expect_status 1
expect_text 'working Git repository'

# Required files come from cwd, even when the script lives elsewhere.
new_case
mkdir "$REPO/nested"
REPO="$REPO/nested"
run_cli
expect_status 1
expect_text 'missing required file: PROMPT.md'

new_case
printf 'existing progress\n' > "$REPO/progress.log"
run_cli
expect_status 0
[ "$(cat "$REPO/progress.log")" = 'existing progress' ] ||
    fail "preflight replaced existing progress"

new_case
mkdir "$REPO/progress.log"
run_cli
expect_status 1
expect_text 'progress.log must be a regular file'

new_case
rm "$BIN/touch"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/touch"
chmod +x "$BIN/touch"
run_cli
expect_status 1
expect_text 'cannot create or update progress.log'

# The task loop chooses the lowest priority, accepts absent passes flags, and
# supplies the exact context contract to a fresh Pi process.
new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[
  {"id":"high","title":"High","priority":1},
  {"id":"low","title":"Low","priority":9,"passes":false},
  {"id":"done","title":"Done","priority":0,"passes":true}
]}
JSON
printf 'line-%s\n' 1 2 3 4 5 6 7 8 9 > "$REPO/progress.log"
cat > "$BIN/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
printf '%s\n' "$(cat)" >> "$CALLS"
printf '{"type":"result","subtype":"success"}\n'
STUB
chmod +x "$BIN/pi"
run_cli 1 4
expect_status 0
expect_text 'Reached MAX_ITERATIONS=1'
grep -q 'Work on EXACTLY ONE task: \[high\] High' "$CASE_DIR/calls" ||
    fail 'Pi context did not select the highest-priority pending story'
grep -q 'line-2' "$CASE_DIR/calls" ||
    fail 'Pi context did not include the last eight log lines'
grep -q 'line-1' "$CASE_DIR/calls" &&
    fail 'Pi context included more than the last eight log lines'
grep -q 'Remaining tasks' "$CASE_DIR/calls" ||
    fail 'Pi context omitted remaining tasks'

new_case
printf '{"userStories": {}}\n' > "$REPO/specs/prd.json"
run_cli
expect_status 3
expect_text 'missing/malformed'

# Pi JSON events are rendered live while the unchanged stream is retained.
new_case
printf '{"userStories":[{"id":"todo","title":"Todo"}]}\n' \
    > "$REPO/specs/prd.json"
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[{"id":"todo","title":"Todo"}]}
JSON
cat > "$BIN/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","model":"tiiny"}'
retry='{"type":"system","subtype":"api_retry",'
retry=$retry'"attempt":1,"max_retries":2,"error":"temporary"}'
printf '%s\n' "$retry"
assistant='{"type":"assistant","message":{"content":['
assistant=$assistant'{"type":"text","text":"hello"},'
assistant=$assistant'{"type":"tool_use","name":"git",'
assistant=$assistant'"input":{"x":1}}]}}'
printf '%s\n' "$assistant"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result"}]}}'
printf '%s\n' '{"type":"result","subtype":"success"}'
STUB
chmod +x "$BIN/pi"
run_cli 1
expect_status 0
expect_text 'session start (tiiny)'
expect_text 'retry 1/2'
expect_text 'hello'
expect_text 'tool git:'
expect_text 'tool result'
expect_text 'session success'

new_case
printf '{"userStories":[{"id":"todo","title":"Todo"}]}\n' \
    > "$REPO/specs/prd.json"
cat > "$BIN/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","subtype":"success"}'
STUB
chmod +x "$BIN/pi"
run_cli 1
expect_status 0
expect_text 'missing assistant terminal output'

for subtype in error aborted; do
    new_case
    printf '{"userStories":[{"id":"todo","title":"Todo"}]}\n' \
        > "$REPO/specs/prd.json"
    cat > "$BIN/pi" <<STUB
#!/usr/bin/env bash
printf '%s\\n' '{"type":"assistant","message":{"content":['\\
    '{"type":"text","text":"failed"}]}}'
printf '%s\\n' '{"type":"result","subtype":"$subtype"}'
STUB
    chmod +x "$BIN/pi"
    run_cli 1
    expect_status 0
    expect_text "Pi terminal outcome: $subtype"
done

new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[{"id":"todo","title":"Todo","passes":false}]}
JSON
cat > "$BIN/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"assistant","message":{"content":['\
    '{"type":"text","text":"<promise>COMPLETE</promise>"}]}}'
printf '%s\n' '{"type":"result","subtype":"success"}'
STUB
chmod +x "$BIN/pi"
run_cli 1
expect_status 0
expect_text 'ignoring COMPLETE'

# Progress is a new commit or fewer pending stories; dirty files alone stall.
new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[{"id":"todo","title":"Todo"}]}
JSON
run_loop_stub
PI_MODE=commit run_cli 1
expect_status 0
expect_text 'Progress (commits:'

new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[{"id":"todo","title":"Todo"}]}
JSON
run_loop_stub
PI_MODE=noop run_cli 4
expect_status 2
expect_text 'No progress this session (stall 4/4)'
mkdir -p "$REPO/.wrangler/state/v3"
PI_MODE=noop run_cli 3
expect_status 0
[ ! -d "$REPO/.wrangler/state/v3" ] || fail 'Wrangler state was not cleaned'

# Three failed sessions stop with exit 4; a successful session resets failures.
new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[{"id":"todo","title":"Todo"}]}
JSON
run_loop_stub
PI_MODE=fail run_cli 3
expect_status 4
expect_text 'Failed 3 consecutive Pi sessions'

new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[{"id":"todo","title":"Todo"}]}
JSON
run_loop_stub
PI_MODE=fail run_cli 1
expect_status 0
PI_MODE=noop run_cli 1
expect_status 0
expect_text 'Reached MAX_ITERATIONS=1'

# A session completing multiple stories is visible to the operator.
new_case
cat > "$REPO/specs/prd.json" <<'JSON'
{"userStories":[
  {"id":"one","title":"One"}, {"id":"two","title":"Two"}
]}
JSON
run_loop_stub
PI_MODE=complete_two run_cli 1
expect_status 0
expect_text 'completed more than one task'

printf 'PASS: %s offline Tiiny CLI cases\n' "$COUNT"
