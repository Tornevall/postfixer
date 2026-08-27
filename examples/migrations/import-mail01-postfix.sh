#!/usr/bin/env bash
# Example migration runner for importing a legacy Postfix /etc/postfix tree.
#
# Defaults are real for the Tornevall mail01 migration, but the script is kept
# as an example so other installations can copy it and override the variables.

set -Eeuo pipefail

REMOTE="${REMOTE:-root@mail01.tornevall.net}"
REMOTE_POSTFIX_DIR="${REMOTE_POSTFIX_DIR:-/etc/postfix}"
STAGING_ROOT="${STAGING_ROOT:-/root/postfixer-migration}"
MIGRATION_NAME="${MIGRATION_NAME:-mail01-postfix}"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
STAGING_DIR="${STAGING_DIR:-${STAGING_ROOT}/${MIGRATION_NAME}}"
FETCHED_DIR="${FETCHED_DIR:-${STAGING_DIR}/fetched/etc-postfix}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${STAGING_DIR}/snapshots}"
REPORT_FILE="${REPORT_FILE:-${STAGING_DIR}/README.migration}"
OVERLAY_DIR="${OVERLAY_DIR:-${REPO_ROOT}/etc-postfix}"

usage() {
    cat <<'EOF_USAGE'
Usage:
  examples/migrations/import-mail01-postfix.sh --fetch
  examples/migrations/import-mail01-postfix.sh --fetch-maildir-users
  examples/migrations/import-mail01-postfix.sh --diff-local
  examples/migrations/import-mail01-postfix.sh --import-overlay
  examples/migrations/import-mail01-postfix.sh --apply-local

Actions:
  --fetch           Rsync REMOTE:/etc/postfix into a staging directory outside Git.
  --fetch-maildir-users
                    Find remote /home/*/Maildir mailboxes with messages and export
                    only matching passwd/shadow entries into staging, mode 0600.
  --diff-local      Diff fetched files against local /etc/postfix.
  --import-overlay  Copy fetched Postfix files into this repo's etc-postfix overlay.
  --apply-local     Backup local /etc/postfix, then rsync fetched files into /etc/postfix.

Defaults:
  REMOTE=root@mail01.tornevall.net
  REMOTE_POSTFIX_DIR=/etc/postfix
  STAGING_DIR=/root/postfixer-migration/mail01-postfix
  OVERLAY_DIR=<repo>/etc-postfix

Examples:
  REMOTE=root@old-mail.example.com ./examples/migrations/import-mail01-postfix.sh --fetch
  ./examples/migrations/import-mail01-postfix.sh --diff-local
  ./examples/migrations/import-mail01-postfix.sh --import-overlay

Notes:
  This script intentionally does not guess node identity. Values such as
  myhostname, relayhost, mynetworks and certificate paths should be migrated
  into /etc/postfixer instead of blindly kept in a shared main.cf.

  Shadow exports are sensitive and are intentionally written outside Git.
EOF_USAGE
}

log() {
    printf '\n=== %s ===\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_fetched_tree() {
    [[ -d "$FETCHED_DIR" ]] || die "Missing fetched tree: ${FETCHED_DIR}. Run --fetch first."
}

write_report() {
    mkdir -p "$STAGING_DIR"
    cat > "$REPORT_FILE" <<EOF_REPORT
Postfixer migration staging

Remote source:
  ${REMOTE}:${REMOTE_POSTFIX_DIR}

Fetched tree:
  ${FETCHED_DIR}

Repository overlay:
  ${OVERLAY_DIR}

Review before applying:
  - main.cf may contain old node identity and should not be copied blindly.
  - master.cf may contain site-specific services such as extra SMTP ports.
  - mynetworks should point to /etc/postfixer/networks on new installations.
  - TLS paths should resolve through /etc/letsencrypt on the target node.
  - DKIM keys belong under /etc/opendkim and private keys should not be committed.

Suggested review commands:
  diff -ruN /etc/postfix ${FETCHED_DIR}
  postconf -c ${FETCHED_DIR} -n
EOF_REPORT
}

fetch_remote_postfix() {
    log "Fetching ${REMOTE}:${REMOTE_POSTFIX_DIR}"
    mkdir -p "$FETCHED_DIR"
    rsync -a --delete \
        --exclude '*.db' \
        --exclude '*.lmdb' \
        --exclude '*.lock' \
        --exclude 'prng_exch' \
        "${REMOTE}:${REMOTE_POSTFIX_DIR}/" \
        "${FETCHED_DIR}/"
    write_report
    log "Fetched Postfix tree to ${FETCHED_DIR}"
}

fetch_maildir_users() {
    local users_file="${STAGING_DIR}/maildir-users.txt"
    local passwd_file="${STAGING_DIR}/passwd.maildir-users"
    local shadow_file="${STAGING_DIR}/shadow.maildir-users"
    local report_file="${STAGING_DIR}/maildir-users.report"

    log "Discovering active Maildir users on ${REMOTE}"
    mkdir -p "$STAGING_DIR"

    ssh "$REMOTE" 'set -e
        find /home -mindepth 2 -maxdepth 3 \
            \( -path "*/Maildir/new/*" -o -path "*/Maildir/cur/*" \) \
            -type f -printf "%h\n" 2>/dev/null |
        sed -E "s#/Maildir/(new|cur)$##" |
        awk -F/ "$2 == \"home\" && NF == 3 {print \$3}" |
        sort -u
    ' > "$users_file"

    if [[ ! -s "$users_file" ]]; then
        die "No active Maildir users were found on ${REMOTE}."
    fi

    ssh "$REMOTE" 'set -e
        tmp="$(mktemp)"
        cat > "$tmp"
        while IFS= read -r user; do
            getent passwd "$user" || true
        done < "$tmp"
        rm -f "$tmp"
    ' < "$users_file" > "$passwd_file"

    ssh "$REMOTE" 'set -e
        tmp="$(mktemp)"
        cat > "$tmp"
        while IFS= read -r user; do
            getent shadow "$user" || true
        done < "$tmp"
        rm -f "$tmp"
    ' < "$users_file" > "$shadow_file"

    chmod 0600 "$users_file" "$passwd_file" "$shadow_file"

    {
        printf 'Maildir user export from %s\n\n' "$REMOTE"
        printf 'Users with messages under /home/*/Maildir/{cur,new}: %s\n' "$(wc -l < "$users_file")"
        printf 'passwd entries exported: %s\n' "$(wc -l < "$passwd_file")"
        printf 'shadow entries exported: %s\n' "$(wc -l < "$shadow_file")"
        printf '\nFiles:\n'
        printf '  %s\n' "$users_file" "$passwd_file" "$shadow_file"
        printf '\nThese files contain account and password-hash material. Keep them outside Git.\n'
    } > "$report_file"
    chmod 0600 "$report_file"

    log "Exported Maildir users to ${STAGING_DIR}"
}

diff_local_postfix() {
    require_fetched_tree
    [[ -d /etc/postfix ]] || die "Local /etc/postfix does not exist."
    diff -ruN /etc/postfix "$FETCHED_DIR" || true
}

import_overlay() {
    require_fetched_tree
    [[ -d "$OVERLAY_DIR" ]] || die "Overlay directory does not exist: ${OVERLAY_DIR}"

    log "Importing fetched tree into repo overlay ${OVERLAY_DIR}"
    rsync -a --delete \
        --exclude 'README.md' \
        --exclude '*.db' \
        --exclude '*.lmdb' \
        --exclude '*.lock' \
        --exclude 'prng_exch' \
        "${FETCHED_DIR}/" \
        "${OVERLAY_DIR}/"

    cat > "${OVERLAY_DIR}/MIGRATION-NOTES.mail01.md" <<EOF_NOTES
# mail01 Postfix Import Notes

Imported from:

\`\`\`text
${REMOTE}:${REMOTE_POSTFIX_DIR}
\`\`\`

This overlay is a migration snapshot. Before treating it as shared
configuration, review and move node-specific settings into:

- \`/etc/postfixer/postfixer.conf\`
- \`/etc/postfixer/networks\`
- \`/etc/postfixer/local-domains\`
- \`/etc/postfixer/relay-domains\`
- \`/etc/postfixer/relay-recipients\`
- \`/etc/postfixer/transport\`

Do not commit private DKIM keys or host-only certificate material.
EOF_NOTES
}

apply_local() {
    require_fetched_tree
    local backup_dir="${SNAPSHOT_DIR}/etc-postfix.$(date +%Y%m%d-%H%M%S)"

    [[ -d /etc/postfix ]] || die "Local /etc/postfix does not exist."
    mkdir -p "$backup_dir"

    log "Backing up local /etc/postfix to ${backup_dir}"
    rsync -a /etc/postfix/ "${backup_dir}/"

    log "Applying fetched tree to local /etc/postfix"
    rsync -a --delete \
        --exclude '*.db' \
        --exclude '*.lmdb' \
        --exclude '*.lock' \
        --exclude 'prng_exch' \
        "${FETCHED_DIR}/" \
        /etc/postfix/

    log "Local Postfix tree replaced. Run postfix check before reload."
}

main() {
    case "${1:-}" in
        --fetch)
            fetch_remote_postfix
            ;;
        --fetch-maildir-users)
            fetch_maildir_users
            ;;
        --diff-local)
            diff_local_postfix
            ;;
        --import-overlay)
            import_overlay
            ;;
        --apply-local)
            apply_local
            ;;
        -h|--help|"")
            usage
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
}

main "$@"
