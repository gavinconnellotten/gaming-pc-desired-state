#!/usr/bin/env bash
#
# ha-backup.sh — pull a config-only Home Assistant backup to this machine.
#
# Managed by roles/homeassistant. Runs as the desktop user from a systemd user
# timer; authenticates with the existing SSH key.
#
# Why it works this way
# ---------------------
# HAOS has no Python, so this cannot be an Ansible task. It also does not need
# the long-lived API token: inside the SSH session the Supervisor API is on
# http://supervisor with $SUPERVISOR_TOKEN already exported, so there is one
# credential to look after (the SSH key) rather than two.
#
# The `ha backups new` CLI cannot express "Home Assistant config and nothing
# else" — passing --app or --folders makes a partial that includes only those,
# and passing neither makes a FULL backup (~8.9 GB here, mostly Ollama models).
# The Supervisor's /backups/new/partial endpoint takes homeassistant=true with
# empty addons and folders, which is exactly what we want, so we call it
# directly.
#
# Pruning only ever removes backups whose name starts with $NAME_PREFIX. That
# is deliberate: a retention sweep must not be able to delete a backup someone
# made by hand, or Home Assistant's own automatic ones.

set -euo pipefail

HA_HOST="${HA_HOST:?}"
HA_USER="${HA_USER:?}"
DEST="${DEST:?}"
KEEP_LOCAL="${KEEP_LOCAL:-8}"
KEEP_REMOTE="${KEEP_REMOTE:-2}"
NAME_PREFIX="${NAME_PREFIX:-gaming-pc weekly config}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15)
STAMP="$(date +%Y-%m-%d)"
NAME="${NAME_PREFIX} ${STAMP}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

remote() { ssh "${SSH_OPTS[@]}" "${HA_USER}@${HA_HOST}" "$@"; }

mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# 1. Reachable?
# ---------------------------------------------------------------------------
log "checking ${HA_HOST}"
remote true 2>/dev/null || die "cannot SSH to ${HA_USER}@${HA_HOST} — is the Terminal & SSH add-on running?"

# ---------------------------------------------------------------------------
# 2. Ask the Supervisor for a config-only backup
#
# The payload goes via a file rather than an inline -d string: quoting JSON
# through ssh through the shell is how you end up with a backup that silently
# included everything.
# ---------------------------------------------------------------------------
log "requesting config-only backup: ${NAME}"
PAYLOAD=$(printf '{"name": "%s", "homeassistant": true, "addons": [], "folders": [], "compressed": true}' "$NAME")

RESP=$(remote "cat > /tmp/ha-backup-req.json <<'JSON'
${PAYLOAD}
JSON
curl -sS -m 900 -X POST \
  -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" \
  -H 'Content-Type: application/json' \
  -d @/tmp/ha-backup-req.json \
  http://supervisor/backups/new/partial
rm -f /tmp/ha-backup-req.json") || die "backup request failed"

case "$RESP" in
    *'"result":"ok"'*) : ;;
    *) die "Supervisor rejected the backup request: ${RESP}" ;;
esac

SLUG=$(printf '%s' "$RESP" | sed -n 's/.*"slug":"\([^"]*\)".*/\1/p')
[ -n "$SLUG" ] || die "no slug in Supervisor response: ${RESP}"
log "created slug ${SLUG}"

# ---------------------------------------------------------------------------
# 3. Wait for the tar to be complete on disk
#
# The endpoint returns a job_id, so completion is not guaranteed at return.
# Wait for the file size to stop changing rather than assuming.
# ---------------------------------------------------------------------------
PREV=-1
for _ in $(seq 1 60); do
    SIZE=$(remote "stat -c %s /backup/${SLUG}.tar 2>/dev/null || echo 0")
    if [ "$SIZE" != "0" ] && [ "$SIZE" = "$PREV" ]; then
        break
    fi
    PREV="$SIZE"
    sleep 5
done
[ "${SIZE:-0}" != "0" ] || die "backup ${SLUG}.tar never appeared on the HA machine"
log "remote size settled at $((SIZE / 1024 / 1024)) MB"

# ---------------------------------------------------------------------------
# 4. Download, to a .part file first so an interrupted transfer never looks
#    like a valid backup.
# ---------------------------------------------------------------------------
OUT="${DEST}/${STAMP}-${SLUG}.tar"
log "downloading to ${OUT}"
scp "${SSH_OPTS[@]}" -q "${HA_USER}@${HA_HOST}:/backup/${SLUG}.tar" "${OUT}.part" \
    || die "download failed"

LOCAL_SIZE=$(stat -c %s "${OUT}.part")
[ "$LOCAL_SIZE" = "$SIZE" ] \
    || die "size mismatch: remote ${SIZE}, local ${LOCAL_SIZE} — keeping ${OUT}.part for inspection"

# A backup that will not open is not a backup. Cheap structural check.
tar -tf "${OUT}.part" >/dev/null 2>&1 || die "downloaded file is not a readable tar"

mv "${OUT}.part" "$OUT"
log "verified and stored: $(du -h "$OUT" | cut -f1)"

# ---------------------------------------------------------------------------
# 5. Prune — ours only, both ends
# ---------------------------------------------------------------------------
log "pruning local copies, keeping ${KEEP_LOCAL}"
# shellcheck disable=SC2012
ls -1t "${DEST}"/*.tar 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)) | while read -r old; do
    log "  removing $(basename "$old")"
    rm -f "$old"
done

log "pruning remote copies, keeping ${KEEP_REMOTE} (only ones named '${NAME_PREFIX}')"
remote "ha backups --no-progress 2>/dev/null || ha backups" 2>/dev/null \
  | grep -E '^  (name|slug|date): ' \
  | paste - - - \
  | grep -F "${NAME_PREFIX}" \
  | sort \
  | head -n -"${KEEP_REMOTE}" \
  | sed -n 's/.*slug: "\?\([a-f0-9]*\)"\?.*/\1/p' \
  | while read -r slug; do
        [ -n "$slug" ] || continue
        log "  removing remote ${slug}"
        remote "ha backups remove ${slug}" >/dev/null 2>&1 || log "  (failed to remove ${slug})"
    done

log "done — $(ls -1 "${DEST}"/*.tar 2>/dev/null | wc -l) local backup(s) in ${DEST}"
