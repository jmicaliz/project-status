#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly MAX_CONTEXT=9500

input=$(cat)
cwd=$(hook_cwd "$input")
[ -n "$cwd" ] || exit 0
repo=$(repo_name "$cwd") || exit 0
file=$(status_file "$repo")

render_template() {
  REPO="$repo" awk '{
    out = ""
    while ((i = index($0, "{{REPO}}")) > 0) {
      out = out substr($0, 1, i - 1) ENVIRON["REPO"]
      $0 = substr($0, i + 8)
    }
    print out $0
  }' "$(template_file)"
}

mkdir -p "$STATUS_DIR/.repos"
dirname "$(repo_common_dir "$cwd")" >"$(repo_path_file "$repo")"

if [ ! -e "$file" ]; then
  (set -C; render_template >"$file") 2>/dev/null || true
fi

rules=$(cat "$(rules_file)")
contents=$(cat "$file")
header="Project status file for repo \"$repo\": $file"
if grep -qxF "$DESC_PLACEHOLDER" "$file"; then
  header="$header

Action needed this session: the description line in the status file is still the placeholder \"$DESC_PLACEHOLDER\". In your first turn, replace it with one plain line describing this project (read the README or top-level files if you need to), even if no code changes."
fi
context=$(printf '%s\n\n%s\n\n<project-status-contents path="%s">\n%s\n</project-status-contents>' "$header" "$rules" "$file" "$contents")

if [ "${#context}" -gt "$MAX_CONTEXT" ]; then
  context="${context:0:$MAX_CONTEXT}"$'\n[truncated: read the full file at '"$file"']'
fi

jq -n --arg ctx "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
