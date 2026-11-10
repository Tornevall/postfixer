#!/usr/bin/env bash
# Postfixer backup utility. Run as root on the mail server.

set -Eeuo pipefail
umask 077

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/postfixer}"
STAMP="${BACKUP_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
HOST="$(hostname -s)"

usage() {
    cat <<'EOF'
Usage:
  bin/backup.sh config
  bin/backup.sh maildirs
  bin/backup.sh all

Environment:
  BACKUP_ROOT   Destination directory (default: /var/backups/postfixer)
  BACKUP_STAMP  Override timestamp, useful for tests

The archives contain sensitive data. Store BACKUP_ROOT on protected storage.
Maildir backups include only /home accounts that actually have a Maildir.
EOF
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
        printf 'ERROR: run this backup as root.\n' >&2
        exit 1
    }
}

archive_config() {
    local out="${BACKUP_ROOT}/${HOST}-${STAMP}-config.tar.gz"
    local list

    install -d -m 0700 "$BACKUP_ROOT"
    list="$(mktemp)"
    trap 'rm -f "$list"' RETURN

    for path in \
        /etc/postfix \
        /etc/postfixer \
        /etc/courier \
        /etc/courier-imap \
        /etc/opendkim \
        /etc/postgrey \
        /etc/spamassassin \
        /etc/default/postgrey \
        /etc/default/saslauthd \
        /etc/pam.d/smtp \
        /etc/aliases \
        /etc/mailname \
        /etc/passwd \
        /etc/group \
        /etc/shadow \
        /etc/gshadow \
        /etc/subuid \
        /etc/subgid \
        /etc/letsencrypt; do
        [[ -e "$path" || -L "$path" ]] && printf '%s\n' "${path#/}" >> "$list"
    done

    tar -C / --create --gzip --file="$out" --numeric-owner --acls --xattrs \
        --ignore-failed-read --files-from="$list"
    chmod 0600 "$out"
    printf 'Created %s\n' "$out"
}

archive_maildirs() {
    local out="${BACKUP_ROOT}/${HOST}-${STAMP}-maildirs.tar.gz"
    local list

    install -d -m 0700 "$BACKUP_ROOT"
    list="$(mktemp)"
    trap 'rm -f "$list"' RETURN

    find /home -mindepth 2 -maxdepth 2 -type d -name Maildir \
        -printf '%h\n' 2>/dev/null | sed 's#^/##' | sort -u > "$list"

    if [[ ! -s "$list" ]]; then
        printf 'No /home/*/Maildir accounts found; no archive created.\n'
        return 0
    fi

    tar -C / --create --gzip --file="$out" --numeric-owner --acls --xattrs \
        --files-from="$list"
    chmod 0600 "$out"
    printf 'Created %s\n' "$out"
    printf 'Accounts:\n'
    sed 's#/Maildir$##' "$list"
}

main() {
    require_root
    case "${1:-}" in
        config) archive_config ;;
        maildirs) archive_maildirs ;;
        all) archive_config; archive_maildirs ;;
        -h|--help) usage ;;
        *) usage >&2; exit 64 ;;
    esac
}

main "$@"
