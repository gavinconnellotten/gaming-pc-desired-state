# state/

Captured inventory of `gaming-pc` as it actually is, produced by
`../scripts/capture-state.sh`.

This is the **observed** state, not the desired state. It's the baseline the
Ansible roles are written against, and the thing to diff when you want to know
what's drifted since.

## Refreshing

```bash
./scripts/capture-state.sh
git diff state/
```

It needs no `sudo` and changes no configuration. Everything except
`00-summary.md` is written without timestamps, and fields that move on their
own — CPU scaling frequency, free memory, kernel module refcounts, disk usage,
snapd's loop-device numbering, systemd timer schedules, PIDs — are stripped or
normalised. Two consecutive runs are byte-identical apart from the summary's
timestamp, so anything a diff shows is real drift.

One deliberate exception to "only reads": the script lists `/mnt/*` and
`/media/*`, and touching a mountpoint is what triggers an
`x-systemd.automount` to attach. That's transient and self-reversing.

## Reading `45-network-mounts.txt`

**An empty "currently mounted" section does not mean the shares are broken.**
They use `x-systemd.automount` with a 60-second idle timeout, so they unmount
when nothing is using them — which looks identical to the failure this repo
spent 2026-08-15 diagnosing. The automount unit is the signal:

| State | Meaning |
|---|---|
| `active/waiting` | Healthy, idle, will mount on first access |
| `active/running` | Healthy, mounted right now |
| `inactive/dead` | Not armed — a real problem |

The capture lists mountpoint contents *before* observing mount state, so the
two sections agree rather than showing a half-idle picture.

## Before committing

Output is redacted by default: usernames, hostname, MAC addresses, UUIDs and
serial numbers are masked. **Read the diff before committing anyway.**
Redaction is pattern-matching, not a guarantee, and `97-user-env.txt` is the
one most likely to pick up something personal.

Credential files are never read — `45-network-mounts.txt` records that they
exist and what their permissions are, nothing more.

## Files

| File | Contents |
|---|---|
| `00-summary.md` | At-a-glance summary; the only file with a timestamp |
| `10-os-kernel.txt` | OS release, kernel, boot cmdline, Secure Boot, SELinux |
| `20-hardware.txt` | CPU, memory, PCI and USB devices |
| `30-gpu-nvidia.txt` | GPU, driver version, NVIDIA packages, Vulkan ICDs |
| `40-storage.txt` | Block devices, filesystems, fstab, Btrfs subvolumes |
| `45-network-mounts.txt` | SMB/NFS mounts, mount units, mount failures |
| `50-repos.txt` | DNF repositories and configuration |
| `55-packages-userinstalled.txt` | Explicitly installed packages — the list that matters |
| `56-packages-all.txt` | Every installed RPM, dependencies included |
| `60-flatpaks.txt` | Flatpak apps, runtimes and remotes |
| `70-services.txt` | Enabled units, timers, failed units |
| `80-kernel-tuning.txt` | sysctl, modprobe, udev, limits, CPU governor |
| `90-desktop-kde.txt` | Plasma version, displays, config file inventory |
| `95-gaming-stack.txt` | Steam/Proton/Lutris/gamemode and controllers |
| `97-user-env.txt` | Groups, shell, dotfiles, KVM access, Claude doctor |
