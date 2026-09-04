# Changelog

Dated log of what's been done to `gaming-pc`, and whether it's been codified
into this repo yet.

## 2026-09-04

- **Idle suspend confirmed working, with a game running.** Five clean suspends
  in two days, each within seven seconds of the configured hour:
  2 Sep 21:51, 3 Sep 09:38, 3 Sep 17:50, 4 Sep 08:46, 4 Sep 09:51. The last
  suspend before the fix was 31 Aug 16:25.

## 2026-09-02

- **A running game was blocking all power management, by design.** SDL and
  `gameoverlayui` each register a "Playing a game" inhibition with KDE's policy
  agent for as long as a game is open — menu included. Measured over 18 minutes
  with Black Mesa live: brightness constant, DPMS never off, nothing fired.
- **Fixed in `roles/gaming`** with `SDL_VIDEO_ALLOW_SCREENSAVER=1` written to
  `~/.config/environment.d/51-sdl-allow-screensaver.conf`
  (`gaming_allow_screensaver_during_games`). Verified afterwards: game running,
  inhibition list empty. It removed the `gameoverlayui` inhibition too, which
  was not certain going in. Tradeoff accepted knowingly — this machine is
  keyboard-and-mouse only, so the gamepad case the inhibition protects does not
  arise here.
- **The login screen has no power management at all.** The `plasmalogin`
  greeter runs as its own user (uid 985) and ships no PowerDevil — zero
  PowerDevil journal entries across a 49-minute greeter session on 2 Sep. A
  machine left at the login screen never dims, blanks or suspends, and cannot
  be made to by any user-level config.
- **Fixed in `roles/power_management`** with auto-login via
  `/etc/plasmalogin.conf.d/10-autologin.conf` (`power_autologin`). A drop-in,
  not an edit to the package-owned `/etc/plasmalogin.conf`. The role refuses to
  write if the named session does not exist, since that would produce a login
  loop at the next boot. **Not yet verified — the machine has not rebooted
  since.**
- **New `scripts/check-power-inhibitors.sh`.** Answers "why isn't this machine
  sleeping?" in one command. It exists because `systemd-inhibit --list` does
  **not** show application inhibitions — those live in KDE's policy agent, so
  the obvious command shows nothing and everything looks fine. It also flags
  requests left behind by an app that has exited, which is a real failure mode:
  see 2026-09-01 below.
- **A stale inhibition survived the game that registered it.** Killing the hung
  Black Mesa on 1 Sep left both "Playing a game" requests held, because the
  D-Bus connection belongs to the surviving Steam client rather than the dead
  game. Power management stayed blocked for a day with no indication why.
  Cleared with `systemctl --user restart plasma-powerdevil.service`. Largely
  pre-empted now that games no longer register the inhibition at all.
- **A diagnostic mistake worth not repeating.** Shortening the dim timeout to
  60s to test quickly requires restarting PowerDevil to load it, and that
  restart appears to disturb the idle chain — the test showed no dim and was
  read as "idle detection is broken", wrongly. The first real suspend landed
  exactly 60 minutes after the test restored the timers, which is what gave it
  away. **Measure the machine's real behaviour over real timings**; do not
  restart PowerDevil mid-measurement.

## 2026-09-01

- **The 640x480-on-wake fault recurred, and DDC/CI was not the cause.** DP-2
  came back from blanking with no EDID again — one mode, 640x480 — despite
  `allowDdcCi=false` and zero `i2c` retry lines in the journal. The August fix
  removed a real delay but never addressed the root cause.
- **No software can recover it**, established rather than assumed:
  `kscreen-doctor` disable/enable failed, and so did
  `echo detect > /sys/class/drm/card1-DP-2/status`, which is the deepest
  re-probe the kernel offers. Only power-cycling the monitor works. That also
  means an auto-healing service is not worth building — it would have nothing
  to call.
- **It is hardware.** The DP link watcher recorded **63 disconnects on DP-2
  against 6 on DP-3** — same GPU, driver, KDE config and power settings, so the
  only variables that differ are cable, monitor port and GPU port.
- **New `scripts/test-display-wake.sh`** drives DPMS directly instead of
  waiting 20 minutes for the real blank timeout, and counts how often each
  connector returns without an EDID. The fault is intermittent, so the failure
  *rate* is the measurement — a single clean cycle proves nothing.
- **DP-2's cable replaced.** 5/5 clean cycles afterwards, but with no
  before-measurement (the script did not exist while the old cable was still
  fitted) that is suggestive rather than conclusive. The real evidence will be
  the 63:6 ratio normalising over a week of ordinary use; the watcher log is
  marked at the cable change so the comparison is countable.
- Each failure also writes a fresh junk 640x480 profile into
  `kwinoutputconfig.json`. That makes the fault stickier but is not its cause:
  with no EDID the kernel offers 640x480 regardless of what KWin has saved.

## 2026-08-24

- **Brave removed, LibreWolf installed and set as default**, all in
  `roles/desktop_apps`.
  - **Brave shipped with the Nobara image** (dnf transaction 1), so removing it
    is a deliberate exception to "manage the delta, not the distribution" —
    that rule is about not fighting `nobara-sync` over versions, not about
    being obliged to keep every application the distro includes.
    `nobara-browser-policy` is removed with it (requires `brave-browser`, ships
    only Brave's policy file, nothing depends on it). `brave-keyring` and the
    Brave repo are left alone, because `nobara-repos` owns the repo file.
  - **LibreWolf's repo had to be codified.** Nothing owned
    `/etc/yum.repos.d/librewolf.repo` — added by hand on 2026-08-09 — so a
    rebuild would have had no repo to install from, and the default-browser
    step would have pointed at a missing desktop file.
  - **Brave was never "hijacking" anything.** No default browser had ever been
    set; Brave simply won the fallback as the first application claiming
    `x-scheme-handler/http`. Links from Proton Mail hit it because flatpaks
    resolve URLs through the XDG portal, which asks the host for the default
    and took the first match.
  - The default is set after the installs and removals, since setting one for
    a desktop file that does not exist yet does nothing. `xdg-settings check`
    gives genuine idempotency: verified `changed=0` when correct, and the role
    restores LibreWolf when the default is changed behind its back.
- **New `roles/system_tuning`, capping core dump storage.** Black Mesa
  segfaults during shutdown on every exit — a known Source-engine-on-Linux bug
  in GL teardown, harmless in itself since the game has already quit — but each
  one writes a 300-500 MB core. Seven had accumulated 2.8 GB of the 3.1 GB in
  `/var/lib/systemd/coredump`.
  - **systemd's defaults are proportional to disk size**, which is the wrong
    shape here: `MaxUse` defaults to 10% of the filesystem (~91 GB on this
    volume) and `KeepFree` to 15% free (~137 GB). The `tmpfiles` rule ages the
    directory at two weeks, far too slow when dumps arrive faster than that.
  - Now capped at `MaxUse=1G` / `KeepFree=20G` via a drop-in under
    `coredump.conf.d/`, so a systemd update doesn't conflict.
  - **The role deletes nothing.** `systemd-coredump` enforces the cap when it
    writes the next dump, so usage can sit above it until then; the role
    reports current usage instead. Deleting crash evidence unattended isn't
    this repo's habit.
  - **`ProcessSizeMax=100M`** as well, so the game dumps are never written at
    all. Under a 1 GB cap a single 500 MB core would evict everything smaller
    and more useful; at 100M the crashes worth inspecting still get stored
    (those findmnt ones were 56 KB) and the unfixable one does not. The
    trade-off: a large core from something genuinely worth debugging is now
    skipped rather than kept — the journal still records the crash, but the
    memory image is gone.
- **The crash itself is not fixable** and is recorded as such, so nobody
  spends an afternoon on it. The stack trace is a single unresolvable frame in
  the shutdown path. Steam's own segfaults, by contrast, all date from
  2026-08-09 during initial setup and have not recurred.
- Two of my own corrections worth noting: `coredumpctl` has no `--vacuum-size`
  option (that is `journalctl`), and a two-week `tmpfiles` aging rule does
  exist — I had implied nothing was pruning these at all.

## 2026-08-21

- **Idle timings relaxed and then separated**: dim at 10 minutes, blank at 20,
  lock at 30, suspend unchanged at 60. Previously 9 / 10 / 10, which locked the
  session several times a day — a pause long enough to read something was
  enough.
  - Blanking and locking are now deliberately **not** coincident. Blanking
    saves the power, locking is the security boundary, and there is no reason
    they must happen at the same moment. The ten minutes between them is a
    grace period: the screen is dark, but a mouse nudge brings it back with no
    password.
  - Changed in `roles/power_management` defaults and applied through the role
    rather than by hand, so the repo and the machine stayed in step. Second run
    reported `changed=0` both times.
- **Game load times: shader handling investigated and partly codified.**
  Black Mesa was showing "Processing Vulkan shaders" on every launch and taking
  far longer than 33s to reach its menu; it is now 33s with the dialog gone.
  - The dialog was **Steam's shader pre-caching** — `fossilize_replay` chewing
    through 2.5 GB of Valve's precompiled pipeline caches for that one game.
    Those mainly help Mesa/RADV; the NVIDIA driver keeps its own cache and
    gains little. Disabled in Steam, which then reclaimed the space. Left as a
    manual step: it lives in `config.vdf`, which Steam rewrites while running.
  - **`roles/gaming` now manages NVIDIA's shader cache** via
    `~/.config/environment.d/50-nvidia-shader-cache.conf` — 12 GB cap, cleanup
    disabled. The driver default of roughly 1 GB is exhausted by a few games
    between them, and the eviction that follows is why "building shaders"
    returns after a driver update. Uses `environment.d` rather than a shell
    profile because Steam is launched from the desktop, never a terminal.
  - The role reports that the setting needs a **new session** — the systemd
    user manager reads `environment.d` only at startup, so the file is inert
    until logout, and Steam must be started from the new session to inherit it.
  - Verified: 0 changed when matching, 1 changed and corrected when the value
    was altered behind its back, and works with `gaming_manage_proton: false`.
- **Correction to an earlier entry.** On 2026-08-16 the NTFS Steam library was
  written off as defunct. It is not — Black Mesa lives there with 206 hours
  played. The library is active, and moving games to the btrfs NVMe remains a
  real (unmanaged) option for load times.
- **`claude_desktop` now tracks `latest` for the app itself.** With
  `state: present` it was installed once and then drifted — the app's own
  `--doctor` had been reporting `official pool has 1.32885.1, this install
  packages 1.30096.1` on every run, and nothing else on the machine updates
  that repo.
  - The install task was **split in two**. `nodejs`, `qemu-system-x86` and
    `edk2-ovmf` stay at `state: present` in their own task, because they are
    Nobara's packages and `latest` on them would force upgrades on Ansible's
    schedule instead of `nobara-sync`'s. They had been in the same dnf call as
    the app, which made that distinction impossible to express.
  - Tunable via `claude_desktop_state` for anyone who would rather pin it.
- **Full playbook run against the machine: `ok=44 changed=3 failed=0`.**
  Proton VPN and Proton Mail installed as intended. The third change was a bug.
- **`smb_mounts` was reporting `changed` forever on "Create mountpoints".**
  While a share is mounted, the mountpoint path *is* the remote filesystem's
  root. The mounted CIFS root reports the mount's `dir_mode` (0775), not the
  0755 the task wants for the bare directory, so Ansible saw a mismatch and
  issued a `chmod` against the server — which CIFS ignores, because `dir_mode`
  is forced. Every run reported a change and no run changed anything.
  - Fixed by checking `findmnt` first and skipping mountpoint creation for
    anything already mounted. Verified: three mounted shares, all skipped,
    `changed=0`; the task still runs and sets ownership when nothing is
    mounted, which is the case that matters on a rebuild.
  - Only visible by running the playbook twice and reading the recap. A single
    run looks entirely healthy.

## 2026-08-20

- **New `roles/desktop_apps`** for applications added after the install:
  qBittorrent and Proton VPN via dnf, Proton Mail via Flathub at user scope.
  - **Two of the five requested Proton apps do not exist on Linux.** Proton
    Calendar has no standalone client — it is a tab inside the Proton Mail
    desktop app. Proton Drive has no Linux client at all; `rclone` speaks its
    protocol and the role can install it, but it is off by default since a
    command-line sync tool with no configured remote achieves nothing.
  - **Proton VPN is the RPM (`proton-vpn-gtk-app`, terra), not the flatpak.** A
    VPN client has to manage NetworkManager, routes and DNS system-wide, which
    is exactly what a flatpak sandbox exists to prevent.
  - Flatpaks are driven with plain `command` tasks rather than
    `community.general.flatpak`, since this repo is ansible-core only. The role
    checks with `flatpak info` first, because `flatpak install` is not quiet
    about an already-present ref.
  - User scope, so `become: false` and a refusal if it would run as root —
    otherwise the install lands in root's flatpak installation and the run
    reports success. Fourth role to need this guard.
- **KWin config landmine cleared.** The stale 640x480 profile for DP-3 is gone
  and `allowDdcCi` is false on all three outputs. Done by an `at` job watching
  `plasma-kwin_wayland.service`, after a first attempt watching the
  `kwin_wayland` *process* waited forever: **the login screen runs its own
  compositor** (`plasma-login-kwin_wayland.service`), overlapping the session's,
  so the process never disappears. Recorded in `state/README.md`.
- **DP link watcher is now a lingering user service**
  (`~/.config/systemd/user/dp-link-watch.service`, logging to
  `~/.local/state/dp-link-events.log`) so it survives logout, which the earlier
  shell-backgrounded version did not.
- **Power, lock and standby configured, and codified as `roles/power_management`.**
  Screens dim at 9 min, blank and lock at 10 min, machine suspends to RAM after
  1 hour, power button sleeps rather than shuts down, password required on
  resume. Verified: `suspend entry (deep)` -> wake on keypress -> `suspend exit`
  one second later.
- **USB wake took most of the day, and the reason is worth keeping.** The wake
  signal crosses five levels — device, hub, root hub, xHCI controller, PCI
  bridge — and every one must be armed. Arming the device and its hub *looks*
  complete, because both report `enabled`, and the machine still will not wake:
  the signal dies at the root hub above them.
  - Also `ACTION=="add|change"`, not `add` alone. `udevadm trigger` emits a
    *change* event, so the first version of the rule silently did nothing on
    reload and would only have taken effect on the next replug.
  - **The actual blocker was firmware**: MSI BIOS -> Wake Up Event Setup ->
    `Resume By USB Device`, which was Disabled. With it off, every sysfs level
    reads `enabled` and nothing wakes. The role cannot set it, so it is
    documented as a manual step alongside recreating the SMB credentials.
  - **`ErP Ready` was NOT the cause** — already Disabled. It was suspected
    because the keyboard LEDs go dark in S3, which turned out to be a
    consequence of `Resume By USB Device` being off. Recorded so nobody
    re-tests it.
- **PowerDevil's action enum established by measurement**: `1` = Sleep,
  `8` = Shut down. Set each in System Settings, read back what was written. An
  earlier guess that `8` was "Lock screen" was wrong, and `AutoSuspendAction`
  is pinned explicitly rather than left to an upstream default, because getting
  it wrong means a machine that shuts down after an hour idle.
- **A monitor was intermittently dropping its DisplayPort link** — DP-2
  disconnecting and re-training every 2-4 minutes. Fixed by reseating the
  cable, almost certainly disturbed while swapping cables during the BIOS hunt.
  A fresh 640x480 profile appeared for DP-3 in `kwinoutputconfig.json` during
  that period, which suggests the EDID-loss fault recurs whenever a link is
  disturbed rather than being a one-off.
- **Locked out of the BIOS for most of the day.** POST produced no picture on
  either DisplayPort monitor, the GPU's HDMI, or an old TV. The firmware *was*
  outputting video the whole time — `simpledrm` gets a framebuffer and BGRT
  reports `status = 1` at 2560x1440 — so the monitors simply weren't syncing to
  it. Eventually displayed on a DisplayPort panel with no clear reason why that
  attempt differed. `Fast Boot` could not be found in the menus. Unresolved;
  `systemctl reboot --firmware-setup` at least removes the key-timing problem.
- **Three wrong inferences worth recording**, all from reading indirect signals
  where a direct test would have been faster: ErP Ready (LEDs going dark),
  "root hub lost power" (taken as evidence the *other* controller kept power),
  and the Lutris runner (assumed wine-ge-8-26 would launch DOOM when umu was
  already selecting GE-Proton11-5 from the prefix's own version file).

## 2026-08-16 (display wake fault)

- **A monitor kept returning from power-save at 640x480.** Diagnosed from the
  machine: DisplayPort fully de-enumerates when a display sleeps, and on wake
  PowerDevil immediately probes the monitors over I2C for DDC/CI brightness
  control (`libddcutil.so.5`). That collides with the link retraining —
  `org_kde_powerdevil: /dev/i2c-3, Checking EDID failed after 3 tries`.
  - KWin stores display profiles **keyed by EDID**. With no EDID it could not
    match DP-2's real profile and fell through to a junk 640x480 one saved
    earlier. That bad profile then lived permanently in
    `~/.config/kwinoutputconfig.json`, so the fault recurred whenever the EDID
    read lost the race — which is why it was intermittent.
  - Fixed by recovering the output, deleting the bad profile, and setting
    `allowDdcCi: false` on both outputs. Cost: no software brightness control
    for these monitors, which have their own buttons.
- **New display health check** in `90-desktop-kde.txt`. A connected output
  offering only one or two modes has not delivered its EDID, which is the whole
  fault in one line. Mode count is the reliable signal — the sysfs `edid` file
  reads as 0 bytes to an unprivileged user even on a healthy output, which is a
  good way to chase the wrong thing for a while.
- **`state/README.md` now points at `kwinoutputconfig.json` for display bugs.**
  It stays excluded from capture — it holds monitor EDID hashes — but its
  absence from `state/` shouldn't mean it gets overlooked when a display
  misbehaves. Duplicate profiles for one connector, and `allowDdcCi`, are the
  two things to look at.

## 2026-08-16

- **Lutris runners are now captured.** Lutris keeps its own Wine builds in
  `~/.local/share/lutris/runners/` — `wine-ge-8-26-x86_64` today — which is the
  same unpacked-tarball category as Proton builds in `compatibilitytools.d`:
  no package manager knows they exist, and a rebuild loses them silently. The
  gaming section now groups both under one heading that says so.
- **`95-gaming-stack.txt` also reports Steam library folders and whether they
  still exist.** Prompted by a real case: renaming a library directory left
  Steam pointing at a path that was gone, which presents as "my games vanished"
  and explains nothing. A `MISSING` line makes it obvious.
- **`GE-Proton11-5-x86_64` deliberately not pinned** in `roles/gaming`. It was
  fetched automatically by `umu` to match a Wine prefix, not chosen — pinning
  it would codify a side effect. `GE-Proton11-3` stays pinned because it was a
  decision. umu re-fetches what a prefix needs, so a rebuild recovers it.
- **Two more capture noise sources removed**, both found by reading a diff
  rather than the script: Plasma stamps `# created by KDE Plasma, <date>` into
  `gtkrc` on every login, and `swapon --show` reports swap currently in use.
  Both diffed constantly while saying nothing. Masked and dropped respectively.

## 2026-08-15 (KDE capture)

- **Plasma settings are now captured, and deliberately not managed.**
  `state/90-desktop-kde.txt` previously listed config *filenames*; it now dumps
  an allowlist of the settings files themselves, plus the distro defaults they
  cascade on top of.
  - **No role applies any of it.** The desktop is still being set up, so
    codifying it now would freeze a half-finished configuration. The capture
    exists so that when it is finished, "what have I actually customised?"
    comes from the machine rather than from memory.
  - **Why there's little to codify yet**: the machine is close to stock Nobara
    Plasma. `kcminputrc` doesn't exist, `kwinrc` holds a generated UUID and the
    default tiling layout, `kdeglobals` `[General]` is one opaque
    `ColorSchemeHash`, and the 251 lines of `kglobalshortcutsrc` are Plasma's
    own defaults.
  - The clear exception is `powerdevilrc` — dim at 600s, display off at 900s,
    120s when locked, `AutoSuspendAction=0`. **Confirmed deliberate by the
    owner**, so recorded as intentional rather than as drift to be tidied.
- **Three exclusions, chosen before writing anything that dumps file
  contents**, since this output is committed to a public repo:
  `~/.config/kdeconnect/` holds a device-pairing **private key** and
  certificate; `kwinoutputconfig.json` holds monitor EDID hashes and
  identifiers; `kactivitymanagerd-statsrc` holds usage statistics. A naive
  "capture my dotfiles" sweep would have published the first of those.
  Verified after the fact: no key material, EDID field, or username in the
  output.
- **The panel is inventoried, not recorded.** `plasma-org.kde.plasma.desktop-appletsrc`
  carries per-screen geometry and applet ids that mean nothing on a rebuilt
  machine, so only the widget list is captured.
- **Noted for whenever the role does get built**: use `kwriteconfig6`, not file
  copying. Plasma rewrites these files while running, so copying whole files
  fights it for ownership and clobbers anything undeclared.

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
