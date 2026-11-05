#!/usr/bin/env bash
# Checks are single-quoted strings run through eval, so their expansions and the variables they read are deliberate.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
WORK=$(mktemp -d "${TMPDIR:-/tmp}/project-status-tests.XXXXXX")
readonly WORK
trap 'rm -rf "$WORK"' EXIT

export PROJECT_STATUS_DIR="$WORK/status"
export CLAUDE_PLUGIN_ROOT="$ROOT"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

hook() {
  local script=$1 cwd=$2 active=${3:-false}
  jq -n --arg cwd "$cwd" --argjson active "$active" \
    '{session_id: "t", transcript_path: "/dev/null", cwd: $cwd, permission_mode: "default", hook_event_name: "x", stop_hook_active: $active}' |
    "$ROOT/scripts/$script"
}

is_continue() { jq -e '.hookSpecificOutput.hookEventName == "Stop"' <<<"$1" >/dev/null 2>&1; }

age() { touch -t 202001010000 "$@"; }

repo="$WORK/repos/demo"
mkdir -p "$repo"
git -C "$repo" init -q
echo one >"$repo/a.txt"
git -C "$repo" add a.txt
GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$repo" commit -qm init --date "2020-01-01T00:00:00"
age "$repo/a.txt"
status="$PROJECT_STATUS_DIR/demo.md"

out=$(hook session-start.sh "$repo")
check "session-start: missing file is created from template" '[ -f "$status" ] && grep -q "^# demo status" "$status"'
check "session-start: output names the file path" 'jq -e --arg f "$status" ".hookSpecificOutput.additionalContext | contains(\$f)" <<<"$out" >/dev/null'
check "session-start: output includes rules and contents" 'jq -e ".hookSpecificOutput | .hookEventName == \"SessionStart\" and (.additionalContext | contains(\"Keep the whole file under 40 lines\") and contains(\"# demo status\"))" <<<"$out" >/dev/null'

echo "My own rules." >"$PROJECT_STATUS_DIR/_rules.md"
out_custom=$(hook session-start.sh "$repo")
rm -f "$PROJECT_STATUS_DIR/_rules.md"
check "session-start: a user's _rules.md replaces the default rules" 'jq -e ".hookSpecificOutput.additionalContext | contains(\"My own rules.\") and (contains(\"Keep the whole file under 40 lines\") | not)" <<<"$out_custom" >/dev/null'

check "session-start: placeholder description asks for a first-turn fill-in" 'jq -e ".hookSpecificOutput.additionalContext | contains(\"Action needed this session\")" <<<"$out" >/dev/null'

echo "custom content" >"$status"
out=$(hook session-start.sh "$repo")
check "session-start: no fill-in request once the description is set" 'jq -e ".hookSpecificOutput.additionalContext | contains(\"Action needed\") | not" <<<"$out" >/dev/null'

check "session-start: existing file is never modified" '[ "$(cat "$status")" = "custom content" ]'

head -c 20000 /dev/zero | tr '\0' x >"$status"
out=$(hook session-start.sh "$repo")
check "session-start: context is truncated under 10000 chars" '[ "$(jq -r ".hookSpecificOutput.additionalContext | length" <<<"$out")" -lt 10000 ]'
echo "custom content" >"$status"

out=$(hook stop.sh "$repo")
check "stop: fresh status file, no changes -> no output" '[ -z "$out" ]'

age "$status"
echo two >>"$repo/a.txt"
out=$(hook stop.sh "$repo")
check "stop: stale status file (modified file) -> continue with feedback" 'jq -e --arg f "$status" ".hookSpecificOutput | .hookEventName == \"Stop\" and (.additionalContext | contains(\$f))" <<<"$out" >/dev/null'

out=$(hook stop.sh "$repo" true)
check "stop: stop_hook_active true -> no output" '[ -z "$out" ]'

touch "$status"
out=$(hook stop.sh "$repo")
check "stop: status updated after change -> no output" '[ -z "$out" ]'

git -C "$repo" checkout -q a.txt
age "$status"
echo new >"$repo/untracked.txt"
out=$(hook stop.sh "$repo")
check "stop: untracked file newer than status -> continue" 'is_continue "$out"'
rm "$repo/untracked.txt"

git -C "$repo" rm -q a.txt
out=$(hook stop.sh "$repo")
check "stop: deleted path only -> no output" '[ -z "$out" ]'
git -C "$repo" reset -q --hard

echo three >"$repo/b.txt"
git -C "$repo" add b.txt
git -C "$repo" commit -qm second
age "$repo/b.txt"
out=$(hook stop.sh "$repo")
check "stop: new commit newer than status -> continue" 'is_continue "$out"'
touch "$status"

wt="$WORK/repos/demo-wt"
git -C "$repo" worktree add -q "$wt"
rm -f "$status"
hook session-start.sh "$wt" >/dev/null
check "worktree: shares the main checkout's status file" '[ -f "$status" ] && [ ! -e "$PROJECT_STATUS_DIR/demo-wt.md" ]'
age "$status"
echo wt >"$wt/c.txt"
out=$(hook stop.sh "$wt")
check "worktree: stop points at the shared file" 'jq -e --arg f "$status" ".hookSpecificOutput.additionalContext | contains(\$f)" <<<"$out" >/dev/null'

plain="$WORK/plain"
mkdir -p "$plain"
before=$(ls -A "$PROJECT_STATUS_DIR")
check "non-git: session-start silent, exit 0" '[ -z "$(hook session-start.sh "$plain")" ]'
check "non-git: stop silent, exit 0" '[ -z "$(hook stop.sh "$plain")" ]'
check "non-git: no status file created" '[ "$(ls -A "$PROJECT_STATUS_DIR")" = "$before" ]'

rm -f "$status"
out=$(hook stop.sh "$repo")
check "stop: missing status file -> no output" '[ -z "$out" ]'

check "session-start: records the main checkout path" '[ "$(cat "$PROJECT_STATUS_DIR/.repos/demo")" = "$(cd "$repo" && pwd -P)" ]'

cat >"$status" <<'MD'
# demo status

Demo project for tests

## Now

- Writing the generator
  across two lines.

## Next

1. First thing
2. Second thing

## Blocked

- Waiting on review (since 2026-10-29)
- Undated blocker

## Last updated

- 2026-11-01: wired the generator.
MD
touch "$status"
cat >"$WORK/sessions.json" <<JSON
[
  {"cwd": "$wt", "kind": "background", "sessionId": "s-wt", "name": "worktree job", "status": "waiting", "waitingFor": "permission prompt", "startedAt": 1793555061189},
  {"cwd": "$repo", "kind": "interactive", "sessionId": "s-main", "name": "main chat", "status": "busy", "startedAt": 1793555061189},
  {"cwd": "$plain", "kind": "interactive", "sessionId": "s-plain", "name": "not a repo", "status": "idle", "startedAt": 1793555061189},
  {"cwd": "$repo", "kind": "background", "sessionId": "s-new", "name": "just started", "status": null, "state": "working", "startedAt": 1793555061190}
]
JSON
gen="$WORK/status.json"
PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
demo() { jq -c --arg n demo '.projects[] | select(.name == $n)' "$gen"; }
check "generate: valid payload with host and interval" 'jq -e ".host and .generatedAt and .intervalSeconds == 30 and (.projects | type == \"array\")" "$gen" >/dev/null'
check "generate: description, now, next parsed" 'demo | jq -e ".desc == \"Demo project for tests\" and .now == \"Writing the generator across two lines.\" and .next == [\"First thing\", \"Second thing\"]" >/dev/null'
check "generate: blocked items with and without since" 'demo | jq -e ".blocked == [{\"text\": \"Waiting on review\", \"since\": \"2026-10-29\"}, {\"text\": \"Undated blocker\", \"since\": null}]" >/dev/null'
check "generate: summary strips the date" 'demo | jq -e ".summary == \"wired the generator.\"" >/dev/null'
check "generate: worktree and main sessions map to one project" 'demo | jq -e "[.sessions[] | {id, state}] == [{\"id\": \"s-wt\", \"state\": \"input\"}, {\"id\": \"s-main\", \"state\": \"working\"}, {\"id\": \"s-new\", \"state\": \"working\"}]" >/dev/null'
check "generate: a session with no status yet falls back to its job state" 'demo | jq -e ".sessions[] | select(.id == \"s-new\") | .state == \"working\"" >/dev/null'
check "generate: non-git session cwd is dropped" '! jq -e "[.projects[].sessions[].id] | index(\"s-plain\")" "$gen" >/dev/null'
check "generate: fresh status file is not stale" 'demo | jq -e ".stale == false" >/dev/null'
age "$status"
PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "generate: stale when code is newer than the status file" 'demo | jq -e ".stale == true" >/dev/null'
PROJECT_STATUS_REMOTE_CONTROL=off PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "generate: reports Remote Control as off when the machine can't use it" 'jq -e ".remoteControl == false" "$gen" >/dev/null'
PROJECT_STATUS_REMOTE_CONTROL=on PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "generate: reports Remote Control as on when available" 'jq -e ".remoteControl == true" "$gen" >/dev/null'

claude_dir="$WORK/claude"
(cd "$repo" && exec sleep 60) &
rc_pid=$!
dead_pid=$( (sleep 0 & echo $!) )
wait "$dead_pid" 2>/dev/null || true
mkdir -p "$claude_dir/projects/live" "$claude_dir/projects/dead"
jq -n --argjson pid "$rc_pid" --arg start "$(. "$ROOT/scripts/lib.sh"; proc_start "$rc_pid")" \
  '{sessionId: "session_01Live", environmentId: "env_01Live", source: "standalone", pid: $pid, procStart: $start}' \
  >"$claude_dir/projects/live/bridge-pointer.json"
jq -n --argjson pid "$dead_pid" '{sessionId: "session_01Dead", environmentId: "env_01Dead", pid: $pid, procStart: "1"}' >"$claude_dir/projects/dead/bridge-pointer.json"
echo '[]' >"$WORK/no-sessions.json"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/no-sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
kill "$rc_pid" 2>/dev/null || true
check "remote control: live server maps to its repo with its claude.ai environment link" 'demo | jq -e "[.sessions[] | {id, kind, remote, url}] == [{\"id\": \"session_01Live\", \"kind\": \"remote-control\", \"remote\": true, \"url\": \"https://claude.ai/code?environment=env_01Live\"}]" >/dev/null'
check "remote control: pointer for a dead pid is ignored" '! jq -e "[.projects[].sessions[].id] | index(\"session_01Dead\")" "$gen" >/dev/null'

enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
mkdir -p "$claude_dir/projects/$(enc "$repo")" "$claude_dir/projects/$(enc "$wt")"
printf '%s\n' '{"type":"user","message":{"content":"Fix the flaky login test please"}}' \
  '{"type":"ai-title","aiTitle":"Old title"}' '{"type":"ai-title","aiTitle":"Flaky login test"}' \
  >"$claude_dir/projects/$(enc "$repo")/s-main.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"Auto title"}' '{"type":"custom-title","customTitle":"My worktree job"}' \
  >"$claude_dir/projects/$(enc "$wt")/s-wt.jsonl"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
session() { demo | jq -c --arg id "$1" '.sessions[] | select(.id == $id)'; }
check "titles: latest ai-title replaces the random agent name" 'session s-main | jq -e ".title == \"Flaky login test\" and .worktree == null" >/dev/null'
check "titles: a /rename custom title wins over the ai-title" 'session s-wt | jq -e ".title == \"My worktree job\"" >/dev/null'
check "worktree: session in a worktree carries its name, branch, and dir" 'session s-wt | jq -e --arg d "$(cd "$wt" && pwd -P)" ".worktree == {\"name\": \"demo-wt\", \"branch\": \"demo-wt\"} and .dir == \$d" >/dev/null'

mkdir -p "$claude_dir/sessions"
jq -n '{pid: 4242, sessionId: "s-rc", bridgeSessionId: "session_01Bridge"}' >"$claude_dir/sessions/4242.json"
jq -n '{pid: 999, sessionId: "s-main", bridgeSessionId: "session_01Stale"}' >"$claude_dir/sessions/999.json"
jq --arg repo "$repo" '. + [{cwd: $repo, kind: "background", pid: 4242, sessionId: "s-rc", status: "busy"}]' "$WORK/sessions.json" >"$WORK/rc-sessions.json"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/rc-sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "remote control: a session with Remote Control on gets its claude.ai session link" 'session s-rc | jq -e ".remote == true and .url == \"https://claude.ai/code/session_01Bridge\"" >/dev/null'
check "remote control: a registry entry from another pid is ignored" 'session s-main | jq -e ".remote == false and .url == null" >/dev/null'

now=$(date +%s)
statusline() { "$ROOT/scripts/statusline.sh"; }
line=$(jq -n --argjson now "$now" '{session_id: "s-main", cost: {total_cost_usd: 1.8361},
  rate_limits: {five_hour: {used_percentage: 23.5, resets_at: ($now + 3600)}, seven_day: {used_percentage: 41.2, resets_at: ($now - 5)}}}' | statusline)
check "statusline: prints live windows and cost, drops a window past its reset" '[ "$line" = "5h 24% · \$1.84" ]'
check "statusline: records limits and the session cost" 'jq -e ".fiveHour.used_percentage == 23.5 and .sevenDay == null" "$PROJECT_STATUS_DIR/.usage/limits.json" >/dev/null && jq -e ".costUsd == 1.8361" "$PROJECT_STATUS_DIR/.usage/sessions/s-main.json" >/dev/null'
cp "$PROJECT_STATUS_DIR/.usage/limits.json" "$WORK/limits-before"
check "statusline: no rate_limits keeps the last recorded limits" '[ -z "$(echo "{\"session_id\": \"s-wt\"}" | statusline)" ] && cmp -s "$WORK/limits-before" "$PROJECT_STATUS_DIR/.usage/limits.json"'
check "statusline: a path-like session id is not written" 'echo "{\"session_id\": \"../x\", \"cost\": {\"total_cost_usd\": 1}}" | statusline >/dev/null && [ ! -e "$PROJECT_STATUS_DIR/.usage/x.json" ] && [ ! -e "$PROJECT_STATUS_DIR/.usage/sessions/../x.json" ]'
check "statusline: garbage input exits 0 silently" '[ -z "$(echo garbage | statusline)" ]'
wrapped=$(echo '{"session_id": "s-wrap", "cost": {"total_cost_usd": 2}}' | "$ROOT/scripts/statusline.sh" jq -r '"mine " + .session_id')
check "statusline: wraps another status line, printing its output and still recording" '[ "$wrapped" = "mine s-wrap" ] && jq -e ".costUsd == 2" "$PROJECT_STATUS_DIR/.usage/sessions/s-wrap.json" >/dev/null'

usage_line() { jq -nc --arg id "$1" --argjson out "$2" '{type: "assistant", message: {id: $id, usage: {input_tokens: 10, cache_creation_input_tokens: 100, cache_read_input_tokens: 1000, output_tokens: $out}}}'; }
{ usage_line m1 5; usage_line m1 5; usage_line m2 7; echo '{"truncated'; } >>"$claude_dir/projects/$(enc "$repo")/s-main.jsonl"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "usage: tokens are summed once per message from the transcript" 'session s-main | jq -e ".usage.tokens == {messages: 2, input: 20, cacheWrite: 200, cacheRead: 2000, output: 12}" >/dev/null'
check "usage: cost comes from the status line record" 'session s-main | jq -e ".usage.costUsd == 1.8361" >/dev/null'
check "usage: a session with no transcript or cost has no usage" 'session s-wt | jq -e ".usage == null" >/dev/null'
check "usage: limits carry live windows with ISO reset times" 'jq -e ".limits | (.fiveHour.usedPercentage == 23.5) and (.fiveHour.resetsAt | test(\"T\")) and (.sevenDay == null) and (.updatedAt != null)" "$gen" >/dev/null'
jq '.tokens.output = 999' "$PROJECT_STATUS_DIR/.usage/tokens/s-main.json" >"$WORK/t" && mv "$WORK/t" "$PROJECT_STATUS_DIR/.usage/tokens/s-main.json"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "usage: an unchanged transcript is read from the cache" 'session s-main | jq -e ".usage.tokens.output == 999" >/dev/null'
usage_line m3 1 >>"$claude_dir/projects/$(enc "$repo")/s-main.jsonl"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "usage: a grown transcript is re-read" 'session s-main | jq -e ".usage.tokens.output == 13" >/dev/null'
jq -n --argjson now "$now" '{fiveHour: {used_percentage: 99, resets_at: ($now - 1)}, updatedAt: $now}' >"$PROJECT_STATUS_DIR/.usage/limits.json"
CLAUDE_CONFIG_DIR="$claude_dir" PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$gen"
check "usage: limits whose windows all reset are dropped" 'jq -e ".limits == null" "$gen" >/dev/null'

fake_bin="$WORK/bin"
mkdir -p "$fake_bin" "$WORK/empty-claude"
cat >"$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
case "$1" in
  agents)
    echo '[{"id": "abcd1234", "sessionId": "abcd1234-0000-4000-8000-000000000000", "kind": "background"}, {"id": "eeee5555", "sessionId": "eeee5555-0000-4000-8000-000000000000", "kind": "interactive"}]'
    exit 0
    ;;
  rm)
    printf '%s\n' "$@" >"$FAKE_CLAUDE_LOG"
    if [ -n "${FAKE_RM_KEEP:-}" ]; then
      printf 'kept %s — its worktree is still at “/w”\n  The worktree has uncommitted changes. Deleting it would lose them.\n' "$2"
      exit 1
    fi
    echo "removed $2"
    exit 0
    ;;
esac
{ pwd -P; printf '%s\n' "$@"; } >"$FAKE_CLAUDE_LOG"
[ -z "${FAKE_CLAUDE_OUTPUT:-}" ] || { echo "$FAKE_CLAUDE_OUTPUT"; exit 0; }
echo "backgrounded · abcd1234 · name"
SH
chmod +x "$fake_bin/claude"
check "generate: records where claude is installed" 'PATH="$WORK/bin:$PATH" PROJECT_STATUS_SESSIONS_FILE="$WORK/sessions.json" "$ROOT/scripts/generate-status.sh" "$WORK/claude-path.json" && jq -e --arg c "$WORK/bin/claude" ".claude == \$c" "$WORK/claude-path.json" >/dev/null'
export FAKE_CLAUDE_LOG="$WORK/claude-args"
start() { CLAUDE_CONFIG_DIR="$WORK/empty-claude" PROJECT_STATUS_CLAUDE="$fake_bin/claude" "$ROOT/scripts/start-session.sh" "$@"; }

check "start: unknown repo is refused" '! start nope 2>/dev/null'
check "start: path-like repo name is refused" '! start ../demo 2>/dev/null && ! start .. 2>/dev/null && ! start . 2>/dev/null'
mkdir -p "$WORK/repos/.dotdemo"
git -C "$WORK/repos/.dotdemo" init -q
printf '%s\n' "$WORK/repos/.dotdemo" >"$PROJECT_STATUS_DIR/.repos/.dotdemo"
check "start: a repo name starting with a dot is allowed" 'PROJECT_STATUS_REMOTE_CONTROL=off start .dotdemo | jq -e ".repo == \".dotdemo\"" >/dev/null'
out=$(PROJECT_STATUS_REMOTE_CONTROL=on start demo "-fix the thing")
check "start: runs claude --bg in the repo, in a worktree, with Remote Control" '[ "$(sed -n 1p "$FAKE_CLAUDE_LOG")" = "$(cd "$repo" && pwd -P)" ] && [ "$(sed -n "2,4p;7,9p" "$FAKE_CLAUDE_LOG" | tr "\n" "|")" = "--bg|-n|fix the thing|--remote-control|fix the thing| -fix the thing|" ] && sed -n 5p "$FAKE_CLAUDE_LOG" | grep -q "^--worktree$"'
check "start: reports the new session id as JSON" 'jq -e ".id == \"abcd1234\" and .repo == \"demo\" and .remoteControl == true and (.worktree | startswith(\"ps-\"))" <<<"$out" >/dev/null'
ANTHROPIC_BASE_URL=https://bifrost.example start demo >/dev/null
check "start: an API gateway turns Remote Control off" '! grep -q "^--remote-control$" "$FAKE_CLAUDE_LOG" && [ "$(tail -n 1 "$FAKE_CLAUDE_LOG")" != "" ]'
mkdir -p "$WORK/gw-claude"
echo '{"env": {"ANTHROPIC_BASE_URL": "https://bifrost.example"}}' >"$WORK/gw-claude/settings.json"
check "start: a gateway in settings.json env also turns it off" 'CLAUDE_CONFIG_DIR="$WORK/gw-claude" "$ROOT/scripts/start-session.sh" --probe | jq -e ".remoteControl == false" >/dev/null'
remove() { PROJECT_STATUS_CLAUDE="$fake_bin/claude" "$ROOT/scripts/remove-session.sh" "$@"; }
check "remove: a background session is removed by its job id" 'remove abcd1234-0000-4000-8000-000000000000 | jq -e ".id == \"abcd1234\" and .removed" >/dev/null && [ "$(tr "\n" " " <"$FAKE_CLAUDE_LOG")" = "rm abcd1234 " ]'
check "remove: an interactive session is refused" '! remove eeee5555 2>/dev/null'
check "remove: a malformed id is refused" '! remove "abcd1234; rm -rf x" 2>/dev/null'
check "remove: a kept worktree comes back as one-line error" '! FAKE_RM_KEEP=1 remove abcd1234 2>"$WORK/rm-err" && grep -q "uncommitted changes" "$WORK/rm-err" && [ "$(wc -l <"$WORK/rm-err")" -eq 1 ]'
check "start: claude output without a session id is an error" '! FAKE_CLAUDE_OUTPUT="Workspace not trusted." start demo 2>"$WORK/start-err" && grep -q "Workspace not trusted" "$WORK/start-err"'

jq --arg repo "$repo" '. + [{cwd: $repo, kind: "interactive", sessionId: "s-old", status: "completed", startedAt: 1793555061000}]' "$WORK/sessions.json" >"$WORK/cli-sessions.json"
jq --arg repo "$repo" '[{cwd: $repo, kind: "interactive", sessionId: "s-term", status: "busy"}]' >"$WORK/cli-term.json" <<<'null'
ln -s "$ROOT/bin/project-status" "$WORK/bin/ps-link"
cli() {
  CLAUDE_CONFIG_DIR="$WORK/empty-claude" PROJECT_STATUS_CLAUDE="$fake_bin/claude" PROJECT_STATUS_REMOTE_CONTROL="${RC:-off}" \
    PROJECT_STATUS_SESSIONS_FILE="${SESSIONS:-$WORK/cli-sessions.json}" "${CLI:-$ROOT/bin/project-status}" "$@"
}
log_args() { sed 1d "$FAKE_CLAUDE_LOG" | tr "\n" " "; }
check "cli: ls --json prints the generated payload" 'cli ls --json | jq -e ".projects | any(.name == \"demo\")" >/dev/null'
check "cli: ls counts live sessions by state, most urgent first" 'cli ls | grep -E "^demo +1 input, 2 working " >/dev/null'
check "cli: ls prints a header and plain text when piped" 'cli ls | head -n 1 | grep -q "^REPO " && ! cli ls | grep -q "$(printf "\033")"'
check "cli: attach picks the most urgent background session" 'cli attach demo && [ "$(log_args)" = "attach s-wt " ]'
check "cli: attach by id prefix resumes an ended session in its directory" 'cli attach demo s-ol && [ "$(sed -n 1p "$FAKE_CLAUDE_LOG")" = "$(cd "$repo" && pwd -P)" ] && [ "$(log_args)" = "--resume s-old " ]'
check "cli: attach refuses a session running in a terminal" '! cli attach demo s-main 2>"$WORK/cli-err" && grep -q "running in a terminal" "$WORK/cli-err"'
check "cli: attach starts a new session when none can be attached" 'SESSIONS="$WORK/cli-term.json" RC=on cli attach demo && [ "$(sed -n 1p "$FAKE_CLAUDE_LOG")" = "$(cd "$repo" && pwd -P)" ] && [ "$(log_args)" = "--remote-control " ]'
check "cli: attach defaults to the repo you are in" '(cd "$repo" && cli attach) && [ "$(log_args)" = "attach s-wt " ]'
check "cli: attach refuses an unknown repo" '! cli attach nope 2>/dev/null'
check "cli: works when run through a symlink" 'CLI="$WORK/bin/ps-link" cli attach demo && [ "$(log_args)" = "attach s-wt " ]'
check "cli: needs lists input sessions first, then blockers" 'cli needs >"$WORK/needs" && head -n 1 "$WORK/needs" | grep -Eq "^input +demo +worktree job \(s-wt, waiting for permission prompt\)$" && grep -Eq "^blocked +demo +Waiting on review \(since 2026-10-29\)$" "$WORK/needs"'
check "cli: needs --json and -q" 'cli needs --json | jq -e "map(.kind) | index(\"input\") == 0 and index(\"blocked\") != null" >/dev/null && [ -z "$(cli needs -q)" ]'
mkdir -p "$WORK/empty-status"
check "cli: needs exits 1 when nothing needs you" 'out=$(PROJECT_STATUS_DIR="$WORK/empty-status" SESSIONS="$WORK/no-sessions.json" cli needs; echo "rc=$?") && [ "$out" = "Nothing needs you.
rc=1" ]'
check "cli: start runs start-session and reports the id" 'cli start demo "do the thing" | grep -q "^Started abcd1234 in demo (worktree ps-" && [ "$(tail -n 1 "$FAKE_CLAUDE_LOG")" = "do the thing" ]'
check "cli: start --next uses that Next item as the prompt" 'cli start --next 2 demo >/dev/null && [ "$(tail -n 1 "$FAKE_CLAUDE_LOG")" = "Second thing" ]'
check "cli: start --attach attaches to the new session" 'cli start demo --attach >/dev/null && [ "$(log_args)" = "attach abcd1234 " ]'
check "cli: start refuses a missing Next item and a prompt with --next" '! cli start demo --next 9 2>/dev/null && ! cli start demo hi --next 1 2>/dev/null'
check "cli: show prints the status file" 'cli show demo | grep -q "^Demo project for tests"'
check "cli: edit opens the status file in EDITOR" '[ "$(EDITOR=echo cli edit demo)" = "$status" ]'
check "cli: show and edit refuse a repo with no status file" '! cli show nope 2>/dev/null && ! EDITOR=echo cli edit nope 2>/dev/null'
jq --arg repo "$repo" '[{cwd: $repo, kind: "background", sessionId: "abcd1234-0000-4000-8000-000000000000", status: "idle"}, {cwd: $repo, kind: "interactive", sessionId: "eeee5555-0000-4000-8000-000000000000", status: "idle"}]' >"$WORK/cli-rm.json" <<<'null'
check "cli: rm -y removes a background session by id prefix" 'SESSIONS="$WORK/cli-rm.json" cli rm -y abcd | grep -q "^Removed abcd1234" && [ "$(log_args)" = "abcd1234 " ]'
check "cli: rm without -y off a terminal is refused" '! SESSIONS="$WORK/cli-rm.json" cli rm abcd </dev/null 2>"$WORK/cli-err" && grep -q "pass -y" "$WORK/cli-err"'
check "cli: rm refuses an interactive session" '! SESSIONS="$WORK/cli-rm.json" cli rm -y eeee 2>/dev/null'

if command -v curl >/dev/null && command -v python3 >/dev/null; then
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  CLAUDE_CONFIG_DIR="$WORK/empty-claude" PROJECT_STATUS_CLAUDE="$fake_bin/claude" PROJECT_STATUS_REMOTE_CONTROL=off \
    PROJECT_STATUS_GENERATOR=true python3 "$ROOT/scripts/dashboard-server.py" --port "$port" 2>"$WORK/server.log" &
  server_pid=$!
  base="http://127.0.0.1:$port"
  for _ in $(seq 50); do curl -fs "$base/api/info" >/dev/null 2>&1 && break; sleep 0.1; done
  token=$(cat "$PROJECT_STATUS_DIR/.token")
  post() { curl -s -o "$WORK/resp" -w '%{http_code}' -H 'Content-Type: application/json' "$@" "$base/${POST_PATH:-api/start}"; }
  check "server: info advertises start and Remote Control state" 'curl -fs "$base/api/info" | jq -e ".start == true and .remoteControl == false" >/dev/null'
  check "server: serves the dashboard page" '[ "$(curl -s -o /dev/null -w "%{http_code}" "$base/")" = 200 ]'
  check "server: token file is private" '[ "$(stat -c %a "$PROJECT_STATUS_DIR/.token" 2>/dev/null || stat -f %Lp "$PROJECT_STATUS_DIR/.token")" = 600 ]'
  check "server: start without the token is refused" '[ "$(post -d "{\"repo\":\"demo\"}")" = 401 ]'
  check "server: start from another origin is refused" '[ "$(post -H "X-Project-Status-Token: $token" -H "Origin: http://evil.example" -d "{\"repo\":\"demo\"}")" = 403 ]'
  check "server: start with the token runs the script" '[ "$(post -H "X-Project-Status-Token: $token" -H "Origin: $base" -d "{\"repo\":\"demo\",\"prompt\":\"First thing\"}")" = 200 ] && jq -e ".id == \"abcd1234\" and .remoteControl == false" "$WORK/resp" >/dev/null && [ "$(tail -n 1 "$FAKE_CLAUDE_LOG")" = "First thing" ]'
  check "server: script errors come back as a message" '[ "$(post -H "X-Project-Status-Token: $token" -d "{\"repo\":\"nope\"}")" = 422 ] && jq -e ".error | startswith(\"unknown repo\")" "$WORK/resp" >/dev/null'
  check "server: remove without the token is refused" '[ "$(POST_PATH=api/remove post -d "{\"id\":\"abcd1234\"}")" = 401 ]'
  check "server: remove with the token runs the script" '[ "$(POST_PATH=api/remove post -H "X-Project-Status-Token: $token" -d "{\"id\":\"abcd1234\"}")" = 200 ] && jq -e ".removed" "$WORK/resp" >/dev/null'
  kill "$server_pid" 2>/dev/null || true

  check "server: --access without its settings refuses to start" '! python3 "$ROOT/scripts/dashboard-server.py" --access --port 0 2>/dev/null'
  access_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  PROJECT_STATUS_ACCESS_TEAM_DOMAIN=team.cloudflareaccess.com PROJECT_STATUS_ACCESS_AUD=aud \
    PROJECT_STATUS_GENERATOR=true python3 "$ROOT/scripts/dashboard-server.py" --access --port "$access_port" 2>"$WORK/access-server.log" &
  access_pid=$!
  access_base="http://127.0.0.1:$access_port"
  for _ in $(seq 50); do curl -s -o /dev/null "$access_base/" 2>/dev/null && break; sleep 0.1; done
  check "server: --access refuses the page without a JWT" '[ "$(curl -s -o /dev/null -w "%{http_code}" "$access_base/")" = 401 ]'
  check "server: --access refuses start without a JWT, even with the token" '[ "$(base=$access_base post -H "X-Project-Status-Token: $token" -d "{\"repo\":\"demo\"}")" = 401 ]'
  check "server: --access refuses a forged JWT" '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Cf-Access-Jwt-Assertion: e30.e30.AAAA" "$access_base/status.json")" = 401 ]'
  kill "$access_pid" 2>/dev/null || true

  while IFS= read -r line; do
    case "$line" in
      "ok   "*) pass "${line#ok   }" ;;
      *) fail "${line#FAIL }" ;;
    esac
  done < <(python3 "$ROOT/tests/test_access.py" 2>&1 || true)
else
  fail "server: curl and python3 are needed for the server tests"
fi

printf '\n%d failure(s)\n' "$failures"
[ "$failures" -eq 0 ]
