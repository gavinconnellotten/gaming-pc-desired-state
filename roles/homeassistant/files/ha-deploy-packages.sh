#!/usr/bin/env bash
#
# ha-deploy-packages.sh — push repo-owned YAML packages to Home Assistant.
#
# Managed by roles/homeassistant. Runs from gaming-pc over SSH.
#
# What a package is, and why it is the right container
# ----------------------------------------------------
# Home Assistant's `packages` mechanism takes a single YAML file containing
# sensors, automations, scripts and so on, and merges it into the running
# configuration. That makes it the natural unit for repo-owned config: one
# file, self-contained, and strictly separate from automations.yaml and
# scripts.yaml, which Home Assistant itself rewrites whenever anything is
# edited in the UI.
#
# Without that separation the repo and the UI editor would take turns
# clobbering each other — the same failure mode as editing Plasma or
# qBittorrent config underneath a running application.
#
# It does NOT restart Home Assistant
# ----------------------------------
# Packages are only read at startup, so a change here does nothing until a
# restart. That restart is deliberately left to a human: Home Assistant is a
# media server and a voice assistant, and interrupting it mid-song as a side
# effect of running a playbook is the wrong default. The script says plainly
# when a restart is needed.
#
# Usage (all via environment):
#   SRC=/path/to/ha-packages DEST=/homeassistant/packages ha-deploy-packages.sh

set -uo pipefail

HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-root}"
SRC="${SRC:?SRC is required}"
DEST="${DEST:-/homeassistant/packages}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
remote() { ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "$@" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }

remote true || die "cannot reach ${HA_USER}@${HA_HOST}"
[ -d "$SRC" ] || die "source directory ${SRC} does not exist"

remote "mkdir -p ${DEST}" || die "could not create ${DEST}"

CHANGED=0

# ---------------------------------------------------------------------------
# Make sure configuration.yaml actually includes the packages directory.
# Adding files nobody reads is a silent no-op, which is worse than an error.
# ---------------------------------------------------------------------------
if ! remote "grep -q 'packages: !include_dir_named' /homeassistant/configuration.yaml"; then
    echo "adding the packages include to configuration.yaml"
    remote "cp /homeassistant/configuration.yaml /homeassistant/configuration.yaml.bak-\$(date +%Y%m%d-%H%M%S)" \
        || die "could not back up configuration.yaml"
    remote "printf '\n# Repo-managed configuration, deployed by roles/homeassistant.\n# Do not edit files in packages/ here — edit them in the repo.\nhomeassistant:\n  packages: !include_dir_named packages\n' >> /homeassistant/configuration.yaml" \
        || die "could not update configuration.yaml"
    CHANGED=1
fi

# ---------------------------------------------------------------------------
# Copy only what differs, so an unchanged run is quiet and a real change shows.
# ---------------------------------------------------------------------------
for f in "$SRC"/*.yaml; do
    [ -e "$f" ] || continue
    n="$(basename "$f")"
    local_sum="$(md5sum "$f" | cut -d' ' -f1)"
    remote_sum="$(remote "md5sum ${DEST}/${n} 2>/dev/null" | cut -d' ' -f1)"
    if [ "$local_sum" = "$remote_sum" ]; then
        echo "unchanged: ${n}"
        continue
    fi
    echo "changed: ${n}"
    scp "${SSH_OPTS[@]}" -q "$f" "${HA_USER}@${HA_HOST}:${DEST}/${n}" || die "could not copy ${n}"
    CHANGED=1
done

[ "$CHANGED" -eq 0 ] && { echo "no changes"; exit 0; }

# ---------------------------------------------------------------------------
# Validate BEFORE telling anyone to restart. `ha core check` parses the whole
# configuration, so a broken package is caught here rather than by Home
# Assistant failing to come back up.
# ---------------------------------------------------------------------------
echo "validating configuration..."
if remote "ha core check" | grep -qi "successful"; then
    echo "  configuration valid"
else
    OUT="$(remote 'ha core check')"
    die "configuration check FAILED — not restarting. Output: ${OUT}"
fi

echo
echo "  Packages changed. Home Assistant reads them only at startup, so this"
echo "  has NOT taken effect yet. Restart when convenient:"
echo "      ssh ${HA_USER}@${HA_HOST} 'ha core restart'"
