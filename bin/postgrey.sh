#!/usr/bin/env bash
# Shared migration helper. The generic installer does not select site-local paths.

install_postgrey_client_whitelist() {
    local source="${1:?Postgrey client whitelist source is required}"
    local active="${POSTFIXER_POSTGREY_WHITELIST_CLIENTS:-/etc/postgrey/whitelist_clients.local}"

    [[ -f "$source" && -r "$source" ]] || die "Postgrey client whitelist is not readable: $source"

    if [[ -e "$active" ]]; then
        [[ -f "$active" && -r "$active" ]] || die "Active Postgrey client whitelist is not a readable file: $active"
        if cmp -s "$active" "$source"; then
            log "Preserving active Postgrey client whitelist at ${active}"
        else
            warn "Preserving active Postgrey client whitelist at ${active}; review imported rules at ${source}."
        fi
        return 0
    fi

    # Never conceal a broken externally managed link by replacing it.
    [[ ! -L "$active" ]] || die "Broken Postgrey client whitelist symlink: $active"

    install -d -m 0755 "$(dirname "$active")"
    install -m 0644 "$source" "$active"
    log "Installed Postgrey client whitelist at ${active}"
    warn "Restart Postgrey after reviewing ${active}."
}
