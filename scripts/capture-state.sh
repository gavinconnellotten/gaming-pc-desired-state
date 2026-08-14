#!/usr/bin/env bash
#
# capture-state.sh — read-only inventory of gaming-pc.
#
# Writes a set of plain-text files describing the machine's current state, to
# be committed as the baseline this repo's desired state is designed against.
#
# This script NEVER modifies the system. It only reads. No sudo required; a few
# sections are simply reported as unavailable if they need privileges we don't
# have.
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
    capture "CPU" lscpu
    capture "Memory" free -h
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
    capture "NVIDIA kernel modules" sh -c "lsmod | grep -i nvidia | sort"
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
    capture "Block devices" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    capture "Filesystem usage" df -hT -x tmpfs -x devtmpfs
    show "fstab" /etc/fstab
    capture "Btrfs subvolumes" btrfs subvolume list /
    capture "Swap" swapon --show
} | write 40-storage.txt

# --------------------------------------------------------------------------
# Network mounts (SMB/CIFS/NFS)
#
# Captures enough to explain the classic "share is listed but the folder is
# empty" symptom, which is almost always a mount that silently failed at boot,
# leaving the bare mountpoint directory visible underneath.
#
# Credential FILES are listed with their permissions; their CONTENTS are never
# read — they hold share passwords.
# --------------------------------------------------------------------------
{
    capture "Network mount entries in fstab" sh -c \
        "grep -nE 'cifs|smb|nfs|_netdev' /etc/fstab 2>/dev/null || echo '(no network mount lines found)'"
    capture "Currently mounted network filesystems" sh -c \
        "findmnt -t cifs,smb3,nfs,nfs4 --output SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || echo '(none mounted)'"
    capture "systemd mount/automount units" sh -c \
        "systemctl list-units --type=mount,automount --all --no-pager --no-legend 2>/dev/null | grep -vE '^\s*(-\.mount|dev-|proc-|sys-|run-|tmp.mount|boot)' | sort"
    capture "Failed mount units" sh -c \
        "systemctl --failed --type=mount,automount --no-pager --no-legend 2>/dev/null || true"
    capture "Credential files (permissions only, contents never read)" sh -c \
        "ls -l /etc/samba/credentials/ 2>/dev/null || echo '(no /etc/samba/credentials directory)'"
    capture "CIFS/SMB client packages" sh -c \
        "rpm -qa --qf '%{NAME}-%{VERSION}\n' | grep -Ei 'cifs-utils|samba|keyutils' | sort"
    capture "Mount errors this boot" sh -c \
        "journalctl -b --no-pager -p warning 2>/dev/null | grep -iE 'cifs|smb|mount' | tail -40 || echo '(journal not readable without privileges)'"
    # An empty mountpoint directory is the tell-tale of a mount that failed:
    # the share is "there" in the file manager but has nothing in it.
    capture "Mountpoint contents (entry counts, not names)" bash -c \
        'shopt -s nullglob; found=0
         for d in /mnt/*/ /media/*/; do
             printf "%s: %s entries\n" "${d%/}" "$(ls -1A "$d" 2>/dev/null | wc -l)"
             found=1
         done
         [ "$found" -eq 1 ] || echo "(nothing under /mnt or /media)"'
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

{
    capture "Flatpak applications" flatpak list --app \
        --columns=application,version,branch,origin
    capture "Flatpak runtimes" flatpak list --runtime --columns=application,branch,origin
    capture "Flatpak remotes" flatpak remotes --columns=name,url,options
} | write 60-flatpaks.txt

# --------------------------------------------------------------------------
# Services and timers
# --------------------------------------------------------------------------
{
    capture "Enabled system units" sh -c \
        "systemctl list-unit-files --state=enabled --no-pager --no-legend | sort"
    capture "Failed system units" systemctl --failed --no-pager --no-legend
    capture "System timers" sh -c \
        "systemctl list-timers --all --no-pager --no-legend | sort"
    capture "Enabled user units" sh -c \
        "systemctl --user list-unit-files --state=enabled --no-pager --no-legend | sort"
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
# Listing config filenames rather than dumping their contents: the contents are
# large, churn constantly, and can carry personal data. When we get to managing
# dotfiles we'll pick specific files deliberately.
# --------------------------------------------------------------------------
{
    capture "Plasma version" plasmashell --version
    capture "KDE Frameworks version" kf6-config --version
    capture "Display configuration" kscreen-doctor -o
    capture "Config files in ~/.config" sh -c \
        "ls -1 \"\${XDG_CONFIG_HOME:-\$HOME/.config}\" 2>/dev/null | sort"
    capture "Autostart entries" sh -c \
        "ls -1 \"\${XDG_CONFIG_HOME:-\$HOME/.config}/autostart\" 2>/dev/null | sort"
    capture "Installed themes (global)" sh -c \
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
    capture "KVM device access" sh -c "ls -l /dev/kvm 2>&1"
    capture "Claude Desktop diagnostics (as this user)" \
        claude-desktop-unofficial --doctor
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
