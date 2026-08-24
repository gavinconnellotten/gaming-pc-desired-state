# system_tuning

System-level settings that don't belong to any one application. Currently just
core dump limits; a home for future sysctl or kernel tweaks rather than
scattering them into unrelated roles.

## Core dump storage

`systemd-coredump`'s defaults are **proportional to disk size**, which is the
wrong shape for a 912 GB volume:

| Setting | Default | Effective here |
|---|---|---|
| `MaxUse` | 10% of filesystem | **~91 GB** before pruning |
| `KeepFree` | 15% free | won't prune until ~137 GB free |

A `tmpfiles` rule ages the directory at two weeks
(`d /var/lib/systemd/coredump 0755 root root 2w`), which is far too slow to
matter when dumps arrive faster than that.

That became a problem because **Black Mesa segfaults during shutdown on every
single exit**. It's a long-standing Source-engine-on-Linux bug: the crash
happens in GL teardown *after* the game has quit, so nothing is lost and it is
not fixable from outside the game. But each one writes a **300–500 MB** core,
and seven had reached 2.8 GB with no ceiling in sight.

This role caps `MaxUse` at 1 GB and `KeepFree` at 20 GB via a drop-in under
`/etc/systemd/coredump.conf.d/`, rather than editing `coredump.conf` directly,
so a systemd package update doesn't conflict.

### It does not delete anything

`systemd-coredump` enforces `MaxUse` **when it writes the next dump**, so usage
can legitimately sit above the cap until the next crash. The role reports
current usage against the cap rather than pruning, because deleting crash
evidence unattended is the sort of thing this repo prefers to report. To clear
it by hand:

```bash
sudo find /var/lib/systemd/coredump -name 'core.*' -mtime +1 -delete
```

Note `coredumpctl` has **no** vacuum or delete option — it only lists and
inspects. Cleanup is file deletion or waiting for the cap to apply.

### Optionally skip large dumps entirely

`system_tuning_coredump_process_size_max` is unset by default. Setting it to
e.g. `100M` excludes every game crash while still capturing small ones — the
two `findmnt` segfaults on 2026-08-15 were 56 KB each and are the kind actually
worth keeping. Left off because a large core might be one you genuinely want to
debug, and the `MaxUse` cap already bounds the damage.

## Verifying by hand

```bash
coredumpctl list --no-pager          # what has crashed
du -sh /var/lib/systemd/coredump     # how much it is using
systemd-analyze cat-config systemd/coredump.conf   # effective config
```
