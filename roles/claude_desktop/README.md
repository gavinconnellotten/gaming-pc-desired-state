# claude_desktop

Installs Claude Desktop on Fedora/Nobara via the community
[`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian)
RPM repackaging (there's no official Anthropic package for DNF-based
distros), plus the dependencies needed for MCP servers and Cowork
(sandboxed execution) mode.

## What it does

1. Adds the `claude-desktop-unofficial` DNF repo.
2. Installs `claude-desktop-unofficial`, `nodejs`, `qemu-system-x86`, and
   `edk2-ovmf`.
3. Runs `claude-desktop-unofficial --doctor` and prints the result, so you
   can see at a glance if anything (KVM permissions, firmware paths, etc.)
   needs attention on this particular machine.

## A note on who runs the diagnostics

The rest of the role needs root, but `--doctor` deliberately runs as the
invoking user (`become: false`). Its checks are per-user: access to
`/dev/kvm`, `kvm` group membership, config under `$HOME`. Run as root they
all pass trivially and tell you nothing about whether *you* can use Cowork —
a green result would be actively misleading.

So run the playbook as yourself with `--ask-become-pass`, not under `sudo`.
If you do use `sudo`, the role notices and says so rather than reporting
root's answers as if they were yours.

If diagnostics report a KVM problem, the usual fix is adding your user to the
`kvm` group (`sudo usermod -aG kvm $USER`), which takes effect at next login.
The role doesn't do this automatically — group changes need a re-login to
apply, so it's better done knowingly.

## Variables

See `defaults/main.yml` — repo URL, package name, and the extra dependency
list are all overridable if upstream naming changes.

## Why `state: latest` for the app but not its dependencies

`claude_desktop_state` defaults to `latest`. Claude Desktop comes from the
community repo and **nothing else on the machine updates it** — with `present`
it is installed once and then drifts, which is exactly what happened: the
app's own `--doctor` was reporting `Version drift: official pool has 1.32885.1,
this install packages 1.30096.1` on every run.

The trade-off is that running the playbook can now upgrade the app. Set
`claude_desktop_state: present` to pin it and upgrade by hand instead.

`nodejs`, `qemu-system-x86` and `edk2-ovmf` are deliberately installed by a
**separate task at `state: present`**. They're Nobara's packages, and
`state: latest` on them would force upgrades on Ansible's schedule rather than
`nobara-sync`'s — the one thing this repo's conventions rule out. Keeping them
in the same task as the app would have made that impossible to express.
