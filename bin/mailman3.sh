#!/usr/bin/env bash
# Optional Mailman maps survive normal Postfixer node configuration.
eval "$(declare -f configure_postfix_node | sed '1s/configure_postfix_node/postfixer_mailman_base_configure_postfix_node/')"
configure_postfix_node() {
    postfixer_mailman_base_configure_postfix_node "$@"
    if [[ -f /etc/postfixer-mailman3/mailman.cfg ]]; then
        python3 "${BIN_DIR}/mailman3.py" postfix
    fi
}
