#!/usr/bin/env bash
#
# capture-state.sh — read-only inventory of gaming-pc.
#
# Writes a set of plain-text files describing the machine's current state, to
# be committed as the baseline this repo's desired state is designed against.
#
# This script changes no configuration. No sudo required; a few sections are
# simply reported as unavailable if they need privileges we don't have.
#
# One deliberate exception to "only reads": it lists the contents of /mnt/* and
# /media/*, and touching a mountpoint is what triggers an x-systemd.automount
# to attach. That's transient and self-reversing — the shares unmount again on
# their idle timeout — and it's what makes the network-mount picture consistent
# instead of half-idle. It happens before anything observes mount state, on
# purpose. See the network mounts section.
#
# Output is deliberately boring and stable — sorted lists, no timestamps in the
# body of any file — so that re-running it and diffing shows real drift rather
# than noise. The only file that changes on every run is 00-summary.md.
#
# Usage:
#   ./scripts/capture-state.sh                # write to ./state, redacted
#   ./scripts/capture-state.sh --out /tmp/x   # write elsewhere
#   ./scripts/capture-state.sh --no-redact    # keep identifiers (see below)
#
# Redaction is ON by default because this output gets committed to git. It
# masks usernames, hostname, MAC addresses, UUIDs and serial numbers. Review
# the files before committing regardless — redaction is a safety net, not a
# guarantee.

set -uo pipefail

OUT_DIR="state"
REDACT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            OUT_DIR="${2:?--out needs a directory}"
            shift 2
            ;;
        --no-redact)
            REDACT=0
            shift
            ;;
        -h | --help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown argument: %s (try --help)\n' "$1" >&2
            exit 2
            ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# capture <heading> <command> [args...]
#
# Prints a markdown-ish heading followed by the command's output. A missing
# command or a non-zero exit is recorded rather than fatal — this machine won't
# have every tool, and an incomplete inventory beats no inventory.
capture() {
    local title="$1"
    shift
    printf '## %s\n\n' "$title"
    if ! have "$1"; then
        printf '(command not found: %s)\n\n' "$1"
        return 0
    fi
    local out
    if out=$("$@" 2>&1); then
        printf '%s\n\n' "${out:-(no output)}"
    else
        printf '(command failed: %s)\n%s\n\n' "$*" "$out"
    fi
}

# show <heading> <path> — dump a file if it's readable.
show() {
    printf '## %s\n\n' "$1"
    if [ -r "$2" ]; then
        printf '%s\n\n' "$(cat "$2")"
    else
        printf '(not readable: %s)\n\n' "$2"
    fi
}

# kde_config_dump <file>... — contents of named Plasma settings files.
#
# An allowlist, never a sweep of ~/.config. Three things there must not end up
# in a committed file:
#
#   kdeconnect/               device pairing private key and certificate
#   kwinoutputconfig.json     monitor EDID hashes and identifiers
#   kactivitymanagerd-statsrc usage statistics — what was opened, and when
#
# Plasma's config cascades: /etc/xdg -> ~/.config/kdedefaults (the distro's
# look-and-feel) -> ~/.config. The user's files therefore already hold only
# what deviates from the defaults underneath, which is what makes dumping them
# a delta rather than a wall of settings.
kde_config_dump() {
    local base="${XDG_CONFIG_HOME:-$HOME/.config}" f
    for f in "$@"; do
        [ -r "$base/$f" ] || continue
        printf '### %s\n' "$f"
        # Masks values that move on their own rather than when a setting
        # changes — a Dolphin view timestamp updates just from browsing.
        sed -E 's/^(ViewPropsTimestamp)=.*/\1=<timestamp>/' "$base/$f" |
            grep -v '^[[:space:]]*$'
        printf '\n'
    done
}

# post_iso_packages — packages explicitly installed since the ISO was built.
#
# dnf transaction 1 is the image's own package set, recorded when Nobara built
# the ISO — months before this machine was installed, and carried onto disk by
# anaconda. Everything from transaction 2 onward happened *here*. That boundary
# is the machine's own record of what has been added by hand, which is exactly
# the drift this repo exists to codify: without it, "what did I install to make
# Steam work?" is answerable only from memory.
#
# Only Action=Install with Reason=User — dependencies and upgrades are noise.
# Anything since removed is filtered out against the current rpmdb.
post_iso_packages() {
    if ! have dnf; then
        printf '(dnf not found)\n'
        return 0
    fi

    local last added installed
    last=$(dnf history list 2>/dev/null |
        awk '$1 ~ /^[0-9]+$/ {print $1}' | sort -n | tail -1)

    if [ -z "$last" ] || [ "$last" -lt 2 ]; then
        printf '(no transactions since the initial image)\n'
        return 0
    fi

    # Strips name-epoch:version-release.arch, and the no-epoch variant.
    added=$(
        for i in $(seq 2 "$last"); do
            dnf history info "$i" 2>/dev/null |
                awk '$1 == "Install" && $3 == "User" {print $2}'
        done |
            sed -E 's/-[0-9]+:.*//; s/-[0-9][^-]*-[^-]*\.(x86_64|i686|noarch)$//' |
            sort -u
    )
    installed=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u)

    added=$(comm -12 <(printf '%s\n' "$added") <(printf '%s\n' "$installed"))

    if [ -z "$added" ]; then
        printf '(nothing explicitly installed since the image)\n'
    else
        printf '%s\n' "$added"
    fi
}

# redact — mask identifiers on the way to disk.
#
# Deliberately does NOT touch IP addresses: we don't capture any networking
# information, and an IPv4 pattern would corrupt four-part version numbers in
# the package lists.
redact() {
    if [ "$REDACT" -eq 0 ]; then
        cat
        return
    fi
    local user="${USER:-$(id -un)}"
    local host="${HOSTNAME:-$(uname -n)}"
    local sed_args=(
        -E
        -e 's/\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b/<mac>/g'
        -e 's/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/<uuid>/g'
        -e 's/([Ss]erial[A-Za-z ]*:[[:space:]]*)[^[:space:]]+/\1<serial>/g'
    )
    # Only substitute names long enough that a word-boundary match is safe.
    if [ "${#user}" -ge 3 ]; then
        sed_args+=(-e "s|/home/${user}\b|/home/<user>|g" -e "s/\b${user}\b/<user>/g")
    fi
    if [ "${#host}" -ge 3 ]; then
        sed_args+=(-e "s/\b${host}\b/<host>/g")
    fi
    sed "${sed_args[@]}"
}

# write <filename> — collect a section's stdout, redact it, save it.
write() {
    local dest="$OUT_DIR/$1"
    redact >"$dest"
    printf '  %s\n' "$dest" >&2
}

mkdir -p "$OUT_DIR" || exit 1
printf 'Capturing state to %s/ (redaction: %s)\n' "$OUT_DIR" \
    "$([ "$REDACT" -eq 1 ] && echo on || echo OFF)" >&2

# --------------------------------------------------------------------------
# OS, kernel, boot
# --------------------------------------------------------------------------
{
    capture "os-release" cat /etc/os-release
    capture "Nobara release" cat /etc/nobara-release
    capture "Kernel" uname -srmo
    capture "Installed kernels" rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n'
    capture "Boot command line" cat /proc/cmdline
    capture "Secure Boot state" mokutil --sb-state
    capture "SELinux mode" getenforce
    capture "Bootloader entries" bootctl list
} | write 10-os-kernel.txt

# --------------------------------------------------------------------------
# Hardware
# --------------------------------------------------------------------------
{
    # Live scaling frequency and a jittery BogoMIPS reading change every run
    # and say nothing about desired state.
    capture "CPU" sh -c \
        "lscpu | grep -vE '^(CPU\(s\) scaling MHz|BogoMIPS):'"
    # Total only. Used/free/buffers churn constantly.
    capture "Memory" sh -c "free -h | awk '/^Mem:/ {print \"total: \" \$2}'"
    capture "Memory devices" lsmem --summary
    capture "PCI devices" lspci -nn
    capture "USB devices" lsusb
} | write 20-hardware.txt

# --------------------------------------------------------------------------
# GPU / NVIDIA
# --------------------------------------------------------------------------
{
    capture "GPU (PCI)" sh -c "lspci -nn | grep -Ei 'vga|3d|display'"
    capture "nvidia-smi" nvidia-smi \
        --query-gpu=name,driver_version,vbios_version,memory.total,compute_cap \
        --format=csv
    # Field 3 is the live reference count and moves with whatever is using the
    # GPU. Keep name, size and dependants.
    capture "NVIDIA kernel modules" sh -c \
        "lsmod | grep -i nvidia | awk '{print \$1, \$2, \$4}' | sort"
    capture "NVIDIA packages" sh -c "rpm -qa | grep -Ei 'nvidia|akmod|kmod' | sort"
    capture "modprobe.d (NVIDIA-related)" sh -c \
        "grep -rIl nvidia /etc/modprobe.d 2>/dev/null | sort"
    capture "Vulkan ICDs" sh -c "ls -1 /usr/share/vulkan/icd.d 2>/dev/null | sort"
    capture "Session type" sh -c "printenv XDG_SESSION_TYPE XDG_CURRENT_DESKTOP"
} | write 30-gpu-nvidia.txt

# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------
{
    # -e 7 drops loop devices: snapd's loop numbering shuffles between runs, so
    # the same squashfs appears as loop1 then loop2 and diffs as a change.
    capture "Block devices" lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    # Size and mountpoint, not usage — used/available move constantly. CIFS is
    # excluded because those mounts come and go by design; see
    # 45-network-mounts.txt.
    capture "Filesystems" sh -c \
        "df -h --output=source,fstype,size,target -x tmpfs -x devtmpfs -x cifs -x squashfs"
    show "fstab" /etc/fstab
    capture "Btrfs subvolumes" btrfs subvolume list /
    capture "Swap" swapon --show
} | write 40-storage.txt

# --------------------------------------------------------------------------
# Network mounts (SMB/CIFS/NFS)
#
# READ THIS BEFORE CONCLUDING THE SHARES ARE BROKEN.
#
# The CIFS mounts use x-systemd.automount with x-systemd.idle-timeout=60: they
# unmount after a minute of inactivity and remount when something touches the
# mountpoint. So "nothing mounted" is the healthy idle state, not a failure —
# and it looks identical to the failure this repo spent 2026-08-15 diagnosing.
#
# The signal that actually matters is the automount unit, not the mount:
#
#   automount active/waiting  — healthy, idle, will mount on first access
#   automount active/running  — healthy, mounted right now
#   automount inactive/dead   — NOT armed. This one is a real problem.
#
# The mountpoint listing below runs FIRST, deliberately: touching the
# directories arms the automounts, so the mount state observed afterwards is
# consistent rather than a mix of idle and active. Don't reorder these.
#
# Credential FILES are listed with their permissions; their CONTENTS are never
# read — they hold share passwords.
# --------------------------------------------------------------------------
{
    capture "Network mount entries in fstab" sh -c \
        "grep -nE 'cifs|smb|nfs|_netdev' /etc/fstab 2>/dev/null || echo '(no network mount lines found)'"
    # Runs before the mount observations below — see the header. An empty
    # mountpoint is the tell-tale of a mount that failed: the share is "there"
    # in the file manager but has nothing in it.
    capture "Mountpoint contents (entry counts, not names)" bash -c \
        'shopt -s nullglob; found=0
         for d in /mnt/*/ /media/*/; do
             printf "%s: %s entries\n" "${d%/}" "$(ls -1A "$d" 2>/dev/null | wc -l)"
             found=1
         done
         [ "$found" -eq 1 ] || echo "(nothing under /mnt or /media)"'
    # tr -s ' ' throughout this file and 70-services: systemctl and findmnt pad
    # columns to the widest row, so adding or removing ONE unit re-spaces every
    # other line and a one-line change diffs as a hundred. Squeezing runs of
    # spaces costs some column alignment and buys diffs that mean something.
    capture "Automount unit health (the signal that matters — see header)" sh -c \
        "systemctl list-units --type=automount --all --no-pager --no-legend 2>/dev/null | grep -vE '^\s*(dev-|proc-|sys-|run-|boot)' | tr -s ' ' | sort || echo '(no automount units)'"
    capture "Currently mounted network filesystems" sh -c \
        "findmnt -t cifs,smb3,nfs,nfs4 --output SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null | tr -s ' ' || echo '(none mounted — normal if idle; check automount health above)'"
    capture "systemd mount/automount units" sh -c \
        "systemctl list-units --type=mount,automount --all --no-pager --no-legend 2>/dev/null | grep -vE '^\s*(-\.mount|dev-|proc-|sys-|run-|tmp.mount|boot)' | tr -s ' ' | sort"
    capture "Failed mount units" sh -c \
        "systemctl --failed --type=mount,automount --no-pager --no-legend 2>/dev/null | tr -s ' ' || true"
    # May be a single file or a directory of per-share files — both layouts are
    # valid, so don't assume either. Contents are never read: they hold
    # passwords, and this script runs without sudo so it couldn't anyway.
    capture "Credential files (permissions only, contents never read)" bash -c \
        'shopt -s nullglob
         found=0
         for p in /etc/samba/credentials /etc/samba/credentials/*; do
             [ -e "$p" ] || continue
             ls -ld "$p"
             found=1
         done
         [ "$found" -eq 1 ] || echo "(no /etc/samba/credentials)"
         printf "\nContents are never read here. The smb_mounts role checks them\n"
         printf "for trailing whitespace and CRLF line endings when it runs — the\n"
         printf "failure mode that broke these mounts on 2026-08-15.\n"'
    capture "CIFS/SMB client packages" sh -c \
        "rpm -qa --qf '%{NAME}-%{VERSION}\n' | grep -Ei 'cifs-utils|samba|keyutils' | sort"
    capture "Mount errors this boot" sh -c \
        "journalctl -b --no-pager -p warning 2>/dev/null | grep -iE 'cifs|smb|mount' | tail -40 || echo '(journal not readable without privileges)'"
} | write 45-network-mounts.txt

# --------------------------------------------------------------------------
# Package sources
# --------------------------------------------------------------------------
{
    capture "Enabled repositories" dnf repolist --enabled
    capture "All repositories" dnf repolist --all
    capture "Repo definition files" sh -c "ls -1 /etc/yum.repos.d/*.repo 2>/dev/null | sort"
    capture "DNF configuration" cat /etc/dnf/dnf.conf
} | write 50-repos.txt

# --------------------------------------------------------------------------
# Packages
#
# The user-installed list is the one that matters for desired state: it's what
# was asked for, rather than what got pulled in as a dependency. dnf5 and dnf4
# spell this differently, hence the fallback.
# --------------------------------------------------------------------------
{
    printf '## Explicitly installed packages\n\n'
    if have dnf; then
        if out=$(dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null | sort -u); then
            :
        else
            out=""
        fi
        if [ -z "$out" ]; then
            out=$(dnf history userinstalled 2>/dev/null | sort -u)
        fi
        printf '%s\n\n' "${out:-(could not determine user-installed packages)}"
    else
        printf '(dnf not found)\n\n'
    fi
} | write 55-packages-userinstalled.txt

{
    capture "All installed packages (name-version-release.arch)" \
        sh -c "rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort"
} | write 56-packages-all.txt

# --------------------------------------------------------------------------
# Drift from the installation image
#
# The most useful file here when rebuilding: what this machine has that a fresh
# ISO install would not. Steam's runtime dependencies and the multimedia codecs
# are both in this list, and neither is obvious from memory.
# --------------------------------------------------------------------------
{
    printf '## What this file is\n\n'
    printf 'dnf transaction 1 is the package set baked into the installation\n'
    printf 'image, recorded when the ISO was built rather than when this machine\n'
    printf 'was installed. Everything after it happened here — so the list below\n'
    printf 'is what a fresh install would NOT give you, and therefore what the\n'
    printf 'playbooks need to cover.\n\n'
    printf 'Package managers other than dnf are not represented here; see\n'
    printf '60-flatpaks-snaps.txt, and 95-gaming-stack.txt for Proton builds,\n'
    printf 'which are unpacked tarballs that no package manager knows about.\n\n'

    printf '## Packages explicitly installed since the image\n\n'
    post_iso_packages
    printf '\n'

    capture "Transaction history" sh -c \
        "dnf history list 2>/dev/null || echo '(dnf history unavailable)'"
} | write 57-post-iso-additions.txt

{
    capture "Flatpak applications" flatpak list --app \
        --columns=application,version,branch,origin
    capture "Flatpak runtimes" flatpak list --runtime --columns=application,branch,origin
    capture "Flatpak remotes" flatpak remotes --columns=name,url,options
    # Snaps were a blind spot until 2026-08-15. Capturing them immediately
    # surfaced a third-party claudeai-desktop snap that nobody remembered
    # installing — the Publisher column is the point of this section.
    # tr -s ' ' for the same reason as the systemctl captures: snap list pads
    # to the widest name, so removing one snap re-spaces all the others.
    capture "Snap applications (note the publisher)" sh -c \
        "snap list 2>/dev/null | tr -s ' ' || echo '(snapd not installed, or no snaps)'"
} | write 60-flatpaks-snaps.txt

# --------------------------------------------------------------------------
# Services and timers
# --------------------------------------------------------------------------
{
    # tr -s ' ': see the note in the network mounts section — column padding
    # turns any single unit added or removed into a whole-file diff.
    capture "Enabled system units" sh -c \
        "systemctl list-unit-files --state=enabled --no-pager --no-legend | tr -s ' ' | sort"
    capture "Failed system units" sh -c \
        "systemctl --failed --no-pager --no-legend | tr -s ' '"
    # Unit and target only: NEXT/LEFT/LAST/PASSED are all wall-clock and
    # differ on every run.
    capture "System timers" sh -c \
        "systemctl list-timers --all --no-pager --no-legend | awk 'NF >= 2 {print \$(NF-1), \"->\", \$NF}' | sort"
    capture "Enabled user units" sh -c \
        "systemctl --user list-unit-files --state=enabled --no-pager --no-legend | tr -s ' ' | sort"
    capture "Default target" systemctl get-default
} | write 70-services.txt

# --------------------------------------------------------------------------
# Kernel tuning / sysctl / udev
# --------------------------------------------------------------------------
{
    capture "sysctl drop-ins" sh -c \
        "find /etc/sysctl.d /usr/lib/sysctl.d -name '*.conf' 2>/dev/null | sort"
    capture "sysctl values of interest" sh -c \
        "sysctl vm.max_map_count vm.swappiness kernel.split_lock_mitigate fs.file-max 2>&1"
    capture "modprobe.d files" sh -c "ls -1 /etc/modprobe.d 2>/dev/null | sort"
    capture "Custom udev rules" sh -c "ls -1 /etc/udev/rules.d 2>/dev/null | sort"
    capture "Security limits drop-ins" sh -c \
        "ls -1 /etc/security/limits.d 2>/dev/null | sort"
    capture "CPU governor" sh -c \
        "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null"
    capture "Platform profile" sh -c "cat /sys/firmware/acpi/platform_profile 2>/dev/null"
} | write 80-kernel-tuning.txt

# --------------------------------------------------------------------------
# Desktop (KDE Plasma)
#
# Dumps an ALLOWLIST of settings files rather than sweeping ~/.config, because
# this output is committed. See kde_config_dump() for what is excluded and why
# — one of the exclusions is a private key.
#
# Nothing here is managed by a role yet (2026-08-15): the desktop is still
# being set up, so codifying it now would freeze a half-finished configuration.
# This section exists so that when that changes, the answer to "what have I
# actually customised?" comes from the machine rather than from memory.
# --------------------------------------------------------------------------
{
    capture "Plasma version" plasmashell --version
    capture "KDE Frameworks version" kf6-config --version
    capture "Display configuration" kscreen-doctor -o

    printf '## What is captured here, and what is not\n\n'
    printf 'The settings below are an allowlist. Deliberately NOT captured,\n'
    printf 'because this file is committed to git:\n\n'
    printf '  kdeconnect/                device pairing PRIVATE KEY and certificate\n'
    printf '  kwinoutputconfig.json      monitor EDID hashes and identifiers\n'
    printf '  kactivitymanagerd-statsrc  usage statistics (what was opened, when)\n'
    printf '  session/, plasmanotifyrc, kconf_updaterc, Trolltech.conf,\n'
    printf '  QtProject.conf             generated state, no settings in them\n\n'
    printf 'Plasma config cascades: /etc/xdg -> ~/.config/kdedefaults (the\n'
    printf "distro's look-and-feel) -> ~/.config. The user files below therefore\n"
    printf 'already contain only what deviates from the defaults beneath them.\n\n'

    printf '## Plasma settings (user)\n\n'
    kde_config_dump kdeglobals kwinrc kcminputrc kscreenlockerrc \
        powerdevilrc powermanagementprofilesrc plasmarc plasmashellrc \
        dolphinrc konsolerc katerc kglobalshortcutsrc

    printf '## Distro defaults these sit on top of\n\n'
    kde_config_dump kdedefaults/kdeglobals kdedefaults/kwinrc \
        kdedefaults/kcminputrc kdedefaults/plasmarc kdedefaults/ksplashrc \
        kdedefaults/package

    printf '## Toolkit and XDG integration\n\n'
    kde_config_dump gtkrc gtkrc-2.0 gtk-3.0/settings.ini gtk-4.0/settings.ini \
        user-dirs.dirs mimeapps.list

    # Widget inventory only. The full appletsrc carries per-screen geometry and
    # applet ids that mean nothing on a rebuilt machine, so restoring it is a
    # bad idea and diffing it is noise. Which widgets are on the panel is the
    # part worth knowing.
    capture "Panel widgets (inventory only — layout is screen-specific)" sh -c \
        "grep -hE '^plugin=' \"\${XDG_CONFIG_HOME:-\$HOME/.config}/plasma-org.kde.plasma.desktop-appletsrc\" 2>/dev/null | sed 's/^plugin=//' | sort | uniq -c | tr -s ' ' || echo '(no panel configuration)'"
    capture "Config files present in ~/.config (names only)" sh -c \
        "ls -1 \"\${XDG_CONFIG_HOME:-\$HOME/.config}\" 2>/dev/null | sort"
    capture "Autostart entries" sh -c \
        "ls -1 \"\${XDG_CONFIG_HOME:-\$HOME/.config}/autostart\" 2>/dev/null | sort"
    capture "Installed look-and-feel themes (global)" sh -c \
        "ls -1 /usr/share/plasma/look-and-feel 2>/dev/null | sort"
} | write 90-desktop-kde.txt

# --------------------------------------------------------------------------
# Gaming stack
# --------------------------------------------------------------------------
{
    printf '## Gaming tools present\n\n'
    for tool in steam lutris heroic bottles gamemoded gamescope mangohud \
        goverlay protonup-qt obs vkcube glxinfo vkbasalt corectrl; do
        if have "$tool"; then
            printf '%-14s present (%s)\n' "$tool" "$(command -v "$tool")"
        else
            printf '%-14s absent\n' "$tool"
        fi
    done
    printf '\n'

    capture "Gaming-related packages" sh -c \
        "rpm -qa --qf '%{NAME}\n' | grep -Ei 'steam|lutris|heroic|wine|proton|gamemode|gamescope|mangohud|vkbasalt|bottles' | sort"
    capture "Steam library paths" sh -c \
        "find \"\$HOME\" -maxdepth 4 -name libraryfolders.vdf 2>/dev/null | sort"
    capture "Compatibility tools (Steam)" sh -c \
        "ls -1 \"\$HOME/.steam/root/compatibilitytools.d\" 2>/dev/null | sort"
    capture "Proton versions in Steam apps" sh -c \
        "ls -1d \"\$HOME\"/.steam/steam/steamapps/common/Proton* 2>/dev/null | sort"
    capture "Game controllers" sh -c \
        "ls -1 /dev/input/by-id 2>/dev/null | grep -i -E 'joystick|gamepad|event-joystick' | sort"
    capture "gamemode configuration" sh -c \
        "cat /etc/gamemode.ini 2>/dev/null || echo '(no /etc/gamemode.ini)'"
} | write 95-gaming-stack.txt

# --------------------------------------------------------------------------
# User environment
#
# Group membership matters here: Cowork/KVM needs the *user* in the kvm group,
# which is easy to miss when diagnostics get run as root.
# --------------------------------------------------------------------------
{
    capture "Groups for current user" id -nG
    capture "Login shell" sh -c "getent passwd \"\$(id -un)\" | cut -d: -f7"
    capture "Shell dotfiles present" sh -c \
        "ls -1a \"\$HOME\" 2>/dev/null | grep -E '^\\.(bash|zsh|profile|inputrc|gitconfig|tmux)' | sort"
    capture "Git configuration (global, keys only)" sh -c \
        "git config --global --list --name-only 2>/dev/null | sort"
    capture "Flatpak overrides (user)" sh -c \
        "ls -1 \"\$HOME/.local/share/flatpak/overrides\" 2>/dev/null | sort"
    # stat, not ls -l: the device node's timestamp changes on every boot.
    capture "KVM device access" sh -c \
        "stat -c '%A %U:%G %n' /dev/kvm 2>&1 || echo '(no /dev/kvm)'"
    # PID, free disk space and log size all move on their own. What matters
    # here is which checks PASS, not the numbers beside them.
    capture "Claude Desktop diagnostics (as this user)" sh -c \
        "claude-desktop-unofficial --doctor 2>&1 |
         sed -E 's/PID [0-9]+/PID <pid>/g;
                 s/Disk space: [0-9]+MB free/Disk space: <n>MB free/;
                 s/Log file: [0-9]+(\.[0-9]+)?([KMG]B)/Log file: <n>\2/'"
} | write 97-user-env.txt

# --------------------------------------------------------------------------
# Summary — the only file with a timestamp, kept last so it reflects the run.
# --------------------------------------------------------------------------
{
    printf '# gaming-pc state summary\n\n'
    printf -- '- Captured: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Redaction: %s\n' "$([ "$REDACT" -eq 1 ] && echo enabled || echo DISABLED)"
    printf -- '- OS: %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
    printf -- '- Kernel: %s\n' "$(uname -r)"
    printf -- '- Desktop: %s (%s)\n' "${XDG_CURRENT_DESKTOP:-unknown}" "${XDG_SESSION_TYPE:-unknown}"
    printf -- '- CPU: %s\n' "$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    printf -- '- Memory: %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}')"
    if have nvidia-smi; then
        printf -- '- GPU: %s\n' "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    fi
    # Count only lines that actually look like package names, so error text
    # ("rpm: not found") and headings don't inflate the totals.
    printf -- '- Explicit packages: %s\n' \
        "$(grep -cE '^[A-Za-z0-9][A-Za-z0-9._+-]*$' "$OUT_DIR/55-packages-userinstalled.txt" 2>/dev/null)"
    printf -- '- Total RPMs: %s\n' \
        "$(grep -cE '^[A-Za-z0-9][A-Za-z0-9._+-]*$' "$OUT_DIR/56-packages-all.txt" 2>/dev/null)"
    printf -- '- Flatpaks: %s\n' \
        "$(flatpak list --app --columns=application 2>/dev/null | grep -c .)"
    printf '\n## Files\n\n'
    for f in "$OUT_DIR"/*.txt; do
        [ -e "$f" ] || continue
        printf -- '- `%s` (%s lines)\n' "$(basename "$f")" "$(wc -l <"$f" | tr -d ' ')"
    done
} | write 00-summary.md

printf '\nDone. Review the files before committing — especially 97-user-env.txt.\n' >&2
