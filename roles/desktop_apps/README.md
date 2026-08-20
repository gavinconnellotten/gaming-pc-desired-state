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
