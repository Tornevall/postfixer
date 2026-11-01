#!/usr/bin/env bash
# Generic migration runner for importing a legacy Postfix server.
#
# The importer is generic. The source host must be supplied explicitly.

set -Eeuo pipefail
umask 077

REMOTE="${REMOTE:-}"
REMOTE_POSTFIX_DIR="${REMOTE_POSTFIX_DIR:-/etc/postfix}"
REMOTE_HOME_ROOT="${REMOTE_HOME_ROOT:-/home}"
TARGET_HOME_ROOT="${TARGET_HOME_ROOT:-/home}"
STAGING_ROOT="${STAGING_ROOT:-/root/postfixer-migration}"
MIGRATION_NAME="${MIGRATION_NAME:-postfix-import}"
STAGING_DIR="${STAGING_DIR:-${STAGING_ROOT}/${MIGRATION_NAME}}"
FETCHED_DIR="${FETCHED_DIR:-${STAGING_DIR}/fetched/etc-postfix}"
REPORT_FILE="${REPORT_FILE:-${STAGING_DIR}/README.migration}"
MAILDIR_STAGING_DIR="${MAILDIR_STAGING_DIR:-${STAGING_DIR}/maildirs}"
FINAL_SYNC_CONFIRM="${FINAL_SYNC_CONFIRM:-}"
POSTFIXER_IMPORT_ROOT="${POSTFIXER_IMPORT_ROOT:-/etc/postfix/postfixer.d/imports}"
IMPORT_TARGET="${IMPORT_TARGET:-${POSTFIXER_IMPORT_ROOT}/${MIGRATION_NAME}}"
SSH_BATCH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10)
RSYNC_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10'

usage() {
    cat <<'EOF_USAGE'
Usage:
  examples/migrations/import-postfix-server.sh --fetch
  examples/migrations/import-postfix-server.sh --fetch-maildir-users
  examples/migrations/import-postfix-server.sh --fetch-maildirs
  examples/migrations/import-postfix-server.sh --fetch-maildirs-final
  examples/migrations/import-postfix-server.sh --diff-local
  examples/migrations/import-postfix-server.sh --install-modular

Actions:
  --fetch           Rsync REMOTE:/etc/postfix into a staging directory outside Git.
  --fetch-maildir-users
                    Find every remote REMOTE_HOME_ROOT/*/Maildir and export only
                    matching passwd/shadow entries into staging, mode 0600.
  --fetch-maildirs   Pre-sync Maildirs into root-only staging without deleting files.
  --fetch-maildirs-final
                    Make staging and target Maildirs exactly match the frozen source,
                    including deletions. Requires FINAL_SYNC_CONFIRM=source-frozen.
  --diff-local      Diff fetched files against local /etc/postfix.
  --install-modular Install non-secret map files below /etc/postfix/postfixer.d/imports.

Defaults:
  REMOTE must be supplied as user@host for remote actions.
  Remote actions require passwordless SSH through a key or SSH agent.
  OpenSSH configuration selects identities, jump hosts and other connection options.
  REMOTE_POSTFIX_DIR=/etc/postfix
  REMOTE_HOME_ROOT=/home
  TARGET_HOME_ROOT=/home
  STAGING_DIR=/root/postfixer-migration/postfix-import
  IMPORT_TARGET=/etc/postfix/postfixer.d/imports/postfix-import

Examples:
  REMOTE=root@old-mail.example.com ./examples/migrations/import-postfix-server.sh --fetch
  REMOTE=root@old-mail.example.com ./examples/migrations/import-postfix-server.sh --fetch-maildir-users
  REMOTE=root@old-mail.example.com ./examples/migrations/import-postfix-server.sh --fetch-maildirs
  FINAL_SYNC_CONFIRM=source-frozen REMOTE=root@old-mail.example.com \
    ./examples/migrations/import-postfix-server.sh --fetch-maildirs-final
  ./examples/migrations/import-postfix-server.sh --diff-local
  sudo ./examples/migrations/import-postfix-server.sh --install-modular

Notes:
  Remote commands use SSH BatchMode and never prompt for a password. Verify the
  connection as the same local account that runs this script before importing.

  This script intentionally does not guess node identity. Values such as
  myhostname, relayhost, mynetworks and certificate paths should be migrated
  into /etc/postfix/postfixer.d instead of blindly kept in a shared main.cf.

  Shadow exports are sensitive and are intentionally written outside Git.
EOF_USAGE
}

log() {
    printf '\n=== %s ===\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_fetched_tree() {
    [[ -d "$FETCHED_DIR" ]] || die "Missing fetched tree: ${FETCHED_DIR}. Run --fetch first."
}

require_remote() {
    [[ -n "$REMOTE" ]] || die "Set REMOTE=user@host for this action."
    [[ "$REMOTE_HOME_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die \
        "REMOTE_HOME_ROOT must be an absolute path without spaces or shell characters."
    [[ "$REMOTE_HOME_ROOT" != *'/../'* && "$REMOTE_HOME_ROOT" != */.. && "$REMOTE_HOME_ROOT" != *'/./'* ]] || die \
        "REMOTE_HOME_ROOT must not contain dot path segments."
    [[ "$TARGET_HOME_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die \
        "TARGET_HOME_ROOT must be an absolute path without spaces or shell characters."
    [[ "$TARGET_HOME_ROOT" != *'/../'* && "$TARGET_HOME_ROOT" != */.. && "$TARGET_HOME_ROOT" != *'/./'* ]] || die \
        "TARGET_HOME_ROOT must not contain dot path segments."
    ssh "${SSH_BATCH_OPTIONS[@]}" "$REMOTE" true || die \
        "Passwordless SSH failed for ${REMOTE}. Configure an SSH key or agent and verify it with: ssh -o BatchMode=yes ${REMOTE} true"
}

write_report() {
    mkdir -p "$STAGING_DIR"
    cat > "$REPORT_FILE" <<EOF_REPORT
Postfixer migration staging

Remote source:
  ${REMOTE}:${REMOTE_POSTFIX_DIR}

Fetched tree:
  ${FETCHED_DIR}

Modular import target:
  ${IMPORT_TARGET}

Review before applying:
  - main.cf may contain old node identity and should not be copied blindly.
  - master.cf may contain site-specific services such as extra SMTP ports.
  - mynetworks should point to /etc/postfix/postfixer.d/networks on new installations.
  - TLS paths should resolve through /etc/letsencrypt on the target node.
  - DKIM keys belong under /etc/opendkim and private keys should not be committed.

Suggested review commands:
  diff -ruN /etc/postfix ${FETCHED_DIR}
  postconf -c ${FETCHED_DIR} -n
EOF_REPORT
}

fetch_remote_postfix() {
    require_remote
    log "Fetching ${REMOTE}:${REMOTE_POSTFIX_DIR}"
    mkdir -p "$FETCHED_DIR"
    chmod 0700 "$STAGING_DIR" "${STAGING_DIR}/fetched" "$FETCHED_DIR"
    rsync -a --delete -e "$RSYNC_SSH_COMMAND" \
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
    local paths_file="${STAGING_DIR}/maildir-paths.tsv"
    local passwd_file="${STAGING_DIR}/passwd.maildir-users"
    local shadow_file="${STAGING_DIR}/shadow.maildir-users"
    local group_file="${STAGING_DIR}/group.maildir-users"
    local report_file="${STAGING_DIR}/maildir-users.report"

    require_remote
    log "Discovering passwd-backed Maildir users on ${REMOTE}"
    mkdir -p "$STAGING_DIR"

    ssh "${SSH_BATCH_OPTIONS[@]}" "$REMOTE" "set -e
        homes_file=\$(mktemp)
        trap 'rm -f \"\$homes_file\"' EXIT
        find ${REMOTE_HOME_ROOT} -mindepth 2 -maxdepth 2 \
            -type d -name Maildir -printf '%h\\n' 2>/dev/null |
        sort -u > \"\$homes_file\"
        getent passwd |
        awk -F: 'NR == FNR {homes[\$0] = 1; next} (\$6 in homes) {printf \"%s\\t%s/Maildir\\n\", \$1, \$6}' \
            \"\$homes_file\" - |
        sort -u
    " > "$paths_file"

    cut -f1 "$paths_file" > "$users_file"

    if [[ ! -s "$users_file" ]]; then
        die "No passwd-backed Maildir users were found below ${REMOTE}:${REMOTE_HOME_ROOT}."
    fi

    ssh "${SSH_BATCH_OPTIONS[@]}" "$REMOTE" 'set -e
        tmp="$(mktemp)"
        cat > "$tmp"
        while IFS= read -r user; do
            getent passwd "$user" || true
        done < "$tmp"
        rm -f "$tmp"
    ' < "$users_file" > "$passwd_file"

    ssh "${SSH_BATCH_OPTIONS[@]}" "$REMOTE" 'set -e
        tmp="$(mktemp)"
        cat > "$tmp"
        while IFS= read -r user; do
            getent shadow "$user" || true
        done < "$tmp"
        rm -f "$tmp"
    ' < "$users_file" > "$shadow_file"

    cut -d: -f4 "$passwd_file" | sort -nu |
        ssh "${SSH_BATCH_OPTIONS[@]}" "$REMOTE" 'set -e
            while IFS= read -r gid; do
                getent group "$gid" || true
            done
        ' > "$group_file"

    chmod 0600 "$users_file" "$paths_file" "$passwd_file" "$shadow_file" "$group_file"

    {
        printf 'Maildir user export from %s\n\n' "$REMOTE"
        printf 'Passwd-backed users with %s/*/Maildir: %s\n' "$REMOTE_HOME_ROOT" "$(wc -l < "$users_file")"
        printf 'passwd entries exported: %s\n' "$(wc -l < "$passwd_file")"
        printf 'shadow entries exported: %s\n' "$(wc -l < "$shadow_file")"
        printf 'primary group entries exported: %s\n' "$(wc -l < "$group_file")"
        printf '\nFiles:\n'
        printf '  %s\n' "$users_file" "$paths_file" "$passwd_file" "$shadow_file" "$group_file"
        printf '\nThese files contain account and password-hash material. Keep them outside Git.\n'
    } > "$report_file"
    chmod 0600 "$report_file"

    log "Exported Maildir users to ${STAGING_DIR}"
}

fetch_maildirs() {
    local delete_mode="${1:-no}"
    local paths_file="${STAGING_DIR}/maildir-paths.tsv"
    local user remote_maildir target target_maildir target_home target_uid target_gid
    local rsync_delete=()

    if [[ "$delete_mode" == yes ]]; then
        [[ "$FINAL_SYNC_CONFIRM" == source-frozen ]] || die \
            "Final Maildir sync refused. Stop mail services on the source, verify they are inactive, then set FINAL_SYNC_CONFIRM=source-frozen."
        rsync_delete=(--delete)
        log "Final exact Maildir sync confirmed for frozen source ${REMOTE}"
    fi

    require_remote
    [[ -s "$paths_file" ]] || die "Missing ${paths_file}. Run --fetch-maildir-users first."
    install -d -m 0700 "$MAILDIR_STAGING_DIR"

    while IFS=$'\t' read -r user remote_maildir; do
        [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Unsafe user name in ${paths_file}: ${user}"
        [[ "$remote_maildir" =~ ^/[A-Za-z0-9._/-]+/Maildir$ ]] || die \
            "Unsafe Maildir path in ${paths_file}: ${remote_maildir}"
        [[ "$remote_maildir" == "${REMOTE_HOME_ROOT%/}/"*"/Maildir" ]] || die \
            "Maildir path is outside REMOTE_HOME_ROOT in ${paths_file}: ${remote_maildir}"
        target="${MAILDIR_STAGING_DIR}/${user}/Maildir"
        install -d -m 0700 "$target"
        log "Fetching ${remote_maildir} for ${user} from ${REMOTE}"
        rsync -aHAX --numeric-ids --partial --info=progress2,stats2 "${rsync_delete[@]}" \
            -e "$RSYNC_SSH_COMMAND" \
            "${REMOTE}:${remote_maildir}/" \
            "${target}/"

        if [[ "$delete_mode" == yes ]]; then
            target_home="$(getent passwd "$user" | cut -d: -f6)"
            [[ "$target_home" == "${TARGET_HOME_ROOT%/}/"* ]] || die \
                "Target home for ${user} is outside TARGET_HOME_ROOT: ${target_home}"
            target_uid="$(getent passwd "$user" | cut -d: -f3)"
            target_gid="$(getent passwd "$user" | cut -d: -f4)"
            target_maildir="${target_home%/}/Maildir"
            install -d -m 0700 "$target_maildir"
            rsync -aHAX --numeric-ids --delete --partial --info=stats2 \
                "${target}/" "${target_maildir}/"
            chown "$target_uid:$target_gid" "$target_maildir"
        fi
    done < "$paths_file"

    log "Maildir staging completed below ${MAILDIR_STAGING_DIR}"
}

diff_local_postfix() {
    require_fetched_tree
    [[ -d /etc/postfix ]] || die "Local /etc/postfix does not exist."
    diff -ruN /etc/postfix "$FETCHED_DIR" || true
}

install_modular() {
    local file
    local manifest="${IMPORT_TARGET}/README.import"
    local files=(
        access-inbound aliases bounce.cf domains-extra-virtual domains.txt
        filtered_domains header_checks header_checks.txt recipient_bcc_maps
        relay relay_recipient_maps relaydomains sender_canonical sender_relaymap
        sms-nums.conf sms.conf smtp_header_checks transport virtual_domains
        virtual_users virtual_users_regex
    )

    require_fetched_tree
    install -d -m 0750 "$IMPORT_TARGET"

    for file in "${files[@]}"; do
        [[ -f "${FETCHED_DIR}/${file}" ]] || continue
        install -m 0640 "${FETCHED_DIR}/${file}" "${IMPORT_TARGET}/${file}"
    done

    if [[ -d "${FETCHED_DIR}/virtual" ]]; then
        install -d -m 0750 "${IMPORT_TARGET}/virtual"
        rsync -a \
            --exclude '*.db' \
            --exclude '*.lmdb' \
            --exclude '*.hash' \
            "${FETCHED_DIR}/virtual/" \
            "${IMPORT_TARGET}/virtual/"
        find "${IMPORT_TARGET}/virtual" -type f -exec chmod 0640 {} +
    fi

    cat > "$manifest" <<EOF_MANIFEST
Postfixer modular import: ${MIGRATION_NAME}

Source: ${REMOTE:-staged source}:${REMOTE_POSTFIX_DIR}
Installed: ${IMPORT_TARGET}

These files are intentionally inactive. Review each file, then either merge its
content into the matching managed file below /etc/postfix/postfixer.d or add an
explicit main.cf map reference. Common managed destinations are:

  relay domains       /etc/postfix/postfixer.d/relay-domains
  relay recipients    /etc/postfix/postfixer.d/relay-recipients
  transport routes    /etc/postfix/postfixer.d/transport
  local domains       /etc/postfix/postfixer.d/local-domains

Run postmap for hash: maps after editing, then run make check and make reload
from the Postfixer checkout. Never activate imported credentials, private keys,
main.cf or master.cf without a manual security review.
EOF_MANIFEST
    chmod 0640 "$manifest"

    log "Installed reviewed modular files below ${IMPORT_TARGET}"
    warn "The imported files are not active until main.cf references them explicitly."
    warn "Credentials, main.cf, master.cf, private keys and generated databases were not installed."
}

main() {
    case "${1:-}" in
        --fetch)
            fetch_remote_postfix
            ;;
        --fetch-maildir-users)
            fetch_maildir_users
            ;;
        --fetch-maildirs)
            fetch_maildirs no
            ;;
        --fetch-maildirs-final)
            fetch_maildirs yes
            ;;
        --diff-local)
            diff_local_postfix
            ;;
        --install-modular)
            install_modular
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
