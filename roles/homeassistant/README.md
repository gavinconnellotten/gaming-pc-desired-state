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

## Voice control and Music Assistant

### What went wrong, and what actually fixed it

Voice music requests "constantly misunderstood" what was asked. Four things
were wrong; only one of them mattered.

**The cause: Whisper was running the `tiny` speech model.** It transcribed
"Love Is All Right" as "love is all as all right", the music automation
searched the library for that literally, and failed. The logs said so plainly:

```
Could not resolve ['the love is all right'] to playable media item
Could not resolve ['love is all as all right'] to playable media item
```

Moving to `small` fixed it outright — every song and album tested played
first time. On this i5-7500T that costs a second or two per phrase, which is a
good trade for being understood. `model: small` is pinned in
`defaults/main.yml` for that reason.

**Three real defects that were NOT the cause**, fixed anyway because each
would have bitten later:

- `script.claude_play_music` had an **empty description**. That description is
  the tool description the LLM sees; without it Claude cannot know the tool's
  seven arguments or when to use it. The blueprint's own docs say in bold to
  set it.
- Its `default_player` was `media_player.music_player_daemon_2`, **which does
  not exist** — the player had been renamed to `media_player.tap`. Anything
  falling through to Claude without naming a room targeted nothing.
- The conversation prompt instructed Claude to say *"sorry I didn't catch
  that"* when confused, turning every near-miss into a dead end rather than a
  clarifying question.

### Two voice paths, and which one wins

There are two, and it is worth knowing which is running:

| Path | Mechanism | When it runs |
|---|---|---|
| `automation.music_assistant_voice_automation` | `conversation` sentence triggers, literal library search | Catches "play X" phrases first |
| `script.claude_play_music` | Claude tool call | Anything the sentence triggers miss |

The automation wins for ordinary phrasing, even though the pipeline has
`prefer_local_intents: false`. It is faster than an LLM round-trip and, with
accurate transcription, reliable — so it is deliberately left enabled, with
Claude as the fallback for phrasings it does not match.

A benign `Template variable warning: 'media_name' is undefined` appears on
every request from that blueprint. Cosmetic; it does not affect playback.

### What is enforced, and what is only captured

`.storage` — the Claude prompt and model, the assist pipeline, entity and area
registries, what is exposed to voice — is owned by the running Home Assistant,
which rewrites it on its own schedule. Writing it from Ansible is the same trap
as editing Plasma or qBittorrent config underneath a running application.

| Layer | Handling |
|---|---|
| Add-on options and Supervisor properties | **Enforced**, via `ha-addon-options.sh` |
| YAML files (scripts, automations, blueprints) | **Captured** to `state/homeassistant/` |
| `.storage` settings | **Captured**; restored from the weekly config backup |

Run `./scripts/capture-homeassistant.sh` and `git diff state/homeassistant/`
to see what has drifted. The capture is read-only, redacts credentials, and
never reads `secrets.yaml`.

### Three traps in ha-addon-options.sh, all paid for

- **Options and properties are different things.** `model` is an option;
  `auto_update` is a Supervisor property. Sending a property inside `options`
  is accepted by the API and then silently dropped, because it is not in the
  add-on's schema.
- **Samba NAS2 has both.** A Supervisor `auto_update` property *and* its own
  option of the same name. Turning off one looks done.
- **Never compare whole objects as strings.** Home Assistant returns Piper's
  `length_scale` as `1.0`, so a desired `1` differs as text and matches as a
  number. And in jq, `$c[.key] // null` falls through on `false` as well as
  `null`, so a stored `false` reads as absent — which made the script report
  `auto_update: unset -> unset` and fail verifying a correct value.

## Camera lingering detection

The requirement was specific: **not** "someone walked past", which in a quiet
suburb is noise, but "someone is hanging about" near the driveway or the front
door (which the upstairs camera overlooks).

### What the sensors actually do, measured

Everything below rests on measurement rather than assumption, because the
obvious design does not work:

**They pulse, they do not stay on.** One person moving about for ~70 seconds
produced four separate on/off pulses of 0.4–10 seconds each. So a trigger of
"person detected continuously for 30 seconds" would never fire. Counting
pulses in a rolling window does work, and maps directly onto passing versus
lingering.

**The two cameras behave differently, and this matters:**

| Camera | Event rate | A count of N means |
|---|---|---|
| Driveway | rate-limited to ~1/min | activity in N of the last N minutes |
| Upstairs | up to 4/min | N detections — intensity as well as duration |

One shared threshold would have been wrong for both: the driveway can never
reach a threshold set for the upstairs camera. The driveway's cap is not a
defect here — it makes the count a direct measure of *how many minutes* had
activity, which is a clean loitering signal.

### Why the driveway watches motion, not people

The driveway camera **does** person detection — the Tapo app fires person
alerts from it — but it does not publish person events over ONVIF, only
generic motion. Verified rather than assumed: walking in front of it produced
a person alert in the app, plenty of ONVIF motion events, and no person sensor
was ever created. The upstairs camera's firmware exposes person detection over
ONVIF; this one's does not, and it reports itself fully up to date for its
variant.

An earlier conclusion that this was a firmware-version problem was **wrong** —
both `tplink` and ONVIF agreeing person detection was absent meant "not exposed
to them", not "not supported".

### ONVIF, not the tplink integration

Motion sensors come from Home Assistant's built-in **ONVIF** integration on
port **2020**, using the camera-account credentials set in the Tapo app.

That matters because the `tplink` integration is currently broken for both
cameras — it returns `INTERNAL_QUERY_ERROR` on every module query, so its
switches and sensors are unusable. ONVIF authenticates separately and works
regardless. Live view kept working throughout for the same reason: RTSP uses
the camera account, the broken API uses the TP-Link account.

ONVIF creates a binary sensor only **after the camera first sends that event
type**. A missing sensor usually means "that event has not happened yet"
rather than "unsupported".

### Currently LOG ONLY — thresholds are placeholders

`files/ha-packages/camera_lingering.yaml` defines four counting sensors and two
automations that write logbook entries and **send no alerts**.

The thresholds in it were set from 33 minutes of data recorded while
deliberately walking about in the rain, which is the opposite of a baseline.
The point of the log-only phase is to accumulate real history — what a postman
scores, what a rainy night scores, what a genuine linger scores — and set the
thresholds from that.

**Do not wire up notifications until that data exists.**

### Packages, and why config lives in one

`automations.yaml` and `scripts.yaml` are rewritten by Home Assistant whenever
anything is edited in the UI, so the repo cannot own them without the two
clobbering each other. A **package** is Home Assistant's own mechanism for a
self-contained lump of YAML config, merged in at startup and untouched by the
UI editor — the same principle as the managed block in `/etc/fstab`.

`ha-deploy-packages.sh` copies only files that differ, adds the
`packages: !include_dir_named packages` line to `configuration.yaml` if it is
missing, and runs `ha core check` before reporting success.

**It does not restart Home Assistant.** Packages are read only at startup, so a
change does nothing until a restart — but restarting a media server and voice
assistant mid-song as a side effect of a playbook run is the wrong default.
The script says when a restart is due and leaves it to a human.
