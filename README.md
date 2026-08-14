# gaming-pc-desired-state

Declarative, reproducible setup for `gaming-pc` — a Fedora/Nobara Linux desktop
with an NVIDIA GPU, used primarily for gaming with some Claude experimentation
on the side.

The goal is that a fresh install of this machine (or a similarly-specced
replacement) can be brought back to a known-good state by running the
Ansible playbook in this repo, rather than by re-following manual notes.

## Layout

- `site.yml` — top-level playbook, run against `localhost`.
- `roles/` — one role per concern (e.g. `claude_desktop`).
- `inventory.ini` — local-only inventory (this repo targets the machine it's
  run on, not a fleet).
- `CHANGELOG.md` — dated log of what's been set up and why.

## Usage

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass
```

Requires `ansible-core` (`sudo dnf install ansible-core`) since roles here
use `sudo`/`become` for system package management.

## Current scope

| Area | Status |
|---|---|
| Base OS | Nobara Linux 44 (KDE Plasma), pre-installed |
| NVIDIA driver | Installed out-of-band (driver ISO), not yet managed here |
| Claude Desktop | Managed via `roles/claude_desktop` |

See `CHANGELOG.md` for the history of what's been done manually vs.
codified into Ansible so far.
