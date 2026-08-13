#!/usr/bin/env bash
# Managed SMTP submission, TLS and Cyrus SASL configuration for Postfixer.
# This file is sourced after customizer.sh and wraps node configuration checks.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'ERROR: Run bin/install.sh.\n' >&2
    exit 64
fi

# Preserve implementations supplied by customizer.sh before overriding them.
eval "$(declare -f configure_postfix_node | sed '1s/configure_postfix_node/postfixer_node_configure_postfix_node/')"
eval "$(declare -f check_mail_stack | sed '1s/check_mail_stack/postfixer_node_check_mail_stack/')"

configure_smtp_pam() {
    cat > /etc/pam.d/smtp <<'PAM'
@include common-auth
@include common-account
@include common-session
PAM
    chmod 0644 /etc/pam.d/smtp
}

configure_cyrus_sasl_server() {
    local sasl_conf=/etc/postfix/sasl/smtpd.conf

    install -d -m 0755 /etc/postfix/sasl
    touch "$sasl_conf"

    # saslauthd can verify PLAIN and LOGIN only. Old DIGEST-MD5/CRAM-MD5
    # configurations must not survive a Postfixer run.
    set_colon_value "$sasl_conf" pwcheck_method saslauthd
    set_colon_value "$sasl_conf" mech_list 'PLAIN LOGIN'

    configure_smtp_pam

    # smtpd_sasl_path is the Cyrus SASL application name. It is not the
    # saslauthd mux socket path. Cyrus reads smtpd.conf and talks to the mux.
    postconf_set smtpd_sasl_type cyrus
    postconf_set smtpd_sasl_path smtpd
    postconf_set smtpd_sasl_security_options noanonymous
    postconf_set smtpd_sasl_tls_security_options noanonymous

    # Never expose AUTH on ordinary plaintext SMTP. The inout submission
    # service below enables it explicitly after mandatory TLS is active.
    postconf_set smtpd_sasl_auth_enable no
    postconf_set smtpd_tls_auth_only yes
}

configure_tls_policy() {
    # Port 25 remains opportunistic TLS. Submission overrides this to encrypt.
    postconf_set smtpd_tls_security_level may
    postconf_set smtp_tls_security_level may

    # Keep compatibility with Postfix versions shipped by Ubuntu 18.04 while
    # excluding obsolete SSL/TLS protocol versions.
    postconf_set smtpd_tls_protocols '!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
    postconf_set smtpd_tls_mandatory_protocols '!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
    postconf_set smtp_tls_protocols '!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
    postconf_set smtp_tls_mandatory_protocols '!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
}

submission_certificate_ready() {
    [[ -r "/etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/fullchain.pem" ]] && \
        [[ -r "/etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/privkey.pem" ]]
}

configure_submission_service() {
    if [[ "$POSTFIXER_ROLE" != inout ]]; then
        # Relay helpers do not provide end-user submission authentication.
        postconf -MX submission/inet >/dev/null 2>&1 || true
        return 0
    fi

    submission_certificate_ready || die \
        "The inout profile requires a TLS certificate for SMTP submission. Missing /etc/letsencrypt/live/${POSTFIXER_CERT_DOMAIN}/{fullchain.pem,privkey.pem}."

    # Create or replace the managed RFC 6409 submission service. The service
    # is deliberately isolated from port 25 and requires authentication.
    postconf -M 'submission/inet=submission inet n - y - - smtpd'
    postconf -P 'submission/inet/syslog_name=postfix/submission'
    postconf -P 'submission/inet/smtpd_tls_security_level=encrypt'
    postconf -P 'submission/inet/smtpd_tls_auth_only=yes'
    postconf -P 'submission/inet/smtpd_sasl_auth_enable=yes'
    postconf -P 'submission/inet/smtpd_sasl_type=cyrus'
    postconf -P 'submission/inet/smtpd_sasl_path=smtpd'
    postconf -P 'submission/inet/smtpd_sasl_security_options=noanonymous'
    postconf -P 'submission/inet/smtpd_sasl_tls_security_options=noanonymous'
    postconf -P 'submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject'
    postconf -P 'submission/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject'
    postconf -P 'submission/inet/milter_macro_daemon_name=ORIGINATING'
}

configure_postfix_node() {
    postfixer_node_configure_postfix_node "$@"
    configure_tls_policy

    if [[ "$POSTFIXER_ROLE" == inout ]]; then
        configure_cyrus_sasl_server
    else
        # Ensure relay-only nodes cannot accidentally inherit SMTP AUTH from an
        # older installation or repository main.cf.
        postconf_set smtpd_sasl_auth_enable no
    fi

    configure_submission_service
}

check_submission_configuration() {
    local failed=0 value

    [[ "$POSTFIXER_ROLE" == inout ]] || return 0

    submission_certificate_ready || {
        warn "SMTP submission certificate is missing for ${POSTFIXER_CERT_DOMAIN}."
        failed=1
    }

    if ! postconf -M submission/inet >/dev/null 2>&1; then
        warn "Postfix submission service is missing from master.cf."
        failed=1
    fi

    for spec in \
        'smtpd_tls_security_level=encrypt' \
        'smtpd_tls_auth_only=yes' \
        'smtpd_sasl_auth_enable=yes' \
        'smtpd_sasl_type=cyrus' \
        'smtpd_sasl_path=smtpd' \
        'smtpd_relay_restrictions=permit_sasl_authenticated,reject'; do
        value="$(postconf -P "submission/inet/${spec%%=*}" 2>/dev/null | sed -E 's/^[^=]+=[[:space:]]*//' || true)"
        if [[ "$value" != "${spec#*=}" ]]; then
            warn "Submission setting mismatch: ${spec} (active value: ${value:-missing})"
            failed=1
        fi
    done

    if ! postconf -a 2>/dev/null | grep -qx cyrus; then
        warn "Postfix does not report Cyrus SASL server support."
        failed=1
    fi

    if [[ ! -S /var/spool/postfix/var/run/saslauthd/mux ]]; then
        warn "saslauthd mux socket is missing from the Postfix chroot."
        failed=1
    fi

    if command -v ss >/dev/null 2>&1 && systemctl is-active --quiet postfix.service 2>/dev/null; then
        if ! ss -ltn 2>/dev/null | awk '$4 ~ /:587$/ {found=1} END {exit !found}'; then
            warn "Postfix is active but nothing is listening on TCP port 587."
            failed=1
        fi
    fi

    [[ "$failed" -eq 0 ]] || die "SMTP submission/SASL check failed."
}

check_mail_stack() {
    postfixer_node_check_mail_stack "$@"
    check_submission_configuration
}
