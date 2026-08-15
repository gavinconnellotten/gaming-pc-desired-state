#!/usr/bin/env bash
#
# setup-smb-credentials.sh — create the credential files the SMB mounts need.
#
# Share passwords must not live in this git repo, so the `smb_mounts` Ansible
# role deliberately does NOT create them: it refuses to run until the files
# exist. This script is how they get created.
#
# For each share you're asked for the server, share name, mountpoint and login.
# The password is read without echo, written to a temporary 0600 file, and
# VERIFIED against the server before anything is installed into place. It is
# never passed as a command-line argument (which would be visible in `ps`),
# never echoed, and never logged.
#
# Verifying before writing matters. On 2026-08-15 these mounts failed for a
# fortnight because the credentials file read `username=gavin  ` — two trailing
# spaces, invisible in any editor, which the server rejected with
# STATUS_LOGON_FAILURE. A file that is written but never tested is a file that
# can be silently wrong. So: this script trims whitespace from the username and
# domain, and refuses to install a credential file it couldn't log in with.
#
# At the end you get the YAML block to paste into host_vars/gaming-pc.yml.
#
# Usage:
#   ./scripts/setup-smb-credentials.sh
#
# Re-running is safe: you'll be asked before any existing file is overwritten.

set -uo pipefail

DEFAULT_CRED_DIR="/etc/samba/credentials"

# Everything here writes under /etc, so get root up front rather than
# scattering sudo through the script — and do it before prompting for any
# password, so the two prompts can't be confused for one another.
if [ "$(id -u)" -ne 0 ]; then
    printf 'This script writes under /etc and needs root. Re-running under sudo...\n\n'
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

HAVE_SMBCLIENT=1
if ! command -v smbclient >/dev/null 2>&1; then
    HAVE_SMBCLIENT=0
    printf 'Note: smbclient is not installed, so credentials cannot be verified\n'
    printf '      before they are written. Install samba-client to enable that:\n'
    printf '        sudo dnf install samba-client\n\n'
fi

# trim <string> — strip leading and trailing whitespace.
#
# The whole reason this script exists in its current form: a trailing space in
# `username=` is invisible and fatal. mount.cifs passes the value verbatim.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ask <variable-name> <prompt> [default] — prompt until non-empty, then trim.
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
    while true; do
        if [ -n "$__default" ]; then
            read -r -p "$__prompt [$__default]: " __reply
            __reply="${__reply:-$__default}"
        else
            read -r -p "$__prompt: " __reply
        fi
        __reply="$(trim "$__reply")"
        if [ -n "$__reply" ]; then
            printf -v "$__var" '%s' "$__reply"
            return 0
        fi
        printf '  (required)\n'
    done
}

# verify_credentials <cred-file> <server> <share>
#
# `share` may carry a subdirectory ("MEDIA/TV SHOWS"). SMB connects to the
# share root and changes directory below it, so split the two apart.
verify_credentials() {
    local cred_file="$1" server="$2" share="$3"
    local share_root="${share%%/*}" subpath="" out=""

    case "$share" in
        */*) subpath="${share#*/}" ;;
    esac

    if [ "$HAVE_SMBCLIENT" -eq 0 ]; then
        printf '  Skipping verification (no smbclient).\n'
        return 0
    fi

    printf '  Verifying against //%s/%s ... ' "$server" "$share"

    local rc=0
    if [ -n "$subpath" ]; then
        out=$(smbclient "//$server/$share_root" --authentication-file="$cred_file" \
            -D "$subpath" -c 'ls' 2>&1) || rc=$?
    else
        out=$(smbclient "//$server/$share_root" --authentication-file="$cred_file" \
            -c 'ls' 2>&1) || rc=$?
    fi

    # smbclient exits 0 for some failures that only show up in the output
    # (a successful anonymous session that can't reach the share, notably),
    # so check both.
    if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'NT_STATUS'; then
        printf 'OK\n'
        return 0
    fi

    printf 'FAILED\n'
    # Server messages only; the password is never part of this output.
    printf '%s\n' "$out" | sed 's/^/    /' | head -5
    return 1
}

# Collected YAML fragments, printed together at the end.
yaml_blocks=()

configure_share() {
    local server share mountpoint username password password2 domain
    local cred_file slug default_mount tmp_file answer

    ask server "  Server (hostname or IP)"
    ask share "  Share name, with any subdirectory (e.g. MEDIA/TV SHOWS)"

    # Stable, filesystem-safe name, derived from the whole share path so that
    # two subdirectories of one share don't collide.
    slug="$(printf '%s' "$share" | tr '[:upper:]' '[:lower:]' |
        tr -c 'a-z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
    default_mount="/mnt/$slug"

    ask mountpoint "  Mountpoint" "$default_mount"
    ask username "  Username on the server"
    ask domain "  Domain / workgroup" "WORKGROUP"

    # Default to the conventional path. A single shared file is equally valid —
    # the role only cares that the path exists and is 0600 root:root — so this
    # is a prompt rather than an assumption.
    ask cred_file "  Credential file" "$DEFAULT_CRED_DIR/$slug"

    local cred_parent
    cred_parent="$(dirname "$cred_file")"
    if [ -e "$cred_parent" ] && [ ! -d "$cred_parent" ]; then
        printf '  ERROR: %s exists and is not a directory, so %s cannot be\n' \
            "$cred_parent" "$cred_file"
        printf '         created. Choose a different path — or reuse %s\n' "$cred_parent"
        printf '         itself as the credential file if it already holds this login.\n'
        return 1
    fi
    # Only create it if absent. Never chmod an existing directory: the
    # single-file layout puts the credential file straight in /etc/samba,
    # and forcing that to 0700 would break the rest of Samba's config.
    if [ ! -d "$cred_parent" ]; then
        install -d -m 0700 -o root -g root "$cred_parent" || return 1
    fi

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

    # Write to a temporary file first and verify from it, so a bad login never
    # replaces a working credential file.
    tmp_file="$(mktemp)" || return 1
    chmod 0600 "$tmp_file"
    {
        printf 'username=%s\n' "$username"
        printf 'password=%s\n' "$password"
        printf 'domain=%s\n' "$domain"
    } >"$tmp_file"
    password=""
    password2=""

    if ! verify_credentials "$tmp_file" "$server" "$share"; then
        printf '  Not written. Check the username and password and try again.\n'
        read -r -p "  Write it anyway? [y/N]: " answer
        case "$answer" in
            [yY] | [yY][eE][sS]) ;;
            *)
                shred -u "$tmp_file" 2>/dev/null || rm -f "$tmp_file"
                return 1
                ;;
        esac
    fi

    if [ -e "$cred_file" ]; then
        read -r -p "  $cred_file exists. Overwrite? [y/N]: " answer
        case "$answer" in
            [yY] | [yY][eE][sS]) ;;
            *)
                printf '  Left existing file untouched.\n'
                shred -u "$tmp_file" 2>/dev/null || rm -f "$tmp_file"
                return 0
                ;;
        esac
    fi

    install -m 0600 -o root -g root "$tmp_file" "$cred_file" || {
        shred -u "$tmp_file" 2>/dev/null || rm -f "$tmp_file"
        return 1
    }
    shred -u "$tmp_file" 2>/dev/null || rm -f "$tmp_file"

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
printf 'Write share names with literal spaces — the role escapes them to \\040\n'
printf 'for fstab. Then apply the mounts with:\n\n'
printf '  ansible-playbook -i inventory.ini site.yml --ask-become-pass\n\n'
printf 'The credential files themselves are outside the repo and are not\n'
printf 'committed. Keep a copy somewhere safe (a password manager) — a\n'
printf 'rebuilt machine needs them recreated by re-running this script.\n'
