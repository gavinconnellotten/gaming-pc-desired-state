#!/usr/bin/env bash
#
# check-shield.sh — read-only health report for the NVIDIA Shield.
#
# Third in the set, alongside check-gaming-pc.sh and check-homeassistant.sh:
# one script per machine this household depends on.
#
# Read-only. No credentials. Nothing is installed on the Shield and nothing is
# changed. Every check is a TCP probe or an unauthenticated HTTP endpoint.
#
# Why the Shield is worth watching at all
# ---------------------------------------
# Since 2026-09-12 gaming-pc mounts //192.168.68.102/internal/Download. The
# Shield is an Android TV box: it reboots for updates and gets switched off
# casually, far less predictably than the Home Assistant machine. The mount is
# x-systemd.automount so an absent Shield is harmless — an empty directory
# rather than a hung boot — but "harmless" and "noticed" are different things.
# Without this you find out the Shield is down when a mount is mysteriously
# empty, which is exactly the class of fault that wasted an evening on Plex.
#
# What this deliberately does NOT do
# ----------------------------------
# It does not manage the Shield, and there is no roles/shield. A Shield has no
# package manager, no config files to version and no declarative surface —
# everything ADB offers is imperative ("install this", "reboot"), which is a
# runbook, not desired state. Writing a role for it would be calling a runbook
# desired-state config. So: monitor, do not manage. See the CHANGELOG for
# 2026-09-12.

set -uo pipefail

SHIELD_HOST="${SHIELD_HOST:-192.168.68.102}"
SHIELD_MOUNT="${SHIELD_MOUNT:-/mnt/shield-downloads}"

hr() { printf '%s\n' "------------------------------------------------------------"; }
probe() { timeout 3 bash -c "echo >/dev/tcp/${SHIELD_HOST}/$1" 2>/dev/null; }

echo "NVIDIA Shield — ${SHIELD_HOST}"
hr

# ---------------------------------------------------------------------------
# Reachable at all? Everything below is meaningless if not, so stop here.
# ---------------------------------------------------------------------------
if ping -c 2 -W 2 "$SHIELD_HOST" >/dev/null 2>&1; then
    echo "  reachable"
else
    echo "  UNREACHABLE — not responding to ping"
    echo
    echo "  Likely just switched off, which is normal for this device."
    echo "  Consequence: ${SHIELD_MOUNT} will be empty until it is back."
    echo "  The mount is automount, so nothing else breaks."
    exit 1
fi
echo

# ---------------------------------------------------------------------------
# Services
#
# Ports rather than deep checks, deliberately: an unauthenticated probe tells
# us "listening or not", which is the question that matters, without needing a
# credential this script would then have to look after.
# ---------------------------------------------------------------------------
echo "Services"
hr
printf '  %-28s ' "SMB (445)"
probe 445 && echo "up" || echo "DOWN  <<< ${SHIELD_MOUNT} will not mount"
printf '  %-28s ' "Plex (32400)"
probe 32400 && echo "up" || echo "DOWN"
printf '  %-28s ' "Cast (8009)"
probe 8009 && echo "up" || echo "down"
printf '  %-28s ' "Android TV Remote (6466)"
probe 6466 && echo "up" || echo "down"
printf '  %-28s ' "ADB network debugging (5555)"
if probe 5555; then
    echo "OPEN"
    echo "      ADB is enabled. That is a debugging interface with no auth"
    echo "      beyond initial pairing — fine if deliberate, worth turning off"
    echo "      if it was left on after a one-off job."
else
    echo "closed (expected)"
fi
echo

# ---------------------------------------------------------------------------
# Plex identity — unauthenticated, and confirms the server is answering rather
# than merely holding the port open.
# ---------------------------------------------------------------------------
echo "Plex"
hr
PLEX="$(timeout 10 curl -sS -m 8 "http://${SHIELD_HOST}:32400/identity" 2>/dev/null)"
if [ -n "$PLEX" ]; then
    # tail -1, because the XML declaration also carries version="1.0" and
    # matches first. The server's own version is the later one.
    V="$(printf '%s' "$PLEX" | grep -oE 'version="[^"]*"' | tail -1 | cut -d'"' -f2)"
    M="$(printf '%s' "$PLEX" | grep -oE 'machineIdentifier="[^"]*"' | cut -d'"' -f2 | cut -c1-8)"
    printf '  responding   version=%s  machine=%s...\n' "${V:-?}" "${M:-?}"
    echo "  NOTE: this is the Shield's OWN Plex, separate from the Home"
    echo "        Assistant add-on. Different libraries, different media."
else
    echo "  port open but no response to /identity — Plex may be starting"
fi
echo

# ---------------------------------------------------------------------------
# The mount, from this machine's point of view
# ---------------------------------------------------------------------------
echo "The SMB mount on this machine"
hr
unit="$(systemd-escape --path --suffix=automount "$SHIELD_MOUNT" 2>/dev/null)"
state="$(systemctl is-active "$unit" 2>/dev/null)"
if [ "$state" = "active" ]; then
    if findmnt -no SOURCE --target "$SHIELD_MOUNT" --types cifs >/dev/null 2>&1; then
        n="$(timeout 15 ls -1 "$SHIELD_MOUNT" 2>/dev/null | wc -l)"
        printf '  armed, currently mounted, %s entries\n' "$n"
    else
        # Detaching on idle is the DESIGN, not a fault. Reporting an idle
        # automount as broken is a mistake this repo has already made once.
        echo "  armed, idle (normal — it attaches on access)"
    fi
else
    printf '  AUTOMOUNT %s  <<< broken\n' "${state:-missing}"
    echo "      apply with: ansible-playbook -i inventory.ini site.yml \\"
    echo "                    --ask-become-pass --tags smb_mounts"
fi
echo

echo "Summary"
hr
if probe 445 && probe 32400; then
    echo "  Shield healthy — SMB and Plex both up."
else
    echo "  Shield reachable but a service is down; see above."
fi
