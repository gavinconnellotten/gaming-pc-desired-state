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

## Browsers: LibreWolf in, Brave out

| | |
|---|---|
| LibreWolf | Installed from its own repo, set as default browser |
| Brave | **Removed** |

### Brave is Nobara's, and removing it is a deliberate exception

Brave arrived with the image — `dnf` transaction 1 lists
`brave-browser-0:1.89.143-1.x86_64`. So taking it out is a departure from
*manage the delta, not the distribution*. That rule exists to stop this repo
fighting `nobara-sync` over package **versions**; deciding you don't want an
application the distro chose to include is a different thing, and it is
recorded here rather than done quietly.

Two details that make it safe:

- **`nobara-browser-policy` goes with it.** It requires `brave-browser` and
  ships exactly one file, `/etc/brave/policies/managed/brave_nobara-policies.json`.
  Nothing requires *it*, so there is no cascade.
- **`brave-keyring` and the Brave repo are left alone.**
  `/etc/yum.repos.d/brave-browser.repo` is owned by `nobara-repos`, so removing
  Brave's repo plumbing would fight a Nobara-managed package for no benefit.
  The browser being gone is the point.

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

