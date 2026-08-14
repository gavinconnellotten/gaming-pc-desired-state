#!/usr/bin/env bash
#
# setup-smb-credentials.sh — create the credential files the SMB mounts need.
#
# Share passwords must not live in this git repo, so the `smb_mounts` Ansible
# role deliberately does NOT create them: it refuses to run until the files
# exist. This script is how they get created.
#
# For each share you're asked for the server, share name, mountpoint and
# login. The password is read without echo and written straight to a
# root-owned 0600 file under /etc/samba/credentials. It is never passed as a
# command-line argument (which would be visible in `ps`), never echoed, and
# never logged.
#
# At the end you get the YAML block to paste into host_vars/gaming-pc.yml so
# that Ansible knows how to mount what you just configured.
#
# Usage:
#   ./scripts/setup-smb-credentials.sh
#
# Re-running is safe: you'll be asked before any existing file is overwritten.

set -uo pipefail

CRED_DIR="/etc/samba/credentials"

# Everything here writes under /etc, so get root up front rather than
# scattering sudo through the script — and do it before prompting for any
# password, so the two prompts can't be confused for one another.
if [ "$(id -u)" -ne 0 ]; then
    printf 'This script writes to %s and needs root. Re-running under sudo...\n\n' "$CRED_DIR"
    exec sudo -- "$0" "$@"
fi

# The invoking user, not root — mounts should be owned by the human.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

printf 'SMB credential setup\n'
printf 'Mounts will be owned by %s (uid=%s gid=%s)\n\n' \
    "$TARGET_USER" "$TARGET_UID" "$TARGET_GID"

if ! command -v mount.cifs >/dev/null 2>&1; then
    printf 'Note: cifs-utils is not installed yet, so mounting will fail until\n'
    printf '      you run the playbook (it installs cifs-utils for you).\n\n'
fi

install -d -m 0700 -o root -g root "$CRED_DIR" || exit 1

# ask <variable-name> <prompt> [default]
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
    while true; do
        if [ -n "$__default" ]; then
            read -r -p "$__prompt [$__default]: " __reply
            __reply="${__reply:-$__default}"
        else
            read -r -p "$__prompt: " __reply
        fi
        if [ -n "$__reply" ]; then
            printf -v "$__var" '%s' "$__reply"
            return 0
        fi
        printf '  (required)\n'
    done
}

# Collected YAML fragments, printed together at the end.
yaml_blocks=()

configure_share() {
    local server share mountpoint username password password2 domain cred_file slug

    ask server    "  Server (hostname or IP)"
    ask share     "  Share name (as exported by the server)"
    # A sensible default mountpoint derived from the share name.
    ask mountpoint "  Mountpoint" "/mnt/${share,,}"
    ask username  "  Username on the server"
    ask domain    "  Domain / workgroup" "WORKGROUP"

    while true; do
        read -r -s -p "  Password: " password
        printf '\n'
        read -r -s -p "  Confirm password: " password2
        printf '\n'
        if [ "$password" = "$password2" ]; then
            [ -n "$password" ] && break
            printf '  (password cannot be empty)\n'
        else
            printf '  (passwords did not match, try again)\n'
        fi
    done

    # Stable, filesystem-safe name so the fstab entry and this file agree.
    slug="$(printf '%s-%s' "$server" "$share" | tr '[:upper:]' '[:lower:]' |
        tr -c 'a-z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
    cred_file="$CRED_DIR/$slug"

    if [ -e "$cred_file" ]; then
        local overwrite
        read -r -p "  $cred_file exists. Overwrite? [y/N]: " overwrite
        case "$overwrite" in
            [yY] | [yY][eE][sS]) ;;
            *)
                printf '  Left existing file untouched.\n'
                password=""
                return 0
                ;;
        esac
    fi

    # umask inside the subshell so the secret is never briefly world-readable
    # between creation and chmod.
    (
        umask 077
        {
            printf 'username=%s\n' "$username"
            printf 'password=%s\n' "$password"
            printf 'domain=%s\n' "$domain"
        } >"$cred_file"
    )
    chown root:root "$cred_file"
    chmod 0600 "$cred_file"
    password=""
    password2=""

    printf '  Wrote %s (0600 root:root)\n' "$cred_file"

    yaml_blocks+=("$(
        cat <<EOF
  - name: $slug
    server: $server
    share: $share
    mountpoint: $mountpoint
    credentials: $cred_file
EOF
    )")
}

share_number=1
while true; do
    printf 'Share %d\n' "$share_number"
    configure_share
    printf '\n'
    read -r -p "Configure another share? [y/N]: " another
    printf '\n'
    case "$another" in
        [yY] | [yY][eE][sS]) share_number=$((share_number + 1)) ;;
        *) break ;;
    esac
done

if [ "${#yaml_blocks[@]}" -eq 0 ]; then
    printf 'No credential files written.\n'
    exit 0
fi

printf -- '----------------------------------------------------------------\n'
printf 'Paste this into host_vars/gaming-pc.yml:\n\n'
printf 'smb_mounts_uid: %s\n' "$TARGET_UID"
printf 'smb_mounts_gid: %s\n\n' "$TARGET_GID"
printf 'smb_mounts:\n'
for block in "${yaml_blocks[@]}"; do
    printf '%s\n' "$block"
done
printf -- '\n----------------------------------------------------------------\n'
printf 'Then apply the mounts with:\n\n'
printf '  ansible-playbook -i inventory.ini site.yml --ask-become-pass\n\n'
printf 'The credential files themselves are outside the repo and are not\n'
printf 'committed. Keep a copy somewhere safe (a password manager) — a\n'
printf 'rebuilt machine needs them recreated by re-running this script.\n'
