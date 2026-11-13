STATUS_DIR="${PROJECT_STATUS_DIR:-$HOME/.project-status}"
# shellcheck disable=SC2034 # read by the scripts that source this file
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

hook_cwd() {
  jq -r '.cwd // empty' <<<"$1"
}

repo_common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

repo_name() {
  local common
  common=$(repo_common_dir "$1") || return 1
  basename "$(dirname "$common")"
}

# shellcheck disable=SC2034 # read by the scripts that source this file
readonly DESC_PLACEHOLDER="(one-line project description)"

status_file() {
  printf '%s/%s.md\n' "$STATUS_DIR" "$1"
}

user_or_default() {
  if [ -f "$STATUS_DIR/$1" ]; then
    printf '%s\n' "$STATUS_DIR/$1"
  else
    printf '%s\n' "$PLUGIN_ROOT/$2"
  fi
}

rules_file() {
  user_or_default _rules.md RULES.md
}

template_file() {
  user_or_default _template.md template.md
}

parse_status() {
  awk '
    FNR == 1 { titled = 0; described = 0; sec = ""; name = FILENAME; sub(/^.*\//, "", name); sub(/\.md$/, "", name) }
    /^# / && !titled { titled = 1; next }
    /^## / { sec = substr($0, 4); sub(/[[:space:]]+$/, "", sec); print name "\t#\t" sec; sec = tolower(sec); next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      if (sec == "") {
        if (!described) { sub(/^> ?/, "", line); print name "\tdesc\t" line; described = 1 }
        next
      }
      if (match(line, /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/)) {
        print name "\t" sec "\t" substr(line, RLENGTH + 1)
      } else {
        sub(/^[[:space:]]+/, "", line)
        print name "\t" sec "+\t" line
      }
    }
  ' "$@"
}

# shellcheck disable=SC2016,SC2034 # jq source, read by the scripts that source this file
STATUS_JQ='
  def status_sections: reduce .[] as $r ({};
    if ($r.k | endswith("+")) then
      ($r.k | rtrimstr("+")) as $k
      | .[$k] |= (if (. // []) | length > 0 then .[:-1] + [.[-1] + " " + $r.v] else [$r.v] end)
    else .[$r.k] += [$r.v] end);
  def blocked_item: capture("^(?<text>.*?)\\s*\\(since (?<since>\\d{4}-\\d{2}-\\d{2})\\)\\s*$") // {text: ., since: null};
'

repo_path_file() {
  printf '%s/.repos/%s\n' "$STATUS_DIR" "$1"
}

# shellcheck disable=SC2034 # read by the scripts that source this file
if stat -c %Y / >/dev/null 2>&1; then
  MTIME_FLAGS=(-c %Y)
  BTIME_FLAGS=(-c %W)
  SIZE_MTIME_PATH_FLAGS=(-c '%s:%Y %n')
  TIMES_PATH_FLAGS=(-c '%Y %W %n')
else
  MTIME_FLAGS=(-f %m)
  BTIME_FLAGS=(-f %B)
  SIZE_MTIME_PATH_FLAGS=(-f '%z:%m %N')
  TIMES_PATH_FLAGS=(-f '%m %B %N')
fi

mtime() {
  stat "${MTIME_FLAGS[@]}" "$@"
}

proc_start() {
  [ -r "/proc/$1/stat" ] || return 0
  sed 's/^.*) //' "/proc/$1/stat" | awk '{ print $20 }'
}

btime() {
  stat "${BTIME_FLAGS[@]}" "$@" 2>/dev/null || echo 0
}

changed_paths() {
  local toplevel=$1 entry code skip_next=0
  git -C "$toplevel" status --porcelain -z --untracked-files=all 2>/dev/null |
    while IFS= read -r -d '' entry; do
      if [ "$skip_next" = 1 ]; then
        skip_next=0
        continue
      fi
      code=${entry:0:2}
      case "$code" in
        R* | C*) skip_next=1 ;;
      esac
      case "$code" in
        *D*) continue ;;
      esac
      printf '%s\0' "$toplevel/${entry:3}"
    done
}

newest_change() {
  local toplevel=$1 newest newest_file
  newest=$(git -C "$toplevel" log -1 --format=%ct 2>/dev/null || echo 0)
  newest_file=$(changed_paths "$toplevel" | xargs -0 stat "${MTIME_FLAGS[@]}" 2>/dev/null | sort -n | tail -n 1 || true)
  if [ -n "$newest_file" ] && [ "$newest_file" -gt "${newest:-0}" ]; then
    newest=$newest_file
  fi
  echo "${newest:-0}"
}
