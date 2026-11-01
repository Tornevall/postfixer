#!/usr/bin/env bash
# Destructive reset helper for returning a test node to a clean mail-stack state.

set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/postfixer-reset-backup-${TIMESTAMP}}"
CONFIRM_VALUE="purge-mail-stack"

log() {
    printf '\n=== %s ===\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this command as root."
}

require_confirmation() {
    if [[ "${POSTFIXER_RESET_CONFIRM:-}" != "$CONFIRM_VALUE" ]]; then
        cat >&2 <<EOF_CONFIRM
ERROR: Refusing destructive reset.

This removes Postfixer-managed mail packages and local mail configuration.
Backups are created first, but the operation is intentionally explicit.
It does not remove this Git checkout, for example /root/postfixer.

Run with:
  POSTFIXER_RESET_CONFIRM=${CONFIRM_VALUE} sudo bin/reset.sh
EOF_CONFIRM
        exit 64
    fi
}

backup_path() {
    local path="$1"

    [[ -e "$path" || -L "$path" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a --parents "$path" "$BACKUP_DIR"
}

backup_mail_state() {
    log "Backing up existing mail state to ${BACKUP_DIR}"

    for path in \
        /etc/postfix \
        /etc/postfixer \
        /etc/mailname \
        /etc/courier \
        /etc/default/saslauthd \
        /etc/default/opendkim \
        /etc/default/opendmarc \
        /etc/pam.d/smtp \
        /etc/pam.d/imap \
        /etc/pam.d/pop3 \
        /etc/opendkim.conf \
        /etc/opendmarc.conf \
        /etc/opendkim \
        /var/spool/postfix \
        /var/lib/postfix \
        /var/lib/postgrey \
        /var/lib/clamav \
        /usr/local/src/postfixer-courier \
        /usr/local/src/postfixer-courier-jammy \
        /usr/local/lib/postfixer; do
        backup_path "$path"
    done

    if [[ -d "$BACKUP_DIR" ]]; then
        chmod 0700 "$BACKUP_DIR"
        log "Backup completed: ${BACKUP_DIR}"
    else
        log "No existing mail state found to back up"
    fi
}

stop_mail_services() {
    local service
    local services=(
        postfix saslauthd postgrey opendkim opendmarc clamav-daemon clamav-freshclam
        spamassassin spamd courier-authdaemon courier-imap courier-imap-ssl
        courier-pop courier-pop-ssl mailgraph
    )

    log "Stopping mail services"
    for service in "${services[@]}"; do
        systemctl disable --now "${service}.service" >/dev/null 2>&1 || true
    done
}

purge_mail_packages() {
    local packages=(
        postfix postfix-pcre postfix-policyd-spf-python postgrey
        sasl2-bin libsasl2-modules
        spamassassin spamc
        clamav clamav-daemon clamav-freshclam clamdscan
        fetchmail procmail
        opendkim opendkim-tools opendmarc
        courier-base courier-imap courier-pop
        courier-authdaemon courier-authlib courier-authlib-pipe courier-authlib-userdb
        gamin libgamin0
        mailgraph rrdtool swaks
    )

    log "Purging mail packages"
    apt-get purge -y "${packages[@]}" || true
    apt-get autoremove -y --purge
}

remove_mail_state() {
    log "Removing mail configuration and runtime state"

    rm -rf \
        /etc/postfix \
        /etc/postfixer \
        /etc/mailname \
        /etc/courier \
        /etc/default/saslauthd \
        /etc/default/opendkim \
        /etc/default/opendmarc \
        /etc/pam.d/smtp \
        /etc/pam.d/imap \
        /etc/pam.d/pop3 \
        /etc/opendkim.conf \
        /etc/opendmarc.conf \
        /etc/opendkim \
        /var/spool/postfix \
        /var/lib/postfix \
        /var/lib/postgrey \
        /usr/local/src/postfixer-courier \
        /usr/local/src/postfixer-courier-jammy \
        /usr/local/lib/postfixer
}

main() {
    require_root
    require_confirmation
    backup_mail_state
    stop_mail_services
    purge_mail_packages
    remove_mail_state

    cat <<EOF_DONE

Postfixer reset completed.

Backup: ${BACKUP_DIR}

The node is ready for a clean Postfixer install. Externally managed data such as
/etc/letsencrypt and /home was not removed. This Git checkout was not removed.
EOF_DONE
}

main "$@"
