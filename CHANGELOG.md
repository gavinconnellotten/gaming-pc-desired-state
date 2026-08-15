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
- **Verified across a reboot**, which is the claim that actually matters. All
  three automount units came up `active`, no failed units, and no
  `STATUS_LOGON_FAILURE` anywhere in the boot journal. Boot completed at
  12:23:15 and the shares mounted at 12:24:16 — a minute later, on first
  access, which is the whole point: boot no longer waits on the NAS. Movies and
  music also picked up the role's `file_mode=0664,dir_mode=0775`, confirming
  they migrated off their old hand-written entries.
- **`scripts/capture-state.sh` made honest and quiet.** Two problems, both
  found by diffing a fresh capture against the committed one:
  - **The mounts section was actively misleading.** With a 60-second idle
    timeout the shares are usually *not* mounted, so the capture recorded
    "(no output)" under currently-mounted — indistinguishable from the failure
    this repo exists to document. It now leads with automount unit health,
    explains what each state means, and lists mountpoint contents *first* so
    that touching the directories arms the automounts and the sections agree.
    The script's "never modifies the system" claim was already untrue for the
    same reason; that's now stated rather than glossed.
  - **Diffs were ~95% noise.** CPU scaling MHz, BogoMIPS, free memory, NVIDIA
    module refcounts, snapd loop-device ordering, disk usage, timer schedules,
    `/dev/kvm`'s mtime and Claude's PID all churned every run, burying real
    change. Those are now stripped or normalised. Two consecutive runs are
    byte-identical apart from the summary timestamp, so `git diff state/` is
    worth reading again.
- **Baseline recaptured** post-reboot, replacing the pre-reboot one.

## 2026-08-15 (later)

- **Answered "what did I install to fix Steam?" from the machine rather than
  memory.** `dnf` transaction 1 is the package set baked into the ISO, stamped
  2026-04-24 when Nobara built the image; everything from transaction 2
  (2026-08-08) happened here. That boundary yields an exact list — 32
  explicitly-installed packages.
  - The likely fix was transaction 7:
    `dnf install -y rocm-meta nobara-resolve-runtime zlib libxcrypt-compat
    python3.11 python3.11-libs alsa-plugins-pulseaudio`. `libxcrypt-compat`
    provides `libcrypt.so.1`, which Fedora dropped and Steam still links
    against — the classic "installs fine, won't launch". Reconstructed from
    evidence, so treat it as most-likely rather than certain; the Proton-GE
    install on 08-10 and the NVIDIA i686 libraries on 08-12 are also
    candidates.
- **`capture-state.sh` learned to record drift from the image.**
  - New `state/57-post-iso-additions.txt` computes the post-ISO delta from dnf
    history. This is the file to open when asking what a rebuild would lose.
  - Snaps were a complete blind spot and are now captured, in
    `state/60-flatpaks-snaps.txt` (renamed from `60-flatpaks.txt`).
- **Adding snap capture immediately found something.** A `claudeai-desktop`
  snap, publisher "Chimeremeze Prevail Ejimadu (prevailexcel)", an unofficial
  third-party Electron wrapper — unrelated to the `claude-desktop-unofficial`
  RPM this repo manages. Installed 08-12, two days before the RPM, so probably
  an abandoned first attempt. Not running. Flagged for removal; not touched.
- **New `roles/gaming`**, following the principle *manage the delta, not the
  distribution*:
  - Installs the runtime dependencies and the codec set (verbatim from
    transaction 12, `.i686` architectures included — the 32-bit halves are
    what older Proton builds and 32-bit games need).
  - Deliberately does **not** manage Steam, Lutris, Heroic, gamescope,
    gamemode, MangoHud or OBS. They ship with the image and Nobara updates
    them; managing them here would fight `nobara-sync`.
  - Omits `rocm-meta` from that install line — AMD's compute stack on an
    NVIDIA machine, along for the ride because the command was run wholesale.
  - Installs Proton-GE pinned to `GE-Proton11-3`, checksum-verified against
    the release's own `.sha512sum` so pinning a version doesn't also mean
    pasting a hash nobody re-verifies.
  - **Refuses to run as root.** `compatibilitytools.d` is under `$HOME`, so
    under `sudo` the build lands in `/root` where Steam never looks — and the
    run would report success. Same class of bug as `claude_desktop`'s
    `--doctor` gotcha. It also resolves the home directory with `getent`
    rather than `ansible_env.HOME`, which is already root's once the play's
    `become` is in effect.
  - Reports Proton builds it doesn't manage. `Proton-GE Latest`, installed via
    ProtonPlus, is flagged as one a rebuild won't restore.
  - Verified live as the desktop user: correct home resolution, download and
    unpack skipped for the already-present pinned build, idempotent on a second
    run, and clean under `--check`.

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
