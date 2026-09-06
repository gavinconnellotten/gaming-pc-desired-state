# homeassistant

Manages the **gaming-pc side** of the relationship with the Home Assistant
machine: SSH-based access, a weekly config-only backup pulled here, and
retention at both ends.

## Home Assistant is not an Ansible host, and cannot be

HAOS is an appliance, not a Linux box you administer. No Python interpreter, no
package manager, no editable systemd units. Every Ansible module needs Python
on the target, so the only thing that would work is `ansible.builtin.raw` —
shell with extra steps and none of Ansible's idempotency.

So this role installs nothing on the HA machine. It manages what runs *here*,
and reaches across over SSH. That is also why there is no second play and no
second inventory group: a group that can only ever run `raw` is a lie about
what the repo controls.

## No API token is needed

There was one, briefly. It turned out to be unnecessary: inside an SSH session
on the Terminal & SSH add-on, the Supervisor API is reachable at
`http://supervisor` with `$SUPERVISOR_TOKEN` already in the environment. So the
backup script authenticates with the SSH key and nothing else — **one**
credential to keep working across a rebuild instead of two.

A long-lived token may still exist at `/etc/homeassistant/api-token` from the
original setup. Nothing here reads it.

## Why the Supervisor API and not the `ha` CLI

`ha backups new` cannot express "Home Assistant's configuration and nothing
else":

- passing `--app` or `--folders` makes a partial containing **only** those
- passing neither makes a **full** backup

A full backup on this machine is about 8.9 GB, most of it Ollama's language
models. The config alone is about 60 MB. `POST /backups/new/partial` with
`homeassistant: true` and empty `addons`/`folders` gives exactly the wanted
result, so the script calls it directly.

The size difference is the whole argument:

| | Size |
|---|---|
| Full "Automatic backup" | ~8900 MB |
| Config only | ~60 MB |

## What is deliberately not backed up

Media. The owner's decision, 2026-09-05.

State the consequence plainly rather than leaving it implied: the **~67 GB TV
library on the HA system disk is protected by nothing**. It is not in these
backups and not in Home Assistant's own. That is an accepted risk, not an
oversight — but it is a risk, and a failed NVMe takes the config, the local
backups and the TV library together.

## Pruning can only ever delete its own work

Every backup the script creates is named with `ha_backup_name_prefix`, and the
remote prune filters on that prefix before deleting anything. A retention sweep
must not be able to remove a backup someone made by hand, or Home Assistant's
own automatic ones — including the 29 Aug full backup being kept deliberately
as the only copy of add-on data.

Local pruning is by modification time within the backup directory, which is
managed and contains nothing else.

## The timer is user scope, not system

It runs as the desktop user because that user's SSH key is the one Home
Assistant authorises. A system timer would run as root, with root's key, which
is not.

That means it depends on **lingering** being enabled — the role checks and
warns rather than assuming. Lingering is already on for this user (the DP link
watcher needs it too).

`Persistent=true` matters more than it looks: gaming-pc suspends after an hour
idle and is switched off overnight, so a Saturday-morning timer *will* be
missed regularly. Persistent runs it at the next opportunity instead of
skipping the week in silence.

## Verification the script does, and why

- **Waits for the remote size to stop changing.** The endpoint returns a
  `job_id`, so a response is not a finished backup.
- **Downloads to `.part`, renames on success.** An interrupted transfer must
  never be left looking like a valid backup.
- **Compares remote and local byte counts.**
- **Opens the tar.** A backup that will not open is not a backup, and this is
  the cheapest possible check that it will.

## Running it by hand

```bash
systemctl --user start ha-backup.service
journalctl --user -u ha-backup.service -n 30
```

## Self-healing after a Home Assistant reboot

`ha-health.sh`, on a 15-minute user timer, repairs the two things that break
media every time Home Assistant restarts.

**The failure, measured on 2026-09-06.** Home Assistant mounts its media over
CIFS from its own Samba add-on, and at boot it loses the race:

```
Samba NAS2   state: startup    <- took 90 seconds to come up
ELEMENTS     state: failed
SSD          state: failed
```

Nothing retries them. Worse, Plex starts in the same window:

```
15:13:31   Plex add-on started    <- media mounts FAILED at this point
15:17      mounts reloaded        <- Plex had already started, never re-checked
```

So repairing the mounts underneath a running Plex fixes the *machine* while
playback still fails — which is exactly how the fault presents: the server is
reachable, the file is on disk and readable, and Plex reports a media error.
Both problems have to be handled, in that order.

**What the script does**

1. Exits quietly if Home Assistant is unreachable. A machine that is off is not
   a fault to repair.
2. Waits for Samba to reach `started` — reloading a CIFS mount while the server
   it points at is still starting simply fails again.
3. Reloads any mount that is not `active`, then **re-reads the state** rather
   than trusting the reload's exit code.
4. Restarts Plex **only if a mount was actually repaired**. A media server that
   restarts itself on a timer for no reason is worse than the fault it is
   meant to fix.

**Why a timer and not a boot hook.** This machine cannot observe Home
Assistant's boot — it may be asleep or switched off at the time. A short
interval catches the reboot whenever it happens.

**The limitation, stated plainly:** it only runs while gaming-pc is awake. This
machine suspends after an hour idle, so a Home Assistant reboot at 3am is
repaired when gaming-pc next wakes, not immediately. Closing that gap properly
would need an automation inside Home Assistant, which would mean editing its
configuration — outside what this repo manages.

`Persistent` is deliberately **not** set on the timer: a repair missed while
this machine slept is worth doing at the next normal firing, not as a burst of
catch-up runs the moment it wakes.

Run it by hand any time:

```bash
systemctl --user start ha-health.service
journalctl --user -u ha-health.service -n 20
```

## Reporting

Two scripts, both read-only, both safe any time:

```bash
./scripts/check-homeassistant.sh   # versions, add-ons, mounts, disk, backups
./scripts/check-gaming-pc.sh       # updates, reboot safety, services, disk, power
```

They report and never apply. That is the same rule the rest of the repo
follows, for the same reason: Nobara ships its own updater with layered repos
and patched packages, and Home Assistant's Supervisor owns its own update
path. Driving either from Ansible causes drift on their release cycles.

`check-gaming-pc.sh` earns its place on the NVIDIA check alone — see the
CHANGELOG for 2026-09-05, where a kernel installed without its driver being
rebuilt would have produced a machine with no graphics on the next reboot, and
the only visible symptom beforehand was a cheerful "reboot pending".

## Storage topology on the HA machine, for when it confuses you later

```
NVMe (system disk)
├── /backup           Supervisor backups
└── /media/TV SHOWS   local, ~67 GB, shared as MEDIA/TV SHOWS

USB disk 1  ──> Samba NAS2 shares as ELEMENTS ──┐ mounted BACK over CIFS
USB disk 2  ──> Samba NAS2 shares as SSD ───────┘ from 172.30.32.1 into /media
```

Home Assistant mounts CIFS shares from its own Samba add-on. That looks
circular and wrong, and it is neither: HAOS's Supervisor can only mount CIFS
and NFS as media storage, so looping through the local Samba server is the
documented way to make a USB disk visible to add-ons.

The real consequence is that **a Samba NAS2 restart drops Home Assistant's own
media mounts**, which is why every add-on except Music Assistant now has
auto-update disabled, and why `check-homeassistant.sh` reports mount state.
