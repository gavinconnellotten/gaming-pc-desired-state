# Changelog

Dated log of what's been done to `gaming-pc`, and whether it's been codified
into this repo yet.

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
