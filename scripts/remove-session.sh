#!/usr/bin/env bash
set -euo pipefail

readonly CLAUDE_BIN=${PROJECT_STATUS_CLAUDE:-claude}

die() {
  printf 'remove-session.sh: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: remove-session.sh <session-id>"
[[ "$1" =~ ^[0-9a-f][0-9a-f-]{7,35}$ ]] || die "invalid session id: $1"

agents=$("$CLAUDE_BIN" agents --json --all 2>/dev/null) || die "couldn't list sessions"
job=$(jq -r --arg id "$1" 'first(.[] | select((.id == $id or .sessionId == $id) and .kind == "background") | .id) // empty' <<<"$agents" 2>/dev/null)
[ -n "$job" ] || die "not a background session that claude agents knows about: $1"

if ! out=$("$CLAUDE_BIN" rm "$job" 2>&1 </dev/null); then
  die "$(printf '%s' "$out" | tr -s ' \n' '  ' | sed 's/^ //; s/ $//')"
fi
jq -n --arg id "$job" '{id: $id, removed: true}'
