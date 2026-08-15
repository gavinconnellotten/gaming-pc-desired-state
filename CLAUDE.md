# CLAUDE.md

Context for Claude Code working in this repo.

## What this is

Desired-state configuration for `gaming-pc`, a personal Fedora/Nobara desktop.
The goal: a fresh install can be brought back to a known-good state by running
the playbook, rather than by re-following manual notes.

This is a gaming machine with casual scripting on the side — **not** a
development workstation. Prefer boring, legible configuration over clever
abstraction. The owner is comfortable in a terminal but doesn't want this repo
to become a project in its own right.

## The machine

| | |
|---|---|
| Hostname | `gaming-pc` |
| OS | Nobara Linux 44 (Fedora-based), KDE Plasma |
| CPU / GPU | AMD CPU, NVIDIA GeForce RTX 4060 Ti |
| NVIDIA driver | 595.91.07, installed from the Nobara NVIDIA driver ISO |
| Storage | Single internal NVMe, whole disk, OS volume |
| Migrated from | Windows 11, week of 2026-08-07 |

## How this repo is run

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass
```

Run **as the user, with `--ask-become-pass`** — not under `sudo`. See the
diagnostics gotcha below; this distinction is load-bearing.

## Conventions

- **`ansible-core` only.** No Galaxy collections. `/etc/fstab` is managed with
  `ansible.builtin.blockinfile` rather than `ansible.posix.mount` specifically
  to avoid a collection dependency. Keep it that way unless there's a real
  reason — adding one means another install step on a rebuilt machine.
- **One role per concern**, each with a `README.md` explaining not just what it
  does but *why* — several roles encode non-obvious failure modes.
- **`CHANGELOG.md` is the ledger**: dated entries recording what was done to
  the machine and whether it's been codified here yet. Update it with any
  substantive change. It's the record of manual-vs-managed drift.
- **No secrets in the repo.** Credentials live in root-owned `0600` files
  outside it, referenced by path. Roles fail loudly when they're missing
  rather than proceeding.
- Roles should **verify their own work** where cheap, and report status rather
  than assuming success.

## Current state

| Area | Status |
|---|---|
| Claude Desktop | Managed — `roles/claude_desktop` |
| SMB network shares | **Managed and applied** — `roles/smb_mounts` |
| State capture | `scripts/capture-state.sh` → `state/` (baseline captured 2026-08-15) |
| NVIDIA driver | Installed out-of-band, deliberately unmanaged |
| Dotfiles / KDE settings | Not managed yet (intended scope, not started) |
| Gaming stack (Steam/Proton/etc) | Not managed yet |

## SMB shares — done

Three shares, all on `homeassistant.local` (Home Assistant's "SambaNAS2"
addon) under one login, managed by `roles/smb_mounts` and applied 2026-08-15:

| Share | Mountpoint |
|---|---|
| `SSD/MOVIES` | `/mnt/plex-movies` |
| `ELEMENTS/Music` | `/mnt/plex-music` |
| `MEDIA/TV SHOWS` | `/mnt/plex-tv` |

They had been failing because the credentials file read `username=gavin  ` with
two trailing spaces, which `mount.cifs` passed verbatim — so the server rejected
a user that didn't exist. `CHANGELOG.md` has the full diagnosis;
`roles/smb_mounts/README.md` has the causes in the order actually worth
checking, and the two gotchas (systemd `\x2d` unit escaping, and why
`findmnt --verify` can't be used directly as a `validate:`).

Worth knowing when re-reading this:

- **A rebuilt machine needs the credential file recreated** by
  `./scripts/setup-smb-credentials.sh` before the playbook can do anything.
  That's deliberate — no passwords in the repo.
- **Share names with spaces are written literally in `host_vars`**; the role
  escapes them to `\040`. The Jinja filter takes **one** backslash, not two —
  two renders a path that's wrong but still parses, so nothing catches it.
- **The role refuses to run** alongside unmanaged CIFS lines in `/etc/fstab`,
  and prints the command to comment them out.

## Gotchas discovered the hard way

- **`--doctor` must not run as root.** Its checks are per-user (`/dev/kvm`
  access, `kvm` group membership, `$HOME` config paths). As root they pass
  trivially and say nothing about whether the desktop user can use Cowork. The
  task uses `become: false` and warns if it still ends up as root. Don't
  "simplify" this away.
- **`blockinfile`'s `validate` runs `findmnt --verify` over the whole fstab**,
  not just the new block. A pre-existing problem anywhere in the file blocks
  the write. The role reports fstab health beforehand so this is interpretable.
- **`findmnt --verify` needs mountpoint directories to already exist**, which
  is why they're created before the fstab task. Don't reorder.
- **Nobara ships its own update system** (`nobara-sync` / Nobara Updater) with
  layered repos and patched packages. Don't force-manage packages Nobara also
  manages — it causes drift or breakage on their update cycle. This is the main
  constraint on widening scope.
- **Claude Desktop has no official Fedora package.** It's installed from
  `aaddrick/claude-desktop-debian`, which since v3.0.0 repackages Anthropic's
  official Linux `.deb` as an RPM. Anthropic officially supports Debian/Ubuntu
  only. If official Fedora support lands, switch to it and drop the community
  repo.

## Validating changes

There's no CI. Before committing:

```bash
bash -n scripts/*.sh                                        # shell syntax
ansible-playbook -i inventory.ini site.yml --syntax-check    # playbook syntax
ansible-playbook -i inventory.ini site.yml --check           # dry run
```

`scripts/capture-state.sh` is safe to run any time — read-only, no `sudo`, no
mutation. Re-run it and `git diff state/` to see what's drifted.

Its output is committed, so it redacts usernames, hostname, MAC addresses,
UUIDs and serial numbers by default. Review diffs before committing anyway;
redaction is a safety net, not a guarantee. Credential file *contents* are
never read.

## Working agreement

The owner wants to understand what's being done, not just receive it. Explain
reasoning, flag concerns before building, and don't silently widen scope.
Prefer detecting-and-reporting over auto-fixing for anything boot-critical —
`/etc/fstab` in particular is not a file to rewrite unattended.

## History

Started 2026-08-14 in Claude Code **on the web** (claude.ai/code) — the same
Claude Code, but executing in an Anthropic cloud container rather than on
`gaming-pc`. That session could see this git repo and nothing else: no
`/etc/fstab`, no `journalctl`, no NAS on the LAN. Everything through commit
`3b48904` was therefore written blind, against the owner's descriptions, and
relayed by hand.

Running locally you have none of that limitation. Read the real files, check
the real journal, test-mount the real shares, and iterate until things
actually work — rather than reasoning about what's probably wrong. Verify the
assumptions baked into `roles/smb_mounts` against the machine rather than
trusting them.

Branch: `claude/fedora-nobara-gaming-setup-ps0v2v` (not yet merged to `main`).
