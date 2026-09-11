# Changelog

Dated log of what's been done to `gaming-pc`, and whether it's been codified
into this repo yet.

## 2026-09-12 — The Shield: monitored, deliberately not managed

Researched remote management of the NVIDIA Shield now that gaming-pc mounts a
share from it. Conclusion: **monitor it, do not manage it.**

### Why there is no roles/shield, and should not be

A Shield has no package manager, no config files to version, and no
declarative surface. Everything ADB offers is **imperative** — "install this",
"reboot" — which is a runbook, not desired state. Writing a role for it would
be calling a runbook desired-state config.

The wider ecosystem agrees: the tools people use are MDM platforms built for
estates of hundreds of devices, or manual ADB app managers. Nobody does
declarative Android TV config, because there is no sensible way to.

What is even theoretically version-controllable is thin: its SMB share is a UI
toggle, Plex settings are capturable but not enforceable, and an "these apps
should exist" check via ADB is possible but marginal.

### What the Shield actually exposes, measured

```
8009  Cast                     open
6466  Android TV Remote v2     open
32400 Plex                     open
445   SMB                      open (enabled 2026-09-12)
5555  ADB network debugging    CLOSED
22    SSH                      closed
```

ADB being off is the right default. It is a debugging interface with no
authentication beyond initial pairing, and enabling it speculatively buys
nothing — so `check-shield.sh` flags it if it is ever found open.

### The Android TV Remote integration was never set up

Two `androidtv_remote` config entries exist in Home Assistant, for the Shield
and a Philips TV, and neither has ever produced a single entity. The cause was
not a broken pairing, which is what it looked like:

```
SHIELD: source=ignore
65PUT7908/79: source=ignore
```

**`source=ignore`** — these are dismissed discovery notifications, not
configured integrations. Both devices were auto-discovered and the "configure?"
card was clicked away, which Home Assistant records so it stops asking. Stale
certificates from 8 May exist in `.storage` and are harmless.

Worth knowing for next time: a config entry with no entities and no log errors
is more likely `source=ignore` than a failure. Adding the integration properly
requires un-ignoring it first, since Home Assistant will not re-offer an
ignored device — and the Add Integration flow fails quietly rather than saying
so, which is what it looked like on 2026-09-12.

**The Philips TV at .106 stays ignored, deliberately.** The owner does not use
its Android TV OS, so there is nothing to control. Only the Shield is worth
pairing. Do not propose adding the Philips entry.

### New: scripts/check-shield.sh

Third in the set alongside `check-gaming-pc.sh` and `check-homeassistant.sh` —
one script per machine the household depends on. Read-only, no credentials,
every check a TCP probe or an unauthenticated endpoint.

It reports reachability, SMB, Plex, Cast and Remote, flags ADB if open, and
checks the mount from this machine's side. It treats an **idle automount as
normal**, which is not a given: reporting an idle `x-systemd.automount` share
as broken is a mistake this repo has already made once.

Added to the weekly Saturday report, and to `.claude/settings.json` so the
scheduled routine does not stall on a permission prompt.

The value is narrow but real: the Shield is an Android TV box that reboots for
updates and gets switched off casually. The mount is automount, so an absent
Shield is harmless — but "harmless" and "noticed" are different things, and
without this you discover it from a mysteriously empty directory.

## 2026-09-12 — A fourth SMB mount, on a second server

`//192.168.68.102/internal/Download` → `/mnt/shield-downloads`, the NVIDIA
Shield in the lounge, which had SMB sharing switched on this morning. First
time this repo has mounted from anything other than the Home Assistant machine.

Verified after mounting rather than assumed: CIFS options applied, contents
readable, and files owned `gavin:gavin` rather than root — CIFS carries no Unix
ownership, so the client decides, and getting it wrong gives a share that
mounts but cannot be used.

Four things differ from the three Home Assistant mounts, each for a reason:

- **Addressed by IP.** The Shield's SMB advertises itself as "localhost server
  (Samba, Ubuntu)", so its own hostname is not trustworthy. Safe to hard-code
  because the Shield holds a static DHCP reservation, confirmed the same day.
  That reservation is now load-bearing and lives on the router, so a router
  replacement has to recreate it — this repo cannot assert it.
- **Its own credential file.** Same username as the Home Assistant shares, but
  a different machine and password. One shared file would break all four mounts
  the moment either password changed.
- **A subdirectory, not the share root.** The only mountable share is
  `internal`; `Download` is a directory inside it. `mount.cifs` handles that
  natively, as the existing `SSD/MOVIES` entries already show.
- **It is an Android TV box.** It reboots for updates and gets switched off
  casually. The `x-systemd.automount` options the role already applies are what
  make that safe: an absent Shield gives an empty mountpoint, not a hung boot.
  Nothing this desktop depends on should live behind it.

### Two rough edges found doing it

**`setup-smb-credentials.sh` defaults to a path that cannot work here.** It
offers `/etc/samba/credentials/<slug>`, treating that path as a directory —
but on this machine `/etc/samba/credentials` is already a *file*, holding the
Home Assistant login. The script caught the conflict and asked for another
path, which is the right behaviour, but the default has never been exercised
on a machine that already had the single-file layout. `credentials-shield` now
sits alongside it. Worth settling on one convention.

**The script prints a complete `smb_mounts:` block, not an entry to append.**
Pasted verbatim it would have replaced the three Home Assistant mounts. Fine
when it was written and there was only ever one server; a trap now. The new
entry was appended by hand instead.

Also noted while looking: the Home Assistant system disk has gone from 49% to
**75%** since 2026-09-05. `/media/TV SHOWS` grew 67 GB → 115.6 GB, and
`/backup` holds two ~9 GB HA Automatic backups where the 29 Aug one is now
superseded by `2026.9.0`. 55 GB free. Our own pruning will not touch those —
it only removes backups matching its own name prefix, by design.

## 2026-09-12 — Give up on removing Brave

`roles/desktop_apps` has been trying to remove `brave-browser` since it was
written. **It has never succeeded, and it errored on every run.** Removed from
`desktop_apps_remove`, which is now empty; the task is skipped rather than
deleted, so the decision stays legible.

Why it was never going to work, measured rather than assumed:

| Check | Result |
|---|---|
| `dnf history` for brave | **Upgraded** at txn 28 and 35, never removed |
| Version now | `1.95.101`, against `1.89.143` on the ISO |
| In `/etc/dnf/protected.d/`? | **No** — so protection was not the blocker |
| `rpm -q --whatrequires brave-browser` | `nobara-browser-policy-2.0.0-5` |

So Brave has been quietly updating itself the entire time this repo claimed it
was removed. The honest reading is that it was never worth fighting: Brave came
with the image, and *manage the delta, not the distribution* exists to stop
exactly this.

**The cost was much larger than a failed step**, and this is the part worth
remembering. `site.yml` stops at the first failure, and `desktop_apps` runs
*before* `system_tuning`, `os_updates` and `homeassistant` — so every
full-playbook run silently stopped before reaching three roles. That is why the
maintenance-window run on 2026-09-12 applied `power_management` and left
`nobara-update.timer` on its old 08:00 schedule; it took a second run with
`--tags os_updates` to land. A step that always errors is not a harmless
no-op.

Consequence to keep in view: Brave stays installed, which makes the
`xdg-settings` default-browser step **load-bearing** rather than cosmetic.
Brave being present is why Proton Mail's links went somewhere unwanted.
Currently correct — `xdg-settings get default-web-browser` returns
`librewolf.desktop`, with `librewolf-155.0.1-1` installed.

If Brave ever genuinely has to go, by hand, reading the real error:
`sudo dnf remove brave-browser nobara-browser-policy`.

## 2026-09-12 — RTC wake VERIFIED; the first test was a black screen, not a failure

First test was read as a failure — "I put the machine into suspend but it did
not come back up, I had to trigger wake with a keyboard press." The evidence
says the machine had already woken itself.

| Observation | Value |
|---|---|
| Alarm armed for | 10:03:19 |
| Suspend entered | 10:01:26 |
| Resumed from S3 | **10:03:21** — two seconds after the alarm |
| Asleep for | 115s, against a 120s alarm |
| RTC `wakeup_active_count` | **1** |
| RTC `wakeup_last_time_ms` | 9218s of awake time; the suspend began at ~9208s |
| USB root hub `wakeup_count` | 0 on both |

So the RTC wakeup source activated exactly once, timed to that resume, and the
machine came back two seconds after its alarm. **The monitor never lit, which
is what made it look asleep.**

Not called proven, because one confound survives: a keypress at the two-minute
mark the owner was waiting for would land within a couple of seconds of the
alarm. `scripts/test-rtc-wake.sh` removes it.

**Confirmed the same day by a clean run.** `scripts/test-rtc-wake.sh arm 300`,
untouched throughout: alarm armed 10:20:57, first heartbeat after the gap
10:20:59, asleep 292s against a 300s alarm. `wakeup_active_count` went to 2 —
one activation per test, which retrospectively confirms the first test had
woken the machine too. **RTC wake works on this machine and needs no BIOS
change**, unlike `Resume By USB Device`.

### It resumes to the LOCK screen, and the whole chain still runs

The clean test resumed to what looked like a login screen. It is the lock
screen from `LockOnResume=true`, and the session is intact: `loginctl` shows
session 2 on `seat0`/`tty1` with `State=active`, `systemctl --user is-active
default.target` returns `active`, and `Linger=yes`. The `plasmalogin-helper`
process carries `--user gavin --autologin` — that is the auto-login session
leader, not a greeter that has taken over.

Which is the outcome wanted, because every Saturday job runs behind a locked
screen: the update is a system service, `ha-backup.timer` is a user timer with
lingering enabled, and the weekly report runs in Claude Desktop inside the
still-live session. The machine wakes itself, does the work, and still demands
a password if somebody walks up to it.

### Two measurement traps this cost, both worth not repeating

**The journal cannot time a resume.** Wall-clock timestamps collapse across a
suspend — the entire suspend sequence is stamped with the post-resume second,
so `Preparing to enter system sleep state S3` and `Waking up from system sleep`
both read 10:03:21. The journal cannot tell you whether the resume preceded a
keypress. `scripts/test-rtc-wake.sh` writes a userspace heartbeat every five
seconds instead: it freezes through the suspend and resumes on wake, giving a
wake time recorded after the clock is correct.

**A black screen is not a sleeping machine.** This is the trap, and it is the
same shape as the one on 2026-09-06 — a confident reading built from something
adjacent. The test's own instructions now say to judge by the log and not the
monitor.

If a clean run shows it genuinely stayed asleep, the fix is almost certainly
firmware: MSI -> Settings -> Advanced -> Wake Up Event Setup -> **Resume By RTC
Alarm**, the direct analogue of `Resume By USB Device`, which sat unnoticed in
the same menu for weeks. The script says so in its failure verdict.

### Still open

`roles/desktop_apps` errors every run on the Brave removal step. Not yet
diagnosed — deferred deliberately while the wake is being settled. The
consequence worth knowing meanwhile: the play stops at the first failure, so
`desktop_apps` failing means `system_tuning`, `os_updates` and `homeassistant`
never run in a full-playbook invocation. That is why the 2026-09-12 run applied
`power_management` and left `nobara-update.timer` on its old 08:00 schedule;
it took a second run with `--tags os_updates` to land.

## 2026-09-12 — A maintenance window, because waking the machine is not enough

The Saturday sequence — update, Home Assistant backup, weekly report — was
only ever running because somebody happened to switch the PC on. Two separate
causes, and the second is the one that matters.

**The machine is asleep when the timers elapse.** `nobara-update.timer`
triggered at `08:28:13` on 2026-09-12, the same second the machine resumed
from S3. Its 08:00 window had passed in its sleep and `Persistent=true` caught
it up. That worked, but it meant a genuinely missed week was
indistinguishable from a healthy one in the journal.

**Waking it early would have made things worse, not better.** With nobody at
the keyboard there is no input, so PowerDevil's idle countdown runs from the
moment of wake and would suspend the machine again an hour later — before the
09:30 backup. The backup succeeded on 2026-09-12 **only because the owner was
sitting at the machine at the time**. An RTC alarm on its own would have
produced a machine that woke at 08:10, updated, and then went back to sleep at
09:10 with the backup still pending.

So `roles/power_management` now opens a window that does both:

| Piece | Unit |
|---|---|
| RTC alarm, `WakeSystem=true`, Sat 08:10 | `maintenance-window.timer` |
| logind `--what=sleep` inhibitor, 8400s (to 10:30) | `maintenance-window.service` |

`roles/os_updates` moves from 08:00 to **08:20** so the update runs on schedule
inside the window rather than as a weekly catch-up. `Persistent=true` stays on
both the update and the backup — RTC wake cannot rouse a machine that is
genuinely powered off.

Three decisions recorded so they are not re-litigated:

- **System timer, not user.** `WakeSystem=true` needs `CAP_WAKE_ALARM`;
  `systemctl --user show ha-backup.timer -p WakeSystem` returns `no`. The
  backup timer cannot be promoted to fix this — it authenticates to Home
  Assistant with the desktop user's SSH key and root's is not authorised. So
  the backup is covered by keeping the machine awake, not by its own alarm.
- **`--what=sleep`, not `sleep:idle`.** Inhibiting idle would also stop the
  screen locking, leaving the machine unlocked and lit for two hours every
  Saturday. Sleep is the only thing that needs blocking.
- **`Persistent=false` on the window**, unlike the timers it protects — a
  two-hour inhibitor at some unrelated hour serves nothing.

**RTC wake is UNVERIFIED and must not be assumed to work.** `wakealarm` exists
and is writable and `/proc/driver/rtc` exposes an alarm, but RTC does not
appear in `/proc/acpi/wakeup`. This machine has form: the USB wake chain read
`enabled` at all five levels and was inert until a BIOS option was changed.
`roles/power_management/README.md` has the two-minute suspend test. Until that
test passes, the window is a hypothesis. It degrades gracefully — nothing
fires until the machine is woken by hand, exactly as before.

Not applied to the machine: the playbook needs `--ask-become-pass`. The
rendered units pass `systemd-analyze verify` and both calendar specs were
checked with `systemd-analyze calendar`.

### Also: the report fired before the backup — retimed

The weekly report ran at ~09:24, ahead of the backup's 09:30–09:35 window,
which is why it reported a 6-day-old backup nine minutes before a fresh one
landed.

The cause was not the `10:09` this file used to claim. The task's cron was
`15 9 * * 6` — 09:15 — plus 555s of dispatch jitter, landing at ~09:24.
Retimed to `40 9 * * 6`, which with jitter fires **~09:49**: clear of the
backup window, and inside the maintenance window that holds sleep off until
10:30. The task's own prompt said the update runs at 08:00 and was corrected
to 08:20.

It is a Claude scheduled task held server-side, not a systemd timer, so it is
not reproducible from this repo — if the machine is rebuilt, the schedule has
to be recreated by hand.

### Permission prompts on the weekly routine

The routine needed interactive approval on 2026-09-12, which is part of why it
ran late. Added `.claude/settings.json` with 25 read-only allow rules covering
the health scripts, `journalctl` reads, read-only `systemctl` subcommands,
`dkms status`, `flatpak` queries, `findmnt` and `rpm -q`.

Scoped deliberately rather than broadly: `journalctl *` would authorise
`--vacuum-*`, which deletes logs; `systemctl *` would authorise `stop` and
`mask`; `ssh <ha> *` would authorise any command on the Home Assistant
machine. Allowlisting `check-homeassistant.sh` instead covers the SSH it does
internally without granting that.

Still outstanding, and deliberately left to the owner:
`permissions.defaultMode: "auto"` has to be set in `~/.claude/settings.json`
(it is ignored from project settings). Claude's own classifier blocked it from
writing that file, which is correct — a tool should not grant itself
permissions.

**The allowlist alone is not sufficient**, and the reason was nearly missed.
The 2026-09-12 session appeared to be running in auto mode, which suggested
the mode was already handled and only the allowlist was needed. It was not:
the owner had switched that *one session* from Manual to Auto by hand during
the morning. Nothing persists it, so a new session — the scheduled task
included — starts in `default` and prompts for anything the allowlist does not
name. The allow rules cover the routine's known commands; `defaultMode` is
what stops it stalling on an unanticipated one.

## 2026-09-12 — Quote the backup unit's NAME_PREFIX

Found during the weekly report. `ha-backup.service` set the backup name prefix
unquoted:

```ini
Environment=NAME_PREFIX=gaming-pc weekly config
```

systemd splits `Environment=` on whitespace, so this set `NAME_PREFIX=gaming-pc`
and then discarded `weekly` and `config` as two malformed assignments. The only
evidence was two lines in the user journal on every daemon-reload:

```
Invalid environment assignment, ignoring: weekly
Invalid environment assignment, ignoring: config
```

Fixed by quoting the whole assignment in
`roles/homeassistant/tasks/main.yml` — `Environment="NAME_PREFIX={{ ha_backup_name_prefix }}"`.
Applied to the live unit the same day, four minutes before the 09:34 timer
firing, so no further backup was written with the truncated name.
`systemctl --user show ha-backup.service -p Environment` now returns the full
value as a single assignment.

**Impact was cosmetic, and the reason is worth recording** so nobody assumes
the pruning was at risk. `ha-backup.sh` prunes with
`grep -F "${NAME_PREFIX}"`, and the truncated value is a *prefix* of the
correct one — so pruning still matched the older, correctly-named backups. Had
the truncation gone the other way (a longer or different string) the script
would have stopped recognising its own backups and pruning would have silently
stopped.

Note that `ha_backup_name_prefix` is the only one of these variables containing
spaces; the rest are single tokens and are left unquoted. The neighbouring
`ha-health.service` block was checked and needs no change.

## 2026-09-12 — DP-2 cable fault declared resolved

**The cable was the cause. Eleven days and 17 wake cycles after the change, the
640x480 fault has not happened once.** The verdict was deferred on 5 Sep with
only six wake cycles of evidence; there is now enough to close it.

Three independent indicators agree, which is why this is a verdict and not
another hopeful reading:

| Indicator | Reading |
|---|---|
| `640x480` anywhere in the journal since 1 Sep 14:22 | **0 occurrences** |
| `card1-DP-2` / `card1-DP-3` connector state now | both `connected`, **38 modes**, topping out at 2560x1440 |
| Junk 640x480 profile written to `kwinoutputconfig.json` | **none** — and the one stale profile left over from before the change has since been pruned by KWin |

The third is the useful one going forward. Every real occurrence of this fault
wrote a fresh junk 640x480 profile into `kwinoutputconfig.json`, so counting
those profiles is a fault counter that survives journal rotation — which
`journalctl` does not.

### The disconnect count fell, but the character of it changed more than the number

Raw DP-2 DDC disconnect episodes since the cable change: **7 across 17 wake
cycles (0.41 per cycle)**, against **14 across 15 (0.93 per cycle)** before it.
DP-3: **0**, against 2 before.

A halved rate would be a weak result on its own — the fault was intermittent,
so halving could be luck. What settles it is that **none of the seven is the
fault**. Every one recovered by itself within 3–10 seconds with full EDID and
all 38 modes, and **not one shows a kernel-level DisplayPort event** — no drm
hotplug, no link-training failure. The old fault was a kernel link drop where
the EDID was never re-delivered and only power-cycling the monitor recovered
it.

What those seven actually were, where the journal says so at the same second:

- **2 were suspend transitions** (5 Sep 08:24, 6 Sep 22:43) — the display drops
  as the machine goes down or comes back, which is expected.
- **2 were the NVIDIA pageflip bug** (9 Sep 12:25 and 12:39), logged as
  `Pageflip timed out! This is a bug in the nvidia-drm kernel driver` and
  `Flip event timeout on head 0` in the same second. KWin drops and re-creates
  its outputs; libddcutil reports that as a disconnect.
- **1 was a USB hub losing power** (10 Sep 11:24) — the `usb 3-4` hub, webcam
  and its siblings all disconnected at 11:24:53 and returned at 11:25:12, with
  the display churn in between.
- **2 have no identified cause** (5 Sep 19:35, 6 Sep 17:21). Recorded as
  unexplained rather than attributed to something adjacent. The 6 Sep one sits
  13 seconds before a `pm_fs_sync` hung-task warning, which is suggestive and
  not evidence.

All seven share one signature — `There are no outputs - creating placeholder
screen` across every Plasma client — meaning KWin briefly had no outputs at
all, a compositor event rather than a monitor dropping its link.

**The step-4 PowerDevil-restart false positive did not apply to any of them.**
PowerDevil's PID was unchanged across all seven (2172, 2162), so these are not
service restarts re-detecting displays. Worth recording so the filter isn't
assumed to have done work it didn't.

### The zero is real, not a dead watcher

Checked, because "no events logged" and "nothing is logging" look identical in
a log file. `dp-link-watch.service` is active with pid 1848, matching the last
`watch started` line, and PowerDevil — the actual source of the DDC events — is
active. The quiet stretch since 11 Sep covers this morning's 08:28 wake
genuinely.

### What remains

Nothing to do. The remaining variables that would have been next — the
monitor's DisplayPort port and the GPU port, isolated by swapping the two
monitors' cables at the GPU end — are not needed and that plan is retired.
`dp-link-watch.service` is left running; it is cheap, and it is now the thing
that would catch a recurrence early.

## 2026-09-10 — Voice music control, and bringing Home Assistant under management

Voice requests to play music were "constantly misunderstood". Four things were
wrong. **Only one of them was the cause.**

### The cause: Whisper was on the `tiny` speech model

It transcribed "Love Is All Right" as "love is all as all right". The music
automation searched the library for that literally and failed. The log said so
in plain text, and had done for days:

```
Could not resolve ['the love is all right'] to playable media item
Could not resolve ['love is all as all right'] to playable media item
```

Changed to `small`. Every song and album tested then played first time. On this
i5-7500T that costs a second or two per phrase — a good trade for being
understood. Now pinned in `roles/homeassistant`.

### Three real defects that were NOT the cause

Fixed anyway, because each would have bitten later:

- **`script.claude_play_music` had an empty description.** That string *is* the
  tool description the LLM sees; without it Claude cannot know the tool's seven
  arguments or when to call it. The blueprint's own documentation says in bold
  to set it.
- **Its `default_player` was `media_player.music_player_daemon_2`, which does
  not exist** — verified against the entity registry and the deleted-entity
  list. The player had been renamed `media_player.tap`. Anything reaching
  Claude without naming a room targeted nothing. The log confirmed it was still
  being hit: `Referenced entities media_player.music_player_daemon_2 are
  missing`.
- **The prompt told Claude to give up.** *"if you are confused by a request,
  state simply 'sorry I didn't catch that'"* — turning every near-miss into a
  dead end instead of a clarifying question. Rewritten, and the model moved off
  `recommended` (which had selected Haiku 4.5) to Sonnet 5.

### Two voice paths, and which one actually wins

| Path | Mechanism | Runs when |
|---|---|---|
| `automation.music_assistant_voice_automation` | `conversation` sentence triggers, literal search | Catches "play X" first |
| `script.claude_play_music` | Claude tool call | Phrasings the triggers miss |

The automation wins for ordinary phrasing **even though the pipeline sets
`prefer_local_intents: false`**. Every failure in the log came from it, none
from Claude. With transcription fixed it is reliable and faster than an LLM
round-trip, so it is deliberately left enabled with Claude as the fallback.

### Home Assistant configuration is now managed, with an honest split

`.storage` — the Claude prompt and model, assist pipeline, registries, voice
exposure — is owned by the running Home Assistant and rewritten on its own
schedule. Writing it from Ansible is the trap this repo already knows from
Plasma and qBittorrent. So:

| Layer | Handling |
|---|---|
| Add-on options and Supervisor properties | **Enforced** — `ha-addon-options.sh` |
| YAML files | **Captured** to `state/homeassistant/` |
| `.storage` settings | **Captured**; restored from the weekly backup |

- **New `roles/homeassistant/files/ha-addon-options.sh`** — enforces named
  add-on settings over the Supervisor API. Merges rather than replaces, writes
  only on a real difference, and verifies per key afterwards.
- **New `scripts/capture-homeassistant.sh`** — read-only, redacted capture into
  `state/homeassistant/`. Never reads `secrets.yaml`. Verified: the Plex claim
  code is masked.
- **Add-on update policy codified** — everything pinned except Music Assistant,
  which stays on auto-update deliberately.

### Four bugs found in this repo's own new tooling, all by testing

Every one was caught by running the thing, not by reading it:

- **Options and Supervisor properties are different fields.** Sending
  `auto_update` inside `options` is accepted by the API and then silently
  dropped, because it is not in the add-on's schema. Plex briefly received a
  key it ignored.
- **Whole-object string comparison is wrong.** Piper returns `length_scale` as
  `1.0`; a desired `1` differs as text and matches as a number. That produced a
  permanent false "changed" and then a verification failure on a correct value.
- **`$c[.key] // null` in jq falls through on `false` as well as `null`**, so a
  stored `false` reads as absent — reporting `auto_update: unset -> unset` and
  failing to verify a value that was already right.
- **`"'changed:' in stdout"` matches `"unchanged:"`.** A substring test where a
  prefix test was needed, which reported every add-on as changed on every run.
  Found only by checking idempotency.

### Camera lingering detection — log-only phase

The requirement: not "someone walked past", which in a quiet suburb is noise,
but "someone is hanging about" near the driveway or the front door.

**Motion events now exist at all.** The `tplink` integration exposes only
switches that *enable* detection at the camera — there was no sensor that fires
when something is detected, so there was nothing to trigger from. Home
Assistant's built-in **ONVIF** integration on port **2020** provides real
binary sensors. It authenticates with the camera account rather than the
TP-Link account, which is why it works while the `tplink` integration is
returning `INTERNAL_QUERY_ERROR` on every query for both cameras.

**What the sensors actually do, measured rather than assumed:**

- **They pulse, they do not stay on.** One person moving about for ~70 seconds
  produced four separate on/off pulses of 0.4–10s. "Person present for 30
  seconds" could never fire; counting pulses in a rolling window works.
- **The cameras differ, and it matters.** The driveway is rate-limited to ~1
  ONVIF event per minute; the upstairs camera manages 4. One shared threshold
  would have been wrong for both — the driveway could never reach an upstairs
  threshold. The cap is useful here: the count becomes "how many of the last N
  minutes had activity", a clean loitering measure.

**A wrong conclusion, corrected by the owner.** Both `tplink` and ONVIF
reported no person detection on the driveway camera, and this was read as
"firmware too old" — the driveway runs 1.3.17 against the upstairs camera's
1.5.7. The owner corrected it: the camera does person detection, it is enabled,
and it is fully up to date for its variant. Two integrations agreeing meant
"not exposed to them", not "not supported". Confirmed by test: the Tapo app
fired a person alert while ONVIF produced only motion events.

**A methodological catch worth recording.** The first history analysis copied
`home-assistant_v2.db` without its `-wal` file and therefore missed the most
recent events entirely — it showed no activity for a walk-past that had just
happened. Copy the write-ahead log too, or the data silently ends minutes ago.

**Also disproved by measurement:** ONVIF debug logging showed ~2 events per
second arriving from the driveway camera during rain, which looked like rain
was triggering constant motion. The database showed the actual sensor fired
**11 times in 33 minutes, never more than once a minute** — the log chatter was
webhook processing, not detections. Worth remembering before reacting to a busy
log.

**New `files/ha-packages/camera_lingering.yaml`** — four `history_stats`
counting sensors (5 and 30 minute windows per camera) and two automations that
write logbook entries and **send no alerts**. Thresholds in it are placeholders
set from 33 minutes of data recorded while deliberately walking about in the
rain, which is the opposite of a baseline. The log-only phase exists to gather
real history first.

**New `files/ha-deploy-packages.sh`** — copies only files that differ, adds the
`packages: !include_dir_named packages` line to `configuration.yaml` if
missing, and runs `ha core check` before reporting success. It deliberately
does **not** restart Home Assistant: packages are read only at startup, but
interrupting a media server mid-song as a side effect of a playbook run is the
wrong default.

Packages are used rather than `automations.yaml` because Home Assistant
rewrites that file whenever anything is edited in the UI. A package is
self-contained and untouched by the UI editor — the same principle as the
managed block in `/etc/fstab`.

### The method lesson, again

The first pass diagnosed the LLM configuration from config files and produced
three plausible causes, none of which was it. The answer was in
`ha core logs` the whole time, in plain English, timestamped. `CLAUDE.md` says
to go to the evidence of actual failures first; that is now twice in one week
it was not followed.

## 2026-09-06 — Plex playback failure, and what it exposed

A household member could not stream a show; Plex reported `s3015` (a *media*
error, not a connection error). Diagnosis found the Home Assistant machine had
gone down at ~14:38 — no ping, ARP `FAILED`, none of its four services
answering anywhere on the LAN, and `CIFS: VFS: \\homeassistant.local has not
responded in 180 seconds` in this machine's kernel log.

**Rebooting it was not enough**, which is the interesting part.

- Samba NAS2 took **90 seconds** to reach `started`.
- Both media mounts came up `failed` and stayed that way. Home Assistant mounts
  its media over CIFS from its own Samba add-on and loses that race at boot;
  nothing retries.
- The Plex add-on started at **15:13:31**, inside that window. Mounts were
  reloaded at **15:17**. A running Plex does not re-examine storage that
  changed underneath it, so the machine looked healthy — reachable, file on
  disk, readable — while playback still failed. Restarting Plex fixed it.

That combination is why the fault is so confusing: every individual check
passes and playback still does not work.

### New: `ha-health.sh`, a 15-minute self-healing timer

Waits for Samba, reloads any mount that is not `active`, re-reads the state
rather than trusting the reload's exit code, and restarts Plex **only if a
mount was actually repaired**. A media server that restarts itself on a timer
for no reason is worse than the fault.

A timer rather than a boot hook because gaming-pc cannot observe Home
Assistant's boot — it may be asleep or off. Stated limitation: it only runs
while gaming-pc is awake, so a 3am reboot is repaired at next wake. Closing
that properly needs an automation inside Home Assistant.

`Persistent` is deliberately not set — a missed repair is worth doing at the
next normal firing, not as a burst of catch-up runs on wake.

### Resolution: the client was a browser

The viewer was using **Plex Web in Firefox on an Android tablet**. Installing
the **Plex Android app** fixed it first time, with no settings changed.

Browsers cannot play HEVC 10-bit. The native app can — and does, via the
server's GPU: the working session still shows `videoDecision="transcode"`,
`hevc -> hevc`, `transcodeHwFullPipeline="1"`, which incidentally disproves the
theory that the tablet could not decode Plex's HEVC output.

**The server was healthy throughout.** Nothing about Home Assistant, the
mounts, the libraries, the codecs on disk or the transcoder was ever the cause.

### How to diagnose this properly next time

The single measurement that separates server from client is
`/status/sessions` with a Plex token:

```bash
curl -sS -H "X-Plex-Token: $TOKEN" http://<server>:32400/status/sessions
```

Read `state`, `speed`, `error` and `maxOffsetAvailable` on the
`TranscodeSession`. A session sitting at `state="paused"` with `error="0"` and
minutes of video already buffered means the **server is fine and the client is
failing** — which was visible here and would have ended the investigation
immediately.

Also useful: `/:/prefs` shows `HardwareAcceleratedCodecs` and
`TranscoderTempDirectory`, and `transcodeHwFullPipeline="1"` in a live session
proves hardware transcoding is genuinely engaged rather than merely enabled.

### Four wrong diagnoses worth recording

In order, each stated confidently and each wrong:

1. **"The NVIDIA Shield reads its media from Home Assistant's shares."** A LAN
   sweep found a second Plex at `192.168.68.102`. From "Home Assistant is down"
   + "a Plex is up" + "the show is on Home Assistant's disk", a dependency was
   invented, presented as the cause, and used to argue Home Assistant was a
   single point of failure for all playback. The Shield's libraries were never
   inspected. The owner corrected it: the two servers host entirely separate
   media and the viewer was on the Home Assistant server all along.
2. **"Plex started before storage was ready."** True, and worth fixing — see
   `ha-health.sh` — but not why this viewer could not play.
3. **"Every TV file is HEVC 10-bit, so it is a codec problem."** The correlation
   was real; the conclusion that the *library* mattered was not. A 10-bit movie
   failed too, which was the right test, run late.
4. **"Hardware transcoding is not enabled."** It already was, and a live session
   proves it works.

**The pattern in all four:** reasoning from something adjacent — a port scan, a
directory listing, a settings page — rather than from what the server reported
about the failing session. Each theory was plausible, none was tested before
being reported. The one piece of correct advice given early ("use the app
instead of the browser") was buried among the wrong ones and not followed up.

When a fault has an obvious suspect and a plausible story, the story is the
thing to test, not the thing to report.

## 2026-09-06

- **Updates now apply on a schedule** — `roles/os_updates`, Saturdays at 08:00.
  A reversal of the "report, don't apply" position taken the day before, at the
  owner's request, and a defensible one: the objection was never to automating
  updates, it was to automating them with a tool that skips the driver rebuild.
  `nobara-sync` is the tool that does it.
- **`nobara-sync cli`, never dnf.** It is non-interactive by design and
  re-invokes itself with `sudo`, which is why the timer runs as root — from a
  user session it stops dead asking for a password. Flatpaks included via
  `--all`, because the Flatpak NVIDIA GL runtimes must track the host driver
  and a stale one breaks Flatpak games in ways that look like a game bug.
- **The driver is verified afterwards, and rebuilt if missing**, closing the
  2026-09-05 race for good. The script re-reads `dkms status` rather than
  trusting `dkms autoinstall`'s exit code, and fails loudly if the module is
  still absent.
- **It never reboots.** `os_updates_auto_reboot` exists only to make that an
  explicit decision rather than an omission. The Saturday report says when a
  reboot is due *and* whether the driver is ready for it; that is when the
  decision gets made, not 8am on a timer.
- **The App Centre tray reminder is off.** Suppressed with an XDG autostart
  override carrying `Hidden=true` in the user's home, **not** by deleting the
  package-owned `/etc/xdg/autostart/org.dnf.AppCenter.Updater.desktop` — which
  would return on the next package update and lose the original if it were
  ever wanted back. Takes effect at the next login; the running process is left
  alone and the role says so rather than implying it has gone.
- **The Saturday sequence is now deliberate:**

  | Time | What |
  |---|---|
  | 08:00 | `nobara-update.timer` — update, then verify the driver |
  | 09:30 | `ha-backup.timer` — pull a Home Assistant config backup |
  | 10:09 | Weekly Claude routine — report on both machines, notify |

  In that order so the report describes the machine as it is *after* updating,
  which is the state a decision actually gets made about. All three are
  `Persistent`: this machine suspends after an hour idle and is off overnight,
  so a fixed Saturday time will be missed regularly, and a silently skipped
  week is the failure mode worth designing against.

## 2026-09-05 — Home Assistant brought into scope

The repo now covers a second machine: the mini PC running Home Assistant OS
that serves the media this desktop mounts. Not as an Ansible host — see below.

### A near-miss found within a minute of the first report running

`scripts/check-gaming-pc.sh` was written, run once, and immediately found that
**kernel 7.2.3-200 was installed with no NVIDIA module built for it**. Rebooting
would have produced a machine with no graphics driver.

The cause was a race, visible only in install timestamps:

```
08:52:04  kernel-core-7.2.3 installed   -> DKMS hook fires, no kernel-devel yet
08:52:33  akmods@7.2.3 fails: "kernel-devel required"
09:06:27  kernel-devel-7.2.3 installed  -> 14 min later, separate transaction
```

`/usr/lib/kernel/install.d/40-dkms.install` only runs when the **kernel** is
installed. Nothing re-runs it when `kernel-devel` arrives afterwards, and
nothing retried. The only visible symptom beforehand was a cheerful "reboot
pending". Fixed with `sudo dkms autoinstall -k 7.2.3-200.nobara.fc44.x86_64`.

**The lesson for updates:** apply with `nobara-sync cli`, not the App Centre or
plain dnf. Nobara's updater does the post-update driver rebuild; the other
paths can install a kernel without it. Also worth knowing that three kernels
are kept, so a driverless boot is recoverable by picking the previous kernel
from GRUB rather than being a crisis.

### Home Assistant is not, and cannot be, an Ansible host

HAOS ships no Python, so no Ansible module can run there — only `raw`, which is
shell with extra steps. `roles/homeassistant` therefore manages the **gaming-pc
side** and reaches across over SSH. No second inventory group was added,
because a group that can only ever run `raw` misrepresents what the repo
controls.

**No API token is needed.** One was created and stored root-owned `0600` at
`/etc/homeassistant/api-token`, then turned out to be unnecessary: inside the
SSH session the Supervisor API is on `http://supervisor` with
`$SUPERVISOR_TOKEN` already exported. One credential to keep working across a
rebuild instead of two. Nothing reads that file now.

### Getting SSH on took three attempts, and the log was the only way to tell

The Terminal & SSH add-on **refuses to start at all** without a login
configured — `FATAL: You need to setup a login!` — and then crash-loops, which
also takes the web terminal down. Two traps:

- The **Network** card has its own Save button, separate from the YAML above
  it. Saving the config does not save the port, and the add-on then serves only
  the web terminal while appearing healthy.
- In the visual editor, `authorized_keys` is a list needing a row added; an
  empty row saves as nothing.

Port 22 refusing connections while the add-on shows "started" means the
container is crash-looping. The add-on's Log tab is the only place that says so.

### Storage topology, and why it is not the misconfiguration it looks like

```
NVMe (system disk)
├── /backup           Supervisor backups
└── /media/TV SHOWS   local, ~67 GB, shared as MEDIA/TV SHOWS

USB disk 1  ──> Samba NAS2 shares as ELEMENTS ──┐ mounted BACK over CIFS from
USB disk 2  ──> Samba NAS2 shares as SSD ───────┘ 172.30.32.1 into /media
```

Home Assistant mounts CIFS shares from its **own** Samba add-on. This was first
read as a fragility and flagged as the likely cause of the reported crashes.
That was unfair: HAOS's Supervisor can only mount CIFS and NFS as media
storage, so looping through the local Samba server is the documented way to
make a USB disk visible to add-ons. It is correct, not a mistake.

The real consequence stands: **a Samba NAS2 restart drops Home Assistant's own
media mounts**, and Plex then sees empty libraries. Hence the auto-update work
below, and why `check-homeassistant.sh` reports mount state.

### Add-on updates pinned, except Music Assistant

Every add-on was set to auto-update, including Samba NAS2 — the component all
media access depends on — and Terminal & SSH, the route Ansible uses.

**Samba NAS2 had two separate `auto_update` settings**: the Supervisor-level
property and its own internal option. Turning off only the obvious one looks
done while the add-on keeps updating itself. Both are off now.

Pinned: Samba NAS2, Plex, Terminal & SSH, Whisper, Piper, openWakeWord, Ollama,
Bluetooth Audio Manager. Left automatic: Music Assistant.

**Correction to advice given earlier the same day:** moving Samba NAS2 off its
`2026.7.0-rc11` release candidate is *not possible* — `version_latest` is also
`rc11`, so the repository ships no stable build. With auto-update off it at
least will not move unattended.

Core, OS and Supervisor were never auto-updating: **Core and HAOS have no such
setting**, and the Supervisor updates itself by design.

### Backups: there were none worth the name

All 15 were `partial`. Twelve were pre-update add-on snapshots the Supervisor
takes automatically — useful, but not a backup strategy. Three were "Automatic
backup" at ~8.9 GB, the newest a week old.

The 8.9 GB is almost entirely add-on payload; Ollama's models alone are ~8 GB.
A config-only backup is **60 MB**:

| | Size |
|---|---|
| Full "Automatic backup" | ~8900 MB |
| Config only | ~60 MB |

`ha backups new` cannot express "config and nothing else" — `--app`/`--folders`
make a partial of only those, and passing neither makes a full backup. So the
script calls `POST /backups/new/partial` with `homeassistant: true` and empty
addons/folders directly.

Purged 14 superseded backups, reclaiming **26 GB** (34.8 GB to 8.8 GB; the
system disk went from 61% to 49% used). Kept the 29 Aug Automatic backup as the
only copy of add-on data, plus the new config-only one.

**Media is deliberately not backed up**, at the owner's direction. Stated
plainly because it is a real exposure: the ~67 GB TV library on the HA system
disk is protected by nothing, and a failed NVMe would take the config, the
local backups and the TV library together.

### What was added

- **`roles/homeassistant`** — weekly config-only backup pulled here, systemd
  **user** timer (Sat 09:30, `Persistent=true` because this machine sleeps and
  will miss it). User scope because the desktop user's SSH key is the one Home
  Assistant authorises; a system timer would run as root with the wrong key.
  Pruning only ever deletes backups matching its own name prefix, so a
  retention sweep cannot remove hand-made or Supervisor backups.
- **`scripts/check-homeassistant.sh`** and **`scripts/check-gaming-pc.sh`** —
  read-only reports, written to be read by someone deciding what to update.
- A weekly Claude routine, Saturdays at 10:09, running both and notifying.

Verified end to end: backup created, size settled, downloaded to `.part`,
byte-count matched, tar opened, renamed. 11 seconds, 62 MB. Role is idempotent.

### Two bugs found in this repo's own tooling

- **`dkms status | grep -q` under `set -o pipefail` silently reads false.**
  `grep -q` exits on first match, `dkms` takes SIGPIPE, and the pipeline
  reports failure — so the NVIDIA check was skipped in silence. A check that
  quietly does nothing is worse than no check. Capture to a variable and test
  that instead.
- **Reporting an idle `x-systemd.automount` share as "NOT MOUNTED"** is wrong;
  detaching after the idle timeout is the design. Check the automount unit's
  state, not `findmnt`.

## 2026-09-05

- **DP-2 cable: first real reading, and it looks like the fix.** Over the six
  wake cycles since the cable was changed on 1 Sep 14:22, the **640x480 fault
  has not occurred once**. One genuine DP-2 disconnect episode (5 Sep 08:24),
  and it came back with full EDID — 38 modes at 2560x1440, same as DP-3. Zero
  DP-3 episodes. Before the change it was **14 DP-2 episodes across 15 wake
  cycles**, near enough one every wake.
- **Count episodes, not log lines.** The 63:6 figure recorded on 2026-09-01
  counts log *lines*, and each episode writes roughly six duplicate lines
  within the same second. Counted as distinct episodes the same period is
  **14:2**. Both are real measurements and the ratio is similar (10.5:1 vs
  7:1), but they are not interchangeable — compare like with like. Group by
  timestamp before counting:

  ```bash
  awk '/cable replaced/{f=1;next} f && /DISCONNECTED, card1-DP-2/{print $1" "$2}' \
      ~/.local/state/dp-link-events.log | sort -u | wc -l
  ```

- **Two false positives to discount when reading this log.** The DP-2 entry at
  2 Sep 20:51:26 coincides exactly with a PowerDevil restart, so it is
  libddcutil re-detecting displays rather than the monitor dropping its link —
  anything that restarts PowerDevil will fake a disconnect. And the `EDID
  colorimetry ... is invalid` warnings in the journal are emitted on every
  wake by these monitors and are unrelated to the fault; the fault's signature
  is a connector coming back with **one** mode, not a colorimetry complaint.
- **Not yet conclusive.** Six wake cycles is short of the week of ordinary use
  the verdict was deferred to on 1 Sep. The watcher is still running as a
  lingering user service; re-check in a few days.
- **One stale artefact left alone:** a single junk 640x480 profile remains in
  `~/.config/kwinoutputconfig.json`. It cannot be dated, and nothing else
  suggests a recurrence, so it is almost certainly a leftover from before the
  cable change. Not cleaned out, since removing it would destroy the only
  record of how many junk profiles the fault produced.

## 2026-09-04

- **Idle suspend confirmed working, with a game running.** Five clean suspends
  in two days, each within seven seconds of the configured hour:
  2 Sep 21:51, 3 Sep 09:38, 3 Sep 17:50, 4 Sep 08:46, 4 Sep 09:51. The last
  suspend before the fix was 31 Aug 16:25.
- **Auto-login verified** on the 14:44 reboot. The session started at 14:44:52,
  52 seconds after boot, and **no `plasmalogin` greeter session was created at
  all** — compare 2 Sep, where a greeter session sat for 49 minutes with no
  power management. PowerDevil was active and uninhibited from session start.
  This also confirms plasmalogin does read `/etc/plasmalogin.conf.d/`, which
  could not be proven from the binary beforehand and was inferred only from the
  package shipping the two-tier drop-in layout.

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
