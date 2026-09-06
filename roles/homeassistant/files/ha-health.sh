#!/usr/bin/env bash
#
# ha-health.sh — detect and repair the two things that break Home Assistant's
# media after every reboot.
#
# Managed by roles/homeassistant. Runs from gaming-pc over SSH, because HAOS is
# an appliance and cannot take a systemd unit of its own.
#
# The failure this exists for, observed 2026-09-06
# ------------------------------------------------
# Home Assistant mounts its media over CIFS from its OWN Samba add-on. On boot
# it tries before Samba is listening, both mounts fail, and nothing retries:
#
#   Samba NAS2   state: startup   (took 90 seconds to come up)
#   ELEMENTS     state: failed
#   SSD          state: failed
#
# Worse, the Plex add-on starts in the same window. Observed timeline:
#
#   15:13:31   Plex started        <- media mounts FAILED at this point
#   15:17      mounts reloaded     <- Plex had already started; never re-checked
#
# So repairing the mounts underneath a running Plex fixes the machine without
# fixing Plex. Both have to be addressed, in that order.
#
# What it does NOT do
# -------------------
# It does not restart Plex unless something was actually broken. A media server
# that restarts itself on a timer for no reason is worse than the fault.
#
# Limitation worth knowing: this only runs while gaming-pc is awake. That
# machine suspends after an hour idle, so a Home Assistant reboot at 3am is
# repaired when gaming-pc next wakes, not immediately. Closing that gap
# properly would mean an automation inside Home Assistant.

set -uo pipefail

HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-root}"
PLEX_SLUG="${PLEX_SLUG:-a0d7b954_plex}"
SAMBA_SLUG="${SAMBA_SLUG:-1a32f091_sambanas2}"
SAMBA_WAIT="${SAMBA_WAIT:-180}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
remote() { ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "$@" 2>/dev/null; }

addon_state() { remote "ha addons info $1" | sed -n 's/^state: *//p' | head -1; }

# ---------------------------------------------------------------------------
# 1. Is it even up? A machine that is off is not a fault to repair.
# ---------------------------------------------------------------------------
if ! remote true; then
    log "Home Assistant not reachable — nothing to do"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Samba must be listening before a CIFS mount to it can possibly succeed.
#    Reloading a mount while Samba is still starting just fails again.
# ---------------------------------------------------------------------------
SAMBA="$(addon_state "$SAMBA_SLUG")"
if [ "$SAMBA" != "started" ]; then
    log "Samba NAS2 is '${SAMBA}' — waiting up to ${SAMBA_WAIT}s"
    WAITED=0
    while [ "$WAITED" -lt "$SAMBA_WAIT" ]; do
        sleep 10
        WAITED=$((WAITED + 10))
        SAMBA="$(addon_state "$SAMBA_SLUG")"
        [ "$SAMBA" = "started" ] && break
    done
    if [ "$SAMBA" != "started" ]; then
        log "ERROR: Samba NAS2 still '${SAMBA}' after ${WAITED}s — not repairing mounts"
        log "ERROR: check: ha addons logs ${SAMBA_SLUG}"
        exit 1
    fi
    log "Samba NAS2 started after ${WAITED}s"
fi

# ---------------------------------------------------------------------------
# 3. Repair any mount that is not active
# ---------------------------------------------------------------------------
REPAIRED=0
MOUNT_INFO="$(remote 'ha mounts info')"

# Pair each "- name:" with the "state:" that follows it.
BROKEN="$(printf '%s\n' "$MOUNT_INFO" \
    | grep -E '^- name:|^  state:' \
    | paste - - \
    | grep -v 'active' \
    | sed -n 's/^- name: *\([^[:space:]]*\).*/\1/p')"

if [ -z "$BROKEN" ]; then
    log "all media mounts active"
else
    for m in $BROKEN; do
        log "mount '${m}' is not active — reloading"
        if remote "ha mounts reload ${m}" >/dev/null; then
            REPAIRED=$((REPAIRED + 1))
        else
            log "ERROR: reload of '${m}' failed"
        fi
    done

    # Verify rather than trusting the reload's exit code.
    sleep 5
    STILL="$(remote 'ha mounts info' \
        | grep -E '^- name:|^  state:' | paste - - | grep -v 'active' \
        | sed -n 's/^- name: *\([^[:space:]]*\).*/\1/p')"
    if [ -n "$STILL" ]; then
        log "ERROR: still not active after reload: ${STILL}"
    else
        log "all mounts active again (${REPAIRED} repaired)"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Plex
#
# Restart it only if a mount was actually repaired — a running Plex does not
# re-examine storage that changed underneath it, which is exactly how the
# machine can look healthy while playback still fails. If nothing was broken,
# leave it alone.
# ---------------------------------------------------------------------------
PLEX="$(addon_state "$PLEX_SLUG")"

if [ "$PLEX" != "started" ]; then
    log "Plex is '${PLEX}' — starting it"
    remote "ha addons start ${PLEX_SLUG}" >/dev/null && log "Plex started"
elif [ "$REPAIRED" -gt 0 ]; then
    log "Plex is running but started before storage was ready — restarting"
    remote "ha addons restart ${PLEX_SLUG}" >/dev/null && log "Plex restarted"
else
    log "Plex running, storage healthy — left alone"
fi

log "done (${REPAIRED} mount(s) repaired)"
