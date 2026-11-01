#!/usr/bin/env bash
# Prepare the saslauthd socket directory inside the Postfix chroot.

set -Eeuo pipefail

SOCKET_DIR="/var/spool/postfix/var/run/saslauthd"

getent group sasl >/dev/null || groupadd --system sasl
install -d -o root -g sasl -m 0770 "$SOCKET_DIR"
