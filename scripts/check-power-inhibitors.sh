#!/usr/bin/env bash
#
# check-power-inhibitors.sh — answers "why isn't this machine sleeping?"
#
# Run it when the screens won't dim or the machine won't suspend. It prints
# what is blocking power management and flags anything left behind by an app
# that has already exited.
#
# Read-only. No sudo, no mutation.
#
# Why this script exists
# ----------------------
# Applications can ask the desktop not to blank the screen or suspend. That is
# normally correct — nobody wants a film or a game interrupted. Two things make
# it hard to diagnose by hand:
#
#   1. `systemd-inhibit --list` does NOT show these. It only lists logind
#      inhibitors. KDE tracks application requests in its own policy agent, so
#      the usual command shows nothing and everything looks fine.
#
#   2. The request can outlive the application. Killing a frozen game leaves
#      its request held, because the D-Bus connection it was registered
#      through belongs to the surviving Steam client rather than to the dead
#      game. Power management then stays blocked indefinitely with no
#      indication why. That happened on 2026-09-01 and cost a day of the
#      machine never sleeping.
#
# The staleness check is a HEURISTIC, not a guarantee — see the note by
# stale_check() below. Treat "possibly stale" as a prompt to look, not proof.

set -uo pipefail

PA=/org/kde/Solid/PowerManagement/PolicyAgent
BC=/org/kde/Solid/PowerManagement/Actions/BrightnessControl
SVC=org.kde.Solid.PowerManagement

QD=""
for q in qdbus6 qdbus-qt6 qdbus; do
    command -v "$q" >/dev/null 2>&1 && QD="$q" && break
done
if [ -z "$QD" ]; then
    echo "ERROR: no qdbus binary found (looked for qdbus6, qdbus-qt6, qdbus)." >&2
    echo "Install qt6-qttools or equivalent." >&2
    exit 1
fi

hr() { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# 1. What the machine is configured to do
# ---------------------------------------------------------------------------
echo "Configured idle behaviour"
hr
RC="$HOME/.config/powerdevilrc"
LOCKRC="$HOME/.config/kscreenlockerrc"
get() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2; }

DIM=$(get DimDisplayIdleTimeoutSec "$RC")
OFF=$(get TurnOffDisplayIdleTimeoutSec "$RC")
SUS=$(get AutoSuspendIdleTimeoutSec "$RC")
LOCK=$(get Timeout "$LOCKRC")
ACTION=$(get AutoSuspendAction "$RC")

mins() { [ -n "${1:-}" ] && echo "$(( $1 / 60 )) min" || echo "not set"; }

printf '  dim      %s\n' "$(mins "${DIM:-}")"
printf '  blank    %s\n' "$(mins "${OFF:-}")"
if [ -n "${LOCK:-}" ]; then
    printf '  lock     %s min\n' "$LOCK"
else
    printf '  lock     not set\n'
fi
# 1 = Sleep, 8 = Shut down. Verified on this machine, not guessed — getting it
# wrong means a machine that shuts down after an hour instead of sleeping.
case "${ACTION:-}" in
    1) A="sleep" ;;
    8) A="SHUT DOWN" ;;
    "") A="not set" ;;
    *) A="unknown action code $ACTION" ;;
esac
printf '  suspend  %s (%s)\n' "$(mins "${SUS:-}")" "$A"
echo

# ---------------------------------------------------------------------------
# 2. Application inhibitions — the ones the usual tools hide
# ---------------------------------------------------------------------------
echo "Application requests blocking power management"
hr

RAW=$($QD --literal "$SVC" "$PA" ListInhibitions 2>/dev/null)
if [ -z "$RAW" ]; then
    echo "  Could not query PowerDevil. Is the desktop session running?"
    echo "  (This script must run as the desktop user, inside that session.)"
    exit 1
fi

# Turn {{"app", "reason"}, {"app", "reason"}} into one "app|reason" per line.
PAIRS=$(printf '%s\n' "$RAW" \
    | sed 's/^\[Argument: aas //; s/\]$//' \
    | grep -o '{"[^}]*"}' \
    | sed 's/^{"//; s/"}$//; s/", "/|/')

# A running Steam game. SDL reports itself under a generic default name, so the
# only way to tell whether "My SDL application" is live is to look for the game
# Steam launched rather than for a process of that name.
steam_game_pid() {
    pgrep -f "ubuntu12_32/reaper SteamLaunch" 2>/dev/null | head -1
}

# HEURISTIC. An inhibition carries only the name the app chose for itself, not
# its PID, so this matches on name and cannot be exact. A generic name, a
# renamed binary or an app running inside a container may be reported as
# possibly stale while genuinely alive. Verify before acting.
stale_check() {
    local app="$1" pid=""
    case "$app" in
        "My SDL application")
            pid=$(steam_game_pid)
            if [ -n "$pid" ]; then
                echo "live (Steam game, pid $pid)"
            else
                echo "POSSIBLY STALE — no Steam game running"
            fi
            ;;
        *)
            pid=$(pgrep -x "$app" 2>/dev/null | head -1)
            [ -z "$pid" ] && pid=$(pgrep -f "$app" 2>/dev/null | head -1)
            if [ -n "$pid" ]; then
                echo "live (pid $pid)"
            else
                echo "POSSIBLY STALE — no process named '$app'"
            fi
            ;;
    esac
}

STALE=0
COUNT=0
if [ -z "$PAIRS" ]; then
    echo "  None. Nothing is blocking dim, blank or suspend."
else
    while IFS='|' read -r app reason; do
        [ -z "$app" ] && continue
        COUNT=$((COUNT + 1))
        STATUS=$(stale_check "$app")
        printf '  %-24s %-18s %s\n' "$app" "\"$reason\"" "$STATUS"
        case "$STATUS" in POSSIBLY*) STALE=$((STALE + 1)) ;; esac
    done <<< "$PAIRS"
fi
echo

# ---------------------------------------------------------------------------
# 3. System-level inhibitors
#
# Shown for completeness. The "delay" ones are normal and harmless — they only
# postpone suspend briefly so drivers can tidy up. A "block" on sleep or idle
# is the kind that actually prevents it.
# ---------------------------------------------------------------------------
echo "System-level inhibitors (logind)"
hr
if command -v systemd-inhibit >/dev/null 2>&1; then
    BLOCKS=$(systemd-inhibit --list --no-legend 2>/dev/null \
        | awk '$NF=="block"' | grep -E "sleep|idle" || true)
    if [ -n "$BLOCKS" ]; then
        printf '%s\n' "$BLOCKS" | sed 's/^/  /'
    else
        echo "  No sleep or idle blocks. (Any 'delay' entries are normal.)"
    fi
else
    echo "  systemd-inhibit not available."
fi
echo

# ---------------------------------------------------------------------------
# 4. Current display state, and the verdict
# ---------------------------------------------------------------------------
echo "Current state"
hr
B=$($QD "$SVC" "$BC" brightness 2>/dev/null)
BMAX=$($QD "$SVC" "$BC" brightnessMax 2>/dev/null)
if [ -n "$B" ] && [ -n "$BMAX" ] && [ "$BMAX" -gt 0 ] 2>/dev/null; then
    printf '  screen brightness  %s of %s (%s%%)\n' "$B" "$BMAX" "$(( B * 100 / BMAX ))"
fi
LAST=$(journalctl -k --no-pager -o short-iso 2>/dev/null \
    | grep -E "PM: suspend entry" | tail -1 | awk '{print $1}')
printf '  last suspend       %s\n' "${LAST:-none this boot}"
echo

echo "Verdict"
hr
if [ "$COUNT" -eq 0 ]; then
    echo "  Nothing is blocking power management."
    echo "  If it still is not sleeping, the machine is probably not idle —"
    echo "  any keyboard or mouse activity restarts the timers from zero."
elif [ "$STALE" -gt 0 ]; then
    echo "  $STALE of $COUNT request(s) look left over from an app that has exited."
    echo "  Clear them with:"
    echo
    echo "      systemctl --user restart plasma-powerdevil.service"
    echo
    echo "  That is safe. PowerDevil re-reads its config on start, so the"
    echo "  timings shown above come straight back."
else
    echo "  $COUNT request(s), all from running applications. Power management"
    echo "  is being blocked deliberately. Close the app(s) above and the"
    echo "  machine will idle out normally."
fi
