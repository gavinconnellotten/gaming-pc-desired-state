#!/usr/bin/env bash
#
# nobara-update.sh — run Nobara's own updater, then make sure the graphics
# driver survived it.
#
# Managed by roles/os_updates. Runs as root from a systemd system timer.
#
# Why nobara-sync and not dnf
# ---------------------------
# Nobara ships patched packages and layered repos, and its updater performs
# post-update fixups — including the NVIDIA module rebuild — that plain dnf and
# the App Centre do not. Driving dnf around it causes drift on Nobara's release
# cycle, which is a standing rule in this repo.
#
# Why the NVIDIA check afterwards
# -------------------------------
# On 2026-09-05 kernel 7.2.3-200 was installed with no NVIDIA module built for
# it. /usr/lib/kernel/install.d/40-dkms.install fires when the KERNEL is
# installed; kernel-devel arrived fourteen minutes later in a separate
# transaction and nothing re-ran it. The only visible symptom was a cheerful
# "reboot pending". Rebooting would have produced a machine with no graphics
# driver.
#
# nobara-sync normally handles this. The check costs a second and the failure
# it guards against is severe, so it runs regardless.
#
# This script NEVER reboots. It reports.

set -uo pipefail

INCLUDE_FLATPAK="${INCLUDE_FLATPAK:-true}"
VERIFY_NVIDIA="${VERIFY_NVIDIA:-true}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[ "$(id -u)" -eq 0 ] || { log "ERROR: must run as root"; exit 1; }

BEFORE_KERNEL="$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 1. Update
# ---------------------------------------------------------------------------
ARGS=(cli)
[ "$INCLUDE_FLATPAK" = "true" ] && ARGS+=(--all)

log "running: nobara-sync ${ARGS[*]}"
if nobara-sync "${ARGS[@]}"; then
    log "nobara-sync completed"
    RC=0
else
    RC=$?
    log "WARNING: nobara-sync exited ${RC} — see output above"
fi

AFTER_KERNEL="$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}')"
if [ "$BEFORE_KERNEL" != "$AFTER_KERNEL" ]; then
    log "kernel changed: ${BEFORE_KERNEL#kernel-core-} -> ${AFTER_KERNEL#kernel-core-}"
else
    log "kernel unchanged (${AFTER_KERNEL#kernel-core-})"
fi

# ---------------------------------------------------------------------------
# 2. Make sure the graphics driver exists for whatever kernel we now have
# ---------------------------------------------------------------------------
if [ "$VERIFY_NVIDIA" = "true" ] && command -v dkms >/dev/null 2>&1; then
    NEWEST="${AFTER_KERNEL#kernel-core-}"

    # Capture, do not pipe into `grep -q`. With pipefail, grep -q exits on its
    # first match, dkms takes SIGPIPE, and the pipeline reports failure — so
    # the test reads false and the check is skipped in silence. That bug was
    # real in scripts/check-gaming-pc.sh before it was caught.
    DKMS_STATUS="$(dkms status 2>/dev/null || true)"

    if [[ "$DKMS_STATUS" == *nvidia* ]]; then
        if [[ "$DKMS_STATUS" == *"$NEWEST"* ]]; then
            log "NVIDIA module present for ${NEWEST}"
        else
            log "NVIDIA module MISSING for ${NEWEST} — building now"
            if dkms autoinstall -k "$NEWEST"; then
                log "dkms autoinstall completed"
            else
                log "ERROR: dkms autoinstall FAILED for ${NEWEST}."
                log "ERROR: DO NOT REBOOT — this kernel has no graphics driver."
                log "ERROR: Boot the previous kernel from GRUB if you already have."
                RC=1
            fi

            # Re-read rather than trusting the exit code.
            DKMS_STATUS="$(dkms status 2>/dev/null || true)"
            if [[ "$DKMS_STATUS" == *"$NEWEST"* ]]; then
                log "verified: NVIDIA module now built for ${NEWEST}"
            else
                log "ERROR: still no NVIDIA module for ${NEWEST} after rebuild"
                RC=1
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. Say whether a reboot is needed. Never take one.
# ---------------------------------------------------------------------------
RUNNING="$(uname -r)"
NEWEST="${AFTER_KERNEL#kernel-core-}"
if [ "$RUNNING" != "$NEWEST" ]; then
    log "REBOOT PENDING: running ${RUNNING}, installed ${NEWEST}"
else
    log "no reboot needed"
fi

log "finished (rc=${RC})"
exit "$RC"
