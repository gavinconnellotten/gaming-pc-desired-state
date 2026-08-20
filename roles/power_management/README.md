# power_management

Idle behaviour for `gaming-pc`: when the screens blank, when it locks, when it
suspends, and — the hard part — making sure a keypress can wake it again.

## What it does

| Behaviour | Setting |
|---|---|
| Screens dim | 9 minutes |
| Screens blank **and** session locks | 10 minutes |
| Blank again while locked | 2 minutes |
| Suspend to RAM (S3) | 1 hour |
| Power button | Sleep |
| Password required after resume | Yes |

Plus a udev rule arming the USB wake chain, without which the machine sleeps
after an hour and can only be woken by the power button.

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
