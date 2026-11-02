#!/usr/bin/env bash
# Pure decision helper, shared by the interactive installer and tests.
mailman3_install_decision() {
    local role="$1" requested="$2" installed="$3" interactive="$4"
    case "$requested" in auto|yes|no) ;; *) printf 'Invalid POSTFIXER_INSTALL_MAILMAN (auto/yes/no).\n' >&2; return 64 ;; esac
    if [[ "$requested" == no ]]; then printf 'no\n'; return; fi
    if [[ "$installed" == yes ]]; then printf 'keep\n'; return; fi
    if [[ "$role" != inout ]]; then
        if [[ "$requested" == yes ]]; then printf 'Mailman requires the inout profile.\n' >&2; return 64; fi
        printf 'no\n'; return
    fi
    if [[ "$requested" == yes ]]; then printf 'yes\n'
    elif [[ "$interactive" == yes ]]; then printf 'ask\n'
    else printf 'no\n'; fi
}
