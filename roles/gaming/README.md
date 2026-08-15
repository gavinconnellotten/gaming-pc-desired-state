# gaming

Reinstates the gaming setup that was added **by hand after the Nobara install**
— the part a rebuild from the ISO would silently lose.

## What this role deliberately does not do

It doesn't install Steam, Lutris, Heroic, gamescope, gamemode, MangoHud,
GOverlay or OBS. All of those ship with the Nobara image and Nobara updates
them on its own cycle. Managing them here would fight `nobara-sync` and produce
exactly the drift this repo exists to prevent.

The rule this follows: **manage the delta, not the distribution.**
`state/57-post-iso-additions.txt` is the machine's own record of that delta,
derived from dnf's transaction history rather than from anyone's memory.

## Why Steam was broken, as best the record shows

Steam crashed for a while after the initial install. The fix wasn't written
down at the time, but dnf history preserved it. On 2026-08-08:

```
dnf install -y rocm-meta nobara-resolve-runtime zlib libxcrypt-compat \
               python3.11 python3.11-libs alsa-plugins-pulseaudio
```

`libxcrypt-compat` is almost certainly the one that mattered. It provides
`libcrypt.so.1`, which Fedora dropped and Steam still links against — the
classic "installs fine, won't launch" failure on this distro family.

This is reconstructed from evidence, not remembered, so treat it as the most
likely explanation rather than a certainty. Two other changes in the same
window could also have contributed: Proton-GE arriving on 2026-08-10, and the
NVIDIA 595.91.07 upgrade with its i686 libraries on 2026-08-12.

Two packages from that command line are **not** installed by this role:

- **`rocm-meta`** — AMD's compute stack, on a machine with an NVIDIA GPU. It
  came along because the command was run wholesale.
- **`zlib` and `nobara-resolve-runtime`** — both ship with the image, so
  installing them was a no-op.

## Codecs

`gaming_codec_packages` reproduces the 2026-08-10 codec install verbatim,
**including the explicit `.i686` architectures**. Those aren't padding: 32-bit
games and older Proton builds need the 32-bit halves, and installing only the
`x86_64` side gives you video that silently fails to decode in-game rather than
an error you can act on.

Set `gaming_manage_codecs: false` to skip them.

## Proton-GE

Pinned to a specific version, not "latest". A Proton upgrade is exactly the
kind of change that fixes one game and breaks another, so bumping
`gaming_proton_ge_version` should be a deliberate commit rather than something
that happens because the playbook ran on a Tuesday.

The tarball's checksum is fetched from the release's own `.sha512sum` file
rather than pasted in here — pinning a version shouldn't also mean pinning a
hash by hand that nobody will re-verify.

ProtonPlus (preinstalled on Nobara) does the same job interactively. This role
exists so a rebuilt machine gets the same build without anyone having to
remember which one it was.

### The gotcha: this must not run as root

Steam reads compatibility tools from `~/.steam/root/compatibilitytools.d`, so
every Proton task runs with `become: false`. Under `sudo` the build unpacks
into `/root`, where Steam will never look — and the playbook would report
success. The role **refuses to run** rather than warning, because a Proton
build in the wrong home is invisible rather than obviously broken.

This is the same class of bug as `claude_desktop`'s `--doctor` gotcha, and it's
worth recognising the pattern: anything living under `$HOME` cannot be managed
by a play running as root.

Facts are gathered with the play's `become` already in effect, so
`ansible_env.HOME` can be root's by the time a task reads it. The role resolves
the home directory with `getent` instead.

## What still isn't captured

- **Which Proton version each game is set to use.** That lives in Steam's
  config, per game, and isn't managed here.
- **Installed games and the Steam library itself.** Out of scope — that's
  hundreds of gigabytes Steam can re-download.
- **Proton builds installed by hand.** The role reports them and flags them as
  unmanaged. `Proton-GE Latest` on this machine is one such: it came from
  ProtonPlus and a rebuild won't restore it. Either pin it here or accept
  losing it.
