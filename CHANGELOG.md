# Changelog

Dated log of what's been done to `gaming-pc`, and whether it's been codified
into this repo yet.

## 2026-08-15

- **SMB shares fixed.** The two CIFS mounts had been failing since they were
  written. Diagnosed on the machine rather than from description, which changed
  the answer completely.
  - **Root cause: trailing whitespace in `/etc/samba/credentials`.** The file
    read `username=gavin  `. `mount.cifs` passes the value verbatim, so the
    server was asked to authenticate a user literally named `gavin␣␣` and
    answered `STATUS_LOGON_FAILURE` — surfacing as
    `mount error(13): Permission denied` and, in Dolphin, as a share that
    exists but is empty.
  - Not the theorised cause. `roles/smb_mounts/README.md` had ranked a missing
    `_netdev` as most likely; the journal showed the mounts being attempted
    with the network up and rejected on authentication. `cifs-utils` was
    already installed and `vers=3.0` was fine. README corrected.
  - **Fixed manually** with `sed -i 's/[ \t]*$//' /etc/samba/credentials`, then
    remounted. Both shares verified mounted with content (69 and 116 entries).
  - **Codified**: the role now strips CRLF and trailing whitespace from
    `username=`/`domain=` lines, and reports (without altering) a password
    ending in whitespace, since that could be deliberate.
- **Three real bugs found in `roles/smb_mounts` while validating it against the
  machine.** All were written blind and none would have worked:
  - **Automount unit names were derived by string substitution**, giving
    `mnt-plex-movies.automount`. systemd escapes a literal hyphen in a path
    component to `\x2d`, so the real unit is `mnt-plex\x2dmovies.automount`.
    The task's `failed_when: false` would have hidden this entirely. Now uses
    `systemd-escape --path`.
  - **`validate: findmnt --verify` could never have succeeded.** It checks the
    whole file, and this fstab lists `/boot/efi` before `/boot` — a
    pre-existing, unrelated error that made `findmnt` exit 1. Replaced with
    `files/validate-fstab.sh`, which rejects parse errors (the class that
    breaks boot, and the only class this role can introduce) and reports the
    rest. The `/boot/efi` ordering is left alone deliberately.
  - **The role assumed `/etc/samba/credentials` was a directory** of per-share
    files; on this machine it's a single file. The role no longer creates it at
    all — the setup script owns that — and dedupes shares that point at one
    credential file.
- **Third share added**: `//homeassistant.local/MEDIA/TV SHOWS` at
  `/mnt/plex-tv`. The space in the share name has to be written `\040` in
  fstab, or the line fails to parse; the role escapes it, and the validator was
  confirmed to reject the unescaped form.
  - **One backslash in the Jinja filter, not two.** `replace(' ', '\\040')`
    renders as `\\040`, which produces a wrong UNC path that still *parses* —
    so it would have failed at mount time with nothing in the fstab validation
    to catch it. Jinja passes the literal through here rather than treating
    `\0` as an escape. Written wrong first, then caught by rendering the block
    and reading the output rather than reasoning about it.
- **`scripts/setup-smb-credentials.sh` now verifies before it writes** —
  credentials go to a temporary 0600 file, are tested with `smbclient`, and are
  only installed if the login actually works. Inputs are whitespace-trimmed.
  This is the direct lesson of the bug above: a credential file that is written
  but never tested can be silently wrong for weeks.
- **`ansible-core` installed** (2.20.7) and the old hand-written CIFS lines in
  `/etc/fstab` commented out, so the role can run. Both were manual steps.
- **Python interpreter pinned** to `/usr/bin/python3` in `inventory.ini`,
  silencing Ansible's interpreter-discovery warning. The versioned path
  (`/usr/bin/python3.14`) would break on the next Fedora upgrade; the symlink is
  RPM-owned and tracks the system Python.
- **Role logic verified without applying it**, since `--syntax-check` proves
  very little:
  - The fstab block was rendered from the real `host_vars`, spliced into a copy
    of the real `/etc/fstab`, and run through the role's own validator —
    `findmnt` resolves all three entries, `TV\040SHOWS` included.
  - The credential-hygiene tasks were run against a scratch file containing
    every defect they're meant to handle. Username and domain trimmed, CRs
    stripped, and a password's trailing space correctly left alone.
  - The verification/reporting section was run standalone in check mode as an
    unprivileged user, confirming the loops and conditions behave.
- **Applied successfully.** All three shares mount and are visible in Dolphin:
  `/mnt/plex-movies` (69 entries), `/mnt/plex-music` (116), `/mnt/plex-tv` (4).
  `/etc/fstab` now carries the managed block; no failed units.
  - As designed, `mnt-plex\x2dtv.automount` is active/running while the movies
    and music automount units are inactive — those two paths were already
    mounted directly, so the automount can't take over until they're unmounted.
    A reboot resolves it, and is also the real test that `_netdev` being in the
    options field now actually does something.
  - **SMB shares are now managed.** A rebuilt machine needs the credential file
    recreated (`./scripts/setup-smb-credentials.sh`) and then one playbook run.

## 2026-08-14

- **Base machine**: newly built gaming PC, `gaming-pc`, running Nobara Linux
  44 (KDE Plasma), NVIDIA GeForce RTX 4060 Ti.
- **NVIDIA driver**: already installed and working (`nvidia-smi` reports
  driver 595.91.07) via the NVIDIA driver ISO. Not yet managed by Ansible —
  candidate for a future `nvidia` role if it ever needs reinstalling.
- **Claude Desktop**: Fedora/Nobara has no official Anthropic package (DNF,
  unlike APT, isn't served directly), so installed via the community
  [`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian)
  project, which repackages Anthropic's official Linux beta as `.rpm` (among
  other formats) under the `claude-desktop-unofficial` package name.
  - Added the project's DNF repo (`pkg.claude-desktop-debian.dev`) and
    installed `claude-desktop-unofficial` manually via `sudo dnf install`.
  - Installed `nodejs` (MCP server support) and `qemu-system-x86` +
    `edk2-ovmf` (KVM/QEMU/OVMF stack required for Claude's "Cowork" sandboxed
    execution mode) — confirmed via the app's built-in
    `claude-desktop-unofficial --doctor` diagnostic, all checks passing
    including Cowork mode (KVM isolation).
  - **Codified**: this manual sequence is now the `roles/claude_desktop`
    Ansible role in this repo (`site.yml`), so a fresh machine gets the same
    result via `ansible-playbook` instead of hand-run commands.
  - Voice mode required no extra setup — it's a standard feature of the
    Claude Desktop app once signed in.
- **Claude Desktop diagnostics fix**: `--doctor` was inheriting the play's
  `become: true` and so reporting on root. Its checks are per-user (access to
  `/dev/kvm`, `kvm` group membership, `$HOME` config paths), so as root they
  pass trivially regardless of whether the desktop user can actually use
  Cowork. Now runs with `become: false`, prints which user it ran as, and
  warns if it still ends up as root (i.e. the playbook was invoked under
  `sudo` rather than with `--ask-become-pass`).
- **State capture**: added `scripts/capture-state.sh`, a read-only inventory
  of the machine (OS, hardware, GPU, storage, network mounts, repos, packages,
  flatpaks, services, kernel tuning, KDE, gaming stack, user environment). No
  `sudo` needed; output lands in `state/`. Redacts usernames, hostname, MACs,
  UUIDs and serials by default since the output is committed. Deliberately
  timestamp-free apart from the summary, so re-runs diff cleanly against the
  previous capture and show real drift.
- **SMB shares**: added `roles/smb_mounts` plus
  `scripts/setup-smb-credentials.sh` to mount two network shares at fixed
  paths. Not yet applied — the share details in `host_vars/gaming-pc.yml` are
  still placeholders, and the existing hand-written `/etc/fstab` entries need
  reviewing first.
  - The shares previously appeared in Dolphin but were empty. That's the
    signature of a mount that failed, leaving the bare mountpoint directory
    visible underneath — see `roles/smb_mounts/README.md` for the causes.
  - The role uses `_netdev` + `x-systemd.automount` + `nofail` so mounting
    happens on first access rather than racing the network at boot, and an
    unreachable NAS can't delay or block startup.
  - It refuses to run if credential files are missing, and refuses to run if
    `/etc/fstab` has unmanaged CIFS lines that would conflict with its own
    managed block.
