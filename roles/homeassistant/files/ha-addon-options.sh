#!/usr/bin/env bash
#
# ha-addon-options.sh — enforce Home Assistant add-on settings from this repo.
#
# Managed by roles/homeassistant. Runs from gaming-pc over SSH.
#
# Why this exists
# ---------------
# On 2026-09-10 the Whisper add-on was found running the `tiny` speech model.
# It transcribed "Love Is All Right" as "love is all as all right", the music
# automation searched for that literally, and every music request appeared to
# be "misunderstood". Nothing in the LLM configuration was at fault. A setting
# nobody can see is a setting nobody checks, so it is pinned here.
#
# Two kinds of setting, which live in different places
# ----------------------------------------------------
#   DESIRED  add-on OPTIONS        -> merged into .data.options  (e.g. model)
#   PROPS    Supervisor PROPERTIES -> set at the top level       (auto_update,
#                                                                 boot, watchdog)
#
# Getting this wrong is easy and silent: sending auto_update inside `options`
# is accepted by the API and then dropped, because it is not in the add-on's
# schema. Samba NAS2 is the trap in the other direction — it has BOTH a
# Supervisor auto_update property and its own option of the same name, and
# turning off only one looks done.
#
# Rules this follows
# ------------------
# 1. MERGE, never replace. Only named keys are enforced; everything else is
#    left alone. Replacing the whole options object would silently drop
#    settings this repo does not know about.
# 2. Only write when something actually differs, so a no-op run is quiet.
# 3. Verify after writing, per key, rather than trusting the response.
#
# Usage (all via environment):
#   SLUG=core_whisper DESIRED='{"model":"small"}' [RESTART=true] ha-addon-options.sh
#   SLUG=a0d7b954_plex PROPS='{"auto_update":false}' ha-addon-options.sh
#
# Prints "unchanged" or "changed"; exit 1 on error.

set -uo pipefail

HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-root}"
SLUG="${SLUG:?SLUG is required}"
DESIRED="${DESIRED:-}"
PROPS="${PROPS:-}"
[ -z "$DESIRED" ] && DESIRED='{}'
[ -z "$PROPS" ] && PROPS='{}'
RESTART="${RESTART:-false}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
remote() { ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "$@" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Compare PER KEY with jq equality, never string equality on whole objects.
#
# Two traps, both paid for on 2026-09-10:
#   - Home Assistant stores numbers with its own type. Piper's length_scale is
#     1.0, so a desired 1 differs as a string and matches as a number.
#   - Do NOT write `$c[.key] // null`. jq's alternative operator falls through
#     on `false` as well as `null`, so a stored `false` reads as absent. That
#     made this script report "auto_update: unset -> unset" and then fail its
#     own verification on a value that was already correct.
differing() {
    jq -rn --argjson c "$1" --argjson d "$2" '
        [ $d | to_entries[] as $e
          | select( ( ($c | has($e.key)) | not ) or ( $c[$e.key] != $e.value ) )
          | $e.key ] | join(" ")'
}
show() {
    jq -rn --argjson o "$1" --arg k "$2" \
        'if ($o | has($k)) then ($o[$k] | tostring) else "unset" end'
}

remote true || die "cannot reach ${HA_USER}@${HA_HOST}"

INFO="$(remote "ha addons info ${SLUG} --raw-json" | jq -c '.data')"
[ -n "$INFO" ] && [ "$INFO" != "null" ] || die "could not read ${SLUG} (does the add-on exist?)"

CUR_OPTS="$(printf '%s' "$INFO" | jq -c '.options')"
CUR_PROPS="$(printf '%s' "$INFO" | jq -c '{auto_update, boot, watchdog}')"

OPTS_DIFF="$(differing "$CUR_OPTS" "$DESIRED")"
PROPS_DIFF="$(differing "$CUR_PROPS" "$PROPS")"

if [ -z "$OPTS_DIFF" ] && [ -z "$PROPS_DIFF" ]; then
    echo "unchanged: ${SLUG} already matches"
    exit 0
fi

MERGED_OPTS="$(printf '%s' "$CUR_OPTS" | jq -c --argjson d "$DESIRED" '. * $d')" \
    || die "could not merge options — is DESIRED valid JSON?"

echo "changed: ${SLUG}"
for k in $OPTS_DIFF;  do echo "  option   ${k}: $(show "$CUR_OPTS" "$k") -> $(show "$MERGED_OPTS" "$k")"; done
for k in $PROPS_DIFF; do echo "  property ${k}: $(show "$CUR_PROPS" "$k") -> $(show "$PROPS" "$k")"; done

# One payload: options merged, properties at the top level. Staged through a
# file rather than an inline -d string, because quoting JSON through ssh
# through a shell is how you apply something you did not intend to a live
# media server.
PAYLOAD="$(jq -cn --argjson o "$MERGED_OPTS" --argjson p "$PROPS" \
    'if ($o | length) > 0 then {options: $o} else {} end + $p')"
remote "cat > /tmp/ha-addon-opts.json" <<< "$PAYLOAD" || die "could not stage payload"

RESP="$(remote "curl -sS -m 30 -X POST \
    -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" \
    -H 'Content-Type: application/json' \
    -d @/tmp/ha-addon-opts.json \
    http://supervisor/addons/${SLUG}/options; rm -f /tmp/ha-addon-opts.json")"

case "$RESP" in
    *'"result":"ok"'*) : ;;
    *) die "Supervisor rejected the change for ${SLUG}: ${RESP}" ;;
esac

# Verify. The Supervisor accepts keys outside an add-on's schema and then drops
# them, so a successful response proves nothing on its own.
AFTER="$(remote "ha addons info ${SLUG} --raw-json" | jq -c '.data')"
STILL_O="$(differing "$(printf '%s' "$AFTER" | jq -c '.options')" "$DESIRED")"
STILL_P="$(differing "$(printf '%s' "$AFTER" | jq -c '{auto_update, boot, watchdog}')" "$PROPS")"
[ -z "$STILL_O" ] || die "options did not take effect for ${SLUG}: ${STILL_O} (is it in the add-on's schema?)"
[ -z "$STILL_P" ] || die "properties did not take effect for ${SLUG}: ${STILL_P}"
echo "  verified"

if [ "$RESTART" = "true" ] && [ -n "$OPTS_DIFF" ]; then
    echo "  restarting ${SLUG} (options only take effect on restart)"
    remote "ha addons restart ${SLUG}" >/dev/null || die "restart of ${SLUG} failed"
    for _ in $(seq 1 18); do
        sleep 5
        [ "$(remote "ha addons info ${SLUG}" | sed -n 's/^state: *//p' | head -1)" = "started" ] && {
            echo "  ${SLUG} started"; exit 0; }
    done
    die "${SLUG} did not return to 'started' after restart"
fi
