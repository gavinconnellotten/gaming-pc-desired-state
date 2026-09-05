#!/usr/bin/env bash
#
# check-homeassistant.sh — read-only health and update report for the Home
# Assistant machine, written to be read by a human deciding what to update.
#
# No sudo, no mutation, nothing installed on the HA machine. Everything goes
# over SSH using the existing key.
#
# Why a script and not an Ansible role: HAOS ships no Python, so Ansible's
# modules cannot run there. See roles/homeassistant/README.md.

set -uo pipefail

HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-root}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$HOME/backups/homeassistant}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

hr() { printf '%s\n' "------------------------------------------------------------"; }
remote() { ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "$@" 2>/dev/null; }

echo "Home Assistant — ${HA_HOST}"
hr

if ! remote true; then
    echo "  UNREACHABLE over SSH."
    echo
    echo "  Check, in order:"
    echo "    - is the machine on? (ping ${HA_HOST})"
    echo "    - is the Terminal & SSH add-on running?"
    echo "    - is its Network port still set to 22? (it resets on some updates)"
    exit 1
fi
echo "  reachable"
echo

# ---------------------------------------------------------------------------
# Core / OS / Supervisor
# ---------------------------------------------------------------------------
echo "Platform versions"
hr
PENDING=0
for c in core os supervisor; do
    INFO=$(remote "ha ${c} info")
    V=$(printf '%s' "$INFO" | sed -n 's/^version: *"\?\([^"]*\)"\?$/\1/p' | head -1)
    L=$(printf '%s' "$INFO" | sed -n 's/^version_latest: *"\?\([^"]*\)"\?$/\1/p' | head -1)
    if [ -n "$L" ] && [ "$V" != "$L" ]; then
        printf '  %-12s %-14s -> %-14s  UPDATE AVAILABLE\n' "$c" "$V" "$L"
        PENDING=$((PENDING + 1))
    else
        printf '  %-12s %-14s  up to date\n' "$c" "$V"
    fi
done
echo

# ---------------------------------------------------------------------------
# Add-ons
#
# auto_update is shown because it is the difference between "this will change
# under you" and "this waits for you". Everything except Music Assistant is
# deliberately pinned — see CHANGELOG 2026-09-05.
# ---------------------------------------------------------------------------
echo "Add-ons"
hr
printf '  %-26s %-10s %-9s %-12s %s\n' NAME STATE AUTO VERSION UPDATE
SLUGS=$(remote "ha addons" | sed -n 's/^  slug: *//p')
ADDON_PENDING=0
for s in $SLUGS; do
    INFO=$(remote "ha addons info ${s}")
    N=$(printf '%s' "$INFO"  | sed -n 's/^name: *//p' | head -1 | cut -c1-25)
    ST=$(printf '%s' "$INFO" | sed -n 's/^state: *//p' | head -1)
    AU=$(printf '%s' "$INFO" | sed -n 's/^auto_update: *//p' | head -1)
    V=$(printf '%s' "$INFO"  | sed -n 's/^version: *"\?\([^"]*\)"\?$/\1/p' | head -1)
    L=$(printf '%s' "$INFO"  | sed -n 's/^version_latest: *"\?\([^"]*\)"\?$/\1/p' | head -1)
    U=""
    if [ -n "$L" ] && [ "$V" != "$L" ]; then
        U="-> ${L}"
        ADDON_PENDING=$((ADDON_PENDING + 1))
    fi
    [ "$AU" = "true" ] && AU="AUTO" || AU="pinned"
    MARK=""
    [ "$ST" != "started" ] && MARK="  <<< NOT RUNNING"
    printf '  %-26s %-10s %-9s %-12s %s%s\n' "$N" "$ST" "$AU" "$V" "$U" "$MARK"
done
echo

# ---------------------------------------------------------------------------
# Storage mounts
#
# These are the CIFS mounts Home Assistant makes back to its OWN Samba add-on,
# which is the documented way to get a USB disk visible to add-ons on HAOS.
# It also means a Samba restart drops them, so their state is worth checking.
# ---------------------------------------------------------------------------
echo "Media mounts"
hr
remote "ha mounts info" | grep -E "^- name:|^  state:" | paste - - \
  | sed 's/- name: /  /; s/  state: / -> /' \
  | awk '{ printf "%s\n", $0; if ($0 !~ /active/) printf "      <<< NOT ACTIVE\n" }'
echo

# ---------------------------------------------------------------------------
# Disk
# ---------------------------------------------------------------------------
echo "Disk"
hr
remote "df -h /backup" | tail -1 | awk '{printf "  system disk  %s used of %s (%s), %s free\n", $3, $2, $5, $4}'
remote "du -sh /backup" | awk '{printf "  /backup      %s\n", $1}'
echo

# ---------------------------------------------------------------------------
# Backups, both ends
# ---------------------------------------------------------------------------
echo "Backups"
hr
echo "  on the HA machine:"
remote "ha backups" | grep -E '^  (name|date|size): ' | paste - - - \
  | sed 's/  *name: /  /; s/  *date: "/  /; s/T[0-9:.+-]*"//; s/  *size: /  /' \
  | awk '{ printf "    %s\n", $0 }'

echo
echo "  pulled to this machine (${LOCAL_BACKUP_DIR}):"
if [ -d "$LOCAL_BACKUP_DIR" ] && ls -1 "$LOCAL_BACKUP_DIR"/*.tar >/dev/null 2>&1; then
    # shellcheck disable=SC2012
    ls -1t "$LOCAL_BACKUP_DIR"/*.tar | while read -r f; do
        printf '    %-34s %8s  %s\n' "$(basename "$f")" \
            "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d')"
    done
    NEWEST=$(ls -1t "$LOCAL_BACKUP_DIR"/*.tar | head -1)
    AGE=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST") ) / 86400 ))
    echo
    if [ "$AGE" -gt 14 ]; then
        echo "    <<< newest local backup is ${AGE} days old — the timer may not be running"
        echo "        check: systemctl --user status ha-backup.timer"
    else
        echo "    newest is ${AGE} day(s) old"
    fi
else
    echo "    NONE YET"
    echo "    run one now: systemctl --user start ha-backup.service"
fi
echo

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo "Summary"
hr
TOTAL=$((PENDING + ADDON_PENDING))
if [ "$TOTAL" -eq 0 ]; then
    echo "  Nothing to update."
else
    echo "  ${PENDING} platform update(s), ${ADDON_PENDING} add-on update(s) available."
    echo
    echo "  Apply from this machine, most cautious first:"
    echo "    ssh ${HA_USER}@${HA_HOST} 'ha core update'        # Home Assistant itself"
    echo "    ssh ${HA_USER}@${HA_HOST} 'ha addons update SLUG' # one add-on"
    echo "    ssh ${HA_USER}@${HA_HOST} 'ha os update'          # REBOOTS the machine"
    echo
    echo "  The Supervisor takes its own backup of an add-on before updating it,"
    echo "  so a bad add-on update is recoverable without doing anything first."
fi
