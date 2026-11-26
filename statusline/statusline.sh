#!/usr/bin/env bash
# Claude Code statusline — model | effort | context% | 5h limit | 7d limit
input=$(cat)

# One jq call, one field per line. Do NOT use `IFS=$'\t' read` here: tab is an
# IFS whitespace char, so consecutive/leading tabs collapse and every field
# shifts left as soon as one value is empty. mapfile splits strictly.
mapfile -t F < <(
  jq -r '[.model.display_name, .effort.level, .context_window.used_percentage,
          .rate_limits.five_hour.used_percentage, .rate_limits.five_hour.resets_at,
          .rate_limits.seven_day.used_percentage, .rate_limits.seven_day.resets_at]
         | map(. // "") | .[]' <<<"$input"
)
model=${F[0]-}; effort=${F[1]-}; used=${F[2]-}
fh=${F[3]-}; fhr=${F[4]-}; sd=${F[5]-}; sdr=${F[6]-}

now=$(date +%s)
R=$'\e[0m'; DIM=$'\e[2m'
GREEN=$'\e[32m'; AMBER=$'\e[33m'; RED=$'\e[31m'

pct() {                                   # raw percent -> coloured "NN%"
  [ -z "$1" ] && return
  local n c
  n=$(printf '%.0f' "$1" 2>/dev/null) || return
  c=$GREEN
  [ "$n" -ge 70 ] && c=$AMBER
  [ "$n" -ge 90 ] && c=$RED
  printf '%s%d%%%s' "$c" "$n" "$R"
}

eta() {                                   # epoch, divisor, suffix -> "2.4h"
  [ -z "$1" ] && return
  local v=$(( ( ${1%.*} - now ) * 10 / $2 ))
  [ "$v" -lt 0 ] && v=0
  printf '%d.%d%s' $((v / 10)) $((v % 10)) "$3"
}

parts=()
[ -n "$model" ]  && parts+=("$model")
[ -n "$effort" ] && parts+=("${DIM}${effort}${R}")
[ -n "$used" ]   && parts+=("$(pct "$used")")

if [ -n "$fh" ]; then
  s="5h: $(pct "$fh")"
  t=$(eta "$fhr" 3600 h); [ -n "$t" ] && s+=" ${DIM}(${t})${R}"
  parts+=("$s")
fi
if [ -n "$sd" ]; then
  s="7d: $(pct "$sd")"
  t=$(eta "$sdr" 86400 d); [ -n "$t" ] && s+=" ${DIM}(${t})${R}"
  parts+=("$s")
fi

out=""
for p in "${parts[@]}"; do
  [ -n "$out" ] && out+="${DIM} | ${R}"
  out+="$p"
done
printf '%s' "$out"
