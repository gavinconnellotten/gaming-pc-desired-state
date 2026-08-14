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
