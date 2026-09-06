# os_updates

Weekly system updates through **Nobara's own updater**, with a graphics-driver
check afterwards, and the App Centre's tray reminder turned off.

## Why `nobara-sync` and never `dnf`

Nobara ships patched packages and layered repos, and its updater performs
post-update fixups — including the NVIDIA module rebuild — that plain `dnf` and
the App Centre skip. Driving `dnf` around it causes drift on Nobara's release
cycle. That is a standing rule in this repo; this role follows it rather than
making an exception for automation.

`nobara-sync cli` is non-interactive by design: *"Installs system updates and
fixups by default; use `--all` to also install Flatpak updates."* It re-invokes
itself with `sudo`, which is why the timer runs as root — from a user session it
would stop dead asking for a password.

Flatpaks are included (`--all`) because the Flatpak NVIDIA GL runtimes have to
track the host driver version, and a stale one breaks Flatpak games in ways
that look like a game bug rather than a packaging one.

## The driver check, and why it exists

On **2026-09-05** kernel `7.2.3-200` was installed with no NVIDIA module built
for it:

```
08:52:04  kernel-core-7.2.3 installed   -> 40-dkms.install fires, no kernel-devel
08:52:33  akmods@7.2.3 fails: "kernel-devel required"
09:06:27  kernel-devel-7.2.3 installed  -> 14 min later, separate transaction
```

`/usr/lib/kernel/install.d/40-dkms.install` only runs when the **kernel** is
installed. Nothing re-runs it when `kernel-devel` turns up afterwards, and
nothing retried. The only visible symptom was a cheerful "reboot pending".
Rebooting would have produced a machine with no graphics driver.

`nobara-sync` normally handles this, which is much of the argument for using it
rather than the App Centre. The check still runs afterwards, because it costs a
second and the thing it guards against is a desktop that will not come back.

If the module is missing the script builds it, then **re-reads `dkms status`
rather than trusting the exit code**, and fails loudly if it is still absent.

## It never reboots

`os_updates_auto_reboot` exists only to make that an explicit decision rather
than an omission. A reboot taken unattended is a reboot taken mid-download or
mid-game. The Saturday report says when one is due *and* whether the driver is
ready for it — that is the moment to decide, not 8am on a timer.

If you ever do boot a kernel with no driver: three kernels are kept, so hold
**Shift** (or tap **Esc**) at startup, choose the previous one, and rebuild from
there. Inconvenience, not crisis.

## Where it sits in the Saturday sequence

```
08:00  nobara-update.timer     updates, then verifies the driver
09:30  ha-backup.timer         pulls a Home Assistant config backup
10:09  weekly Claude routine   reports on both machines, notifies
```

Deliberately in that order, so the report describes the machine as it is
**after** updating — which is the state a decision actually gets made about.

All three carry `Persistent=true` or its equivalent. This machine suspends after
an hour idle and is switched off overnight, so a fixed Saturday time will be
missed regularly; a silently skipped week is the failure mode worth designing
against.

## The tray icon

`/etc/xdg/autostart/org.dnf.AppCenter.Updater.desktop` starts
`dnf-app-center-updater`, which is what puts the update icon in the system tray
and nags about pending updates. With updates on a schedule and a weekly report,
that is a second nagging system for one job.

It is suppressed with an XDG autostart override in the user's home carrying
`Hidden=true` — **not** by deleting the packaged file, which would come back on
the next package update and would lose the original if it were ever wanted
again. Reversible by deleting
`~/.config/autostart/org.dnf.AppCenter.Updater.desktop`, or by setting
`os_updates_disable_appcenter_tray: false`, which removes it for you.

It takes effect at the next login. The already-running process is left alone;
the role says so rather than implying it has gone.

## Running it by hand

```bash
sudo systemctl start nobara-update.service
journalctl -u nobara-update.service -n 50
```

Worth doing once after first install, to watch it work rather than discovering
on a Saturday that it does not.
