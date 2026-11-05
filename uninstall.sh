#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT
readonly STATUS_DIR="$HOME/.project-status"
readonly SETTINGS="$HOME/.claude/settings.json"
readonly BACKUP_DIR="$HOME/.claude/backups"
readonly EDIT_RULE="Edit(/$STATUS_DIR/**)"
readonly PLUGIN_ID="project-status@project-status"

command -v jq >/dev/null || { echo "uninstall.sh: jq is required" >&2; exit 1; }

if command -v claude >/dev/null; then
  if claude plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" '.[] | select(.id == $id)' >/dev/null; then
    claude plugin uninstall "$PLUGIN_ID" --scope user
  fi
  if claude plugin marketplace list --json 2>/dev/null | jq -e '.[] | select(.name == "project-status")' >/dev/null; then
    claude plugin marketplace remove project-status
  fi
fi

remove_permission() {
  local key=$1 value=$2
  [ -f "$STATUS_DIR/.added-$key" ] && [ -f "$SETTINGS" ] || return 0
  stripped=$(jq --arg k "$key" --arg v "$value" '
    if .permissions[$k] then
      .permissions[$k] -= [$v]
      | if .permissions[$k] == [] then del(.permissions[$k]) else . end
    else . end
  ' "$SETTINGS")
  printf '%s\n' "$stripped" >"$SETTINGS"
  rm -f "$STATUS_DIR/.added-$key"
}

if [ -f "$SETTINGS" ]; then
  mkdir -p "$BACKUP_DIR"
  cp "$SETTINGS" "$BACKUP_DIR/settings.json.project-status-uninstall.$(date +%Y%m%d-%H%M%S)"
fi
remove_permission additionalDirectories "$STATUS_DIR"
remove_permission allow "$EDIT_RULE"
if [ -f "$STATUS_DIR/.added-statusLine" ] && [ -f "$SETTINGS" ]; then
  stripped=$(jq --arg c "$REPO_ROOT/scripts/statusline.sh" 'if .statusLine.command == $c then del(.statusLine) else . end' "$SETTINGS")
  printf '%s\n' "$stripped" >"$SETTINGS"
  rm -f "$STATUS_DIR/.added-statusLine"
fi
if [ -f "$STATUS_DIR/.added-cli" ]; then
  [ "$(readlink "$HOME/.local/bin/project-status" 2>/dev/null)" != "$REPO_ROOT/bin/project-status" ] || rm -f "$HOME/.local/bin/project-status"
  rm -f "$STATUS_DIR/.added-cli"
fi
! cmp -s "$REPO_ROOT/template.md" "$STATUS_DIR/_template.md" || rm -f "$STATUS_DIR/_template.md"
! cmp -s "$REPO_ROOT/RULES.md" "$STATUS_DIR/_rules.md" || rm -f "$STATUS_DIR/_rules.md"
rm -rf "${STATUS_DIR:?}/.usage"
rm -rf "${STATUS_DIR:?}/.repos"
rm -f "$STATUS_DIR/.token"
rmdir "$STATUS_DIR" 2>/dev/null || true

printf 'project-status uninstalled. Status files in %s were kept.\n' "$STATUS_DIR"
