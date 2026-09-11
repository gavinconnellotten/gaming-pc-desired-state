# CLAUDE.md

Context for Claude Code working in this repo.

## What this is

Desired-state configuration for `gaming-pc`, a personal Fedora/Nobara desktop.
The goal: a fresh install can be brought back to a known-good state by running
the playbook, rather than by re-following manual notes.

This is a gaming machine with casual scripting on the side — **not** a
development workstation. Prefer boring, legible configuration over clever
abstraction. The owner is comfortable in a terminal but doesn't want this repo
to become a project in its own right.

## The machine

| | |
|---|---|
| Hostname | `gaming-pc` |
| OS | Nobara Linux 44 (Fedora-based), KDE Plasma |
| CPU / GPU | AMD CPU, NVIDIA GeForce RTX 4060 Ti |
| NVIDIA driver | 595.91.07, installed from the Nobara NVIDIA driver ISO |
| Storage | Single internal NVMe, whole disk, OS volume |
| Migrated from | Windows 11, week of 2026-08-07 |

## How this repo is run

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass
```

Run **as the user, with `--ask-become-pass`** — not under `sudo`. See the
diagnostics gotcha below; this distinction is load-bearing.

## Conventions

- **`ansible-core` only.** No Galaxy collections. `/etc/fstab` is managed with
  `ansible.builtin.blockinfile` rather than `ansible.posix.mount` specifically
  to avoid a collection dependency. Keep it that way unless there's a real
  reason — adding one means another install step on a rebuilt machine.
- **One role per concern**, each with a `README.md` explaining not just what it
  does but *why* — several roles encode non-obvious failure modes.
- **`CHANGELOG.md` is the ledger**: dated entries recording what was done to
  the machine and whether it's been codified here yet. Update it with any
  substantive change. It's the record of manual-vs-managed drift.
- **No secrets in the repo.** Credentials live in root-owned `0600` files
  outside it, referenced by path. Roles fail loudly when they're missing
  rather than proceeding.
- Roles should **verify their own work** where cheap, and report status rather
  than assuming success.

## Current state

| Area | Status |
|---|---|
| Claude Desktop | Managed — `roles/claude_desktop` |
| SMB network shares | **Managed and applied** — `roles/smb_mounts` |
| State capture | `scripts/capture-state.sh` → `state/` (baseline captured 2026-08-15) |
| NVIDIA driver | Installed out-of-band, deliberately unmanaged |
| Dotfiles / KDE settings | **Captured, deliberately not managed** — see below |
| Gaming stack | **Post-install additions managed** — `roles/gaming`. Nobara's own packages deliberately unmanaged |
| Power / idle behaviour | **Managed and verified** — `roles/power_management`. Includes auto-login. Depends on a BIOS setting the role can't apply |
| Desktop apps | **Managed** — `roles/desktop_apps`. qBittorrent, Proton VPN, Proton Mail, LibreWolf. Brave removal was tried and abandoned 2026-09-12 — it errored every run and blocked three later roles |
| System tuning | **Managed** — `roles/system_tuning`. Core dump storage caps |
| Home Assistant | **Managed from here** — `roles/homeassistant`. Weekly config backup pulled to this machine. HAOS is deliberately *not* an Ansible host |
| Health reporting | `scripts/check-gaming-pc.sh`, `scripts/check-homeassistant.sh` — read-only, plus a weekly Claude routine |
| HA add-on settings | **Enforced** — `roles/homeassistant`, via the Supervisor API. Whisper model pinned to `small` |
| HA config capture | `scripts/capture-homeassistant.sh` → `state/homeassistant/` — captured, not enforced |

## Manage the delta, not the distribution

The organising principle for anything Nobara also ships. `dnf` transaction 1 is
the package set baked into the ISO; everything after it happened on this
machine. `state/57-post-iso-additions.txt` computes that boundary from dnf's
own history, so "what did I install to fix Steam?" is answerable from the
machine rather than from memory.

Roles should manage that delta and leave the rest alone. `roles/gaming`
installs the runtime dependencies and codecs that were added by hand, and
pointedly does **not** install Steam, Lutris, gamescope, MangoHud or OBS —
those come with the image and Nobara updates them on its own cycle.

Three things drift and only one is a package manager's business:

| Kind | Where it's recorded |
|---|---|
| RPMs | `state/57-post-iso-additions.txt` |
| Flatpaks and Snaps | `state/60-flatpaks-snaps.txt` |
| Unpacked tarballs (Proton-GE) | `state/95-gaming-stack.txt` |

The third is the dangerous one: ProtonPlus drops Proton builds into
`~/.steam/root/compatibilitytools.d` as plain directories that no package
manager knows about, so a rebuild loses them silently.

## SMB shares — done

Three shares, all on `homeassistant.local` (Home Assistant's "SambaNAS2"
addon) under one login, managed by `roles/smb_mounts` and applied 2026-08-15:

| Share | Mountpoint |
|---|---|
| `SSD/MOVIES` | `/mnt/plex-movies` |
| `ELEMENTS/Music` | `/mnt/plex-music` |
| `MEDIA/TV SHOWS` | `/mnt/plex-tv` |

They had been failing because the credentials file read `username=gavin  ` with
two trailing spaces, which `mount.cifs` passed verbatim — so the server rejected
a user that didn't exist. `CHANGELOG.md` has the full diagnosis;
`roles/smb_mounts/README.md` has the causes in the order actually worth
checking, and the two gotchas (systemd `\x2d` unit escaping, and why
`findmnt --verify` can't be used directly as a `validate:`).

Worth knowing when re-reading this:

- **A rebuilt machine needs the credential file recreated** by
  `./scripts/setup-smb-credentials.sh` before the playbook can do anything.
  That's deliberate — no passwords in the repo.
- **Share names with spaces are written literally in `host_vars`**; the role
  escapes them to `\040`. The Jinja filter takes **one** backslash, not two —
  two renders a path that's wrong but still parses, so nothing catches it.
- **The role refuses to run** alongside unmanaged CIFS lines in `/etc/fstab`,
  and prints the command to comment them out.

## KDE settings — captured, not managed, and that's on purpose

`state/90-desktop-kde.txt` records Plasma's settings. **No role applies them,
and that's a decision rather than an omission**: as of 2026-08-15 the desktop is
still being set up, so codifying it would freeze a half-finished configuration.
Don't build a `kde_settings` role until the owner says the desktop is settled.

What the capture showed, which is why there's little to codify yet: this
machine is close to stock Nobara Plasma. `kcminputrc` doesn't exist,
`kwinrc` holds a generated UUID and the default tiling layout, `kdeglobals`
`[General]` is a single opaque `ColorSchemeHash`, and the 251 lines of
`kglobalshortcutsrc` are Plasma's own defaults.

The one area that *was* a set of deliberate choices, `powerdevilrc`, has since
moved out of this section entirely — it's managed by `roles/power_management`
now. Don't treat power settings as unmanaged KDE config; see the power section
below.

When the time comes, use **`kwriteconfig6`, not file copying**. Plasma rewrites
these files while it runs, so copying whole files fights it for ownership,
clobbers every setting not declared, and restores UUIDs that mean nothing on a
new install. Declaring individual keys is the same principle as the managed
block in `/etc/fstab`: own the settings that were decided, leave the rest alone.

If a whole file *must* be replaced, the session compositor has to be stopped
first — and note that the login screen runs its own `kwin_wayland`, so
`pgrep` cannot tell you whether yours is running. Check
`systemctl --user is-active plasma-kwin_wayland.service`. See `state/README.md`.

**Three files must never be captured or committed** — the capture excludes them
by name and that list is load-bearing, not decoration:

| File | Why |
|---|---|
| `~/.config/kdeconnect/` | Device pairing **private key** and certificate |
| `kwinoutputconfig.json` | Monitor EDID hashes and identifiers |
| `kactivitymanagerd-statsrc` | Usage statistics |

## Power and idle behaviour — one part is firmware

`roles/power_management` sets when the screens blank, when the session locks,
and when the machine suspends. It also installs a udev rule arming USB wake.

Current timings, four separated stages: **dim at 10, blank at 20, lock at 30,
suspend at 60 minutes.** Revised 2026-08-21 from 9/10/10, which locked the
session several times a day.

It also opens the **Saturday maintenance window** (08:10–10:30): an RTC alarm
to wake the machine, and a logind `sleep` inhibitor so it cannot suspend out
from under the update, the backup or the report. The inhibitor asks for
`sleep` only and deliberately not `idle`, so the screen still locks on the
normal timing.

**RTC wake is verified** (2026-09-12) and — unlike `Resume By USB Device` —
needs no BIOS change. Re-test with `scripts/test-rtc-wake.sh`. Two traps cost
real time getting there: a successful wake can leave the **monitor dark**, so
it looks like the machine never came back; and journal timestamps **collapse
across a suspend**, so `journalctl` cannot tell you whether the resume came
before or after a keypress. The script keeps its own heartbeat for that reason.

The machine resumes to the **lock screen**, which is intended. The session
survives with `Linger=yes`, so the update (system service), the backup (user
timer) and the report (Claude Desktop in the live session) all still run.

Blanking and locking are deliberately **not** coincident. Blanking is what
saves the power; locking is the security boundary; there is no reason they must
fire together. The ten minutes between them is a grace period where the screen
is dark but a mouse nudge restores it with no password.

**The role cannot make wake work on its own.** MSI BIOS → Settings → Advanced →
Wake Up Event Setup → **Resume By USB Device must be Enabled**. With it off,
every sysfs level reads `enabled` and the machine still will not wake — the rule
is present, correct and inert. A rebuild restores the rule and cannot restore
the firmware setting, so it sits on the manual checklist next to recreating the
SMB credentials.

`ErP Ready` was **not** the cause and was already Disabled. It got suspected
because the keyboard LEDs go dark in S3, which is a consequence of
`Resume By USB Device` being off. Recorded so nobody re-tests it.

### Two things stopped it working that were not settings at all

Resolved 2026-09-02, verified 2026-09-04 by five clean suspends within seven
seconds of the configured hour. Both are worth knowing before touching a timer
value, because neither is visible in `powerdevilrc`.

**A running game blocks everything, by design.** SDL and `gameoverlayui` each
register a "Playing a game" inhibition for as long as a game is open — menu
included — so a game left running means a machine that never sleeps.
`roles/gaming` now sets `SDL_VIDEO_ALLOW_SCREENSAVER=1`, which removes both
(the `gameoverlayui` one goes too, which was not obvious in advance). The
tradeoff is real but does not apply here: it would permit blanking during
gamepad-only play, and this machine is keyboard-and-mouse.

That inhibition can also **outlive the game**. Killing a hung game leaves it
held, because the D-Bus connection belongs to the surviving Steam client rather
than the dead game. `systemctl --user restart plasma-powerdevil.service` clears
it and re-reads the config.

**The login screen has no power management whatsoever.** The `plasmalogin`
greeter runs as its own user and ships no PowerDevil, so a machine sitting at
it stays fully awake indefinitely — and no user-level config can reach it.
`roles/power_management` closes this with auto-login, written as a drop-in to
`/etc/plasmalogin.conf.d/` rather than into the package-owned
`/etc/plasmalogin.conf`. The role refuses to write if the named session does
not exist, since that produces a login loop at the next boot.

### Diagnosing this, and one trap

Run **`scripts/check-power-inhibitors.sh`** first. It exists because
`systemd-inhibit --list` does **not** show application inhibitions — they live
in KDE's policy agent, so the obvious command reports nothing and everything
looks healthy. The script also flags requests left behind by an exited app.

Two measurement traps, both paid for:

- **PowerDevil does not log dim or blank** at default verbosity. Journal
  silence is not evidence. Sample brightness instead.
- **Do not shorten the timers to get a fast test.** Loading a shortened value
  means restarting PowerDevil, and that restart disturbs the idle chain — a
  60-second dim test showed nothing and was read as "idle detection is broken",
  which was wrong, and led to a hardware accusation against the USB-to-PS/2
  adapter that was also wrong. Measure real behaviour over real timings.

Two things worth not rediscovering:

- **The USB wake signal crosses five levels** — device, hub, root hub, xHCI
  controller, PCI bridge — and all must be armed. Arming the device and its hub
  looks complete (both report `enabled`) and does nothing, because the signal
  dies at the root hub. `roles/power_management/README.md` has a chain-walking
  snippet; use it rather than checking the device.
- **PowerDevil's action enum: `1` = Sleep, `8` = Shut down**, verified by
  setting each in System Settings and reading back what was written. An early
  guess that `8` meant "Lock screen" was wrong, and getting `AutoSuspendAction`
  wrong means a machine that shuts down after an hour idle.

## The second machine: Home Assistant

`homeassistant.local` (192.168.68.117) is a mini PC running **Home Assistant
OS**, serving the three SMB shares this desktop mounts. `roles/homeassistant`
manages the relationship; `roles/homeassistant/README.md` has the detail.

**It is not an Ansible host and cannot be one.** HAOS ships no Python, so no
module can run there — only `raw`, which is shell with extra steps and none of
Ansible's idempotency. The role manages the gaming-pc side and reaches across
over SSH. Don't add an inventory group for it: a group that can only run `raw`
misrepresents what this repo controls.

**The SSH key covers add-on and Supervisor work.** Inside the SSH session the
Supervisor API is at `http://supervisor` with `$SUPERVISOR_TOKEN` already
exported, so `roles/homeassistant` needs no separate credential for backups,
add-on settings or mount repair.

**A long-lived HA token exists for the Core API**, at
`~/.config/homeassistant/api-token` — user-owned `0600`, added 2026-09-12.

That is a deliberate departure from "credentials live in root-owned `0600`
files", and the distinction matters. The root-owned rule exists because
`mount.cifs` runs as root and the SMB credentials must not be readable by
anything else. This token's consumers are all user-level — the health scripts,
the backup timer, ad-hoc queries — so a root-owned copy is not more secure, it
is merely unusable. The original at `/etc/homeassistant/api-token` sat unread
for a week for exactly that reason.

What it unlocks, and why it is worth having: reading entity states directly
(the camera analysis previously copied a 223 MB database over the network to
get at them), reloading YAML without restarting Home Assistant, deleting
config entries, and calling services — which means an automation can be
*tested* rather than handed over untested.

It grants full control of the home automation system. Treat it like the SMB
passwords: never printed, never committed, never passed as a command-line
argument.

**The mounts look circular and are not wrong.** Home Assistant mounts CIFS
shares from its own Samba add-on, because HAOS's Supervisor can only mount CIFS
and NFS as media storage — looping through the local Samba server is the
documented way to expose a USB disk to add-ons. The consequence that matters:
a Samba NAS2 restart drops HA's own media mounts and Plex sees empty libraries.
That is why every add-on except Music Assistant has auto-update disabled.

**Samba NAS2 has two separate `auto_update` settings** — the Supervisor
property and its own internal option. Turning off one looks done.

**Media is deliberately not backed up.** Backups are config-only: 60 MB against
8900 MB for a full one, which is mostly Ollama's models. The ~67 GB TV library
on the HA system disk is therefore protected by nothing — an accepted risk, not
an oversight.

### Voice control and music — the one setting that mattered

Voice music requests failed constantly until 2026-09-10. The cause was
**Whisper running the `tiny` speech model**: it heard "Love Is All Right" as
"love is all as all right", and the music automation searched the library for
that literally. `roles/homeassistant` now pins `model: small`. Do not drop it
back without testing real song titles — proper nouns are the whole difficulty.

Three genuine defects were found and fixed alongside it, **none of which were
the cause**: an empty description on `script.claude_play_music` (that string is
the tool description the LLM sees), a `default_player` pointing at an entity
that no longer existed, and a prompt instructing Claude to say "sorry I didn't
catch that" rather than ask a clarifying question.

There are **two voice paths**, and the non-LLM one usually wins: a
`conversation` sentence-trigger automation catches "play X" before Claude sees
it, even with `prefer_local_intents: false`. It is left enabled deliberately —
faster than an LLM round-trip, and reliable now transcription is accurate.

What can and cannot be managed:

| Layer | Handling |
|---|---|
| Add-on options and Supervisor properties | **Enforced** |
| YAML files | **Captured** to `state/homeassistant/` |
| `.storage` (Claude prompt/model, pipeline, registries) | **Captured**; restored from the weekly backup |

`.storage` is owned by the running Home Assistant, which rewrites it — the same
trap as Plasma and qBittorrent config. Don't try to enforce it.

Run `./scripts/capture-homeassistant.sh` then `git diff state/homeassistant/`
to see drift. It redacts credentials and never reads `secrets.yaml`.

## Updates

Automated on gaming-pc, deliberate on Home Assistant. The rule that matters is
not "automate or don't" — it is **use the tool that understands the system**.

- **gaming-pc:** `roles/os_updates` runs `nobara-sync cli` weekly, never plain
  `dnf` or the App Centre. Nobara's updater does the post-update driver rebuild
  the others skip. The NVIDIA module is verified afterwards and rebuilt if
  missing. **It never reboots.** The App Centre tray reminder is deliberately
  suppressed, since updates are scheduled and reported.
- **Home Assistant:** everything pinned except Music Assistant. Core and HAOS
  have no auto-update setting; the Supervisor updates itself by design. Applied
  by hand, on the owner's judgement.

Saturday sequence, in this order so the report describes the machine *after*
updating: **08:10** wake, **08:20** update, **09:30** HA backup, **~09:49**
report.

All of it now sits inside one maintenance window opened by
`roles/power_management` — an RTC alarm wakes the machine at 08:10 and a logind
inhibitor holds sleep off until 10:30. Before that, none of these times meant
anything: the machine was asleep at 08:00 every week and the update only ran as
a `Persistent` catch-up whenever somebody switched the PC on. **Waking it
early is not sufficient on its own** — with no keyboard input PowerDevil
suspends it again an hour after the wake, which would have killed the 09:30
backup. See the power section below.

**The reason any of this matters, concretely:** on 2026-09-05 a kernel was
installed with no NVIDIA module built for it, because `40-dkms.install` fires
when the *kernel* is installed and `kernel-devel` arrived fourteen minutes later
in a separate transaction. Nothing retried. The only visible symptom was "reboot
pending", which reads like good news. Both `scripts/check-gaming-pc.sh` and the
update script now refuse to call a reboot safe unless the module exists.

Three kernels are kept, so a driverless boot is recoverable by choosing the
previous kernel in GRUB. Worth knowing before it happens late at night.

**The reason this matters, concretely:** on 2026-09-05 a kernel was installed
with no NVIDIA module built for it, because `40-dkms.install` fires when the
*kernel* is installed and `kernel-devel` arrived fourteen minutes later in a
separate transaction. Nothing retried. The only visible symptom was "reboot
pending", which reads like good news. `scripts/check-gaming-pc.sh` now refuses
to say "safe to reboot" unless the module exists — run it before rebooting
after any kernel update.

Three kernels are kept, so a driverless boot is recoverable by choosing the
previous kernel in GRUB. Worth knowing before it happens late at night.

## Gotchas discovered the hard way

- **`--doctor` must not run as root.** Its checks are per-user (`/dev/kvm`
  access, `kvm` group membership, `$HOME` config paths). As root they pass
  trivially and say nothing about whether the desktop user can use Cowork. The
  task uses `become: false` and warns if it still ends up as root. Don't
  "simplify" this away.
- **`blockinfile`'s `validate` runs `findmnt --verify` over the whole fstab**,
  not just the new block. A pre-existing problem anywhere in the file blocks
  the write. The role reports fstab health beforehand so this is interpretable.
- **`findmnt --verify` needs mountpoint directories to already exist**, which
  is why they're created before the fstab task. Don't reorder.
- **Nobara ships its own update system** (`nobara-sync` / Nobara Updater) with
  layered repos and patched packages. Don't force-manage packages Nobara also
  manages — it causes drift or breakage on their update cycle. This is the main
  constraint on widening scope.
- **Claude Desktop has no official Fedora package.** It's installed from
  `aaddrick/claude-desktop-debian`, which since v3.0.0 repackages Anthropic's
  official Linux `.deb` as an RPM. Anthropic officially supports Debian/Ubuntu
  only. If official Fedora support lands, switch to it and drop the community
  repo.

## Validating changes

There's no CI. Before committing:

```bash
bash -n scripts/*.sh                                        # shell syntax
ansible-playbook -i inventory.ini site.yml --syntax-check    # playbook syntax
ansible-playbook -i inventory.ini site.yml --check           # dry run
```

`scripts/capture-state.sh` is safe to run any time — read-only, no `sudo`, no
mutation. Re-run it and `git diff state/` to see what's drifted.

Its output is committed, so it redacts usernames, hostname, MAC addresses,
UUIDs and serial numbers by default. Review diffs before committing anyway;
redaction is a safety net, not a guarantee. Credential file *contents* are
never read.

## Working agreement

The owner wants to understand what's being done, not just receive it. Explain
reasoning, flag concerns before building, and don't silently widen scope.
Prefer detecting-and-reporting over auto-fixing for anything boot-critical —
`/etc/fstab` in particular is not a file to rewrite unattended.

### Be evidence-driven

Standing instruction from the owner, 2026-09-06, after the same mistake twice
in one week. **Measure before diagnosing. Don't report a plausible theory as a
cause.**

What it cost. Diagnosing a Plex playback failure produced four confident
explanations in a row — a second Plex server on the LAN, the TV Shows library,
the on-disk codecs, hardware transcoding being off. Each was built from
something *adjacent*: a port scan, a directory listing, a settings page. None
was tested before being stated. The owner had to correct the first one himself.
The real answer was that the viewer was using a **browser**, which cannot play
HEVC 10-bit; the native app worked first time and the server had been healthy
throughout. Worse, the correct advice had already been given early and was then
buried under three more theories instead of being followed up.

Earlier the same week, a 60-second dim test — whose own method disturbed the
thing it measured — led to "idle detection is broken" and a wrong accusation
against the USB-to-PS/2 adapter. And `roles/homeassistant` was "verified" with a
throwaway playbook using `become: false`, the one condition under which its
`ansible_env.HOME` bug could not appear.

In practice:

- Ask what **single observation** would distinguish the candidates, then go and
  get it. One measurement beats three inferences.
- Ask for the access or credential needed to measure **early**, rather than
  reasoning around its absence. `/status/sessions` with a Plex token settled in
  one step what four theories could not.
- Say plainly when something is a hypothesis. "This is a theory until X" is
  cheap; a confident wrong cause is not.
- Reproduce a fault the way it actually occurs — same privileges, same entry
  point, same client. A test that cannot fail the way production fails is not a
  test.
- When the owner pushes back on a claim, treat that as a signal the reasoning
  was assembled rather than observed. Re-derive from evidence instead of
  defending it.

`CHANGELOG.md` for 2026-09-06 records the four wrong diagnoses in order, and
the measurement that would have ended the whole thing in one step.

## History

Started 2026-08-14 in Claude Code **on the web** (claude.ai/code) — the same
Claude Code, but executing in an Anthropic cloud container rather than on
`gaming-pc`. That session could see this git repo and nothing else: no
`/etc/fstab`, no `journalctl`, no NAS on the LAN. Everything through commit
`3b48904` was therefore written blind, against the owner's descriptions, and
relayed by hand.

Running locally you have none of that limitation. Read the real files, check
the real journal, test-mount the real shares, and iterate until things
actually work — rather than reasoning about what's probably wrong. Verify the
assumptions baked into `roles/smb_mounts` against the machine rather than
trusting them.

Branch: `claude/fedora-nobara-gaming-setup-ps0v2v` (not yet merged to `main`).
