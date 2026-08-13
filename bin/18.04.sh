#!/usr/bin/env bash
# Ubuntu 18.04 package strategy for Postfixer.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'ERROR: Run bin/install.sh. Release files are sourced by the main installer.\n' >&2
    exit 64
fi

install_release_packages() {
    log "Applying Ubuntu 18.04 package strategy"
    install_base_stack
    install_courier_from_archive
}
