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

status_file() {
  printf '%s/%s.md\n' "$STATUS_DIR" "$1"
}

repo_path_file() {
  printf '%s/.repos/%s\n' "$STATUS_DIR" "$1"
}

if stat -c %Y / >/dev/null 2>&1; then
  MTIME_FLAGS=(-c %Y)
  BTIME_FLAGS=(-c %W)
else
  MTIME_FLAGS=(-f %m)
  BTIME_FLAGS=(-f %B)
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
