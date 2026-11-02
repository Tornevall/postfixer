#!/usr/bin/env bash
# Optional Mailman maps survive normal Postfixer node configuration.
source "${BIN_DIR}/mailman3-options.sh"
eval "$(declare -f configure_postfix_node | sed '1s/configure_postfix_node/postfixer_mailman_base_configure_postfix_node/')"
configure_postfix_node() {
    postfixer_mailman_base_configure_postfix_node "$@"
    if [[ -f /etc/postfixer-mailman3/mailman.cfg ]]; then
        python3 "${BIN_DIR}/mailman3.py" postfix
    fi
}

eval "$(declare -f full_install | sed '1s/full_install/postfixer_mailman_base_full_install/')"
full_install() {
    postfixer_mailman_base_full_install "$@"
    local decision installed=no interactive=no answer
    [[ -f /etc/postfixer-mailman3/mailman.cfg ]] && installed=yes
    [[ -t 0 ]] && interactive=yes
    decision="$(mailman3_install_decision "$POSTFIXER_ROLE" "${POSTFIXER_INSTALL_MAILMAN:-auto}" "$installed" "$interactive")" || return
    if [[ "$decision" == ask ]]; then
        read -r -p 'Install optional Mailman 3 lists, administration and archives? [y/N]: ' answer
        case "$answer" in y|Y|yes|YES) decision=yes ;; *) decision=no ;; esac
    fi
    case "$decision" in
        no) return 0 ;; # Never removes an existing list system.
        keep) python3 "${BIN_DIR}/mailman3.py" check; return ;;
    esac
    local domain="${MAILMAN_DOMAIN:-}" owner="${MAILMAN_OWNER:-}" cert="${CERT_DOMAIN:-${POSTFIXER_CERT_DOMAIN:-}}"
    if [[ "$interactive" == yes ]]; then
        [[ -n "$domain" ]] || domain="$(prompt_fqdn 'Mailman list domain' "lists.${POSTFIXER_MAIL_DOMAIN}")"
        [[ -n "$owner" ]] || owner="$(prompt_required_value 'Mailman site-owner email address')"
    fi
    [[ -n "$domain" && -n "$owner" && -n "$cert" ]] || die 'Set MAILMAN_DOMAIN, MAILMAN_OWNER and CERT_DOMAIN for optional Mailman installation.'
    MAILMAN_DOMAIN="$domain" MAILMAN_OWNER="$owner" CERT_DOMAIN="$cert" python3 "${BIN_DIR}/mailman3.py" install
}
