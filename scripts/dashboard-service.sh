#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
readonly UNITS=(project-status-generate.service project-status-generate.timer project-status-web.service)
readonly AGENT_DIR="$HOME/Library/LaunchAgents"
readonly AGENTS=(com.project-status.generate com.project-status.web)
readonly LOG_DIR="$HOME/Library/Logs"
readonly PORT=${PORT:-8765}
readonly BIND=${BIND:-127.0.0.1}

die() {
  printf 'dashboard-service.sh: %s\n' "$*" >&2
  exit 1
}

tool_dirs() {
  local tool dirs=""
  for tool in claude git jq; do
    command -v "$tool" >/dev/null || die "$tool is required on PATH"
    case ":$dirs:" in
      *":$(dirname "$(command -v "$tool")"):"*) ;;
      *) dirs="$dirs:$(dirname "$(command -v "$tool")")" ;;
    esac
  done
  printf '%s:/usr/local/bin:/usr/bin:/bin\n' "${dirs#:}"
}

render() {
  local python path
  python=$(command -v python3) || die "python3 is required to serve the page"
  path=$(tool_dirs)
  sed -e "s|@ROOT@|$ROOT|g" -e "s|@PATH@|$path|g" -e "s|@PYTHON@|$python|g" \
    -e "s|@PORT@|$PORT|g" -e "s|@BIND@|$BIND|g" -e "s|@LOGS@|$LOG_DIR|g" "$1" >"$2"
}

announce() {
  local host=localhost
  [ "$BIND" = 127.0.0.1 ] || host=$(hostname -s 2>/dev/null || hostname)
  printf 'Dashboard: http://%s:%s/\n' "$host" "$PORT"
}

install_systemd() {
  local unit
  mkdir -p "$UNIT_DIR"
  for unit in "${UNITS[@]}"; do
    render "$ROOT/systemd/$unit" "$UNIT_DIR/$unit"
  done
  systemctl --user daemon-reload
  "$ROOT/scripts/generate-status.sh"
  systemctl --user enable --now project-status-generate.timer project-status-web.service
  announce
}

uninstall_systemd() {
  systemctl --user disable --now project-status-generate.timer project-status-web.service 2>/dev/null || true
  local unit
  for unit in "${UNITS[@]}"; do
    rm -f "$UNIT_DIR/$unit"
  done
  systemctl --user daemon-reload
}

install_launchd() {
  local agent domain
  domain="gui/$(id -u)"
  mkdir -p "$AGENT_DIR" "$LOG_DIR"
  "$ROOT/scripts/generate-status.sh"
  for agent in "${AGENTS[@]}"; do
    launchctl bootout "$domain/$agent" 2>/dev/null || true
    render "$ROOT/launchd/$agent.plist" "$AGENT_DIR/$agent.plist"
    launchctl bootstrap "$domain" "$AGENT_DIR/$agent.plist"
  done
  announce
}

uninstall_launchd() {
  local agent
  for agent in "${AGENTS[@]}"; do
    launchctl bootout "gui/$(id -u)/$agent" 2>/dev/null || true
    rm -f "$AGENT_DIR/$agent.plist"
  done
}

if [ "$(uname -s)" = Darwin ]; then
  manager=launchd
elif command -v systemctl >/dev/null; then
  manager=systemd
else
  manager=""
fi

case "${1:-}" in
  install)
    [ -n "$manager" ] || die "needs systemd (Linux) or launchd (macOS); use make serve instead"
    "install_$manager"
    ;;
  uninstall) [ -z "$manager" ] || "uninstall_$manager" ;;
  *) die "usage: $0 install|uninstall" ;;
esac
