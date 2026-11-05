#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly OUT=${1:-${PROJECT_STATUS_OUT:-$PLUGIN_ROOT/dashboard/status.json}}
readonly ROOTS=${PROJECT_STATUS_ROOTS:-"$HOME/repos $HOME/code"}
readonly INTERVAL=${PROJECT_STATUS_INTERVAL:-30}
readonly CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
readonly USAGE_DIR="$STATUS_DIR/.usage"

work=$(mktemp -d "${TMPDIR:-/tmp}/project-status-gen.XXXXXX")
trap 'rm -rf "$work"' EXIT

sessions_json() {
  if [ -n "${PROJECT_STATUS_SESSIONS_FILE:-}" ]; then
    cat "$PROJECT_STATUS_SESSIONS_FILE"
    return
  fi
  command -v claude >/dev/null || { echo '[]'; return; }
  if command -v timeout >/dev/null; then
    timeout 20 claude agents --json --all 2>/dev/null || echo '[]'
  else
    claude agents --json --all 2>/dev/null || echo '[]'
  fi
}

pid_cwd() {
  if [ -d "/proc/$1" ]; then
    readlink "/proc/$1/cwd"
  else
    lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
  fi
}

elapsed_seconds() {
  ps -o etime= -p "$1" 2>/dev/null | awk '{
    n = split($1, t, /[-:]/); d = 0
    if ($1 ~ /-/) { d = t[1]; s = 2 } else s = 1
    secs = 0
    for (i = s; i <= n; i++) secs = secs * 60 + t[i]
    print d * 86400 + secs
  }'
}

pointer_alive() {
  local pid=$1 recorded=$2 actual
  kill -0 "$pid" 2>/dev/null || return 1
  actual=$(proc_start "$pid")
  [ -z "$actual" ] || [ -z "$recorded" ] || [ "$actual" = "$recorded" ]
}

remote_control_sessions() {
  local pointer pid recorded id env cwd elapsed
  for pointer in "$CLAUDE_DIR"/projects/*/bridge-pointer.json; do
    [ -f "$pointer" ] || continue
    pid=$(jq -r '.pid // empty' "$pointer" 2>/dev/null) || continue
    recorded=$(jq -r '.procStart // empty' "$pointer")
    id=$(jq -r '.sessionId // empty' "$pointer")
    env=$(jq -r '.environmentId // empty' "$pointer")
    [[ "$id" =~ ^session_[A-Za-z0-9]+$ ]] || continue
    [[ "$env" =~ ^env_[A-Za-z0-9]+$ ]] || continue
    if [ -z "$pid" ] || ! pointer_alive "$pid" "$recorded"; then continue; fi
    cwd=$(pid_cwd "$pid")
    [ -n "$cwd" ] && [ -d "$cwd" ] || continue
    elapsed=$(elapsed_seconds "$pid" || true)
    jq -n --arg cwd "$cwd" --arg id "$id" --arg env "$env" \
      --arg elapsed "$elapsed" --argjson now "$now" '{
        cwd: $cwd, sessionId: $id, title: "Remote Control", status: "idle", kind: "remote-control",
        startedAt: (if ($elapsed | test("^[0-9]+$")) then $now - ($elapsed | tonumber) else null end),
        remote: true, url: ("https://claude.ai/code?environment=" + $env)
      }'
  done
}

bridge_sessions() {
  local f
  for f in "$CLAUDE_DIR"/sessions/*.json; do
    [ -f "$f" ] || continue
    jq -c 'select(.pid and .sessionId and (.bridgeSessionId // "" | test("^session_[A-Za-z0-9]+$")))
      | {key: "\(.pid):\(.sessionId)", value: .bridgeSessionId}' "$f" 2>/dev/null || true
  done | jq -s 'from_entries'
}

transcript_title() {
  local file=$1 title
  [ -f "$file" ] || return 0
  title=$(grep -h '"type":"custom-title"' "$file" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)
  [ -n "$title" ] || title=$(grep -h '"type":"ai-title"' "$file" | tail -n 1 | jq -r '.aiTitle // empty' 2>/dev/null)
  [ -n "$title" ] || title=$(head -n 400 "$file" | jq -r '
    select(.type == "user" and (.message.content | type) == "string" and (.message.content | startswith("<") | not))
    | .message.content' 2>/dev/null | head -n 1 | cut -c1-80)
  printf '%s' "$title" | tr '\t\n' '  '
}

transcript_tokens() {
  local id=$1 file=$2 cache="$USAGE_DIR/tokens/$1.json" key
  [ -f "$file" ] || return 0
  key="$(wc -c <"$file" | tr -d ' '):$(mtime "$file")"
  if [ -f "$cache" ] && jq -e --arg k "$key" '.key == $k' "$cache" >/dev/null 2>&1; then
    jq -c '.tokens' "$cache"
    return
  fi
  grep -F '"usage"' "$file" | jq -R -n -c '
    reduce (inputs | fromjson? | select(.type == "assistant" and .message.id and .message.usage)) as $l
      ({}; .[$l.message.id] = $l.message.usage)
    | [.[]] | def total(f): map(f // 0) | add // 0;
    {messages: length, input: total(.input_tokens), cacheWrite: total(.cache_creation_input_tokens),
     cacheRead: total(.cache_read_input_tokens), output: total(.output_tokens)}' >"$work/tokens" 2>/dev/null || return 0
  mkdir -p "$USAGE_DIR/tokens"
  jq -c --arg k "$key" '{key: $k, tokens: .}' "$work/tokens" >"$cache.$$" && mv "$cache.$$" "$cache"
  cat "$work/tokens"
}

resolve_path() {
  local name=$1 recorded root
  recorded=$(repo_path_file "$name")
  if [ -f "$recorded" ] && [ -d "$(cat "$recorded")" ]; then
    cat "$recorded"
    return
  fi
  for root in $ROOTS; do
    if [ -d "$root/$name/.git" ]; then
      printf '%s\n' "$root/$name"
      return
    fi
  done
}

parse_status() {
  awk '
    /^# / && !titled { titled = 1; next }
    /^## / { sec = tolower(substr($0, 4)); sub(/[[:space:]]+$/, "", sec); next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      if (sec == "") {
        if (!described) { sub(/^> ?/, "", line); print "desc\t" line; described = 1 }
        next
      }
      if (match(line, /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/)) {
        print sec "\t" substr(line, RLENGTH + 1)
      } else {
        sub(/^[[:space:]]+/, "", line)
        print sec "+\t" line
      }
    }
  ' "$1"
}

now=$(date +%s)
sessions_json >"$work/agents.json"
jq -e 'type == "array"' "$work/agents.json" >/dev/null 2>&1 || echo '[]' >"$work/agents.json"
remote_control_sessions >"$work/remote-control.jsonl"
jq -s '.[0] + .[1:]' "$work/agents.json" "$work/remote-control.jsonl" >"$work/sessions.json"
bridge_sessions >"$work/bridges.json"

: >"$work/titles.tsv"
: >"$work/usage.jsonl"
jq -r '.[] | select(.kind != "remote-control" and .sessionId and .cwd) | [.sessionId, .cwd] | @tsv' "$work/sessions.json" |
  while IFS=$'\t' read -r id cwd; do
    transcript="$CLAUDE_DIR/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')/$id.jsonl"
    title=$(transcript_title "$transcript")
    if [ -n "$title" ]; then
      printf '%s\t%s\n' "$id" "$title" >>"$work/titles.tsv"
    fi
    [[ "$id" =~ ^[A-Za-z0-9-]+$ ]] || continue
    tokens=$(transcript_tokens "$id" "$transcript")
    cost="$USAGE_DIR/sessions/$id.json"
    [ -f "$cost" ] || cost=/dev/null
    jq -c -n --arg id "$id" --argjson tokens "${tokens:-null}" --slurpfile cost "$cost" \
      '{id: $id, tokens: $tokens, costUsd: ($cost[0].costUsd // null)} | select(.tokens != null or .costUsd != null)' >>"$work/usage.jsonl" 2>/dev/null || true
  done
[ ! -d "$USAGE_DIR" ] || find "$USAGE_DIR/sessions" "$USAGE_DIR/tokens" -type f -mtime +30 -exec rm -f {} + 2>/dev/null || true
remote_control=false
"$PLUGIN_ROOT/scripts/start-session.sh" --probe 2>/dev/null | jq -e '.remoteControl == true' >/dev/null 2>&1 && remote_control=true
limits="$USAGE_DIR/limits.json"
jq -e 'type == "object"' "$limits" >/dev/null 2>&1 || limits=/dev/null

: >"$work/session-repos.tsv"
jq -r '.[].cwd // empty' "$work/sessions.json" | sort -u | while IFS= read -r cwd; do
  [ -d "$cwd" ] || continue
  common=$(repo_common_dir "$cwd") || continue
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
  printf '%s\t%s\t%s\t%s\t%s\n' "$cwd" "$(basename "$(dirname "$common")")" "$(dirname "$common")" "$top" "$branch" >>"$work/session-repos.tsv"
done

{
  for file in "$STATUS_DIR"/*.md; do
    [ -e "$file" ] || continue
    name=$(basename "$file" .md)
    case "$name" in _*) continue ;; esac
    printf '%s\n' "$name"
  done
  cut -f2 "$work/session-repos.tsv"
} | sort -u >"$work/names"

while IFS= read -r name; do
  file=$(status_file "$name")
  path=$(resolve_path "$name")
  [ -n "$path" ] || path=$(awk -F '\t' -v n="$name" '$2 == n { print $3; exit }' "$work/session-repos.tsv")
  [ -n "$path" ] || path="${ROOTS%% *}/$name"
  if [ -f "$file" ]; then
    has_status=true
    mt=$(mtime "$file")
    bt=$(btime "$file")
    parsed=$(parse_status "$file")
  else
    has_status=false
    mt=0
    bt=0
    parsed=""
  fi
  stale=false
  if [ "$has_status" = true ] && [ -n "$path" ] && [ -d "$path" ] && [ "$(newest_change "$path")" -gt "$mt" ]; then
    stale=true
  fi
  jq -n \
    --arg name "$name" --arg path "$path" --arg home "$HOME" --arg parsed "$parsed" \
    --argjson hasStatus "$has_status" --argjson mt "$mt" --argjson bt "$bt" \
    --argjson stale "$stale" --argjson now "$now" '
    ($parsed | split("\n") | map(select(length > 0) | index("\t") as $i | {k: .[:$i], v: .[$i + 1:]})) as $rows
    | (reduce $rows[] as $r ({};
        if ($r.k | endswith("+")) then
          ($r.k | rtrimstr("+")) as $k
          | .[$k] |= (if (. // []) | length > 0 then .[:-1] + [.[-1] + " " + $r.v] else [$r.v] end)
        else .[$r.k] += [$r.v] end)) as $s
    | {
        name: $name,
        path: (if ($path | startswith($home + "/")) then "~" + ($path | ltrimstr($home)) else $path end),
        hasStatus: $hasStatus,
        desc: (($s.desc // [""])[0] | if test("^\\(.*description\\)$") then "" else . end),
        now: (($s.now // []) | join(" ")),
        next: (($s.next // []) | map(select(test("^\\(none yet\\)$") | not))),
        blocked: (($s.blocked // [])
          | map(select(test("^none\\.?$"; "i") | not)
            | (capture("^(?<text>.*?)\\s*\\(since (?<since>\\d{4}-\\d{2}-\\d{2})\\)\\s*$") // {text: ., since: null}))),
        updatedAt: (if $hasStatus then ($mt | todate) else null end),
        summary: (($s["last updated"] // [""])[0]
          | sub("^\\d{4}-\\d{2}-\\d{2}:?\\s*"; "")
          | if test("^\\(not yet updated\\)$") then "" else . end),
        stale: $stale,
        isNew: ($bt > 0 and ($now - $bt) < 86400)
      }'
done <"$work/names" >"$work/projects.jsonl"

jq -n \
  --slurpfile projects "$work/projects.jsonl" \
  --slurpfile sessions "$work/sessions.json" \
  --slurpfile bridges "$work/bridges.json" \
  --slurpfile usage "$work/usage.jsonl" \
  --slurpfile limits "$limits" \
  --rawfile repos "$work/session-repos.tsv" \
  --rawfile titles "$work/titles.tsv" \
  --arg home "$HOME" \
  --arg host "$(hostname -s 2>/dev/null || hostname)" \
  --arg claude "$(command -v claude 2>/dev/null || true)" \
  --argjson rc "$remote_control" \
  --argjson now "$now" --argjson interval "$INTERVAL" '
  ($repos | split("\n") | map(select(length > 0) | split("\t")
    | {key: .[0], value: {name: .[1], main: .[2], top: .[3], branch: .[4]}}) | from_entries) as $repoOf
  | ($titles | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $titleOf
  | ($usage | map({key: .id, value: del(.id)}) | from_entries) as $usageOf
  | def tilde: if startswith($home + "/") then "~" + ltrimstr($home) else . end;
    def state:
      {busy: "working", running: "working", working: "working",
       waiting: "input", input: "input", blocked: "input",
       idle: "idle",
       completed: "done", done: "done", finished: "done", success: "done",
       failed: "failed", error: "failed", errored: "failed"}[(.status // .state // "" | ascii_downcase)] // "stopped";
    def window: if type == "object" and (.resets_at // 0) > $now
      then {usedPercentage: .used_percentage, resetsAt: (.resets_at | todate), usedUsd: .used_usd, limitUsd: .limit_usd, period: .period}
        | with_entries(select(.value != null))
      else null end;
    def iso: if . == null then null elif type == "number" then (if . > 100000000000 then . / 1000 else . end | floor | todate) else . end;
    ($sessions[0] | map(select(.cwd and $repoOf[.cwd]) | $repoOf[.cwd] as $r
      | $bridges[0]["\(.pid):\(.sessionId)"] as $bridge | {
      repo: $r.name,
      id: .sessionId,
      title: ($titleOf[.sessionId] // .title // .name // ""),
      worktree: (if $r.top != $r.main then {name: ($r.top | split("/") | last), branch: (if $r.branch == "" then null else $r.branch end)} else null end),
      dir: ($r.top | tilde),
      state: state,
      kind: (.kind // "interactive"),
      waitingFor: (.waitingFor // null),
      cwd: .cwd,
      startedAt: (.startedAt | iso),
      lastActivityAt: ((.lastActivityAt // .updatedAt // .endedAt // .startedAt) | iso),
      remote: (.remote // ($bridge != null)),
      url: (.url // (if $bridge then "https://claude.ai/code/" + $bridge else null end)),
      usage: ($usageOf[.sessionId] // null)
    })) as $all
  | {
      generatedAt: ($now | todate),
      host: $host,
      claude: (if $claude == "" then null else ($claude | tilde) end),
      remoteControl: $rc,
      intervalSeconds: $interval,
      limits: ($limits[0] // null
        | if . == null then null
          else {fiveHour: (.fiveHour | window), sevenDay: (.sevenDay | window), spendLimit: (.spendLimit | window)}
            | with_entries(select(.value != null))
            | if . == {} then null else . + {updatedAt: ($limits[0].updatedAt | iso)} end
          end),
      projects: [$projects[] | . as $p | . + {sessions: [$all[] | select(.repo == $p.name) | del(.repo)]}]
    }' >"$work/status.json"

mkdir -p "$(dirname "$OUT")"
mv "$work/status.json" "$OUT.tmp.$$"
mv "$OUT.tmp.$$" "$OUT"
