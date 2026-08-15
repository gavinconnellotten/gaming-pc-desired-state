#!/usr/bin/env bash
#
# validate-fstab.sh — validation hook for the smb_mounts fstab block.
#
# Called by blockinfile's `validate:` with the path to a CANDIDATE fstab (a
# temporary file), before Ansible moves it into place. Exit 0 to accept.
#
# Why this exists rather than `validate: findmnt --verify --tab-file %s`:
#
# findmnt --verify checks the WHOLE file and exits non-zero for problems that
# have nothing to do with us. gaming-pc's fstab lists /boot/efi before /boot,
# which findmnt reports as an error, so a plain --verify would permanently
# refuse to write our block over a pre-existing, unrelated wart in a
# boot-critical file we've deliberately chosen not to rewrite.
#
# So: reject PARSE errors, which are the class that actually breaks boot and
# the only class our own block can introduce. Report everything else and
# accept. The role separately reports overall fstab health so pre-existing
# problems stay visible rather than being silently tolerated.

set -uo pipefail

candidate="${1:?usage: validate-fstab.sh <fstab-file>}"

if [ ! -r "$candidate" ]; then
    printf 'validate-fstab: cannot read %s\n' "$candidate" >&2
    exit 1
fi

# findmnt exits non-zero for any error class, so capture output and decide
# ourselves rather than trusting the exit code.
output="$(findmnt --verify --tab-file "$candidate" 2>&1)"

# A line-level complaint. findmnt reports these as it goes and then bails
# without printing a summary, so check for it before looking for the summary.
if printf '%s\n' "$output" | grep -q 'parse error at line'; then
    printf 'validate-fstab: malformed line in the candidate fstab.\n' >&2
    printf 'The block was NOT written. findmnt said:\n%s\n' "$output" >&2
    exit 1
fi

# The summary line looks like: "0 parse errors, 1 error, 5 warnings"
parse_errors="$(printf '%s\n' "$output" |
    sed -n 's/^\([0-9]\+\) parse errors\?,.*/\1/p' | tail -1)"

# No summary line and no line-level complaint means findmnt behaved in a way
# this script wasn't written for. Refuse rather than guess about fstab.
if [ -z "$parse_errors" ]; then
    printf 'validate-fstab: could not interpret findmnt output, refusing:\n%s\n' \
        "$output" >&2
    exit 1
fi

if [ "$parse_errors" -ne 0 ]; then
    printf 'validate-fstab: %s parse error(s) in the candidate fstab.\n' \
        "$parse_errors" >&2
    printf 'The block was NOT written. findmnt said:\n%s\n' "$output" >&2
    exit 1
fi

exit 0
