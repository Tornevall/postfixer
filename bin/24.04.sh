#!/usr/bin/env bash
# Ubuntu 24.04 package strategy for Postfixer.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'ERROR: Run bin/install.sh. Release files are sourced by the main installer.\n' >&2
    exit 64
fi

install_release_packages() {
    log "Applying Ubuntu 24.04 package strategy"
    install_base_stack

    if apt_has_candidate courier-imap && apt_has_candidate courier-pop; then
        install_courier_from_archive
    else
        build_courier_for_noble
    fi
}
