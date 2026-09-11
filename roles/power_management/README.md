# power_management

Idle behaviour for `gaming-pc`: when the screens blank, when it locks, when it
suspends, and — the hard part — making sure a keypress can wake it again.

## What it does

| Behaviour | Setting |
|---|---|
| Screens dim | 10 minutes |
| Screens blank | 20 minutes |
| Session locks | 30 minutes |
| Blank again while locked | 2 minutes |
| Suspend to RAM (S3) | 1 hour |
| Power button | Sleep |
| Password required after resume | Yes |

Blanking and locking are deliberately not coincident — blanking is what saves
the power, locking is the security boundary, and the ten minutes between them
is a grace period where a mouse nudge costs no password.

Plus a udev rule arming the USB wake chain, without which the machine sleeps
after an hour and can only be woken by the power button; auto-login, because
the login greeter has no power management at all; and the Saturday maintenance
window described below.

## The bit that is genuinely hard: USB wake

**The wake signal crosses five levels and every one must be armed.**

```
3-4.2          keyboard+mouse HID device     1bcf:08a0
3-4            the USB 2.0 hub               1a40:0101
usb3 / usb4    the ROOT HUBS                 1d6b:0002 / 1d6b:0003
0000:2d:00.3   xHCI controller               (armed by firmware)
0000:00:08.1   PCI bridge                    (armed by firmware)
```

Arming the device and its hub **looks** complete — both report `enabled` — and
the machine still will not wake, because the signal dies at the root hub above
them. That is the trap, and it cost an afternoon.

Walk the whole chain rather than checking the device:

```bash
p=$(readlink -f /sys/bus/usb/devices/3-4.2)
while [ -n "$p" ] && [ "$p" != /sys/devices ]; do
    [ -e "$p/power/wakeup" ] && echo "$(basename $p) $(cat $p/power/wakeup)"
    p=$(dirname "$p")
done
```

Two further details worth keeping:

- **`ACTION=="add|change"`, not `add` alone.** `udevadm trigger` emits a
  *change* event, so an add-only rule appears to do nothing when you reload and
  trigger it — it would only take effect on the next replug or reboot. The
  first version of this rule failed exactly that way and looked correct.
- **Root hubs are matched by PCI address**, not by `usbN`, because kernel
  numbering is not guaranteed stable across boots.

## Firmware prerequisite this role cannot satisfy

**MSI BIOS → Settings → Advanced → Wake Up Event Setup**

| Setting | Value |
|---|---|
| Resume By USB Device | **Enabled** |
| Wake Up Event By | BIOS |

**This was the actual blocker on 2026-08-20.** With it disabled, the udev rule
is present, correct and completely inert — every sysfs level reads `enabled`
and the machine still will not wake. A rebuilt machine restores the rule
automatically and *cannot* restore this, so it belongs on the manual checklist
alongside recreating the SMB credentials.

**`ErP Ready` was NOT the cause.** It was already Disabled on this board. It
was suspected because the keyboard LEDs go dark in S3 — which turned out to be
a consequence of `Resume By USB Device` being off, not of ErP. Recorded so
nobody re-tests it.

## The Saturday maintenance window

Three jobs run on a Saturday morning — the system update (08:20), the Home
Assistant backup (09:30) and the weekly report. All three were unreliable, for
two separate reasons that look like one.

**The machine is asleep when they elapse.** On 2026-09-12 the update timer
triggered at `08:28:13` — the same second the machine resumed from S3. Its
08:00 window had passed while the machine slept, and `Persistent=true` caught
it up on wake. It worked, but it meant the real start time was "whenever
somebody switched the PC on", and a genuinely missed week looked identical to
a healthy one in the journal.

**Waking it is not enough, and this is the part that catches people.** With
nobody at the keyboard there is no input, so PowerDevil's idle countdown runs
from the moment of wake and suspends the machine again an hour later — before
the 09:30 backup. The backup succeeded on 2026-09-12 only because the owner
happened to be sitting at the machine. An early wake *on its own* would have
made the backup worse, not better.

So the window is two mechanisms:

| Piece | Unit | Job |
|---|---|---|
| RTC alarm | `maintenance-window.timer` | `WakeSystem=true` resumes the machine at 08:10 |
| Sleep inhibitor | `maintenance-window.service` | Holds `--what=sleep` until 10:30 |

### Three decisions worth not re-litigating

**It is a system timer, not a user timer.** `WakeSystem=true` needs
`CAP_WAKE_ALARM` to arm the RTC, which a `--user` timer does not have —
`systemctl --user show ha-backup.timer -p WakeSystem` reports `no` for exactly
that reason. And `ha-backup.timer` *cannot* be moved to the system manager to
fix this: it authenticates to Home Assistant with the desktop user's SSH key,
and root's is not authorised there. So the backup is covered by keeping the
machine awake, not by giving it its own alarm.

**The inhibitor asks for `sleep`, not `sleep:idle`.** Inhibiting idle would
also stop the screen locking, so the machine would sit unlocked and lit for
two hours every Saturday. Sleep is the only thing that needs blocking; the
screen still dims, blanks and locks on the normal timings inside the window.

**The timer is `Persistent=false`**, unlike the two it protects. If the window
is missed outright there is nothing useful about running a two-hour inhibitor
at some unrelated hour, and the update and backup each keep their own
`Persistent=true` as the real backstop.

### RTC wake — VERIFIED 2026-09-12, and it needs no BIOS change

Unlike `Resume By USB Device`, this one works out of the box. Confirmed with
`scripts/test-rtc-wake.sh arm 300`, untouched throughout: alarm armed
10:20:57, machine back at 10:20:59, asleep 292s against a 300s alarm.

Re-test with:

```bash
./scripts/test-rtc-wake.sh arm 300   # then touch NOTHING for ~7 minutes
./scripts/test-rtc-wake.sh report
```

**Two things made the first attempt look like a failure.** Both are in the
script's header comment, and neither is obvious:

- **A black screen is not a sleeping machine.** The first test resumed
  correctly and the monitor simply never lit, so it was read as "it did not
  come back up" and woken with a keypress. Judge by the script's heartbeat
  log, never by the screen.
- **The journal cannot time a resume.** Wall-clock timestamps collapse across
  a suspend — `Preparing to enter system sleep state S3` and `Waking up from
  system sleep` both carry the post-resume second — so `journalctl` cannot
  tell you whether the resume preceded a keypress. That is why the script
  keeps its own userspace heartbeat.

If a clean run ever does show it staying asleep, suspect firmware: MSI →
Settings → Advanced → Wake Up Event Setup → **Resume By RTC Alarm**. The
window degrades gracefully in that case — nothing fires until the machine is
woken by hand, with `Persistent=true` catching the update up.

### It resumes to the lock screen, and that is fine

`LockOnResume=true` means the machine wakes to a password prompt. The session
underneath is untouched — `State=active`, `Linger=yes` — so every Saturday job
still runs: the update is a system service, `ha-backup.timer` is a user timer
with lingering, and the report runs in Claude Desktop inside the live session.
A resumed machine that still demands a password is the wanted outcome, not a
problem to solve.

**One behaviour change to know about.** Inside the window a deliberate suspend
request is refused, because the inhibitor is `--mode=block`. That is the point,
but it is surprising if you have forgotten. To suspend anyway:

```bash
sudo systemctl stop maintenance-window.service
```

`scripts/check-power-inhibitors.sh` shows it under system-level inhibitors
while it is held — unlike KDE's application inhibitions, a logind one is
visible to `systemd-inhibit --list`.

## Why kwriteconfig6 rather than copying files

Plasma rewrites `powerdevilrc` and `kscreenlockerrc` while it runs, so copying
whole files fights it for ownership and clobbers every setting not declared
here. Declaring individual keys owns the decisions and leaves the rest alone —
the same principle as the managed block in `/etc/fstab`.

The role reads each value before writing it, because `kwriteconfig6` has no
"only if different" mode and always exits 0, so writing unconditionally would
report `changed` on every run.

**It must not run as root.** These are per-user config files; under `sudo` they
land in root's home where the desktop never reads them, and the run reports
success. The role refuses rather than warning. Same class of bug as
`claude_desktop`'s `--doctor` and `gaming`'s Proton paths.

## The action enum

`1` = Sleep, `8` = Shut down. **Verified**, by setting each in System Settings
and reading back what PowerDevil wrote — not inferred. The numbering isn't
documented anywhere obvious, and an early guess that `8` was "Lock screen" was
wrong. Getting `AutoSuspendAction` wrong means a machine that shuts down after
an hour idle rather than sleeping, so it's pinned explicitly rather than left
to an upstream default.

## Verifying by hand

```bash
systemctl suspend            # then press a key
journalctl -b | grep -iE 'suspend entry|Waking up from system sleep'
cat /sys/power/mem_sleep     # want [deep], not s2idle
```

A healthy cycle looks like `suspend entry (deep)` → `Waking up from S3` →
`suspend exit` about a second later. The wake settings survive the cycle, so no
sleep hook is needed to re-arm them.

## Not managed

Wake-on-LAN, hibernation, and the CPU power profile. Suspend-then-hibernate is
deliberately not used: `NVreg_PreserveVideoMemoryAllocations=1` is set for
resume reliability, and hibernation with 8 GB of VRAM to write out is a
different problem than this machine needs solved.
