#!/usr/bin/env bash
set -Eeuo pipefail

# Deployment script for Ubuntu/Debian-based host.
# Expected files next to this script:
#   install-docker.sh
#   docker-compose.yml
#   nginx-configs.zip
#   fail2ban-configs.zip

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NGINX_ZIP="$SCRIPT_DIR/nginx-configs.zip"
FAIL2BAN_ZIP="$SCRIPT_DIR/fail2ban-configs.zip"
DOCKER_INSTALLER="$SCRIPT_DIR/install-docker.sh"
COMPOSE_SOURCE="$SCRIPT_DIR/docker-compose.yml"

NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_CONF_DIR="/etc/nginx/conf.d"
GEO_DIR="/etc/nginx/geo"
DOCKER_DIR="/opt/docker/3x-ui"
AMMO_DIR="/opt/ammo"
BACKUP_ROOT="/root/deploy-backups"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
TMP_DIR=""

GEO_BASE_URL="https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download"

log()  { printf '\n\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '\n\033[1;31m[ERROR]\033[0m Deployment failed at line %s (exit code %s).\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
    printf 'Backups, if created: %s\n' "$BACKUP_DIR" >&2
    exit "$rc"
}
trap on_error ERR
trap 'if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi' EXIT

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root: sudo ./deploy.sh"
}

check_sources() {
    local f
    for f in "$NGINX_ZIP" "$FAIL2BAN_ZIP" "$DOCKER_INSTALLER" "$COMPOSE_SOURCE"; do
        if [[ ! -f "$f" ]]; then
            die "Required file not found: $f"
        fi
    done

    unzip -tq "$NGINX_ZIP" >/dev/null || die "Invalid ZIP archive: $NGINX_ZIP"
    unzip -tq "$FAIL2BAN_ZIP" >/dev/null || die "Invalid ZIP archive: $FAIL2BAN_ZIP"
}

validate_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

install_packages() {
    log "Updating system packages"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

    log "Installing required packages"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ufw \
        ipset \
        nginx \
        certbot \
        python3-certbot-nginx \
        python3-setuptools \
        python3-pip \
        python3-systemd \
        libnginx-mod-http-geoip2 \
        git \
        curl \
        unzip \
        ca-certificates
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Docker and Docker Compose plugin are already installed; skipping installer"
        return 0
    fi

    log "Installing Docker using install-docker.sh"
    chmod +x "$DOCKER_INSTALLER"
    bash "$DOCKER_INSTALLER"
    command -v docker >/dev/null 2>&1 || die "Docker was not installed successfully"
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
}

create_directories() {
    log "Creating required directories"
    mkdir -p \
        "$DOCKER_DIR/db" \
        "$AMMO_DIR" \
        "$GEO_DIR" \
        "$NGINX_CONF_DIR" \
        /etc/fail2ban/filter.d \
        "$BACKUP_DIR"
}

backup_file() {
    local source="$1"
    local name="$2"

    # Missing files are normal on the first deployment.
    # Always return success so set -e does not abort the script.
    if [[ -e "$source" ]]; then
        cp -a "$source" "$BACKUP_DIR/$name"
    fi

    return 0
}

configure_main_nginx() {
    log "Stopping Nginx and updating $NGINX_CONF"
    systemctl stop nginx || true

    [[ -f "$NGINX_CONF" ]] || die "$NGINX_CONF does not exist"
    backup_file "$NGINX_CONF" "nginx.conf"

    # Comment active access_log directives while preserving indentation.
    sed -Ei 's@^([[:space:]]*)access_log([[:space:]]+)@\1# access_log\2@' "$NGINX_CONF"

    # Ensure the requested global error_log directive exists. error_log is valid
    # in the main context, so insert it before the events{} block when absent.
    if ! grep -Eq '^[[:space:]]*error_log[[:space:]]+/var/log/nginx/error\.log([[:space:]]|;)' "$NGINX_CONF"; then
        sed -i '/^[[:space:]]*events[[:space:]]*{/i error_log /var/log/nginx/error.log;\n' "$NGINX_CONF"
    fi
}

install_nginx_configs() {
    log "Installing prepared Nginx configuration"
    TMP_DIR="$(mktemp -d)"
    unzip -q "$NGINX_ZIP" -d "$TMP_DIR/nginx"

    local geoip_src logformat_src vless_src
    geoip_src="$(find "$TMP_DIR/nginx" -type f -name geoip2.conf -print -quit)"
    logformat_src="$(find "$TMP_DIR/nginx" -type f -name logformat.conf -print -quit)"
    vless_src="$(find "$TMP_DIR/nginx" -type f -name vless.conf -print -quit)"

    [[ -n "$geoip_src" && -n "$logformat_src" && -n "$vless_src" ]] || \
        die "nginx-configs.zip must contain geoip2.conf, logformat.conf and vless.conf"

    backup_file "$NGINX_CONF_DIR/geoip2.conf" "geoip2.conf"
    backup_file "$NGINX_CONF_DIR/logformat.conf" "logformat.conf"
    backup_file "$NGINX_CONF_DIR/vless.conf" "vless.conf"

    install -m 0644 "$geoip_src" "$NGINX_CONF_DIR/geoip2.conf"
    install -m 0644 "$logformat_src" "$NGINX_CONF_DIR/logformat.conf"
    install -m 0644 "$vless_src" "$NGINX_CONF_DIR/vless.conf"
}

set_domain() {
    local domain
    while true; do
        read -r -p "Enter domain for Nginx (example: cloud.example.com): " domain
        domain="${domain,,}"
        if validate_domain "$domain"; then
            break
        fi
        warn "Invalid domain name. Try again."
    done

    grep -q 'Domain_name' "$NGINX_CONF_DIR/vless.conf" || \
        die "Marker Domain_name was not found in $NGINX_CONF_DIR/vless.conf"

    sed -i "s/Domain_name/${domain}/g" "$NGINX_CONF_DIR/vless.conf"
    log "Nginx domain set to: $domain"
}

download_geoip() {
    log "Downloading latest GeoLite2 MMDB databases"
    local country_tmp="$GEO_DIR/GeoLite2-Country.mmdb.tmp"
    local city_tmp="$GEO_DIR/GeoLite2-City.mmdb.tmp"

    rm -f "$country_tmp" "$city_tmp"

    curl -fL --retry 3 --retry-delay 2 \
        "$GEO_BASE_URL/GeoLite2-Country.mmdb" \
        -o "$country_tmp"
    curl -fL --retry 3 --retry-delay 2 \
        "$GEO_BASE_URL/GeoLite2-City.mmdb" \
        -o "$city_tmp"

    [[ -s "$country_tmp" ]] || die "Downloaded GeoLite2-Country.mmdb is empty"
    [[ -s "$city_tmp" ]] || die "Downloaded GeoLite2-City.mmdb is empty"

    [[ $(stat -c %s "$country_tmp") -gt 1048576 ]] || die "GeoLite2-Country.mmdb download is unexpectedly small"
    [[ $(stat -c %s "$city_tmp") -gt 1048576 ]] || die "GeoLite2-City.mmdb download is unexpectedly small"

    mv -f "$country_tmp" "$GEO_DIR/GeoLite2-Country.mmdb"
    mv -f "$city_tmp" "$GEO_DIR/GeoLite2-City.mmdb"
    chmod 0644 "$GEO_DIR/GeoLite2-Country.mmdb" "$GEO_DIR/GeoLite2-City.mmdb"
}

validate_and_start_nginx() {
    log "Validating Nginx configuration"
    nginx -t

    log "Enabling and starting Nginx"
    systemctl enable nginx
    systemctl restart nginx
}

install_fail2ban() {
    log "Installing Fail2Ban from the official Git repository"

    local f2b_build_dir f2b_src
    f2b_build_dir="$(mktemp -d)"
    f2b_src="$f2b_build_dir/fail2ban"

    git clone --depth 1 https://github.com/fail2ban/fail2ban.git "$f2b_src"

    (
        cd "$f2b_src"
        python3 setup.py install

        install -m 0755 files/debian-initd /etc/init.d/fail2ban
    )

    update-rc.d fail2ban defaults

    command -v fail2ban-client >/dev/null 2>&1 || \
        die "Fail2Ban installation failed: fail2ban-client was not found"

    rm -rf "$f2b_build_dir"
}

configure_fail2ban() {
    log "Installing prepared Fail2Ban configuration"
    local f2b_tmp
    f2b_tmp="$(mktemp -d)"
    unzip -q "$FAIL2BAN_ZIP" -d "$f2b_tmp"

    local jail_src
    jail_src="$(find "$f2b_tmp" -type f \( -name jail.local -o -name jail.conf \) -print -quit)"
    [[ -n "$jail_src" ]] || die "Neither jail.local nor jail.conf was found in fail2ban-configs.zip"

    backup_file /etc/fail2ban/jail.local "fail2ban-jail.local"
    install -m 0644 "$jail_src" /etc/fail2ban/jail.local

    local filter count=0
    while IFS= read -r -d '' filter; do
        backup_file "/etc/fail2ban/filter.d/$(basename "$filter")" "fail2ban-filter-$(basename "$filter")"
        install -m 0644 "$filter" "/etc/fail2ban/filter.d/$(basename "$filter")"
        count=$((count + 1))
    done < <(find "$f2b_tmp" -type f -name 'nginx-*.conf' -print0)

    [[ "$count" -gt 0 ]] || die "No nginx-*.conf Fail2Ban filters found in archive"

    log "Validating Fail2Ban configuration"
    fail2ban-client -t

    log "Starting Fail2Ban"
    if service fail2ban status >/dev/null 2>&1; then
        service fail2ban restart
    else
        service fail2ban start
    fi

    rm -rf "$f2b_tmp"
}

install_and_start_3xui() {
    log "Installing docker-compose.yml for 3x-ui"
    backup_file "$DOCKER_DIR/docker-compose.yml" "docker-compose.yml"
    install -m 0644 "$COMPOSE_SOURCE" "$DOCKER_DIR/docker-compose.yml"

    log "Starting 3x-ui container"
    docker compose -f "$DOCKER_DIR/docker-compose.yml" --project-directory "$DOCKER_DIR" up -d
}

show_summary() {
    printf '\n============================================================\n'
    printf ' Deployment completed successfully\n'
    printf '============================================================\n'
    printf 'Nginx:     %s\n' "$(systemctl is-active nginx 2>/dev/null || true)"
    printf 'Fail2Ban:  %s\n' "$(systemctl is-active fail2ban 2>/dev/null || true)"
    printf 'Docker:    %s\n' "$(systemctl is-active docker 2>/dev/null || true)"
    printf 'UFW:       installed only; not configured/enabled by this script\n'
    printf 'ipset:     installed only; not configured by this script\n'
    printf 'Backups:   %s\n' "$BACKUP_DIR"
    printf '\n3x-ui container status:\n'
    docker compose -f "$DOCKER_DIR/docker-compose.yml" --project-directory "$DOCKER_DIR" ps || true
    printf '\nCertificate issuance and 3x-ui application configuration are intentionally left for manual setup.\n'
}

main() {
    require_root
    check_sources

    printf 'This script will update the system and deploy Nginx, GeoIP, Fail2Ban, Docker and 3x-ui.\n'
    printf 'UFW and ipset will only be installed; they will not be configured.\n\n'

    install_packages
    install_docker
    create_directories
    configure_main_nginx
    install_nginx_configs
    set_domain
    download_geoip
    validate_and_start_nginx
    install_fail2ban
    configure_fail2ban
    install_and_start_3xui
    show_summary
}

main "$@"
