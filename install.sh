#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT
readonly STATUS_DIR="$HOME/.project-status"
readonly SETTINGS="$HOME/.claude/settings.json"
readonly BACKUP_DIR="$HOME/.claude/backups"
readonly EDIT_RULE="Edit(/$STATUS_DIR/**)"
readonly PLUGIN_ID="project-status@project-status"

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null || die "jq is required (macOS: brew install jq, Debian/Ubuntu: sudo apt install jq, SteamOS: use brew or nix in \$HOME)"
command -v git >/dev/null || die "git is required"
command -v claude >/dev/null || die "the claude CLI is required"

mkdir -p "$STATUS_DIR" "$BACKUP_DIR"
[ -e "$STATUS_DIR/_template.md" ] || cp "$REPO_ROOT/template.md" "$STATUS_DIR/_template.md"
[ -e "$STATUS_DIR/_rules.md" ] || cp "$REPO_ROOT/RULES.md" "$STATUS_DIR/_rules.md"

[ -s "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON; fix it and re-run"
cp "$SETTINGS" "$BACKUP_DIR/settings.json.project-status.$(date +%Y%m%d-%H%M%S)"

add_permission() {
  local key=$1 value=$2
  jq -e --arg k "$key" --arg v "$value" '(.permissions[$k] // []) | index($v)' "$SETTINGS" >/dev/null && return 0
  merged=$(jq --arg k "$key" --arg v "$value" '
    .permissions[$k] = ((.permissions[$k] // []) as $a | $a + ([$v] - $a))
  ' "$SETTINGS")
  printf '%s\n' "$merged" >"$SETTINGS"
  touch "$STATUS_DIR/.added-$key"
}

add_permission additionalDirectories "$STATUS_DIR"
add_permission allow "$EDIT_RULE"

if jq -e '.statusLine == null' "$SETTINGS" >/dev/null; then
  merged=$(jq --arg c "$REPO_ROOT/scripts/statusline.sh" '.statusLine = {type: "command", command: $c}' "$SETTINGS")
  printf '%s\n' "$merged" >"$SETTINGS"
  touch "$STATUS_DIR/.added-statusLine"
elif ! jq -e --arg c "$REPO_ROOT/scripts/statusline.sh" '.statusLine.command // "" | startswith($c)' "$SETTINGS" >/dev/null; then
  printf 'install.sh: kept your existing statusLine, so the dashboard gets no plan limits. To record them and keep yours, set statusLine.command to:\n  %s %s\n' \
    "$REPO_ROOT/scripts/statusline.sh" "$(jq -r '.statusLine.command // ""' "$SETTINGS")" >&2
fi

readonly CLI_LINK="$HOME/.local/bin/project-status"
if [ "$(readlink "$CLI_LINK" 2>/dev/null)" != "$REPO_ROOT/bin/project-status" ]; then
  if [ -e "$CLI_LINK" ] || [ -L "$CLI_LINK" ]; then
    printf 'install.sh: %s already exists, so the project-status CLI was not linked\n' "$CLI_LINK" >&2
  else
    mkdir -p "$(dirname "$CLI_LINK")"
    ln -s "$REPO_ROOT/bin/project-status" "$CLI_LINK"
    touch "$STATUS_DIR/.added-cli"
  fi
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) printf "install.sh: add ~/.local/bin to PATH to use the project-status CLI:\n  export PATH=\"\$HOME/.local/bin:\$PATH\"\n" >&2 ;;
esac

if ! claude plugin marketplace list --json 2>/dev/null | jq -e '.[] | select(.name == "project-status")' >/dev/null; then
  claude plugin marketplace add "$REPO_ROOT"
fi

if ! claude plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" '.[] | select(.id == $id and .scope == "user")' >/dev/null; then
  claude plugin install "$PLUGIN_ID" --scope user
fi

printf 'project-status installed. Status files: %s\n' "$STATUS_DIR"
