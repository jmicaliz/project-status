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

jq_files() {
  local filter=$1 out f
  shift
  [ $# -gt 0 ] || return 0
  if out=$(jq -c "$filter" "$@" 2>/dev/null); then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  for f in "$@"; do jq -c "$filter" "$f" 2>/dev/null || true; done
}

readonly FILE_ID='input_filename | split("/") | last | sub("\\.[a-z]+$"; "")'

bridge_sessions() {
  local f files=()
  for f in "$CLAUDE_DIR"/sessions/*.json; do
    [ -f "$f" ] && files+=("$f")
  done
  jq_files 'select(.pid and .sessionId and (.bridgeSessionId // "" | test("^session_[A-Za-z0-9]+$")))
    | {key: "\(.pid):\(.sessionId)", value: .bridgeSessionId}' ${files[@]+"${files[@]}"} | jq -s 'from_entries'
}

transcript_titles() {
  [ $# -gt 0 ] || return 0
  grep -H --null -E '"type":"(custom|ai)-title"' "$@" 2>/dev/null | jq -R -n -r '
    reduce (inputs | index("\u0000") as $i | {f: .[:$i], l: (.[$i + 1:] | fromjson? // empty)}) as $r ({};
      if $r.l.type == "custom-title" then .[$r.f].custom = ($r.l.customTitle // "")
      elif $r.l.type == "ai-title" then .[$r.f].ai = ($r.l.aiTitle // "")
      else . end)
    | to_entries[]
    | ((.value.custom // "") | if . == "" then null else . end) // ((.value.ai // "") | if . == "" then null else . end) // empty
      as $title
    | (.key | split("/") | last | rtrimstr(".jsonl")) + "\t" + ($title | gsub("[\t\n]"; " "))' || true
}

first_prompts() {
  [ $# -gt 0 ] || return 0
  awk 'FNR > 400 { nextfile } { print FILENAME "\t" $0 }' "$@" 2>/dev/null | jq -R -n -r '
    reduce (inputs | index("\t") as $i | {f: .[:$i], l: (.[$i + 1:] | fromjson? // empty)}
      | select(.l.type == "user" and (.l.message.content | type) == "string" and (.l.message.content | startswith("<") | not))) as $r
      ({}; .[$r.f] //= ($r.l.message.content | split("\n")[0] | .[:80]))
    | to_entries[] | select(.value != "")
    | (.key | split("/") | last | rtrimstr(".jsonl")) + "\t" + (.value | gsub("\t"; " "))' || true
}

refresh_tokens() {
  local id=$1 key=$2 file=$3 cache="$USAGE_DIR/tokens/$1.json"
  if grep -F '"usage"' "$file" | jq -R -n -c --arg k "$key" '
    reduce (inputs | fromjson? | select(.type == "assistant" and .message.id and .message.usage)) as $l
      ({}; .[$l.message.id] = $l.message.usage)
    | [.[]] | def total(f): map(f // 0) | add // 0;
    {key: $k, tokens: {messages: length, input: total(.input_tokens), cacheWrite: total(.cache_creation_input_tokens),
     cacheRead: total(.cache_read_input_tokens), output: total(.output_tokens)}}' >"$cache.$$" 2>/dev/null; then
    mv "$cache.$$" "$cache"
  else
    rm -f "$cache.$$"
  fi
}

session_repo() {
  local cwd=$1 out common="" gitdir="" top="" head="" branch="" main
  out=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir --git-dir --show-toplevel 2>/dev/null || true)
  { IFS= read -r common; IFS= read -r gitdir; IFS= read -r top; } <<<"$out" || true
  [ -n "$common" ] || return 0
  [ -n "$top" ] || top=$cwd
  { IFS= read -r head || true; } <"$gitdir/HEAD" 2>/dev/null || true
  case "$head" in "ref: refs/heads/"*) branch=${head#ref: refs/heads/} ;; esac
  if [ "$branch" = .invalid ]; then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
  fi
  main=${common%/*}
  printf '%s\t%s\t%s\t%s\t%s\n' "$cwd" "${main##*/}" "$main" "$top" "$branch"
}

resolve_path() {
  local name=$1 recorded root path="" cwd repo main rest
  recorded=$(repo_path_file "$name")
  if [ -f "$recorded" ]; then
    { IFS= read -r path || true; } <"$recorded"
    if [ -n "$path" ] && [ -d "$path" ]; then
      printf '%s\n' "$path"
      return
    fi
  fi
  for root in $ROOTS; do
    if [ -d "$root/$name/.git" ]; then
      printf '%s\n' "$root/$name"
      return
    fi
  done
  while IFS=$'\t' read -r cwd repo main rest; do
    if [ "$repo" = "$name" ]; then
      printf '%s\n' "$main"
      return
    fi
  done <"$work/session-repos.tsv"
  printf '%s\n' "${ROOTS%% *}/$name"
}

now=$(date +%s)
sessions_json >"$work/agents.json"
jq -e 'type == "array"' "$work/agents.json" >/dev/null 2>&1 || echo '[]' >"$work/agents.json"
remote_control_sessions >"$work/remote-control.jsonl"
jq -s '.[0] + .[1:]' "$work/agents.json" "$work/remote-control.jsonl" >"$work/sessions.json"
bridge_sessions >"$work/bridges.json"

transcripts=()
while IFS=$'\t' read -r id cwd; do
  transcript="$CLAUDE_DIR/projects/${cwd//[^A-Za-z0-9]/-}/$id.jsonl"
  [ -f "$transcript" ] && transcripts+=("$transcript")
done < <(jq -r '.[] | select(.kind != "remote-control" and .sessionId and .cwd and (.sessionId | test("^[A-Za-z0-9-]+$"))) | [.sessionId, .cwd] | @tsv' "$work/sessions.json")

transcript_titles ${transcripts[@]+"${transcripts[@]}"} >"$work/titles.tsv"
untitled=()
for transcript in ${transcripts[@]+"${transcripts[@]}"}; do
  id=${transcript##*/}
  id=${id%.jsonl}
  grep -q "^$id"$'\t' "$work/titles.tsv" || untitled+=("$transcript")
done
first_prompts ${untitled[@]+"${untitled[@]}"} >>"$work/titles.tsv"

mkdir -p "$USAGE_DIR/tokens" "$USAGE_DIR/sessions" 2>/dev/null || true
if [ ${#transcripts[@]} -gt 0 ]; then
  stat "${SIZE_MTIME_PATH_FLAGS[@]}" "${transcripts[@]}" 2>/dev/null >"$work/transcript-keys" || true
  cached=()
  for transcript in "${transcripts[@]}"; do
    id=${transcript##*/}
    id=${id%.jsonl}
    [ -f "$USAGE_DIR/tokens/$id.json" ] && cached+=("$USAGE_DIR/tokens/$id.json")
  done
  jq_files "{id: ($FILE_ID), key}" ${cached[@]+"${cached[@]}"} | jq -r '[.id, .key] | @tsv' >"$work/cached-keys"
  while IFS=' ' read -r key transcript; do
    id=${transcript##*/}
    id=${id%.jsonl}
    grep -qxF "$id"$'\t'"$key" "$work/cached-keys" || refresh_tokens "$id" "$key" "$transcript" &
  done <"$work/transcript-keys"
  wait
fi
usage_files=()
for f in "$USAGE_DIR"/tokens/*.json "$USAGE_DIR"/sessions/*.json; do
  [ -f "$f" ] && usage_files+=("$f")
done
jq_files "{id: ($FILE_ID), kind: (input_filename | split(\"/\")[-2]), tokens, costUsd}" ${usage_files[@]+"${usage_files[@]}"} |
  jq -s -c 'reduce .[] as $u ({}; if $u.kind == "tokens" then .[$u.id].tokens = $u.tokens else .[$u.id].costUsd = $u.costUsd end)
    | to_entries[] | {id: .key, tokens: (.value.tokens // null), costUsd: (.value.costUsd // null)}
    | select(.tokens != null or .costUsd != null)' >"$work/usage.jsonl"
[ ! -d "$USAGE_DIR" ] || find "$USAGE_DIR/sessions" "$USAGE_DIR/tokens" -type f -mtime +30 -exec rm -f {} + 2>/dev/null || true
remote_control=false
"$PLUGIN_ROOT/scripts/start-session.sh" --probe 2>/dev/null | jq -e '.remoteControl == true' >/dev/null 2>&1 && remote_control=true
limits="$USAGE_DIR/limits.json"
jq -e 'type == "object"' "$limits" >/dev/null 2>&1 || limits=/dev/null

i=0
while IFS= read -r cwd; do
  [ -d "$cwd" ] || continue
  i=$((i + 1))
  session_repo "$cwd" >"$work/repo.$((100000 + i))" &
done < <(jq -r '.[].cwd // empty' "$work/sessions.json" | sort -u)
wait
cat /dev/null "$work"/repo.* >"$work/session-repos.tsv" 2>/dev/null || : >"$work/session-repos.tsv"

{
  for file in "$STATUS_DIR"/*.md; do
    [ -e "$file" ] || continue
    name=${file##*/}
    case "$name" in _*) continue ;; esac
    printf '%s\n' "${name%.md}"
  done
  cut -f2 "$work/session-repos.tsv"
} | sort -u >"$work/names"

status_files=()
while IFS= read -r name; do
  file=$(status_file "$name")
  [ -f "$file" ] && status_files+=("$file")
done <"$work/names"

: >"$work/parsed.tsv"
: >"$work/times"
if [ ${#status_files[@]} -gt 0 ]; then
  parse_status "${status_files[@]}" >"$work/parsed.tsv"
  stat "${TIMES_PATH_FLAGS[@]}" "${status_files[@]}" 2>/dev/null >"$work/times" || true
fi

: >"$work/paths.tsv"
while IFS= read -r name; do
  path=$(resolve_path "$name")
  printf '%s\t%s\n' "$name" "$path" >>"$work/paths.tsv"
  file=$(status_file "$name")
  if [ -f "$file" ] && [ -d "$path" ]; then
    { printf '%s\t%s\n' "$name" "$(newest_change "$path")" >"$work/newest.$name"; } &
  fi
done <"$work/names"
wait
cat /dev/null "$work"/newest.* >"$work/newest.tsv" 2>/dev/null || : >"$work/newest.tsv"

jq -n -c \
  --rawfile names "$work/names" --rawfile paths "$work/paths.tsv" --rawfile parsed "$work/parsed.tsv" \
  --rawfile times "$work/times" --rawfile newest "$work/newest.tsv" \
  --arg home "$HOME" --arg dir "$STATUS_DIR" --argjson now "$now" "$STATUS_JQ"'
  def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
  (rows($paths) | map({key: .[0], value: .[1]}) | from_entries) as $pathOf
  | (rows($newest) | map({key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries) as $newestOf
  | ($times | split("\n") | map(select(length > 0) | capture("^(?<m>[0-9]+) (?<b>[^ ]+) (?<f>.*)$")
      | {key: (.f | split("/") | last | rtrimstr(".md")), value: {mt: (.m | tonumber), bt: (.b | tonumber? // 0 | if . < 0 then 0 else . end)}})
      | from_entries) as $timesOf
  | (rows($parsed) | group_by(.[0]) | map({key: .[0][0], value: map({k: .[1], v: (.[2:] | join("\t"))})}) | from_entries) as $rowsOf
  | rows($names)[] | .[0] as $name
  | ($timesOf[$name] != null) as $hasStatus
  | ($timesOf[$name] // {mt: 0, bt: 0}) as $t
  | ($pathOf[$name] // "") as $path
  | ($rowsOf[$name] // [] | status_sections) as $s
  | {
      name: $name,
      path: (if ($path | startswith($home + "/")) then "~" + ($path | ltrimstr($home)) else $path end),
      hasStatus: $hasStatus,
      desc: (($s.desc // [""])[0] | if test("^\\(.*description\\)$") then "" else . end),
      now: (($s.now // []) | join(" ")),
      next: (($s.next // []) | map(select(test("^\\(none yet\\)$") | not))),
      blocked: (($s.blocked // [])
        | map(select(test("^none\\.?$"; "i") | not)
          | blocked_item)),
      updatedAt: (if $hasStatus then ($t.mt | todate) else null end),
      summary: (($s["last updated"] // [""])[0]
        | sub("^\\d{4}-\\d{2}-\\d{2}:?\\s*"; "")
        | if test("^\\(not yet updated\\)$") then "" else . end),
      stale: ($hasStatus and ($newestOf[$name] // 0) > $t.mt),
      isNew: ($t.bt > 0 and ($now - $t.bt) < 86400)
    }' >"$work/projects.jsonl"

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
      jobId: (.id // null),
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
