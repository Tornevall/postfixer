#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
TMP_ROOT="$(mktemp -d /tmp/postfixer-profile-test.XXXXXX)"

trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_log_contains() {
    local log_file="$1"
    local pattern="$2"

    grep -Fq -- "$pattern" "$log_file" || {
        printf 'Missing expected log line:\n  %s\n\nLog:\n' "$pattern" >&2
        sed -n '1,240p' "$log_file" >&2
        exit 1
    }
}

assert_log_not_contains() {
    local log_file="$1"
    local pattern="$2"

    if grep -Fq -- "$pattern" "$log_file"; then
        printf 'Unexpected log line:\n  %s\n\nLog:\n' "$pattern" >&2
        sed -n '1,240p' "$log_file" >&2
        exit 1
    fi
}

write_profile_config() {
    local role="$1"
    local config_dir="$2"
    local hostname="mail-primary.example.com"

    [[ "$role" == relay ]] && hostname="relay-1.example.com"

    mkdir -p "$config_dir"
    cat > "${config_dir}/postfixer.conf" <<EOF_CONFIG
POSTFIXER_ROLE=${role}
POSTFIXER_HOSTNAME=${hostname}
POSTFIXER_MAIL_DOMAIN=example.com
POSTFIXER_RELAYHOST=[relay-upstream.example.com]
POSTFIXER_FALLBACK_RELAYS=[relay-fallback.example.com]
POSTFIXER_CERT_DOMAIN=${hostname}
POSTFIXER_NETWORKS_FILE=${config_dir}/networks
POSTFIXER_LOCAL_DOMAINS_FILE=${config_dir}/local-domains
POSTFIXER_RELAY_DOMAINS_FILE=${config_dir}/relay-domains
POSTFIXER_RELAY_RECIPIENTS_FILE=${config_dir}/relay-recipients
POSTFIXER_TRANSPORT_FILE=${config_dir}/transport
POSTFIXER_DKIM_DIR=${config_dir}/opendkim
EOF_CONFIG

    cat > "${config_dir}/networks" <<'EOF_NETWORKS'
# Trusted network fixture with IPv4 and IPv6 entries.
127.0.0.0/8
10.0.0.0/8
[::1]/128
[2a01:299:a0::]/48
65.109.143.9
EOF_NETWORKS
    printf 'example.com\n' > "${config_dir}/local-domains"
    printf 'example.net\n' > "${config_dir}/relay-domains"
    printf 'postmaster@example.net OK\n' > "${config_dir}/relay-recipients"
    printf 'example.net relay:[mail-primary.example.com]\n' > "${config_dir}/transport"
}

run_profile_install() {
    local role="$1"
    local run_dir="${TMP_ROOT}/${role}"
    local log_file="${run_dir}/commands.log"
    local config_dir="${run_dir}/etc-postfixer"

    mkdir -p "$run_dir"
    write_profile_config "$role" "$config_dir"
    : > "$log_file"

    if ! (
        cd "$ROOT_DIR"

        # shellcheck source=../bin/common.sh
        source bin/common.sh
        # shellcheck source=../bin/customizer.sh
        source bin/customizer.sh
        # shellcheck source=../bin/submission.sh
        source bin/submission.sh

        export POSTFIXER_ETC="$config_dir"
        export POSTFIXER_CONFIG="${config_dir}/postfixer.conf"
        export TEST_COMMAND_LOG="$log_file"

        require_root() { :; }
        load_os() { UBUNTU_VERSION=22.04; ARCH=amd64; }
        backup_existing_configuration() { printf 'backup_existing_configuration\n' >> "$TEST_COMMAND_LOG"; }
        configure_system_identity() { printf 'configure_system_identity %s %s\n' "$POSTFIXER_ROLE" "$POSTFIXER_HOSTNAME" >> "$TEST_COMMAND_LOG"; }
        postfixer_common_apply_postfix_configuration() { printf 'apply_postfix_configuration\n' >> "$TEST_COMMAND_LOG"; }
        configure_saslauthd() { printf 'configure_saslauthd %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        configure_courier() { printf 'configure_courier %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        configure_smtp_pam() { printf 'configure_smtp_pam %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        configure_opendkim_node() { printf 'configure_opendkim_node %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        rebuild_postfix_maps() { printf 'rebuild_postfix_maps %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        deploy_courier_certificate() { printf 'deploy_courier_certificate %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        check_mail_stack() { printf 'check_mail_stack %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"; }
        submission_certificate_ready() { return 0; }
        service_exists() { return 0; }
        install_base_stack() {
            printf 'install_base_stack %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"
            install_required_packages postfix sasl2-bin libsasl2-2 libsasl2-modules postfix-policyd-spf-python postgrey opendkim opendmarc
            install_optional_packages curl wget swaks mailgraph rrdtool certbot python3-certbot
        }
        run_release_install() {
            printf 'run_release_install %s\n' "$POSTFIXER_ROLE" >> "$TEST_COMMAND_LOG"
            install_base_stack
            install_courier_from_archive
        }

        apt_has_candidate() { return 0; }
        install_required_packages() { printf 'install_required_packages %s\n' "$*" >> "$TEST_COMMAND_LOG"; }
        install_optional_packages() { printf 'install_optional_packages %s\n' "$*" >> "$TEST_COMMAND_LOG"; }
        postconf() { printf 'postconf %s\n' "$*" >> "$TEST_COMMAND_LOG"; }
        postfix() { printf 'postfix %s\n' "$*" >> "$TEST_COMMAND_LOG"; }
        systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_COMMAND_LOG"; return 0; }

        full_install > "${run_dir}/stdout.log" 2> "${run_dir}/stderr.log"
    ); then
        printf 'Profile install simulation failed for %s\n\ncommands.log:\n' "$role" >&2
        sed -n '1,240p' "$log_file" >&2
        printf '\nstdout.log:\n' >&2
        sed -n '1,240p' "${run_dir}/stdout.log" >&2
        printf '\nstderr.log:\n' >&2
        sed -n '1,240p' "${run_dir}/stderr.log" >&2
        exit 1
    fi

    assert_log_contains "$log_file" "configure_saslauthd ${role}"
    assert_log_contains "$log_file" "install_optional_packages curl wget swaks mailgraph rrdtool certbot python3-certbot"
    assert_log_contains "$log_file" "configure_smtp_pam ${role}"
    assert_log_contains "$log_file" "postconf -e smtpd_sasl_auth_enable = no"
    assert_log_contains "$log_file" "postconf -M submission/inet=submission inet n - y - - smtpd"
    assert_log_contains "$log_file" "postconf -P submission/inet/smtpd_sasl_auth_enable=yes"
    assert_log_contains "$log_file" "postconf -P submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject"
    assert_log_contains "$log_file" "postconf -e mynetworks = ${config_dir}/networks"
    assert_log_contains "$log_file" "postconf -M policyd-spf/unix=policyd-spf unix - n n - 0 spawn user=policyd-spf argv=/usr/bin/policyd-spf"

    if [[ "$role" == inout ]]; then
        assert_log_contains "$log_file" "configure_courier inout"
        assert_log_contains "$log_file" "postconf -e home_mailbox = Maildir/"
    else
        assert_log_not_contains "$log_file" "configure_courier relay"
        assert_log_contains "$log_file" "postconf -e local_transport = error:local mail delivery is disabled"
        assert_log_contains "$log_file" "systemctl enable saslauthd.service"
        assert_log_not_contains "$log_file" "systemctl disable --now saslauthd.service"
    fi
}

run_noble_relay_package_test() {
    local run_dir="${TMP_ROOT}/noble-relay"
    local config_dir="${run_dir}/etc-postfixer"
    local log_file="${run_dir}/commands.log"

    mkdir -p "$run_dir"
    write_profile_config relay "$config_dir"
    : > "$log_file"

    (
        cd "$ROOT_DIR"
        source bin/common.sh
        source bin/customizer.sh

        export POSTFIXER_ETC="$config_dir"
        export POSTFIXER_CONFIG="${config_dir}/postfixer.conf"

        install_base_stack() { printf 'install_base_stack\n' >> "$log_file"; }
        apt_has_candidate() { return 1; }
        postfixer_common_install_courier_from_jammy_packages() { printf 'jammy_courier\n' >> "$log_file"; }
        postfixer_common_build_courier_for_noble() { printf 'built_courier\n' >> "$log_file"; }

        source bin/24.04.sh
        install_release_packages >/dev/null
    )

    assert_log_contains "$log_file" "install_base_stack"
    assert_log_not_contains "$log_file" "jammy_courier"
    assert_log_not_contains "$log_file" "built_courier"
}

run_legacy_networks_migration_test() {
    local run_dir="${TMP_ROOT}/legacy-networks"
    local config_dir="${run_dir}/etc-postfixer"

    mkdir -p "$run_dir" "$config_dir"
    cat > "${config_dir}/postfixer.conf" <<EOF_CONFIG
POSTFIXER_ROLE=relay
POSTFIXER_HOSTNAME=relay-legacy.example.com
POSTFIXER_MAIL_DOMAIN=example.com
POSTFIXER_CERT_DOMAIN=relay-legacy.example.com
POSTFIXER_NETWORKS_FILE=${config_dir}/networks
POSTFIXER_LOCAL_DOMAINS_FILE=${config_dir}/local-domains
POSTFIXER_RELAY_DOMAINS_FILE=${config_dir}/relay-domains
POSTFIXER_RELAY_RECIPIENTS_FILE=${config_dir}/relay-recipients
POSTFIXER_TRANSPORT_FILE=${config_dir}/transport
POSTFIXER_DKIM_DIR=${config_dir}/opendkim
EOF_CONFIG
    printf '198.51.100.10\n10.0.0.0/8\n' > "${run_dir}/legacy-networks"

    (
        cd "$ROOT_DIR"
        # shellcheck source=../bin/common.sh
        source bin/common.sh
        # shellcheck source=../bin/customizer.sh
        source bin/customizer.sh

        POSTFIXER_ETC="$config_dir"
        POSTFIXER_CONFIG="$config_dir/postfixer.conf"
        POSTFIXER_NETWORKS_FILE="${config_dir}/networks"
        install_networks_file() {
            local legacy="${run_dir}/legacy-networks"

            [[ -e "$POSTFIXER_NETWORKS_FILE" || -L "$POSTFIXER_NETWORKS_FILE" ]] && return 0
            install -d -m 0755 "$(dirname "$POSTFIXER_NETWORKS_FILE")"
            cp -a "$legacy" "$POSTFIXER_NETWORKS_FILE"
        }
        load_postfixer_config
    )

    cmp -s "${run_dir}/legacy-networks" "${config_dir}/networks" || \
        fail "legacy networks file was not copied into POSTFIXER_NETWORKS_FILE"
}

run_postfixer_symlink_materialization_test() {
    local run_dir="${TMP_ROOT}/symlink-materialization"
    local config_dir="${run_dir}/postfixer.d"
    local external_file="${run_dir}/external-networks"

    mkdir -p "$config_dir"
    printf '192.0.2.10\n' > "$external_file"
    ln -s "$external_file" "${config_dir}/networks"

    (
        cd "$ROOT_DIR"
        source bin/common.sh
        source bin/customizer.sh

        POSTFIXER_ETC="$config_dir"
        materialize_postfixer_data_symlinks >/dev/null
    )

    [[ -f "${config_dir}/networks" && ! -L "${config_dir}/networks" ]] || \
        fail "Postfixer data symlink was not materialized"
    cmp -s "$external_file" "${config_dir}/networks" || \
        fail "materialized Postfixer data changed content"
}

run_modular_import_test() {
    local run_dir="${TMP_ROOT}/modular-import"
    local fetched_dir="${run_dir}/fetched"
    local import_target="${run_dir}/installed"
    local output_file="${run_dir}/output.log"

    mkdir -p "$fetched_dir"
    printf 'example.net\n' > "${fetched_dir}/relaydomains"
    printf 'example.net relay:[mail.example.net]\n' > "${fetched_dir}/transport"
    printf '[smtp.example.net] user:secret\n' > "${fetched_dir}/sasl_passwd"
    printf 'myhostname = old.example.net\n' > "${fetched_dir}/main.cf"
    printf 'smtp inet n - y - - smtpd\n' > "${fetched_dir}/master.cf"
    printf 'private key fixture\n' > "${fetched_dir}/private.pem"
    printf 'generated map fixture\n' > "${fetched_dir}/transport.db"

    FETCHED_DIR="$fetched_dir" \
    IMPORT_TARGET="$import_target" \
    MIGRATION_NAME=test-import \
        bash "${ROOT_DIR}/examples/migrations/import-postfix-server.sh" --install-modular \
        > "$output_file" 2>&1

    [[ -f "${import_target}/relaydomains" ]] || fail "relay domains were not imported"
    [[ -f "${import_target}/transport" ]] || fail "transport map was not imported"
    [[ -f "${import_target}/README.import" ]] || fail "import manifest was not generated"
    [[ ! -e "${import_target}/sasl_passwd" ]] || fail "SMTP credentials were imported"
    [[ ! -e "${import_target}/main.cf" ]] || fail "main.cf was imported"
    [[ ! -e "${import_target}/master.cf" ]] || fail "master.cf was imported"
    [[ ! -e "${import_target}/private.pem" ]] || fail "private key material was imported"
    [[ ! -e "${import_target}/transport.db" ]] || fail "generated map database was imported"
    grep -Fq 'not active until main.cf references them' "$output_file" || \
        fail "import activation warning was not printed"
}

run_profile_install inout
run_profile_install relay
run_noble_relay_package_test
run_legacy_networks_migration_test
run_postfixer_symlink_materialization_test
run_modular_import_test

printf 'profile install tests passed\n'
