#!/usr/bin/env bash
# Shared installer and maintenance functions for Postfixer.
# This file is sourced by bin/install.sh.

set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

BIN_DIR="${BIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
ROOT_DIR="${ROOT_DIR:-$(cd -- "${BIN_DIR}/.." && pwd -P)}"
ETC_POSTFIX_SOURCE="${ETC_POSTFIX_SOURCE:-${ROOT_DIR}/etc-postfix}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUNTIME_DIR="${POSTFIXER_RUNTIME_DIR:-/usr/local/lib/postfixer}"

# Ubuntu 24.04 does not currently ship courier-imap/courier-pop binary packages.
# These values are only used by the Noble source-package fallback.
COURIER_SOURCE_VERSION="${COURIER_SOURCE_VERSION:-1.4.1-3}"
COURIER_SOURCE_BASE="${COURIER_SOURCE_BASE:-https://archive.ubuntu.com/ubuntu/pool/universe/c/courier}"
COURIER_BUILD_ROOT="${COURIER_BUILD_ROOT:-/usr/local/src/postfixer-courier}"
COURIER_JAMMY_VERSION="${COURIER_JAMMY_VERSION:-1.0.16-3build3}"
COURIER_JAMMY_IMAP_VERSION="${COURIER_JAMMY_IMAP_VERSION:-5.0.13+1.0.16-3build3}"
COURIER_JAMMY_BASE="${COURIER_JAMMY_BASE:-https://se.archive.ubuntu.com/ubuntu/pool/universe/c/courier}"
GAMIN_JAMMY_VERSION="${GAMIN_JAMMY_VERSION:-0.1.10-6}"
GAMIN_JAMMY_BASE="${GAMIN_JAMMY_BASE:-https://se.archive.ubuntu.com/ubuntu/pool/universe/g/gamin}"
COURIER_JAMMY_ROOT="${COURIER_JAMMY_ROOT:-/usr/local/src/postfixer-courier-jammy}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'ERROR: Run %s/install.sh instead.\n' "$BIN_DIR" >&2
    exit 64
fi

log() {
    printf '\n=== %s ===\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this command as root."
}

load_os() {
    [[ -r "$OS_RELEASE_FILE" ]] || die "OS release file is missing: $OS_RELEASE_FILE"

    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"

    [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported distribution: ${ID:-unknown}. Ubuntu is required."

    UBUNTU_VERSION="${VERSION_ID:-}"
    [[ -n "$UBUNTU_VERSION" ]] || die "Ubuntu VERSION_ID is missing from $OS_RELEASE_FILE."
    [[ -r "${BIN_DIR}/${UBUNTU_VERSION}.sh" ]] || \
        die "Unsupported Ubuntu release: ${UBUNTU_VERSION}. Missing ${BIN_DIR}/${UBUNTU_VERSION}.sh."

    ARCH="$(dpkg --print-architecture)"
}

apt_has_candidate() {
    local package="$1"
    local candidate

    candidate="$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_required_packages() {
    local packages=("$@")
    local missing=()
    local package

    for package in "${packages[@]}"; do
        if ! apt_has_candidate "$package"; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]})); then
        die "Missing package candidate(s) on Ubuntu ${UBUNTU_VERSION}: ${missing[*]}"
    fi

    apt-get install -y --no-install-recommends "${packages[@]}"
}

install_optional_packages() {
    local packages=("$@")
    local available=()
    local missing=()
    local package

    for package in "${packages[@]}"; do
        if apt_has_candidate "$package"; then
            available+=("$package")
        else
            missing+=("$package")
        fi
    done

    if ((${#available[@]})); then
        apt-get install -y --no-install-recommends "${available[@]}"
    fi

    if ((${#missing[@]})); then
        warn "Optional package candidate(s) unavailable: ${missing[*]}"
    fi
}

enable_universe_if_needed() {
    if apt_has_candidate courier-authdaemon && apt_has_candidate opendkim; then
        return 0
    fi

    log "Enabling Ubuntu universe repository"
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y universe
    apt-get update
}

preseed_postfix() {
    local mailname

    mailname="$(hostname -f 2>/dev/null || hostname)"
    printf 'postfix postfix/mailname string %s\n' "$mailname" | debconf-set-selections
    printf 'postfix postfix/main_mailer_type select Internet Site\n' | debconf-set-selections
}

backup_existing_configuration() {
    local backup_dir="${BACKUP_ROOT}/postfixer-backup-${TIMESTAMP}"
    local copied=0

    for path in /etc/postfix /etc/courier /etc/default/saslauthd /etc/pam.d/imap /etc/pam.d/pop3; do
        [[ -e "$path" || -L "$path" ]] || continue

        if [[ "$copied" -eq 0 ]]; then
            mkdir -p "$backup_dir"
            copied=1
        fi

        cp -a --parents "$path" "$backup_dir"
    done

    if [[ "$copied" -eq 1 ]]; then
        log "Existing mail configuration backed up to ${backup_dir}"
    fi
}

install_base_stack() {
    log "Installing common mail stack packages"

    apt-get update
    enable_universe_if_needed
    preseed_postfix

    install_required_packages \
        ca-certificates openssl rsync make iproute2 \
        postfix postfix-pcre postfix-policyd-spf-python postgrey \
        sasl2-bin libsasl2-2 libsasl2-modules \
        spamassassin spamc \
        clamav clamav-daemon clamav-freshclam clamdscan \
        fetchmail procmail \
        opendkim opendkim-tools opendmarc \
        courier-authdaemon courier-authlib courier-authlib-pipe courier-authlib-userdb

    install_optional_packages curl wget swaks mailgraph rrdtool certbot python3-certbot
}

install_courier_from_archive() {
    log "Installing Courier IMAP and POP3 from Ubuntu packages"
    install_required_packages courier-imap courier-pop
}

install_courier_build_dependencies() {
    install_required_packages \
        build-essential dpkg-dev fakeroot wget devscripts equivs \
        dh-exec dh-apache2 courier-authlib-dev default-libmysqlclient-dev \
        expect ghostscript gnupg2 gnutls-bin groff-base \
        libcourier-unicode-dev libgcrypt20-dev libgdbm-dev libgnutls28-dev \
        libidn-dev libldap2-dev libpam0g-dev libpcre2-dev libperl-dev \
        libpq-dev libsasl2-dev libtool-bin media-types mgetty-fax netpbm
}

install_courier_from_jammy_packages() {
    local work_dir="${COURIER_JAMMY_ROOT}/${COURIER_JAMMY_VERSION}-${ARCH}"
    local files=(
        "gamin_${GAMIN_JAMMY_VERSION}_${ARCH}.deb"
        "libgamin0_${GAMIN_JAMMY_VERSION}_${ARCH}.deb"
        "courier-base_${COURIER_JAMMY_VERSION}_${ARCH}.deb"
        "courier-imap_${COURIER_JAMMY_IMAP_VERSION}_${ARCH}.deb"
        "courier-pop_${COURIER_JAMMY_VERSION}_${ARCH}.deb"
    )
    local file url

    log "Installing Courier IMAP and POP3 from Ubuntu 22.04 local packages"
    warn "Ubuntu 24.04 does not publish courier-imap/courier-pop. Postfixer will install the required Jammy Courier .deb files locally instead of compiling Courier."

    case "$ARCH" in
        amd64|arm64|armhf|ppc64el|riscv64|s390x) ;;
        *) die "Jammy Courier fallback does not know how to fetch architecture: ${ARCH}" ;;
    esac

    install_required_packages gnutls-bin libcourier-unicode4 libidn12 libpcre3

    mkdir -p "$work_dir"
    cd "$work_dir"

    for file in "${files[@]}"; do
        case "$file" in
            gamin_*|libgamin0_*) url="${GAMIN_JAMMY_BASE}/${file}" ;;
            *) url="${COURIER_JAMMY_BASE}/${file}" ;;
        esac

        if [[ ! -s "$file" ]]; then
            log "Downloading ${file}"
            wget --timeout=20 --tries=3 -q --show-progress "$url"
        fi
    done

    apt-get install -y "./${files[0]}" "./${files[1]}" "./${files[2]}" "./${files[3]}" "./${files[4]}"
}

build_courier_for_noble() {
    local upstream="${COURIER_SOURCE_VERSION%%-*}"
    local build_dir="${COURIER_BUILD_ROOT}/${COURIER_SOURCE_VERSION}"
    local dsc="courier_${COURIER_SOURCE_VERSION}.dsc"
    local orig="courier_${upstream}.orig.tar.bz2"
    local orig_sig="${orig}.asc"
    local debian="courier_${COURIER_SOURCE_VERSION}.debian.tar.xz"
    local source_dir base_deb imap_deb pop_deb

    log "Building Courier packages for Ubuntu 24.04"
    warn "Ubuntu 24.04 does not publish courier-imap/courier-pop in the normal archive. Postfixer will build Debian packages from Ubuntu's Courier source package."

    install_courier_build_dependencies

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"

    wget -q --show-progress "${COURIER_SOURCE_BASE}/${dsc}"
    wget -q --show-progress "${COURIER_SOURCE_BASE}/${orig}"
    wget -q --show-progress "${COURIER_SOURCE_BASE}/${orig_sig}"
    wget -q --show-progress "${COURIER_SOURCE_BASE}/${debian}"

    dpkg-source -x "$dsc"
    source_dir="$(find . -mindepth 1 -maxdepth 1 -type d -name 'courier-*' | head -n1)"
    [[ -n "$source_dir" ]] || die "Courier source extraction failed."

    cd "$source_dir"
    mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control
    dpkg-checkbuilddeps -B
    dpkg-buildpackage -us -uc -B
    cd ..

    base_deb="$(find . -maxdepth 1 -type f -name "courier-base_*_${ARCH}.deb" | head -n1)"
    imap_deb="$(find . -maxdepth 1 -type f -name "courier-imap_*_${ARCH}.deb" | head -n1)"
    pop_deb="$(find . -maxdepth 1 -type f -name "courier-pop_*_${ARCH}.deb" | head -n1)"

    [[ -n "$base_deb" && -n "$imap_deb" && -n "$pop_deb" ]] || \
        die "Courier build completed, but the required .deb files were not found."

    apt-get install -y "$PWD/$base_deb" "$PWD/$imap_deb" "$PWD/$pop_deb"
}

set_equals_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    [[ -f "$file" ]] || die "Cannot configure missing file: $file"

    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

set_colon_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    touch "$file"

    if grep -qE "^[[:space:]]*${key}:" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}:.*|${key}: ${value}|" "$file"
    else
        printf '%s: %s\n' "$key" "$value" >> "$file"
    fi
}

find_courier_config_dir() {
    local candidate

    for candidate in /usr/lib/courier-imap/etc /etc/courier /usr/lib/courier/etc; do
        if [[ -f "${candidate}/imapd" || -f "${candidate}/imapd.dist" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

initialize_courier_config() {
    local config_dir="$1"
    local tool=""
    local dist active

    if command -v sysconftool >/dev/null 2>&1; then
        tool="$(command -v sysconftool)"
    else
        for tool in /usr/lib/courier-imap/libexec/sysconftool /usr/lib/courier/libexec/sysconftool; do
            [[ -x "$tool" ]] && break
            tool=""
        done
    fi

    for active in imapd imapd-ssl pop3d pop3d-ssl; do
        dist="${config_dir}/${active}.dist"
        [[ -f "$dist" ]] || continue

        if [[ -n "$tool" ]]; then
            "$tool" "$dist"
        elif [[ ! -f "${config_dir}/${active}" ]]; then
            cp -a "$dist" "${config_dir}/${active}"
        fi
    done
}

configure_courier() {
    local config_dir authdaemonrc shared_dir file

    log "Configuring Courier IMAP, POP3 and PAM"

    config_dir="$(find_courier_config_dir)" || die "Could not locate Courier's active configuration directory."
    initialize_courier_config "$config_dir"

    for file in imapd imapd-ssl pop3d pop3d-ssl; do
        [[ -f "${config_dir}/${file}" ]] || die "Courier configuration file is missing: ${config_dir}/${file}"
    done

    set_equals_value "${config_dir}/imapd" IMAPDSTART YES
    set_equals_value "${config_dir}/imapd-ssl" IMAPDSSLSTART YES
    set_equals_value "${config_dir}/pop3d" POP3DSTART YES
    set_equals_value "${config_dir}/pop3d-ssl" POP3DSSLSTART YES

    shared_dir="${config_dir}/shared"
    install -d -o daemon -g daemon -m 0755 "$shared_dir"
    touch "${shared_dir}/index"
    chown daemon:daemon "${shared_dir}/index"
    chmod 0644 "${shared_dir}/index"

    authdaemonrc=""
    for file in /etc/courier/authdaemonrc /usr/local/etc/authlib/authdaemonrc /usr/lib/courier-imap/etc/authdaemonrc; do
        if [[ -f "$file" ]]; then
            authdaemonrc="$file"
            break
        fi
    done

    [[ -n "$authdaemonrc" ]] || die "Courier authdaemonrc was not found."
    set_equals_value "$authdaemonrc" authmodulelist '"authpam"'

    cat > /etc/pam.d/imap <<'PAM'
@include common-auth
@include common-account
@include common-session
PAM

    cat > /etc/pam.d/pop3 <<'PAM'
@include common-auth
@include common-account
@include common-session
PAM

    COURIER_CONFIG_DIR="$config_dir"
}

install_runtime_helpers() {
    install -d -m 0755 "$RUNTIME_DIR"
    install -m 0755 "${BIN_DIR}/saslauthd-prepare.sh" "${RUNTIME_DIR}/saslauthd-prepare.sh"
}

configure_saslauthd() {
    log "Configuring Cyrus SASL and saslauthd"

    getent group sasl >/dev/null || groupadd --system sasl
    id postfix >/dev/null 2>&1 || die "Postfix system user does not exist."
    usermod -a -G sasl postfix

    [[ -f /etc/default/saslauthd ]] || touch /etc/default/saslauthd
    set_equals_value /etc/default/saslauthd START yes
    set_equals_value /etc/default/saslauthd MECHANISMS '"pam"'
    set_equals_value /etc/default/saslauthd OPTIONS '"-c -m /var/spool/postfix/var/run/saslauthd"'

    install_runtime_helpers
    "${RUNTIME_DIR}/saslauthd-prepare.sh"

    install -d -m 0755 /etc/systemd/system/saslauthd.service.d
    cat > /etc/systemd/system/saslauthd.service.d/postfixer.conf <<EOF_DROPIN
[Service]
ExecStartPre=${RUNTIME_DIR}/saslauthd-prepare.sh
PIDFile=/var/spool/postfix/var/run/saslauthd/saslauthd.pid
EOF_DROPIN

    systemctl daemon-reload

    install -d -m 0755 /etc/postfix/sasl
    set_colon_value /etc/postfix/sasl/smtpd.conf pwcheck_method saslauthd

    if ! grep -qE '^[[:space:]]*mech_list:' /etc/postfix/sasl/smtpd.conf; then
        printf 'mech_list: PLAIN LOGIN\n' >> /etc/postfix/sasl/smtpd.conf
    fi
}

apply_postfix_configuration() {
    local count

    [[ -d "$ETC_POSTFIX_SOURCE" ]] || die "Postfix source directory is missing: $ETC_POSTFIX_SOURCE"
    [[ -d /etc/postfix ]] || die "/etc/postfix does not exist. Install Postfix before applying repository configuration."

    count="$(find "$ETC_POSTFIX_SOURCE" -type f ! -name 'README.md' ! -name '.gitkeep' | wc -l)"

    if [[ "$count" -eq 0 ]]; then
        log "No repository Postfix configuration has been added yet - keeping the package-generated /etc/postfix"
        return 0
    fi

    log "Applying ${count} file(s) from etc-postfix/ to /etc/postfix"
    rsync -a \
        --exclude 'README.md' \
        --exclude '.gitkeep' \
        "${ETC_POSTFIX_SOURCE}/" /etc/postfix/
}

rebuild_postfix_maps() {
    local line parameter value token path key
    declare -A seen=()

    log "Rebuilding Postfix hash maps"

    while IFS= read -r line; do
        [[ "$line" == *" = "* ]] || continue
        parameter="${line%% = *}"
        value="${line#* = }"

        while IFS= read -r token; do
            [[ -n "$token" ]] || continue
            path="${token#hash:}"
            path="${path%,}"
            [[ -f "$path" ]] || continue

            key="${parameter}:${path}"
            [[ -z "${seen[$key]:-}" ]] || continue
            seen[$key]=1

            case "$parameter" in
                alias_maps|alias_database)
                    postalias "$path"
                    ;;
                *)
                    postmap "$path"
                    ;;
            esac
        done < <(grep -oE 'hash:[^,[:space:]]+' <<<"$value" || true)
    done < <(postconf -n)

    if [[ -f /etc/aliases ]]; then
        newaliases
    fi
}

detect_cert_domain() {
    local cert_file=""

    if [[ -n "${CERT_DOMAIN:-}" ]]; then
        printf '%s\n' "$CERT_DOMAIN"
        return 0
    fi

    if command -v postconf >/dev/null 2>&1; then
        cert_file="$(postconf -h smtpd_tls_cert_file 2>/dev/null || true)"
        if [[ "$cert_file" =~ ^/etc/letsencrypt/live/([^/]+)/ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    hostname -f 2>/dev/null || hostname
}

validate_certificate_pair() {
    local fullchain="$1"
    local privkey="$2"
    local cert_pub key_pub

    openssl x509 -in "$fullchain" -noout -checkend 0 >/dev/null || return 1

    cert_pub="$(openssl x509 -in "$fullchain" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_pub="$(openssl pkey -in "$privkey" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"

    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

install_atomic_if_changed() {
    local source="$1"
    local target="$2"
    local mode="$3"
    local tmp="${target}.postfixer.$$"

    install -m "$mode" "$source" "$tmp"

    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$target"
    return 0
}

deploy_courier_certificate() {
    local domain fullchain privkey config_dir bundle changed=0

    domain="$(detect_cert_domain)"
    fullchain="/etc/letsencrypt/live/${domain}/fullchain.pem"
    privkey="/etc/letsencrypt/live/${domain}/privkey.pem"

    if [[ ! -r "$fullchain" || ! -r "$privkey" ]]; then
        warn "No externally managed Let's Encrypt certificate found for ${domain}. Leaving Courier's current TLS files untouched."
        return 0
    fi

    validate_certificate_pair "$fullchain" "$privkey" || die "Certificate validation failed for ${domain}."

    config_dir="$(find_courier_config_dir)" || die "Could not locate Courier configuration while deploying certificates."
    install -d -m 0755 /etc/courier

    bundle="$(mktemp)"
    cat "$privkey" "$fullchain" > "$bundle"
    chmod 0600 "$bundle"

    if install_atomic_if_changed "$bundle" /etc/courier/imapd.pem 0600; then
        changed=1
    fi
    if install_atomic_if_changed "$bundle" /etc/courier/pop3d.pem 0600; then
        changed=1
    fi

    set_equals_value "${config_dir}/imapd-ssl" TLS_CERTFILE /etc/courier/imapd.pem
    set_equals_value "${config_dir}/pop3d-ssl" TLS_CERTFILE /etc/courier/pop3d.pem

    rm -f "$bundle"

    if [[ "$changed" -eq 1 ]]; then
        log "Courier TLS certificate updated for ${domain}"
        restart_courier_services
        if systemctl is-active --quiet postfix.service 2>/dev/null; then
            systemctl reload postfix.service
        fi
    else
        log "Courier TLS certificate is already current for ${domain}"
    fi
}

service_exists() {
    systemctl cat "$1.service" >/dev/null 2>&1
}

restart_courier_services() {
    local service

    for service in courier-authdaemon courier-imap courier-imap-ssl courier-pop courier-pop-ssl; do
        if service_exists "$service"; then
            systemctl restart "$service.service"
        fi
    done
}

enable_and_restart_services() {
    local service
    local services=(
        saslauthd postgrey opendkim opendmarc clamav-daemon
        spamassassin spamd
        courier-authdaemon courier-imap courier-imap-ssl courier-pop courier-pop-ssl
        postfix
    )

    log "Enabling and restarting installed mail services"

    for service in "${services[@]}"; do
        if service_exists "$service"; then
            systemctl enable "$service.service" >/dev/null 2>&1 || true
            systemctl restart "$service.service"
        fi
    done
}

check_mail_stack() {
    local failed=0
    local service

    log "Checking mail stack"

    postfix check
    postconf -n >/dev/null

    if service_exists saslauthd; then
        if [[ ! -S /var/spool/postfix/var/run/saslauthd/mux ]]; then
            warn "saslauthd mux socket is missing from the Postfix chroot."
            failed=1
        fi
    fi

    for service in postfix saslauthd postgrey opendkim opendmarc courier-authdaemon courier-imap; do
        if service_exists "$service" && ! systemctl is-active --quiet "$service.service"; then
            warn "Service is not active: ${service}"
            failed=1
        fi
    done

    if command -v ss >/dev/null 2>&1; then
        printf '\nListening mail ports:\n'
        ss -ltnp 2>/dev/null | awk 'NR == 1 || $4 ~ /:(25|110|143|465|587|993|995)$/' || true
    fi

    [[ "$failed" -eq 0 ]] || die "Mail stack check failed."
    log "Mail stack check passed"
}

run_release_install() {
    # shellcheck disable=SC1090
    source "${BIN_DIR}/${UBUNTU_VERSION}.sh"
    declare -F install_release_packages >/dev/null || \
        die "Release file ${BIN_DIR}/${UBUNTU_VERSION}.sh does not define install_release_packages()."
    install_release_packages
}

full_install() {
    require_root
    load_os

    log "Postfixer - Ubuntu ${UBUNTU_VERSION} (${ARCH})"
    backup_existing_configuration
    run_release_install
    configure_courier
    configure_saslauthd
    apply_postfix_configuration
    rebuild_postfix_maps
    deploy_courier_certificate
    enable_and_restart_services
    check_mail_stack

    cat <<EOF_SUMMARY

Postfixer installation completed.

Ubuntu:            ${UBUNTU_VERSION}
Repository:        ${ROOT_DIR}
Postfix config:    /etc/postfix
Config source:     ${ETC_POSTFIX_SOURCE}
Courier config:    ${COURIER_CONFIG_DIR:-$(find_courier_config_dir 2>/dev/null || true)}
SASL socket:       /var/spool/postfix/var/run/saslauthd/mux
Certificates:      externally managed under /etc/letsencrypt

Add your Postfix configuration to ${ETC_POSTFIX_SOURCE} and run:
  sudo make apply
EOF_SUMMARY
}

maintenance_action() {
    local action="$1"

    require_root

    case "$action" in
        apply)
            [[ -d /etc/postfix ]] || die "Postfix is not installed. Run make install first."
            backup_existing_configuration
            apply_postfix_configuration
            rebuild_postfix_maps
            postfix check
            systemctl reload postfix.service
            ;;
        maps)
            rebuild_postfix_maps
            ;;
        cert)
            deploy_courier_certificate
            ;;
        check)
            check_mail_stack
            ;;
        status)
            load_postfixer_config
            printf 'Role: %s\nHostname: %s\nMail domain: %s\nConfig: %s\n\n' \
                "$POSTFIXER_ROLE" "$POSTFIXER_HOSTNAME" "$POSTFIXER_MAIL_DOMAIN" "$POSTFIXER_CONFIG"
            systemctl --no-pager --plain is-active \
                postfix saslauthd postgrey opendkim opendmarc \
                courier-authdaemon courier-imap courier-imap-ssl courier-pop courier-pop-ssl 2>/dev/null || true
            ;;
        restart)
            enable_and_restart_services
            check_mail_stack
            ;;
        *)
            die "Unknown maintenance action: $action"
            ;;
    esac
}

usage() {
    cat <<'EOF_USAGE'
Usage:
  sudo bin/install.sh
  sudo bin/install.sh --apply
  sudo bin/install.sh --maps
  sudo bin/install.sh --cert
  sudo bin/install.sh --check
  sudo bin/install.sh --status
  sudo bin/install.sh --restart

Environment overrides:
  CERT_DOMAIN=mail.example.com
  ETC_POSTFIX_SOURCE=/path/to/etc-postfix
EOF_USAGE
}

main() {
    case "${1:-}" in
        "")
            full_install
            ;;
        --apply)
            maintenance_action apply
            ;;
        --maps)
            maintenance_action maps
            ;;
        --cert)
            maintenance_action cert
            ;;
        --check)
            maintenance_action check
            ;;
        --status)
            maintenance_action status
            ;;
        --restart)
            maintenance_action restart
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
}
