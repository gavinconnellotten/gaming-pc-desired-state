# state/

Captured inventory of `gaming-pc` as it actually is, produced by
`../scripts/capture-state.sh`.

This is the **observed** state, not the desired state. It's the baseline the
Ansible roles are written against, and the thing to diff when you want to know
what's drifted since.

## Refreshing

```bash
./scripts/capture-state.sh
git diff state/
```

It needs no `sudo` and changes no configuration. Everything except
`00-summary.md` is written without timestamps, and fields that move on their
own — CPU scaling frequency, free memory, kernel module refcounts, disk usage,
snapd's loop-device numbering, systemd timer schedules, PIDs — are stripped or
normalised. Two consecutive runs are byte-identical apart from the summary's
timestamp, so anything a diff shows is real drift.

One deliberate exception to "only reads": the script lists `/mnt/*` and
`/media/*`, and touching a mountpoint is what triggers an
`x-systemd.automount` to attach. That's transient and self-reversing.

## Reading `57-post-iso-additions.txt`

The file to open first when asking "what would a rebuild lose?".

`dnf` transaction 1 is the package set baked into the installation image,
stamped when the ISO was built rather than when this machine was installed.
Everything after it happened here. That boundary is derived from the machine's
own records, not from anyone's memory — which matters, because the packages
that made Steam work were installed once, months ago, by a Nobara helper
nobody wrote down.

It covers RPMs only. Two other things drift and are recorded elsewhere:

- **Flatpaks and Snaps** — `60-flatpaks-snaps.txt`. Watch the Snap publisher
  column; that's how a third-party `claudeai-desktop` snap was found sitting
  alongside the packaged Claude Desktop this repo actually manages.
- **Proton builds and Lutris runners** — `95-gaming-stack.txt`. Both are
  unpacked tarballs: Proton in `~/.steam/root/compatibilitytools.d/`, Lutris's
  own Wine builds in `~/.local/share/lutris/runners/`. No package manager knows
  either exists, so a rebuild loses them silently — the game just stops working
  and the reason appears in no package list. `roles/gaming` pins the Proton
  build for that reason; everything else in that section is unmanaged.

That file also reports **Steam library folders and whether they still exist**.
A library Steam still believes in but which has been renamed or unplugged
presents as "my games vanished" and explains nothing about why.

## Reading `90-desktop-kde.txt`

Plasma settings, captured so that "what have I actually customised?" is
answerable from the machine when it comes time to codify the desktop. **No role
manages any of this yet** — the desktop is still being set up, and codifying a
half-finished configuration would be worse than not codifying it.

It dumps an **allowlist** of settings files, never a sweep of `~/.config`.
Three exclusions are deliberate and must stay that way, because this file is
committed:

| Excluded | Why |
|---|---|
| `kdeconnect/` | Device pairing **private key** and certificate |
| `kwinoutputconfig.json` | Monitor EDID hashes and identifiers |
| `kactivitymanagerd-statsrc` | Usage statistics — what was opened, and when |

**If a display misbehaves, read `~/.config/kwinoutputconfig.json` directly.**
It is excluded from this capture on purpose and that should stay true — but it
is also exactly where display bugs live, so its absence here is not a reason to
overlook it.

KWin stores one profile per output, **keyed by the monitor's EDID**. On
2026-08-16 a DisplayPort monitor woke from power-save without delivering its
EDID, so KWin could not match its real profile and fell through to a junk
640x480 one it had saved earlier. The bad profile then persisted in that file
and the fault recurred at random — whenever the EDID read lost the race.

Two things to check there: duplicate profiles for one connector (the extra one
is the fallback that bites), and `allowDdcCi`, which lets PowerDevil probe
monitors over I2C at wake time and can be what breaks the EDID read. The
capture's own "Display connector health" section flags the symptom: a connected
output offering only one or two modes has not delivered its EDID.

**Replacing that file requires the session compositor to be stopped**, because
KWin rewrites it while running. Two traps there, both of which cost an attempt
on 2026-08-20:

- `Ctrl+Alt+F3` only *switches* virtual terminals. The Plasma session keeps
  running on the other one, KWin included, so a copy made from a TTY without
  logging out first is silently overwritten later. Log out first.
- **The login screen runs its own `kwin_wayland`.** `plasma-login` starts
  `plasma-login-kwin_wayland.service`, which overlaps the session's compositor
  — the greeter's is still up when yours starts. So `pgrep kwin_wayland` never
  returns empty and cannot tell you whether *your* session is running. Check
  the unit instead:

  ```bash
  systemctl --user is-active plasma-kwin_wayland.service
  ```

Also skipped as generated state with no settings in it: `session/`,
`plasmanotifyrc`, `kconf_updaterc`, `Trolltech.conf`, `QtProject.conf`.

Two things are worth understanding before reading it:

- **Plasma config cascades** — `/etc/xdg` → `~/.config/kdedefaults` (the
  distro's look-and-feel) → `~/.config`. The user files already hold only what
  deviates from the defaults beneath them, so this is a delta already. The
  distro defaults are captured alongside for comparison.
- **The panel is inventoried, not recorded.** `plasma-org.kde.plasma.desktop-appletsrc`
  carries per-screen geometry and applet ids that mean nothing on a rebuilt
  machine. Which widgets are on the panel is worth knowing; where they sit is
  not worth diffing.

## Reading `45-network-mounts.txt`

**An empty "currently mounted" section does not mean the shares are broken.**
They use `x-systemd.automount` with a 60-second idle timeout, so they unmount
when nothing is using them — which looks identical to the failure this repo
spent 2026-08-15 diagnosing. The automount unit is the signal:

| State | Meaning |
|---|---|
| `active/waiting` | Healthy, idle, will mount on first access |
| `active/running` | Healthy, mounted right now |
| `inactive/dead` | Not armed — a real problem |

The capture lists mountpoint contents *before* observing mount state, so the
two sections agree rather than showing a half-idle picture.

## Before committing

Output is redacted by default: usernames, hostname, MAC addresses, UUIDs and
serial numbers are masked. **Read the diff before committing anyway.**
Redaction is pattern-matching, not a guarantee, and `97-user-env.txt` is the
one most likely to pick up something personal.

Credential files are never read — `45-network-mounts.txt` records that they
exist and what their permissions are, nothing more.

## Files

| File | Contents |
|---|---|
| `00-summary.md` | At-a-glance summary; the only file with a timestamp |
| `10-os-kernel.txt` | OS release, kernel, boot cmdline, Secure Boot, SELinux |
| `20-hardware.txt` | CPU, memory, PCI and USB devices |
| `30-gpu-nvidia.txt` | GPU, driver version, NVIDIA packages, Vulkan ICDs |
| `40-storage.txt` | Block devices, filesystems, fstab, Btrfs subvolumes |
| `45-network-mounts.txt` | SMB/NFS mounts, mount units, mount failures |
| `50-repos.txt` | DNF repositories and configuration |
| `55-packages-userinstalled.txt` | Explicitly installed packages — the list that matters |
| `56-packages-all.txt` | Every installed RPM, dependencies included |
| `57-post-iso-additions.txt` | **What's been added since the ISO** — see below |
| `60-flatpaks-snaps.txt` | Flatpak apps, runtimes, remotes, and Snap packages |
| `70-services.txt` | Enabled units, timers, failed units |
| `80-kernel-tuning.txt` | sysctl, modprobe, udev, limits, CPU governor |
| `90-desktop-kde.txt` | Plasma settings — an allowlist, see below |
| `95-gaming-stack.txt` | Steam/Proton/Lutris/gamemode and controllers |
| `97-user-env.txt` | Groups, shell, dotfiles, KVM access, Claude doctor |
