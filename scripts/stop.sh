#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
[ "$(jq -r '.stop_hook_active // false' <<<"$input")" = true ] && exit 0
cwd=$(hook_cwd "$input")
[ -n "$cwd" ] || exit 0
repo=$(repo_name "$cwd") || exit 0
file=$(status_file "$repo")
[ -e "$file" ] || exit 0
toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0

[ "$(newest_change "$toplevel")" -gt "$(mtime "$file")" ] || exit 0

reason="Code in this repo changed after the project status file was last updated. Before finishing, update $file following the project-status rules (Now / Next / Blocked / Last updated, under 40 lines, replace stale content, no log). Use the absolute path; do not create a status file inside the repo."
jq -n --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $reason}}'
