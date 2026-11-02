#!/usr/bin/env bash
# Stage the original Mailman 2 data without deleting or importing anything.
set -Eeuo pipefail
remote="${REMOTE:?Set REMOTE=user@original-host-or-IP}"
[[ "$remote" =~ ^[a-zA-Z0-9_.-]+@[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ && "$remote" != -* ]] || {
    printf 'Invalid SSH source.\n' >&2; exit 64;
}
[[ "$EUID" -eq 0 ]] || { printf 'Run as root.\n' >&2; exit 1; }
destination="${MAILMAN_STAGE:-/root/postfixer-migration/mailman2}"
install -d -m 0700 "$destination"
# Include config.pck, mbox, HTML, membership and private archives together.
# Do not use --delete, dereference symlinks, or publish this private staging tree.
rsync -a --numeric-ids -- "$remote:/var/lib/mailman/" "$destination/"
printf 'Staged Mailman 2 data at %s. No lists imported and no archive published.\n' "$destination"
