#!/usr/bin/env bash
#
# test-display-wake.sh — reproduce the DisplayPort wake fault on demand.
#
# The fault: a monitor comes back from blanking without delivering its EDID.
# The kernel then offers exactly one mode, 640x480, and that is what you get.
# No software recovers it — not `kscreen-doctor` toggling, not even
# `echo detect > /sys/class/drm/<connector>/status`. Only power-cycling the
# monitor does. See roles/power_management/README.md and state/README.md.
#
# Waiting 20 minutes for the real blank timeout makes this untestable, so this
# drives DPMS directly and counts how often each connector fails to come back.
# Run it before and after changing a cable: the failure RATE is the measurement,
# because the fault is intermittent and a single clean cycle proves nothing.
#
# Usage:
#   ./scripts/test-display-wake.sh [cycles] [seconds-off]
#
#   cycles       how many blank/wake cycles       (default 5)
#   seconds-off  how long to stay blanked         (default 60)
#
# The screens go dark while this runs — it does not lock the session, but do
# not run it while you need to see anything. Ctrl-C wakes them back up.

set -uo pipefail

CYCLES="${1:-5}"
OFF_SECS="${2:-60}"
ON_SETTLE=10          # seconds to allow link training after waking
HEALTHY_MIN_MODES=3   # a connector with <= 2 modes has delivered no EDID

command -v kscreen-doctor >/dev/null || { echo "kscreen-doctor not found" >&2; exit 1; }

# Always try to bring the screens back, even on Ctrl-C.
cleanup() { kscreen-doctor --dpms on >/dev/null 2>&1 || true; }
trap 'echo; echo "Interrupted — waking screens."; cleanup; exit 130' INT TERM

connectors() {
    for c in /sys/class/drm/card*-DP-*/ /sys/class/drm/card*-HDMI-*/; do
        [ -e "$c/status" ] || continue
        [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
        basename "$c"
    done
}

modes_for() { wc -l < "/sys/class/drm/$1/modes" 2>/dev/null || echo 0; }

printf 'Baseline:\n'
for c in $(connectors); do
    printf '  %-24s %s modes\n' "$c" "$(modes_for "$c")"
done
baseline="$(connectors)"
[ -n "$baseline" ] || { echo "No connected outputs — plug a monitor in first." >&2; exit 1; }

printf '\n%s cycles, %ss blanked, %ss settle. Screens will go dark.\n\n' \
    "$CYCLES" "$OFF_SECS" "$ON_SETTLE"

declare -A fails
for c in $baseline; do fails["$c"]=0; done
missing=0

for i in $(seq 1 "$CYCLES"); do
    kscreen-doctor --dpms off >/dev/null 2>&1
    sleep "$OFF_SECS"
    kscreen-doctor --dpms on >/dev/null 2>&1
    sleep "$ON_SETTLE"

    line="  cycle $i:"
    for c in $baseline; do
        if [ "$(cat "/sys/class/drm/$c/status" 2>/dev/null)" != connected ]; then
            line="$line  $c=GONE"
            fails["$c"]=$(( ${fails["$c"]} + 1 ))
            missing=1
            continue
        fi
        m="$(modes_for "$c")"
        if [ "$m" -lt "$HEALTHY_MIN_MODES" ]; then
            line="$line  $c=FAIL(${m} mode)"
            fails["$c"]=$(( ${fails["$c"]} + 1 ))
        else
            line="$line  $c=ok(${m})"
        fi
    done
    printf '%s\n' "$line"
done

printf '\nResult over %s cycles:\n' "$CYCLES"
worst=0
for c in $baseline; do
    n=${fails["$c"]}
    [ "$n" -gt "$worst" ] && worst="$n"
    printf '  %-24s %s/%s failed\n' "$c" "$n" "$CYCLES"
done

printf '\n'
if [ "$worst" -eq 0 ]; then
    printf 'No failures. Not proof of a fix on its own — the fault is\n'
    printf 'intermittent, so compare against the rate you measured BEFORE the\n'
    printf 'change, and re-run with more cycles or a longer blank if in doubt.\n'
else
    printf 'Reproduced. Power-cycle any failed monitor at its own button to\n'
    printf 'recover it; no software will.\n'
fi
[ "$missing" -eq 1 ] && printf '\nA connector disappeared entirely — that is the same fault, worse.\n'
exit 0
