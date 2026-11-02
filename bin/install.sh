#!/usr/bin/env bash
# Main entry point for Postfixer.
# Ubuntu release-specific package handling lives in bin/<VERSION_ID>.sh.

set -Eeuo pipefail

BIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${BIN_DIR}/.." && pwd -P)"

# Shared package, Courier, SASL, certificate and map handling.
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

# Server-specific roles, routing, identity and OpenDKIM customization.
# shellcheck source=customizer.sh
source "${BIN_DIR}/customizer.sh"

# Managed port 587 submission, STARTTLS and Cyrus SASL policy.
# shellcheck source=submission.sh
source "${BIN_DIR}/submission.sh"

# Opt-in Mailman configuration is reapplied only on hosts with its config.
source "${BIN_DIR}/mailman3.sh"

main "$@"
