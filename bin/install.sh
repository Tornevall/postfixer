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

main "$@"
