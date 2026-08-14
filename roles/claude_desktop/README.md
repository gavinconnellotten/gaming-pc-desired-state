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

## Variables

See `defaults/main.yml` — repo URL, package name, and the extra dependency
list are all overridable if upstream naming changes.
