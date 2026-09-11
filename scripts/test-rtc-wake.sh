#!/usr/bin/env bash
#
# Does the RTC alarm actually wake this machine from S3?
#
# The obvious test — arm an alarm, suspend, see if it comes back — misled us
# once already, in two separate ways. Both are why this script exists.
#
#   1. THE SCREEN CAN STAY BLACK AFTER A SUCCESSFUL WAKE. On 2026-09-12 a test
#      was read as "it did not come back up" and a keypress was used to wake
#      it. The evidence afterwards said the machine had resumed on its own two
#      seconds after the armed alarm, and the RTC wakeup source showed exactly
#      one activation timed to that resume. The monitor simply never lit.
#      JUDGE BY THIS SCRIPT'S LOG, NOT BY THE SCREEN.
#
#   2. JOURNAL TIMESTAMPS COLLAPSE ACROSS A SUSPEND. The whole suspend
#      sequence gets stamped with the post-resume second, so `journalctl`
#      cannot tell you whether the resume came before or after a keypress.
#
# So this writes a userspace heartbeat every 5 seconds. It freezes during
# suspend and resumes on wake, giving a wake time recorded after the clock is
# correct — independent of the journal, and independent of the screen.
#
# Needs sudo to arm the alarm. The check-* scripts here are deliberately
# sudo-free; this one cannot be.

set -euo pipefail

ALARM=/sys/class/rtc/rtc0/wakealarm
LOG=/tmp/rtc-wake-test.log
TARGETFILE=/tmp/rtc-wake-test.target
BEAT=5

usage() {
    cat <<USAGE
usage: $0 arm [seconds]   arm the alarm (default 300) and suspend
       $0 report          read the log and say whether the RTC woke it

Run 'arm', then DO NOT TOUCH the keyboard or mouse until well past the
alarm time. Then run 'report'.
USAGE
    exit 1
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
arm)
    SECS="${2:-300}"
    [[ "$SECS" =~ ^[0-9]+$ ]] || die "seconds must be a number, got '$SECS'"
    [ -w "$ALARM" ] || [ -e "$ALARM" ] || die "$ALARM does not exist — no RTC alarm on this machine"

    # Clear first. Writing a new alarm over an armed one fails.
    sudo sh -c "echo 0 > $ALARM"
    TARGET=$(( $(date +%s) + SECS ))
    sudo sh -c "echo $TARGET > $ALARM"

    ARMED="$(cat "$ALARM")"
    [ "$ARMED" = "$TARGET" ] || die "alarm did not take: wrote $TARGET, reads '$ARMED'"
    echo "$TARGET" > "$TARGETFILE"

    : > "$LOG"
    # Heartbeat must outlive this script and the suspend.
    setsid bash -c "while true; do date '+%s %Y-%m-%d %H:%M:%S' >> '$LOG'; sleep $BEAT; done" \
        >/dev/null 2>&1 < /dev/null &
    disown || true

    echo "alarm armed for $(date -d "@$TARGET" '+%Y-%m-%d %H:%M:%S %Z') (in ${SECS}s)"
    echo "heartbeat logging to $LOG every ${BEAT}s"
    echo
    echo "Suspending in 10 seconds."
    echo "DO NOT touch the keyboard or mouse until at least $(date -d "@$((TARGET + 120))" '+%H:%M:%S')."
    echo "The screen may stay black even if the wake worked — that is the whole point."
    sleep 10
    systemctl suspend
    ;;

report)
    [ -s "$LOG" ] || die "no heartbeat log at $LOG — run '$0 arm' first"
    [ -s "$TARGETFILE" ] || die "no target at $TARGETFILE — run '$0 arm' first"
    TARGET="$(cat "$TARGETFILE")"

    # Largest gap between consecutive heartbeats is the suspend.
    read -r GAP BEFORE AFTER < <(
        awk '
            NR > 1 {
                d = $1 - prev
                if (d > max) { max = d; b = prev; a = $1 }
            }
            { prev = $1 }
            END { printf "%d %d %d\n", max, b, a }
        ' "$LOG"
    )

    [ "$GAP" -gt "$((BEAT * 2))" ] || die "no suspend gap found in $LOG — did it suspend at all?"

    echo "RTC wake test"
    echo "------------------------------------------------------------"
    printf '  alarm armed for   %s\n' "$(date -d "@$TARGET" '+%Y-%m-%d %H:%M:%S')"
    printf '  last beat before  %s\n' "$(date -d "@$BEFORE" '+%Y-%m-%d %H:%M:%S')"
    printf '  first beat after  %s\n' "$(date -d "@$AFTER" '+%Y-%m-%d %H:%M:%S')"
    printf '  asleep for        %ss\n' "$GAP"
    echo

    # A wake caused by the alarm lands within a few seconds of it. Allow one
    # heartbeat interval either side plus a little resume latency.
    DELTA=$(( AFTER - TARGET ))
    ABS=${DELTA#-}
    if [ "$ABS" -le $(( BEAT + 15 )) ]; then
        echo "  VERDICT: the RTC woke it — first beat is ${DELTA}s from the alarm."
        echo "  Nothing was touched, so the alarm is what resumed the machine."
    elif [ "$DELTA" -lt 0 ]; then
        echo "  VERDICT: INCONCLUSIVE — it woke ${ABS}s BEFORE the alarm, so"
        echo "  something else resumed it. Re-run and touch nothing."
    else
        echo "  VERDICT: the RTC did NOT wake it — it stayed asleep ${DELTA}s"
        echo "  past the alarm. Check the BIOS: MSI -> Settings -> Advanced ->"
        echo "  Wake Up Event Setup -> Resume By RTC Alarm must be Enabled."
        echo "  This is the same class of problem as Resume By USB Device."
    fi
    echo
    echo "  RTC wakeup source activations since boot:"
    printf '    wakeup_active_count = %s\n' "$(cat /sys/class/rtc/rtc0/device/power/wakeup_active_count 2>/dev/null || echo '?')"
    ;;

*)
    usage
    ;;
esac
