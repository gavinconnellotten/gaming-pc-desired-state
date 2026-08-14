# smb_mounts

Mounts SMB/CIFS network shares at fixed paths, on demand, surviving reboots.

## Why the shares showed as empty

A share that appears in Dolphin but contains nothing is almost never a
permissions problem on the server. It's a mount that didn't happen. The
mountpoint is just a normal empty directory when nothing is mounted over it,
and file managers show it happily — there's no visual difference between "an
empty share" and "a directory where a mount failed".

The usual causes, in rough order of likelihood:

1. **No `_netdev` option.** `mount -a` runs at boot before the network is
   up. Without `_netdev`, systemd doesn't know to wait, the mount fails
   against an unreachable server, and boot carries on. Mounting by hand later
   works fine, which makes this one confusing to diagnose.
2. **No credentials, or unreadable ones.** `mount.cifs` needs a credential
   file readable by root, containing `username=` / `password=` / `domain=`.
   A missing file, a typo in the path, or a stray quote around the password
   all produce a failed mount.
3. **Missing `uid=`/`gid=`.** CIFS doesn't carry Unix ownership, so without
   these everything mounts as root-owned and your user can't read it. This
   one usually looks like "permission denied" rather than "empty", but on
   some setups the listing simply comes back empty.
4. **`cifs-utils` not installed.** Produces `unknown filesystem type 'cifs'`.
5. **Wrong `vers=`.** A pinned protocol version the server doesn't speak
   fails the mount outright. Leaving it unset lets the kernel negotiate.

This role addresses 1–4 directly and leaves 5 unset by default.

## What it does

1. Installs `cifs-utils`.
2. Ensures `/etc/samba/credentials` exists as `0700 root:root`.
3. **Fails early with instructions** if any credential file is missing —
   passwords aren't in this repo, so they must be created out of band by
   `scripts/setup-smb-credentials.sh`.
4. Enforces `0600 root:root` on the credential files.
5. Creates the mountpoints, owned by your user.
6. Writes the fstab entries as one Ansible-managed block, validated with
   `findmnt --verify` before it's saved.
7. Reloads systemd, starts the automount units, then lists each mountpoint
   and reports whether it's genuinely mounted, mounted-but-empty, or failed.

## The automount approach

Rather than mounting at boot, the entries use `x-systemd.automount`, so the
share is mounted the first time something touches the directory. This sidesteps
boot ordering entirely: no race against the network, no hung boot if the NAS is
off, and a share that comes back on its own once the server reappears.
Combined with `nofail` and a mount timeout, an unavailable NAS can't stop the
machine from booting.

`x-systemd.idle-timeout=60` unmounts the share after a minute of inactivity,
which keeps a sleeping NAS from leaving stale handles behind.

## Configuration

Shares are defined in `host_vars/gaming-pc.yml`; tunables are in
`defaults/main.yml`. Credentials are referenced by path and never stored here.

## Verifying by hand

```bash
findmnt -t cifs                      # what's actually mounted
systemctl list-units '*.automount'   # are the automount units active
journalctl -b | grep -i cifs         # why a mount failed
sudo mount -a                        # re-run fstab, showing any errors
```
