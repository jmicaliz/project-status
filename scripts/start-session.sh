#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly CLAUDE_BIN=${PROJECT_STATUS_CLAUDE:-claude}
readonly CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

die() {
  printf 'start-session.sh: %s\n' "$*" >&2
  exit 1
}

auth_env() {
  env
  local f
  for f in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json"; do
    [ -f "$f" ] || continue
    jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' "$f" 2>/dev/null || true
  done
}

remote_control_available() {
  case "${PROJECT_STATUS_REMOTE_CONTROL:-auto}" in
    on) return 0 ;;
    off) return 1 ;;
  esac
  if [ -f "$CLAUDE_DIR/settings.json" ] && jq -e '.apiKeyHelper or .disableRemoteControl' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    return 1
  fi
  local vars
  vars=$(auth_env)
  if grep -Eq '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX|CLAUDE_CODE_USE_FOUNDRY|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_GROWTHBOOK)=.' <<<"$vars"; then
    return 1
  fi
  ! grep -E '^ANTHROPIC_BASE_URL=.' <<<"$vars" | grep -Evq '^ANTHROPIC_BASE_URL=https://api\.anthropic\.com/?$'
}

if [ "${1:-}" = --probe ]; then
  if remote_control_available; then rc=true; else rc=false; fi
  jq -n --argjson rc "$rc" '{remoteControl: $rc}'
  exit 0
fi

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: start-session.sh <repo> [prompt] | --probe"
repo=$1
prompt=${2:-}
if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$repo" = . ] || [ "$repo" = .. ] || [[ "$repo" == -* ]]; then
  die "invalid repo name: $repo"
fi
recorded=$(repo_path_file "$repo")
[ -f "$recorded" ] || die "unknown repo: $repo (start a Claude session in it once so it gets recorded)"
path=$(cat "$recorded")
[ -d "$path" ] || die "repo path no longer exists: $path"

title=""
if [ -n "$prompt" ]; then
  title=$(printf '%s' "$prompt" | tr '\t\n' '  ' | sed 's/^[- ]*//' | cut -c1-60)
  [ -n "$title" ] || title="$repo session"
  case "$prompt" in -*) prompt=" $prompt" ;; esac
fi

worktree=""
args=(--bg)
[ -z "$title" ] || args+=(-n "$title")
if [ "${PROJECT_STATUS_WORKTREE:-1}" = 1 ]; then
  worktree="ps-$(date +%Y%m%d-%H%M%S)"
  args+=(--worktree "$worktree")
fi
rc=false
if remote_control_available; then
  rc=true
  if [ -n "$title" ]; then
    args+=(--remote-control "$title")
  else
    args+=(--remote-control)
  fi
fi
[ -z "$prompt" ] || args+=("$prompt")

if ! out=$(cd "$path" && "$CLAUDE_BIN" "${args[@]}" 2>&1 </dev/null); then
  die "$(printf '%s' "$out" | tail -n 1)"
fi
id=$(printf '%s\n' "$out" | awk '$1 == "backgrounded" { print $3; exit }')
[ -n "$id" ] || die "$(printf '%s' "$out" | tail -n 1)"

jq -n --arg id "$id" --arg repo "$repo" --arg title "$title" --arg worktree "$worktree" --argjson rc "$rc" \
  '{id: $id, repo: $repo, title: $title, worktree: (if $worktree == "" then null else $worktree end), remoteControl: $rc}'
