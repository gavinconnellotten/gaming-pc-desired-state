#!/usr/bin/env bash
#
# capture-homeassistant.sh — read-only inventory of the Home Assistant machine.
#
# Companion to capture-state.sh, which does the same job for gaming-pc. Writes
# plain-text files describing Home Assistant's configuration so that drift
# shows up in `git diff` rather than being discovered when something stops
# working.
#
# Read-only. No sudo. Nothing on the Home Assistant machine is modified.
#
# Why capture rather than enforce
# -------------------------------
# Home Assistant's `.storage` directory — the Claude conversation settings, the
# assist pipeline, entity and area registries, what is exposed to voice — is
# owned by the running Home Assistant, which rewrites those files on its own
# schedule. Writing them from Ansible is the same trap as editing Plasma or
# qBittorrent config underneath a running application: the change is silently
# discarded, or worse, half-applied.
#
# So the split this repo uses is:
#
#   add-on options        ENFORCED   roles/homeassistant, via the Supervisor API
#   YAML config files     CAPTURED   here, diffable, restored from HA backup
#   .storage settings     CAPTURED   here, diffable, restored from HA backup
#
# The restore path for everything captured here is the weekly config backup
# pulled by roles/homeassistant, NOT this repo. What this gives you is the
# ability to see what changed and when, and to notice a setting drifting before
# it costs an evening.
#
# Redaction is ON by default, because this output is committed. It masks API
# keys, tokens, claim codes and passwords. secrets.yaml is never read at all.
# Review diffs before committing regardless — redaction is a safety net, not a
# guarantee.
#
# Usage:
#   ./scripts/capture-homeassistant.sh                # write to ./state/homeassistant
#   ./scripts/capture-homeassistant.sh --out /tmp/x

set -uo pipefail

OUT_DIR="state/homeassistant"
HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-root}"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
remote() { ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "$@" 2>/dev/null; }

# Mask anything that looks like a credential. Applied to every captured file.
redact() {
    sed -E \
        -e 's/("?(api_key|apikey|token|password|passwd|secret|claim_code|access_token|refresh_token)"?[[:space:]]*[:=][[:space:]]*"?)[^",}[:space:]]+/\1REDACTED/gI' \
        -e 's/(sk-[A-Za-z0-9_-]{8,})/REDACTED/g' \
        -e 's/(claim-[A-Za-z0-9_-]{8,})/REDACTED/g'
}

remote true || { echo "ERROR: cannot reach ${HA_USER}@${HA_HOST}" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
echo "capturing platform versions..."
{
    echo "# Home Assistant platform"
    echo
    remote 'ha info' | grep -E '^(hassos|homeassistant|supervisor|docker|arch|channel):'
    echo
    echo "## OS"
    remote 'ha os info' | grep -E '^(version|version_latest|board|boot):'
} | redact > "$OUT_DIR/10-platform.txt"

# ---------------------------------------------------------------------------
echo "capturing add-ons..."
{
    echo "# Add-ons, with the update policy this repo pins"
    echo "#"
    echo "# auto_update false is deliberate for anything media or access depends on."
    echo "# See roles/homeassistant/defaults/main.yml."
    echo
    printf '%-34s %-14s %-8s %s\n' SLUG VERSION AUTO STATE
    for s in $(remote 'ha addons' | sed -n 's/^  slug: *//p' | sort); do
        remote "ha addons info ${s} --raw-json" \
          | jq -r --arg s "$s" '.data | [$s, .version, (.auto_update|tostring), .state] | @tsv' \
          | awk -F'\t' '{printf "%-34s %-14s %-8s %s\n", $1, $2, $3, $4}'
    done
} | redact > "$OUT_DIR/20-addons.txt"

# ---------------------------------------------------------------------------
echo "capturing add-on options..."
{
    echo "# Add-on options. Only the keys listed in roles/homeassistant are"
    echo "# enforced; the rest are captured so drift is visible."
    echo
    for s in $(remote 'ha addons' | sed -n 's/^  slug: *//p' | sort); do
        echo "## ${s}"
        remote "ha addons info ${s} --raw-json" | jq -S '.data.options'
        echo
    done
} | redact > "$OUT_DIR/25-addon-options.json"

# ---------------------------------------------------------------------------
echo "capturing voice assistant configuration..."
{
    echo "# Voice assistant: pipeline, conversation agent, speech engines"
    echo "#"
    echo "# NOT enforced by Ansible — these live in .storage, which the running"
    echo "# Home Assistant owns. Restore from the weekly config backup."
    echo
    echo "## Assist pipeline"
    remote 'cat /homeassistant/.storage/assist_pipeline.pipelines' \
      | jq -S '.data.items[] | {name, conversation_engine, stt_engine, tts_engine, tts_voice, prefer_local_intents, wake_word_entity}'
    echo
    echo "## Conversation agent (Claude)"
    remote 'cat /homeassistant/.storage/core.config_entries' \
      | jq -S '.data.entries[] | select(.domain=="anthropic") | .subentries[]
               | select(.subentry_type=="conversation") | .data'
} | redact > "$OUT_DIR/30-voice.txt"

# ---------------------------------------------------------------------------
echo "capturing music setup..."
{
    echo "# Music Assistant players and areas"
    echo
    echo "## Media players"
    remote 'cat /homeassistant/.storage/core.entity_registry' \
      | jq -r '.data.entities[] | select(.entity_id|startswith("media_player."))
               | [.entity_id, .platform, (.disabled_by // "enabled")] | @tsv' \
      | sort | awk -F'\t' '{printf "  %-46s %-18s %s\n", $1, $2, $3}'
    echo
    echo "## Devices and their areas"
    remote 'cat /homeassistant/.storage/core.device_registry' \
      | jq -r '.data.devices[] | select(.identifiers|tostring|test("music_assistant|cast|mpd|esphome"))
               | [(.name_by_user // .name), (.area_id // "-"), (.disabled_by // "enabled")] | @tsv' \
      | sort | awk -F'\t' '{printf "  %-34s %-16s %s\n", $1, $2, $3}'
    echo
    echo "## Storage mounts (CIFS from the local Samba add-on — see README)"
    remote 'ha mounts info' | grep -E '^- name:|^  (state|server|share|usage):'
} | redact > "$OUT_DIR/40-music.txt"

# ---------------------------------------------------------------------------
echo "capturing YAML configuration..."
mkdir -p "$OUT_DIR/yaml"
# secrets.yaml is deliberately NOT in this list and must never be added.
for f in configuration.yaml scripts.yaml automations.yaml scenes.yaml; do
    remote "cat /homeassistant/${f}" | redact > "$OUT_DIR/yaml/${f}" 2>/dev/null
    [ -s "$OUT_DIR/yaml/${f}" ] || echo "# (empty or absent)" > "$OUT_DIR/yaml/${f}"
done

{
    echo "# Blueprints in use"
    echo
    remote 'find /homeassistant/blueprints -name "*.yaml" -type f' | sort | sed 's|/homeassistant/|  |'
} | redact > "$OUT_DIR/50-blueprints.txt"

# ---------------------------------------------------------------------------
{
    echo "# Home Assistant capture"
    echo
    echo "Written by \`scripts/capture-homeassistant.sh\`. Read-only, redacted."
    echo
    echo "| File | Contents |"
    echo "|---|---|"
    echo "| \`10-platform.txt\` | Core, OS and Supervisor versions |"
    echo "| \`20-addons.txt\` | Add-ons, versions, and update policy |"
    echo "| \`25-addon-options.json\` | Every add-on's options |"
    echo "| \`30-voice.txt\` | Assist pipeline and the Claude agent's settings |"
    echo "| \`40-music.txt\` | Players, areas, storage mounts |"
    echo "| \`50-blueprints.txt\` | Blueprints present |"
    echo "| \`yaml/\` | configuration, scripts, automations, scenes |"
    echo
    echo "**Enforced** by \`roles/homeassistant\`: add-on options and Supervisor"
    echo "properties only. Everything else here is captured for drift detection;"
    echo "the restore path is the weekly config backup, not this repo."
    echo
    echo "\`secrets.yaml\` is never read."
} > "$OUT_DIR/README.md"

echo
echo "done -> ${OUT_DIR}/"
echo "review with: git diff ${OUT_DIR}/"
