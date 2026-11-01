#!/usr/bin/env bash
# Node-specific Postfixer customization.
# This file is sourced after common.sh and overrides selected shared functions.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'ERROR: Run bin/install.sh.\n' >&2
    exit 64
fi

POSTFIXER_ETC="${POSTFIXER_ETC:-/etc/postfix/postfixer.d}"
POSTFIXER_CONFIG="${POSTFIXER_CONFIG:-${POSTFIXER_ETC}/postfixer.conf}"
POSTFIXER_CONFIG_SOURCE="${POSTFIXER_CONFIG_SOURCE:-${ROOT_DIR}/etc-postfixer}"
POSTFIXER_SAMPLES_DIR="${POSTFIXER_SAMPLES_DIR:-}"
POSTFIXER_LEGACY_ETC="${POSTFIXER_LEGACY_ETC:-/etc/postfixer}"
SPAMASSASSIN_DEFAULTS="${SPAMASSASSIN_DEFAULTS:-/etc/default/spamassassin}"

# Preserve shared implementations before overriding them.
eval "$(declare -f install_courier_from_archive | sed '1s/install_courier_from_archive/postfixer_common_install_courier_from_archive/')"
eval "$(declare -f install_courier_from_jammy_packages | sed '1s/install_courier_from_jammy_packages/postfixer_common_install_courier_from_jammy_packages/')"
eval "$(declare -f build_courier_for_noble | sed '1s/build_courier_for_noble/postfixer_common_build_courier_for_noble/')"
eval "$(declare -f deploy_courier_certificate | sed '1s/deploy_courier_certificate/postfixer_common_deploy_courier_certificate/')"
eval "$(declare -f apply_postfix_configuration | sed '1s/apply_postfix_configuration/postfixer_common_apply_postfix_configuration/')"

config_write() {
    local key="$1"
    local value="$2"
    printf '%s=%q\n' "$key" "$value"
}

prompt_value() {
    local prompt="$1"
    local default_value="$2"
    local value=""

    if [[ -t 0 ]]; then
        read -r -p "${prompt} [${default_value}]: " value
    fi

    printf '%s\n' "${value:-$default_value}"
}

prompt_required_value() {
    local prompt="$1"
    local value=""

    while [[ -z "$value" ]]; do
        read -r -p "${prompt}: " value
    done

    printf '%s\n' "$value"
}

prompt_fqdn() {
    local prompt="$1"
    local default_value="$2"
    local value=""

    while true; do
        if [[ -n "$default_value" ]]; then
            value="$(prompt_value "$prompt" "$default_value")"
        else
            value="$(prompt_required_value "$prompt")"
        fi

        if is_fqdn "$value"; then
            printf '%s\n' "$value"
            return 0
        fi

        warn "${prompt} must be a fully qualified domain name, for example mail.example.com."
    done
}

prompt_optional() {
    local prompt="$1"
    local value=""

    if [[ -t 0 ]]; then
        read -r -p "${prompt}: " value
    fi

    printf '%s\n' "$value"
}

is_fqdn() {
    local value="$1"

    [[ ${#value} -le 253 ]] || return 1
    [[ "$value" == *.* ]] || return 1
    [[ "$value" != .* && "$value" != *. ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

create_postfixer_config() {
    local detected_hostname detected_domain role hostname_value mail_domain relayhost fallbacks cert_domain trusted_networks
    local relay_domains="" relay_destination="" domain

    install -d -m 0755 "$POSTFIXER_ETC"

    detected_hostname="$(hostname -f 2>/dev/null || hostname)"
    if is_fqdn "$detected_hostname"; then
        detected_domain="${detected_hostname#*.}"
    else
        warn "Could not detect a reliable FQDN from this host. The installer will ask for one explicitly."
        detected_hostname=""
        detected_domain=""
    fi

    if [[ ! -t 0 ]]; then
        die "Missing ${POSTFIXER_CONFIG}. Run the installer interactively once or create the file from etc-postfixer/postfixer.conf.example."
    fi

    cat <<'EOF_INTRO'

Postfixer node customizer

Choose one role:
  inout  - complete inbound/outbound server with local Maildir, SMTP AUTH and Courier
  relay  - relay helper with SMTP AUTH; no local Maildir delivery and no IMAP/POP service

EOF_INTRO

    role="$(prompt_value 'Node role (inout/relay)' "${POSTFIXER_ROLE_HINT:-inout}")"
    case "$role" in
        inout|relay) ;;
        *) die "Invalid role: ${role}. Choose inout or relay." ;;
    esac
    hostname_value="$(prompt_fqdn 'SMTP/server hostname (FQDN)' "$detected_hostname")"
    mail_domain="$(prompt_fqdn 'Default mail domain' "$detected_domain")"
    relayhost="$(prompt_optional 'Primary outbound relay in Postfix syntax, for example [relay-2.example.com] (blank = direct delivery)')"
    fallbacks="$(prompt_optional 'Fallback outbound relays separated by spaces, for example [relay-3.example.com] [relay-4.example.com]')"
    cert_domain="$(prompt_fqdn 'Certificate domain under /etc/letsencrypt/live' "$hostname_value")"
    trusted_networks="$(prompt_optional 'Trusted relay networks/IPs separated by spaces, for example 10.0.0.0/8 192.0.2.10 [2001:db8::]/32 (blank = edit later)')"

    if [[ "$role" == relay ]]; then
        relay_domains="$(prompt_required_value 'Domains accepted by this relay, separated by spaces')"
        relay_destination="$(prompt_required_value 'Final delivery host in Postfix syntax, for example [mail.example.com]')"
    else
        relay_domains="$(prompt_optional 'Optional non-local domains relayed by this hybrid server, separated by spaces')"
        if [[ -n "$relay_domains" ]]; then
            relay_destination="$(prompt_required_value 'Final delivery host for those relay domains, for example [mail.example.com]')"
        fi
    fi

    {
        printf '# Postfixer node configuration. This file is the source of truth for server-specific settings.\n'
        config_write POSTFIXER_ROLE "$role"
        config_write POSTFIXER_HOSTNAME "$hostname_value"
        config_write POSTFIXER_MAIL_DOMAIN "$mail_domain"
        config_write POSTFIXER_RELAYHOST "$relayhost"
        config_write POSTFIXER_FALLBACK_RELAYS "$fallbacks"
        config_write POSTFIXER_CERT_DOMAIN "$cert_domain"
        config_write POSTFIXER_NETWORKS_FILE "${POSTFIXER_ETC}/networks"
        config_write POSTFIXER_LOCAL_DOMAINS_FILE "${POSTFIXER_ETC}/local-domains"
        config_write POSTFIXER_RELAY_DOMAINS_FILE "${POSTFIXER_ETC}/relay-domains"
        config_write POSTFIXER_RELAY_RECIPIENTS_FILE "${POSTFIXER_ETC}/relay-recipients"
        config_write POSTFIXER_TRANSPORT_FILE "${POSTFIXER_ETC}/transport"
        config_write POSTFIXER_DKIM_DIR "/etc/opendkim"
        config_write POSTFIXER_SPAMD_HOSTS "127.0.0.1"
    } > "$POSTFIXER_CONFIG"

    chmod 0644 "$POSTFIXER_CONFIG"

    if [[ -n "$trusted_networks" ]]; then
        {
            printf '# Trusted Postfix networks.\n'
            printf '# Add only networks and hosts that are allowed to relay through this node.\n'
            # shellcheck disable=SC2086
            printf '%s\n' $trusted_networks
        } > "${POSTFIXER_ETC}/networks"
        chmod 0644 "${POSTFIXER_ETC}/networks"
    fi

    if [[ "$role" == inout ]]; then
        printf '%s\n' "$mail_domain" > "${POSTFIXER_ETC}/local-domains"
        chmod 0644 "${POSTFIXER_ETC}/local-domains"
    fi

    if [[ -n "$relay_domains" ]]; then
        : > "${POSTFIXER_ETC}/relay-domains"
        : > "${POSTFIXER_ETC}/transport"
        for domain in $relay_domains; do
            printf '%s\n' "$domain" >> "${POSTFIXER_ETC}/relay-domains"
            printf '%s relay:%s\n' "$domain" "$relay_destination" >> "${POSTFIXER_ETC}/transport"
        done
        chmod 0644 "${POSTFIXER_ETC}/relay-domains" "${POSTFIXER_ETC}/transport"
    fi

    log "Created ${POSTFIXER_CONFIG}"
}

migrate_legacy_postfixer_tree() {
    [[ -f "${POSTFIXER_LEGACY_ETC}/postfixer.conf" ]] || return 0
    [[ ! -e "$POSTFIXER_CONFIG" ]] || return 0

    install -d -m 0755 "$POSTFIXER_ETC"
    cp -a "${POSTFIXER_LEGACY_ETC}/." "$POSTFIXER_ETC/"
    sed -i "s#${POSTFIXER_LEGACY_ETC}/#${POSTFIXER_ETC}/#g" "$POSTFIXER_CONFIG"
    log "Migrated legacy Postfixer data from ${POSTFIXER_LEGACY_ETC} to ${POSTFIXER_ETC}"
}

materialize_postfixer_data_symlinks() {
    local path temporary mode

    [[ -d "$POSTFIXER_ETC" ]] || return 0

    while IFS= read -r -d '' path; do
        if [[ ! -f "$path" ]]; then
            warn "Postfixer data symlink is broken or not a regular file: ${path}"
            continue
        fi

        temporary="$(mktemp "${path}.postfixer.XXXXXX")"
        mode="$(stat -Lc '%a' "$path")"
        cat -- "$path" > "$temporary"
        chmod "$mode" "$temporary"
        mv -fT "$temporary" "$path"
        log "Materialized Postfixer data symlink: ${path}"
    done < <(find "$POSTFIXER_ETC" -maxdepth 1 -type l -print0)
}

install_postfixer_samples() {
    local source samples_dir

    samples_dir="${POSTFIXER_SAMPLES_DIR:-$(dirname "$(dirname "$POSTFIXER_CONFIG")")/samples-postfixer}"
    install -d -m 0755 "$samples_dir"
    for source in "${POSTFIXER_CONFIG_SOURCE}"/*.example; do
        [[ -f "$source" ]] || continue
        install -m 0644 "$source" "${samples_dir}/$(basename "$source")"
    done

    if [[ -d "${ROOT_DIR}/samples-postfixer" ]]; then
        cp -a "${ROOT_DIR}/samples-postfixer/." "$samples_dir/"
        find "$samples_dir" -type f -exec chmod 0644 {} +
    fi
}

install_postfixer_data_file() {
    local target="$1"
    local example="$2"

    [[ -e "$target" ]] && return 0
    install -d -m 0755 "$(dirname "$target")"

    if [[ -f "${POSTFIXER_CONFIG_SOURCE}/${example}" ]]; then
        install -m 0644 "${POSTFIXER_CONFIG_SOURCE}/${example}" "$target"
    else
        : > "$target"
        chmod 0644 "$target"
    fi
}

install_networks_file() {
    local legacy=/etc/postfix_networks

    [[ -e "$POSTFIXER_NETWORKS_FILE" || -L "$POSTFIXER_NETWORKS_FILE" ]] && return 0
    install -d -m 0755 "$(dirname "$POSTFIXER_NETWORKS_FILE")"

    if [[ -e "$legacy" || -L "$legacy" ]]; then
        cp -a "$legacy" "$POSTFIXER_NETWORKS_FILE"
        return 0
    fi

    install_postfixer_data_file "$POSTFIXER_NETWORKS_FILE" networks.example
}

load_postfixer_config() {
    migrate_legacy_postfixer_tree
    materialize_postfixer_data_symlinks
    install_postfixer_samples
    [[ -f "$POSTFIXER_CONFIG" ]] || create_postfixer_config

    # shellcheck disable=SC1090
    source "$POSTFIXER_CONFIG"

    POSTFIXER_ROLE="${POSTFIXER_ROLE:-inout}"
    POSTFIXER_HOSTNAME="${POSTFIXER_HOSTNAME:-}"
    POSTFIXER_MAIL_DOMAIN="${POSTFIXER_MAIL_DOMAIN:-}"
    POSTFIXER_RELAYHOST="${POSTFIXER_RELAYHOST:-}"
    POSTFIXER_FALLBACK_RELAYS="${POSTFIXER_FALLBACK_RELAYS:-}"
    POSTFIXER_CERT_DOMAIN="${POSTFIXER_CERT_DOMAIN:-$POSTFIXER_HOSTNAME}"
    POSTFIXER_NETWORKS_FILE="${POSTFIXER_NETWORKS_FILE:-${POSTFIXER_ETC}/networks}"
    POSTFIXER_LOCAL_DOMAINS_FILE="${POSTFIXER_LOCAL_DOMAINS_FILE:-${POSTFIXER_ETC}/local-domains}"
    POSTFIXER_RELAY_DOMAINS_FILE="${POSTFIXER_RELAY_DOMAINS_FILE:-${POSTFIXER_ETC}/relay-domains}"
    POSTFIXER_RELAY_RECIPIENTS_FILE="${POSTFIXER_RELAY_RECIPIENTS_FILE:-${POSTFIXER_ETC}/relay-recipients}"
    POSTFIXER_TRANSPORT_FILE="${POSTFIXER_TRANSPORT_FILE:-${POSTFIXER_ETC}/transport}"
    POSTFIXER_DKIM_DIR="${POSTFIXER_DKIM_DIR:-/etc/opendkim}"
    POSTFIXER_SPAMD_HOSTS="${POSTFIXER_SPAMD_HOSTS:-127.0.0.1}"

    case "$POSTFIXER_ROLE" in
        inout|relay) ;;
        *) die "Invalid POSTFIXER_ROLE=${POSTFIXER_ROLE}. Supported roles: inout, relay." ;;
    esac

    is_fqdn "$POSTFIXER_HOSTNAME" || \
        die "POSTFIXER_HOSTNAME must be a fully qualified domain name. Run the installer interactively or edit ${POSTFIXER_CONFIG}."
    is_fqdn "$POSTFIXER_MAIL_DOMAIN" || \
        die "POSTFIXER_MAIL_DOMAIN must be a fully qualified domain name. Run the installer interactively or edit ${POSTFIXER_CONFIG}."
    is_fqdn "$POSTFIXER_CERT_DOMAIN" || \
        die "POSTFIXER_CERT_DOMAIN must be a fully qualified domain name. Run the installer interactively or edit ${POSTFIXER_CONFIG}."
    [[ "$POSTFIXER_SPAMD_HOSTS" =~ ^[A-Za-z0-9._:-]+(,[A-Za-z0-9._:-]+)*$ ]] || \
        die "POSTFIXER_SPAMD_HOSTS must be a comma-separated list of hostnames or IP addresses without spaces."

    install_networks_file
    install_postfixer_data_file "$POSTFIXER_LOCAL_DOMAINS_FILE" local-domains.example
    install_postfixer_data_file "$POSTFIXER_RELAY_DOMAINS_FILE" relay-domains.example
    install_postfixer_data_file "$POSTFIXER_RELAY_RECIPIENTS_FILE" relay-recipients.example
    install_postfixer_data_file "$POSTFIXER_TRANSPORT_FILE" transport.example

    CERT_DOMAIN="$POSTFIXER_CERT_DOMAIN"
}

relay_endpoint_host() {
    local endpoint="$1"
    local host

    endpoint="${endpoint%%[[:space:]]*}"
    if [[ "$endpoint" == \[*\]* ]]; then
        host="${endpoint#\[}"
        host="${host%%\]*}"
    else
        host="${endpoint%%:*}"
    fi

    printf '%s\n' "$host"
}

validate_node_routes() {
    local endpoint host

    for endpoint in "$POSTFIXER_RELAYHOST" $POSTFIXER_FALLBACK_RELAYS; do
        [[ -n "$endpoint" ]] || continue
        host="$(relay_endpoint_host "$endpoint")"
        if [[ "$host" == "$POSTFIXER_HOSTNAME" ]]; then
            die "Node ${POSTFIXER_HOSTNAME} cannot use itself as relay destination: ${endpoint}"
        fi
    done
}

configure_system_identity() {
    log "Configuring node identity: ${POSTFIXER_HOSTNAME}"

    printf '%s\n' "$POSTFIXER_MAIL_DOMAIN" > /etc/mailname

    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$POSTFIXER_HOSTNAME"
    else
        printf '%s\n' "$POSTFIXER_HOSTNAME" > /etc/hostname
        hostname "$POSTFIXER_HOSTNAME"
    fi

    # Keep myhostname server-specific without storing it in the repository main.cf.
    # Postfix will use the system FQDN when myhostname is not explicitly configured.
    sed -i -E '/^[[:space:]]*myhostname[[:space:]]*=/d' /etc/postfix/main.cf
}

postconf_set() {
    local key="$1"
    local value="$2"
    postconf -e "${key} = ${value}"
}

configure_spamassassin_node() {
    log "Configuring local SpamAssassin with spamd hosts: ${POSTFIXER_SPAMD_HOSTS}"

    install -d -m 0755 "$(dirname "$SPAMASSASSIN_DEFAULTS")"
    touch "$SPAMASSASSIN_DEFAULTS"
    set_equals_value "$SPAMASSASSIN_DEFAULTS" ENABLED 1
    set_equals_value "$SPAMASSASSIN_DEFAULTS" OPTIONS '"--create-prefs --max-children 5 --helper-home-dir -i 127.0.0.1"'
    set_equals_value "$SPAMASSASSIN_DEFAULTS" CRON 1

    postconf -M "spamassassin/unix=spamassassin unix - n n - - pipe flags=Rq user=debian-spamd argv=/usr/bin/spamc -f -n 10 -t 120 -d ${POSTFIXER_SPAMD_HOSTS} -e /usr/sbin/sendmail -oi -f \${sender} \${recipient}"
    postconf -P 'smtp/inet/content_filter=spamassassin'
}

configure_postfix_node() {
    local relay_recipients=""

    load_postfixer_config
    validate_node_routes
    configure_system_identity

    log "Applying Postfixer node profile: ${POSTFIXER_ROLE}"

    postconf -M 'policyd-spf/unix=policyd-spf unix - n n - 0 spawn user=policyd-spf argv=/usr/bin/policyd-spf'

    postconf_set smtpd_banner '$myhostname ESMTP $mail_name'
    postconf_set myorigin /etc/mailname
    postconf_set mynetworks "$POSTFIXER_NETWORKS_FILE"
    postconf_set relayhost "$POSTFIXER_RELAYHOST"
    postconf_set smtp_fallback_relay "$POSTFIXER_FALLBACK_RELAYS"
    postconf_set relay_domains "$POSTFIXER_RELAY_DOMAINS_FILE"
    postconf_set transport_maps "hash:${POSTFIXER_TRANSPORT_FILE}"
    postconf_set smtpd_relay_restrictions 'permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
    postconf_set smtpd_recipient_restrictions 'permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, check_policy_service inet:127.0.0.1:10023, check_policy_service unix:private/policyd-spf'
    postconf_set milter_default_action accept
    postconf_set milter_protocol 6
    postconf_set smtpd_milters inet:127.0.0.1:18891
    postconf_set non_smtpd_milters inet:127.0.0.1:18891
    postconf_set smtp_tls_security_level may
    postconf_set smtpd_tls_security_level may
    postconf_set policyd-spf_time_limit 3600
    configure_spamassassin_node

    if [[ -r "/etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/fullchain.pem" && -r "/etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/privkey.pem" ]]; then
        postconf_set smtpd_tls_cert_file "/etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/fullchain.pem"
        postconf_set smtpd_tls_key_file "/etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/privkey.pem"
    else
        warn "Certificate for ${POSTFIXER_CERT_DOMAIN} is not present yet under /etc/letsencrypt/live."
    fi

    if grep -qEv '^[[:space:]]*(#|$)' "$POSTFIXER_RELAY_RECIPIENTS_FILE"; then
        relay_recipients="hash:${POSTFIXER_RELAY_RECIPIENTS_FILE}"
    fi
    postconf_set relay_recipient_maps "$relay_recipients"

    case "$POSTFIXER_ROLE" in
        inout)
            postconf_set mydestination "\$myhostname, localhost.\$mydomain, localhost, ${POSTFIXER_LOCAL_DOMAINS_FILE}"
            postconf_set local_recipient_maps 'proxy:unix:passwd.byname $alias_maps'
            postconf_set local_transport 'local:$myhostname'
            postconf_set home_mailbox Maildir/
            postconf_set mailbox_command '/usr/bin/procmail -a "$EXTENSION" DEFAULT=$HOME/Maildir/ MAILDIR=$HOME/Maildir'
            postconf_set smtpd_sasl_auth_enable yes
            ;;
        relay)
            postconf_set mydestination ''
            postconf_set local_recipient_maps ''
            postconf_set local_transport 'error:local mail delivery is disabled'
            postconf_set home_mailbox ''
            postconf_set mailbox_command ''
            postconf_set smtpd_sasl_auth_enable no

            if [[ -z "$relay_recipients" ]]; then
                warn "Relay profile has no relay-recipient map. Public MX relays should synchronize valid recipients from the final delivery server to avoid backscatter."
            fi
            ;;
    esac
}

set_opendkim_directive() {
    local file="$1"
    local key="$2"
    local value="$3"

    touch "$file"
    if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
    else
        printf '%s %s\n' "$key" "$value" >> "$file"
    fi
}

configure_opendkim_node() {
    local conf=/etc/opendkim.conf trusted="${POSTFIXER_DKIM_DIR}/trusted.hosts" line

    log "Configuring OpenDKIM signing and verification"
    install -d -o opendkim -g opendkim -m 0750 "$POSTFIXER_DKIM_DIR"
    install -d -o opendkim -g opendkim -m 0700 "${POSTFIXER_DKIM_DIR}/keys"
    touch "${POSTFIXER_DKIM_DIR}/key.table" "${POSTFIXER_DKIM_DIR}/signing.table" "$trusted"

    set_opendkim_directive "$conf" Syslog yes
    set_opendkim_directive "$conf" UMask 007
    set_opendkim_directive "$conf" UserID opendkim
    set_opendkim_directive "$conf" KeyTable "${POSTFIXER_DKIM_DIR}/key.table"
    set_opendkim_directive "$conf" SigningTable "refile:${POSTFIXER_DKIM_DIR}/signing.table"
    set_opendkim_directive "$conf" ExternalIgnoreList "$trusted"
    set_opendkim_directive "$conf" InternalHosts "$trusted"
    set_opendkim_directive "$conf" Canonicalization relaxed/relaxed
    set_opendkim_directive "$conf" Mode sv
    set_opendkim_directive "$conf" SubDomains no
    set_opendkim_directive "$conf" AutoRestart yes
    set_opendkim_directive "$conf" AutoRestartRate 10/1M
    set_opendkim_directive "$conf" DNSTimeout 5
    set_opendkim_directive "$conf" SignatureAlgorithm rsa-sha256
    set_opendkim_directive "$conf" Socket inet:18891@localhost
    set_opendkim_directive "$conf" OversignHeaders From

    if [[ -r /usr/share/dns/root.key ]]; then
        set_opendkim_directive "$conf" TrustAnchorFile /usr/share/dns/root.key
    fi

    {
        printf '127.0.0.1\n::1\nlocalhost\n%s\n' "$POSTFIXER_HOSTNAME"
        [[ -n "$POSTFIXER_MAIL_DOMAIN" ]] && printf '%s\n' "$POSTFIXER_MAIL_DOMAIN"
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(printf '%s' "$line" | xargs)"
            [[ -n "$line" ]] && printf '%s\n' "$line"
        done < "$POSTFIXER_NETWORKS_FILE"
    } | awk '!seen[$0]++' > "${trusted}.tmp"

    install -o opendkim -g opendkim -m 0640 "${trusted}.tmp" "$trusted"
    rm -f "${trusted}.tmp"
    chown opendkim:opendkim "${POSTFIXER_DKIM_DIR}/key.table" "${POSTFIXER_DKIM_DIR}/signing.table"
    chmod 0640 "${POSTFIXER_DKIM_DIR}/key.table" "${POSTFIXER_DKIM_DIR}/signing.table"
    find "${POSTFIXER_DKIM_DIR}/keys" -type f -name '*.private' -exec chown opendkim:opendkim {} + -exec chmod 0600 {} + 2>/dev/null || true
}

install_courier_from_archive() {
    load_postfixer_config
    if [[ "$POSTFIXER_ROLE" == relay ]]; then
        log "Relay profile selected - skipping Courier IMAP/POP packages"
        return 0
    fi
    postfixer_common_install_courier_from_archive "$@"
}

install_courier_from_jammy_packages() {
    load_postfixer_config
    if [[ "$POSTFIXER_ROLE" == relay ]]; then
        log "Relay profile selected - skipping Courier IMAP/POP packages"
        return 0
    fi
    postfixer_common_install_courier_from_jammy_packages "$@"
}

build_courier_for_noble() {
    load_postfixer_config
    if [[ "$POSTFIXER_ROLE" == relay ]]; then
        log "Relay profile selected - skipping Courier build"
        return 0
    fi
    postfixer_common_build_courier_for_noble "$@"
}

apply_postfix_configuration() {
    postfixer_common_apply_postfix_configuration "$@"
    configure_postfix_node
}

deploy_courier_certificate() {
    load_postfixer_config
    configure_postfix_node

    if [[ "$POSTFIXER_ROLE" == relay ]]; then
        if systemctl is-active --quiet postfix.service 2>/dev/null; then
            postfix check
            systemctl reload postfix.service
        fi
        return 0
    fi

    postfixer_common_deploy_courier_certificate "$@"
}

enable_and_restart_services() {
    local service
    local services=(saslauthd postgrey opendkim opendmarc clamav-daemon spamassassin spamd postfix)

    load_postfixer_config

    if [[ "$POSTFIXER_ROLE" == inout ]]; then
        services+=(courier-authdaemon courier-imap courier-imap-ssl courier-pop courier-pop-ssl)
    fi

    log "Enabling and restarting services for ${POSTFIXER_ROLE} profile"
    for service in "${services[@]}"; do
        if service_exists "$service"; then
            systemctl enable "$service.service" >/dev/null 2>&1 || true
            systemctl restart "$service.service"
        fi
    done

    if [[ "$POSTFIXER_ROLE" == relay ]]; then
        for service in courier-authdaemon courier-imap courier-imap-ssl courier-pop courier-pop-ssl; do
            service_exists "$service" && systemctl disable --now "$service.service" >/dev/null 2>&1 || true
        done
    fi
}

check_mail_stack() {
    local failed=0 service
    local services=(postfix postgrey opendkim opendmarc spamassassin)

    load_postfixer_config
    log "Checking ${POSTFIXER_ROLE} mail stack"

    postfix check
    postconf -n >/dev/null

    if ! postconf -M policyd-spf/unix >/dev/null 2>&1; then
        warn "Postfix policyd-spf service is missing from master.cf."
        failed=1
    fi

    if ! postconf -M spamassassin/unix >/dev/null 2>&1; then
        warn "Postfix SpamAssassin pipe service is missing from master.cf."
        failed=1
    fi

    if ! spamassassin --lint; then
        warn "SpamAssassin configuration lint failed."
        failed=1
    fi

    services+=(saslauthd)
    if [[ ! -S /var/spool/postfix/var/run/saslauthd/mux ]]; then
        warn "saslauthd mux socket is missing from the Postfix chroot."
        failed=1
    fi

    if [[ "$POSTFIXER_ROLE" == inout ]]; then
        services+=(courier-authdaemon courier-imap)
    fi

    for service in "${services[@]}"; do
        if service_exists "$service" && ! systemctl is-active --quiet "$service.service"; then
            warn "Service is not active: ${service}"
            failed=1
        fi
    done

    if command -v ss >/dev/null 2>&1; then
        if systemctl is-active --quiet spamassassin.service 2>/dev/null && \
            ! ss -ltn 2>/dev/null | awk '$4 ~ /127\.0\.0\.1:783$/ {found=1} END {exit !found}'; then
            warn "SpamAssassin is active but spamd is not listening on 127.0.0.1:783."
            failed=1
        fi
        printf '\nListening mail ports:\n'
        ss -ltnp 2>/dev/null | awk 'NR == 1 || $4 ~ /:(25|110|143|465|587|993|995)$/' || true
    fi

    [[ "$failed" -eq 0 ]] || die "Mail stack check failed."
    log "Mail stack check passed"
}

full_install() {
    local postfix_preexisting=no

    require_root
    load_os
    load_postfixer_config
    validate_node_routes

    [[ -f /etc/postfix/main.cf ]] && postfix_preexisting=yes

    log "Postfixer - Ubuntu ${UBUNTU_VERSION} (${ARCH}), role ${POSTFIXER_ROLE}"
    if [[ "$postfix_preexisting" == yes ]]; then
        log "Existing /etc/postfix/main.cf detected - treating Postfix as an existing installation"
    else
        log "No /etc/postfix/main.cf detected - Postfix will be installed as part of the stack"
    fi

    backup_existing_configuration
    run_release_install

    configure_saslauthd

    if [[ "$POSTFIXER_ROLE" == inout ]]; then
        configure_courier
    fi

    apply_postfix_configuration
    configure_opendkim_node
    rebuild_postfix_maps
    deploy_courier_certificate
    enable_and_restart_services
    check_mail_stack

    cat <<EOF_SUMMARY

Postfixer installation completed.

Ubuntu:             ${UBUNTU_VERSION}
Role:               ${POSTFIXER_ROLE}
Hostname:           ${POSTFIXER_HOSTNAME}
Node config:        ${POSTFIXER_CONFIG}
Trusted networks:   ${POSTFIXER_NETWORKS_FILE}
Relay domains:      ${POSTFIXER_RELAY_DOMAINS_FILE}
Primary relay:      ${POSTFIXER_RELAYHOST:-direct delivery}
Fallback relays:    ${POSTFIXER_FALLBACK_RELAYS:-none}
Postfix config:     /etc/postfix
Repository overlay: ${ETC_POSTFIX_SOURCE}
Certificates:       externally managed under /etc/letsencrypt

Server-specific identity and relay routing belong in ${POSTFIXER_CONFIG}, not in the repository main.cf.
EOF_SUMMARY
}
