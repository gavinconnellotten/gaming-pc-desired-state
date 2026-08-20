# gaming-pc-desired-state

Declarative, reproducible setup for `gaming-pc` — a Fedora/Nobara Linux desktop
with an NVIDIA GPU, used primarily for gaming with some Claude experimentation
on the side.

The goal is that a fresh install of this machine (or a similarly-specced
replacement) can be brought back to a known-good state by running the
Ansible playbook in this repo, rather than by re-following manual notes.

## Layout

- `CLAUDE.md` — context for Claude Code sessions working in this repo.
- `site.yml` — top-level playbook, run against `localhost`.
- `roles/` — one role per concern (e.g. `claude_desktop`, `smb_mounts`).
- `host_vars/gaming-pc.yml` — machine-specific settings (share definitions).
- `inventory.ini` — local-only inventory (this repo targets the machine it's
  run on, not a fleet).
- `scripts/` — helpers that sit outside the playbook (state capture, secret
  setup).
- `state/` — captured inventory of the machine as it actually is; the baseline
  the roles are written against.
- `CHANGELOG.md` — dated log of what's been set up and why.

## Usage

Capture what the machine currently looks like (read-only, no `sudo`):

```bash
./scripts/capture-state.sh
git diff state/
```

Create the SMB share credentials (prompts; writes outside the repo):

```bash
./scripts/setup-smb-credentials.sh
```

Apply the desired state:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass
```

Requires `ansible-core` (`sudo dnf install ansible-core`) since roles here
use `sudo`/`become` for system package management.

## Secrets

No passwords in this repo. SMB credentials live in root-owned `0600` files
under `/etc/samba/credentials`, created by `scripts/setup-smb-credentials.sh`
and referenced by path. The playbook refuses to run if they're missing rather
than failing obscurely later.

A rebuilt machine needs those files recreated by re-running that script — keep
the logins in a password manager.

## Current scope

| Area | Status |
|---|---|
| Base OS | Nobara Linux 44 (KDE Plasma), pre-installed |
| NVIDIA driver | Installed out-of-band (driver ISO), not yet managed here |
| Claude Desktop | Managed via `roles/claude_desktop` |
| SMB network shares | Managed via `roles/smb_mounts` |
| Gaming stack | Post-install additions managed via `roles/gaming`; Nobara's own packages left alone |
| Power / idle behaviour | Managed via `roles/power_management` (plus one BIOS setting) |
| Desktop apps | Managed via `roles/desktop_apps` (qBittorrent, Proton VPN, Proton Mail) |
| Dotfiles / KDE settings | Not managed yet |
| State capture | `scripts/capture-state.sh` → `state/` |

See `CHANGELOG.md` for the history of what's been done manually vs.
codified into Ansible so far.
