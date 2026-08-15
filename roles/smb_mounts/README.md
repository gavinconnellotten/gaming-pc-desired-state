# smb_mounts

Mounts SMB/CIFS network shares at fixed paths, on demand, surviving reboots.

## Why the shares showed as empty

A share that appears in Dolphin but contains nothing is almost never a
permissions problem on the server. It's a mount that didn't happen. The
mountpoint is just a normal empty directory when nothing is mounted over it,
and file managers show it happily — there's no visual difference between "an
empty share" and "a directory where a mount failed".

**On gaming-pc it was trailing whitespace in the credentials file.** The file
read `username=gavin  `. `mount.cifs` passes the value verbatim, so the server
was asked to authenticate a user literally named `gavin␣␣` and answered
`STATUS_LOGON_FAILURE`, which surfaces as `mount error(13): Permission denied`.

Two things made that hard to find. Trailing whitespace is invisible in every
editor, and typing the *same* password by hand into `smbclient -U gavin` works
perfectly — so the evidence points at the server, the protocol version, or the
share path, none of which were wrong.

The general causes, in the order worth checking:

1. **Bad credentials file.** Wrong username or password, but also trailing
   whitespace, CRLF line endings (a file edited on Windows), or quotes around
   the password. All produce `STATUS_LOGON_FAILURE` / `mount error(13)`.
   The journal names it explicitly:
   `journalctl -b | grep -i cifs`.
2. **No `_netdev` option, or it's in the wrong field.** `mount -a` runs at boot
   before the network is up. Without `_netdev`, systemd doesn't wait, the mount
   fails against an unreachable server, and boot carries on. Mounting by hand
   later works, which makes this confusing. Note `_netdev` must be in the
   **options** field — gaming-pc's hand-written entries had it after
   `dump`/`pass`, where fstab ignores it entirely.
3. **Missing `uid=`/`gid=`.** CIFS carries no Unix ownership, so without these
   everything mounts root-owned and your user can't read it.
4. **`cifs-utils` not installed.** Produces `unknown filesystem type 'cifs'`.
5. **Wrong `vers=`.** A pinned protocol version the server doesn't speak fails
   the mount outright.

This role addresses 1–4 directly and leaves 5 to the host configuration.

## What it does

1. Installs `cifs-utils`.
2. **Fails early with instructions** if a credential file is missing —
   passwords aren't in this repo, so they're created out of band by
   `scripts/setup-smb-credentials.sh`.
3. Enforces `0600 root:root` on the credential files.
4. Normalises them: strips CRLF line endings, and trailing whitespace from
   `username=` / `domain=` lines. A trailing space on `password=` is
   *reported but not removed*, because it could legitimately be part of the
   password — removing it would be the role breaking a working login.
5. Creates the mountpoints, owned by your user.
6. Writes the fstab entries as one Ansible-managed block, validated before
   it's saved.
7. Reloads systemd, starts the automount units, then checks each mountpoint
   with `findmnt` and reports whether it's genuinely mounted, mounted but
   empty, or not mounted at all.

## The automount approach

Rather than mounting at boot, the entries use `x-systemd.automount`, so the
share is mounted the first time something touches the directory. This sidesteps
boot ordering entirely: no race against the network, no hung boot if the NAS is
off, and a share that comes back on its own once the server reappears.
Combined with `nofail` and a mount timeout, an unavailable NAS can't stop the
machine from booting.

`x-systemd.idle-timeout=60` unmounts the share after a minute of inactivity,
which keeps a sleeping NAS from leaving stale handles behind.

## Two things that bite

**Unit names aren't the path with slashes swapped for hyphens.** systemd
escapes a literal hyphen inside a path component to `\x2d`, because a hyphen
already means `/` in a unit name. So `/mnt/plex-movies` is
`mnt-plex\x2dmovies.mount`, not `mnt-plex-movies.mount`. The role asks
`systemd-escape --path` instead of deriving the name by substitution — an
earlier version guessed, produced a unit that doesn't exist, and masked the
failure with `failed_when: false`.

**`findmnt --verify` checks the whole file, not just the new block.**
gaming-pc's fstab lists `/boot/efi` before `/boot`, which findmnt reports as an
error, so using it directly as blockinfile's `validate` would permanently
refuse to write over a pre-existing and unrelated problem. `files/validate-fstab.sh`
rejects **parse errors** — the class that actually breaks boot, and the only
class this role's own block can introduce — and reports the rest. The role
prints pre-existing fstab problems separately so they stay visible.

## Configuration

Shares are defined in `host_vars/gaming-pc.yml`; tunables are in
`defaults/main.yml`. Credentials are referenced by path and never stored here.
Several shares may share one credential file — the role dedupes before
checking them.

## Verifying by hand

```bash
findmnt -t cifs                      # what's actually mounted
systemctl list-units '*.automount'   # are the automount units active
journalctl -b | grep -i cifs         # why a mount failed
sudo mount -a                        # re-run fstab, showing any errors
```

To test credentials without touching anything, which separates "the login is
wrong" from "the mount options are wrong":

```bash
smbclient //<server>/<share> -U <username> -c 'ls'
```
