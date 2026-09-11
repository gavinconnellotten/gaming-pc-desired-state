# desktop_apps

Applications added by hand after the Nobara install. Same principle as
`roles/gaming`: manage the delta, leave the distribution's own packages alone.

| App | How | Why that way |
|---|---|---|
| qBittorrent | dnf (`nobara`) | Already installed; codified so a rebuild restores it |
| Proton VPN | dnf (`terra`) | Official Linux app. RPM, not flatpak — see below |
| Proton Mail | flatpak, **user** scope | Proton ships no RPM; Flathub build is theirs |
| Proton Calendar | — | **No Linux app exists.** Built into the Mail app |
| Proton Drive | — | **No Linux client exists.** See the rclone note |

## Two of the five requested apps don't exist

Worth stating plainly rather than leaving someone to hunt for them:

- **Proton Calendar** has no standalone Linux desktop application. It is a tab
  inside the Proton Mail desktop app, so installing Proton Mail gets you both.
- **Proton Drive** has no Linux desktop client at all. Proton ships Windows and
  macOS only. The options are the web interface, or `rclone`, which supports
  Proton Drive as a backend.

`rclone` is available in the `nobara` repo and this role can install it via
`desktop_apps_install_rclone: true`, but it is off by default. It is a
command-line sync tool needing a configured remote, not a drop-in replacement
for a desktop client, so turning it on without setting it up achieves nothing.

## Why Proton VPN is the RPM and not the flatpak

Both exist — `proton-vpn-gtk-app` in `terra`, and `com.protonvpn.www` on
Flathub. The RPM is the right choice here: a VPN client has to talk to
NetworkManager and manage routes, DNS and kill-switch rules for the **whole
system**. A flatpak is sandboxed precisely to prevent that, so the Flathub
build needs extra permissions to do its job and gains nothing in return.

## Why flatpaks are driven with plain commands

This repo is `ansible-core` only — no Galaxy collections — so
`community.general.flatpak` is out. A collection would mean another install
step on a rebuilt machine, which is exactly what this repo exists to avoid.

The role checks with `flatpak info` before installing, because
`flatpak install` is not quiet about an already-present ref and would report
changed on every run otherwise.

## The gotcha: user scope, so not as root

Flatpaks here install at **user** scope, matching Flatseal and Bazaar which
were already on the machine. Mixing user and system scope leads to two copies
of the same app and confusion about which one launched.

That means the tasks run with `become: false`. Under `sudo` they would install
into root's flatpak installation, which the desktop session never displays —
and the run would report success. The role refuses rather than warning. Same
class of bug as `claude_desktop`'s `--doctor`, `gaming`'s Proton paths and
`power_management`'s Plasma settings; it comes up once per role because
anything user-owned has this shape.

## Adding more

Add to `desktop_apps_dnf` or `desktop_apps_flatpaks` in `defaults/main.yml`.
Prefer the RPM when one exists and the app needs system integration; prefer the
flatpak when upstream ships no RPM, as with Proton Mail.

## Browsers: LibreWolf in, Brave left alone

| | |
|---|---|
| LibreWolf | Installed from its own repo, set as default browser |
| Brave | **Still installed, deliberately unmanaged** |

### Brave removal was tried and abandoned

This role used to remove `brave-browser`. **It never once worked, and it
errored on every playbook run.** Given up on 2026-09-12.

The evidence, because "it didn't work" is not much use on its own:

- `dnf history` shows `brave-browser` being **upgraded** — transactions 28 and
  35 — and never removed. It is currently `1.95.101`, against the
  `brave-browser-0:1.89.143-1.x86_64` that `dnf` transaction 1 shipped. So it
  has been quietly updating the whole time the repo claimed it was gone.
- It is **not** in `/etc/dnf/protected.d/`, so protection was not the blocker.
  `nobara.conf` protects `nobara-welcome`, `nobara-nvidia-wizard`,
  `nobara-login`, `nobara-release` and `nobara-repos` — not Brave.
- `nobara-browser-policy` **requires** `brave-browser`, so any removal has to
  take that with it.

The deeper reason to stop rather than fix it: Brave arrived with the image, and
*manage the delta, not the distribution* exists precisely to stop this repo
fighting Nobara over the package set it maintains. A step that errors every
single run is worse than no step at all — it stops the play, and because
`desktop_apps` runs before `system_tuning`, `os_updates` and `homeassistant`,
a full-playbook run silently never reached those three.

**The consequence that matters:** Brave staying installed makes the
default-browser setting below load-bearing rather than cosmetic. Brave being
present is the whole reason Proton Mail's links went somewhere unwanted.

If it ever genuinely has to go, do it by hand and read the actual error:

```bash
sudo dnf remove brave-browser nobara-browser-policy
```

`brave-keyring` and `/etc/yum.repos.d/brave-browser.repo` should still be left
alone either way — the repo file is owned by `nobara-repos`.

### The LibreWolf repo has to be declared

Nothing owns `/etc/yum.repos.d/librewolf.repo` — it was added by hand on
2026-08-09. A rebuilt machine would therefore have no repo to install LibreWolf
from, and the default-browser step would point at a desktop file that does not
exist. The role writes the repo definition itself.

### Why the default browser was Brave in the first place

Not because Brave "hijacked" anything. **No default had ever been set.** Brave
appeared in no `mimeapps.list` anywhere; it simply won the fallback by being
the first application claiming `x-scheme-handler/http`.

That is why links from Proton Mail opened it: flatpaks resolve URLs through the
XDG desktop portal, which asks the host for the default handler and got the
first match. Setting an explicit default fixes the flatpak case too — though a
running flatpak may need restarting to notice.

The task ordering matters: the default is set **after** the installs and
removals, because setting a default for a desktop file that isn't present yet
silently does nothing.

`xdg-settings check` gives real idempotency here — it returns `yes`/`no`, so
the role only writes when the answer is wrong. Verified: `changed=0` when
correct, and it restores LibreWolf when the default is changed behind its back.


## qBittorrent: don't sleep mid-transfer

`roles/power_management` suspends this machine after an hour idle, and a
torrent transferring is not idle in any sense worth honouring.

qBittorrent handles this itself — verified in the 5.2.3 binary, which carries
the settings `checkPreventFromSuspendWhenDownloading` /
`...WhenSeeding` and an `InhibitorDBus` class. It registers a **D-Bus
inhibition**, the same mechanism games use and the one PowerDevil actually acts
on. So the role only has to set two preferences; there is no wrapper, watcher
or timer involved.

**Activity-based, not process-based.** Sleep is blocked by an active transfer,
not merely because the application is open. A machine that never sleeps because
a window was left open is a worse outcome than the problem being solved.

**Downloading blocks sleep; seeding does not.** The owner's decision,
2026-09-06. A download is a task with an end and is worth staying awake for.
Seeding has no end, so honouring it would mean a machine that never suspends
again once a torrent completes — exactly the behaviour `roles/power_management`
exists to prevent.

The consequence is worth stating rather than leaving implied: **when the machine
suspends, seeding stops until it wakes.** That is accepted, not overlooked. If
you ever want to seed overnight, set
`desktop_apps_qbittorrent_inhibit_seeding: true` and expect the machine to stay
awake for as long as the torrent is shared.

Both keys are written explicitly, including the `false` one, so the desired
state does not depend on a qBittorrent default that could change between
versions.

Check what is holding the machine awake at any time with
`scripts/check-power-inhibitors.sh` — qBittorrent appears there by name during
a transfer. Note that `systemd-inhibit --list` does **not** show it, for the
same reason it does not show games.

### It refuses to write while qBittorrent is running

qBittorrent rewrites `~/.config/qBittorrent/qBittorrent.conf` while running and
again on exit, so anything written underneath it is silently discarded. The
role checks with `pgrep` and reports instead, telling you to either close it or
set it in **Tools → Options → Behaviour → Power Management**.

Same principle as using `kwriteconfig6` for Plasma rather than copying files:
never fight a running application for ownership of its own config. Reporting
rather than failing is deliberate too — a running qBittorrent is a normal
state, not an error, and failing the play over a preference would be
disproportionate.

If the config file does not exist yet (a rebuilt machine where qBittorrent has
never been started), the role says so rather than creating a partial file that
qBittorrent would overwrite on first run.
