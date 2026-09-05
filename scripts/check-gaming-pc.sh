#!/usr/bin/env bash
#
# check-gaming-pc.sh — read-only health and update report for this machine.
#
# Reports; never applies. That is deliberate and is the same rule the rest of
# this repo follows: Nobara ships its own update system (nobara-sync / Nobara
# Updater) with layered repos and patched packages, and driving dnf around it
# causes drift or breakage on Nobara's own update cycle. So this tells you what
# is waiting and leaves applying to the tool that understands the distro.
#
# No sudo. `dnf check-update` works unprivileged against the cached metadata;
# if the cache is stale the count may lag, which is noted in the output rather
# than hidden.

set -uo pipefail

hr() { printf '%s\n' "------------------------------------------------------------"; }

echo "gaming-pc — $(hostnamectl --static 2>/dev/null || hostname)"
hr
echo "  $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "  kernel $(uname -r)"
echo "  up $(uptime -p | sed 's/^up //')"
echo

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
echo "Package updates"
hr
CACHE_AGE="unknown"
if [ -d /var/cache/libdnf5 ] || [ -d /var/cache/dnf ]; then
    NEWEST=$(find /var/cache/libdnf5 /var/cache/dnf -name 'repomd.xml' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    [ -n "$NEWEST" ] && CACHE_AGE="$(( ( $(date +%s) - ${NEWEST%.*} ) / 3600 )) hours old"
fi
echo "  (metadata cache: ${CACHE_AGE})"

# dnf5 prints section headers such as "Upgrades" in the same column as package
# names, so filter on the shape of a real row: three fields, and a name that
# carries an architecture suffix.
RPM_LIST=$(dnf -q --cacheonly check-update 2>/dev/null \
    | awk 'NF>=3 && $1 ~ /\.(x86_64|i686|noarch|aarch64)$/ {print}')
RPM_COUNT=$(printf '%s' "$RPM_LIST" | grep -c . || true)
if [ "${RPM_COUNT:-0}" -gt 0 ]; then
    echo "  ${RPM_COUNT} RPM update(s) available. First 15:"
    printf '%s\n' "$RPM_LIST" | head -15 | awk '{printf "    %-45s %s\n", $1, $2}'
else
    echo "  no RPM updates in the cached metadata"
fi
echo

echo "Flatpak updates"
hr
if command -v flatpak >/dev/null 2>&1; then
    FP=$(flatpak remote-ls --updates --columns=application,version 2>/dev/null)
    if [ -n "$FP" ]; then
        printf '%s\n' "$FP" | awk '{printf "    %-45s %s\n", $1, $2}'
    else
        echo "  none"
    fi
else
    echo "  flatpak not installed"
fi
echo

# ---------------------------------------------------------------------------
# Reboot needed?
#
# A kernel newer than the running one means the machine is running code it has
# already replaced on disk — worth knowing before deciding whether to update.
# ---------------------------------------------------------------------------
echo "Reboot"
hr
NEWEST_KERNEL=$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-core-//')
RUNNING="$(uname -r)"
if [ -n "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != "$RUNNING" ]; then
    echo "  REBOOT PENDING — running ${RUNNING}, installed ${NEWEST_KERNEL}"
else
    echo "  running the newest installed kernel"
fi

# The NVIDIA driver is built per-kernel by DKMS. If a new kernel is installed
# but its module has not been built, rebooting boots a machine with no NVIDIA
# driver — no acceleration, no gaming, and possibly no usable desktop on this
# hardware.
#
# This is not hypothetical: on 2026-09-05 kernel 7.2.3-200 installed at
# 08:52:04, akmods fired 29 seconds later and failed because kernel-devel had
# not landed yet (it arrived at 09:06:27). Nothing retried, and nothing said
# so. Only the pending-reboot notice would have appeared, which reads like
# good news.
# NOTE: capture dkms output into a variable rather than piping it into
# `grep -q`. With `set -o pipefail`, grep -q exits on its first match, dkms
# takes SIGPIPE, and the pipeline reports failure — so the test reads as false
# and the whole check is skipped in silence. That is exactly the kind of quiet
# no-op this script exists to catch, so it must not have one of its own.
if [ -n "$NEWEST_KERNEL" ] && command -v dkms >/dev/null 2>&1; then
    DKMS_STATUS="$(dkms status 2>/dev/null || true)"
    if [[ "$DKMS_STATUS" == *nvidia* ]]; then
        if [[ "$DKMS_STATUS" == *"$NEWEST_KERNEL"* ]]; then
            echo "  NVIDIA module built for ${NEWEST_KERNEL} — safe to reboot"
        else
            echo
            echo "  *** DO NOT REBOOT ***"
            echo "  No NVIDIA module is built for ${NEWEST_KERNEL}."
            echo "  Rebooting would start a machine with no graphics driver."
            echo
            echo "  Build it first:"
            echo "      sudo dkms autoinstall -k ${NEWEST_KERNEL}"
            echo "      dkms status | grep ${NEWEST_KERNEL}"
        fi
    fi
fi
echo

# ---------------------------------------------------------------------------
# Things that are supposed to be working
# ---------------------------------------------------------------------------
echo "Service health"
hr
FAILED_SYS=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
FAILED_USR=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -z "$FAILED_SYS" ] && [ -z "$FAILED_USR" ]; then
    echo "  no failed units"
else
    [ -n "$FAILED_SYS" ] && printf '%s\n' "$FAILED_SYS" | sed 's/^/  FAILED (system): /'
    [ -n "$FAILED_USR" ] && printf '%s\n' "$FAILED_USR" | sed 's/^/  FAILED (user):   /'
fi

echo
echo "  SMB shares:"
# These are x-systemd.automount, so being unmounted is NORMAL — they detach
# after their idle timeout and remount on access. The thing that matters is
# whether the AUTOMOUNT unit is active; checking findmnt instead reports a
# perfectly healthy idle share as broken.
for m in /mnt/plex-movies /mnt/plex-music /mnt/plex-tv; do
    unit="$(systemd-escape --path --suffix=automount "$m")"
    state="$(systemctl is-active "$unit" 2>/dev/null)"
    if [ "$state" = "active" ]; then
        if findmnt -no SOURCE --target "$m" --types cifs >/dev/null 2>&1; then
            printf '    %-18s armed, currently mounted\n' "$m"
        else
            printf '    %-18s armed, idle (normal)\n' "$m"
        fi
    else
        printf '    %-18s AUTOMOUNT %s  <<< broken\n' "$m" "${state:-missing}"
    fi
done

echo
echo "  HA backup timer:"
if systemctl --user list-unit-files ha-backup.timer >/dev/null 2>&1; then
    printf '    state: %s, next: %s\n' \
        "$(systemctl --user is-active ha-backup.timer 2>/dev/null)" \
        "$(systemctl --user show ha-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    printf '    last run: %s\n' \
        "$(systemctl --user show ha-backup.service -p ExecMainStartTimestamp --value 2>/dev/null || echo never)"
else
    echo "    not installed"
fi
echo

# ---------------------------------------------------------------------------
# Disk
# ---------------------------------------------------------------------------
echo "Disk"
hr
df -h --output=target,size,used,avail,pcent / /run/media/gavin/08167B30167B1DBE 2>/dev/null \
  | tail -n +2 | awk '{printf "  %-38s %5s used of %5s (%s), %5s free\n", $1, $3, $2, $5, $4}'
echo

# ---------------------------------------------------------------------------
# Power — the thing that took a fortnight to get right
# ---------------------------------------------------------------------------
echo "Power"
hr
LAST=$(journalctl --no-pager -o short-iso 2>/dev/null | grep "PM: suspend entry" | tail -1 | awk '{print $1}')
printf '  last suspend: %s\n' "${LAST:-none recorded}"
if command -v qdbus-qt6 >/dev/null 2>&1; then
    INH=$(qdbus-qt6 --literal org.kde.Solid.PowerManagement \
        /org/kde/Solid/PowerManagement/PolicyAgent ListInhibitions 2>/dev/null)
    case "$INH" in
        *"aas {}"*) echo "  nothing blocking sleep" ;;
        "")         echo "  (PowerDevil not reachable — not in a desktop session?)" ;;
        *)          echo "  BLOCKED BY: ${INH}"
                    echo "  detail: ./scripts/check-power-inhibitors.sh" ;;
    esac
fi
echo

echo "Summary"
hr
echo "  ${RPM_COUNT:-0} RPM update(s) pending."
echo
echo "  Apply with Nobara's own updater, NOT dnf directly:"
echo "      nobara-sync cli"
echo
echo "  It handles the layered repos and patched packages that plain dnf will"
echo "  fight. This repo deliberately does not manage those packages."
