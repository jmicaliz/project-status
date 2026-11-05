#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly USAGE_DIR="$STATUS_DIR/.usage"

input=$(cat)
now=$(date +%s)

fields=$(jq -r --argjson now "$now" '
  def pct: if type == "number" then (. + 0.5 | floor | tostring) + "%" else empty end;
  def window: if type == "object" and (.resets_at // 0) > $now then . else null end;
  (.rate_limits // {}) as $rl
  | {fiveHour: ($rl.five_hour | window), sevenDay: ($rl.seven_day | window), spendLimit: ($rl.spend_limit | window)} as $w
  | [
      ([("5h " + ($w.fiveHour.used_percentage | pct)), ("7d " + ($w.sevenDay.used_percentage | pct)),
        ("spend " + ($w.spendLimit.used_percentage | pct)),
        (.cost.total_cost_usd | if type == "number" and . > 0 then "$" + ((. * 100 + 0.5 | floor) / 100 | tostring) else empty end)]
       | join(" · ")),
      (if ($w | map(values) | length) > 0 then $w + {updatedAt: $now} | tojson else "" end),
      (.session_id // "" | tostring),
      ({costUsd: (.cost.total_cost_usd // null), updatedAt: $now} | tojson)
    ] | join("\u001f")' <<<"$input" 2>/dev/null) || fields=""

# A unit separator, not tabs: IFS whitespace would collapse the empty fields.
IFS=$'\x1f' read -r line limits session cost <<<"$fields"

write() {
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 0
  printf '%s\n' "$2" >"$1.$$" 2>/dev/null && mv "$1.$$" "$1" 2>/dev/null
}

[ -z "$limits" ] || write "$USAGE_DIR/limits.json" "$limits"
[[ "$session" =~ ^[A-Za-z0-9-]+$ ]] && write "$USAGE_DIR/sessions/$session.json" "$cost"
if [ $# -gt 0 ]; then
  printf '%s' "$input" | "$@"
elif [ -n "$line" ]; then
  printf '%s\n' "$line"
fi
