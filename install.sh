#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HIVEPANEL_INSTALL_DIR:-/opt/hivepanel}"
REPOSITORY="${HIVEPANEL_REPOSITORY:-HiveDevelopment/HivePanel}"
INSTALLER_REPOSITORY="${HIVEPANEL_INSTALLER_REPOSITORY:-HiveDevelopment/HivePanel-Installer}"
REQUESTED_VERSION="${HIVEPANEL_VERSION:-}"

log() {
    printf '\033[1;33m[HivePanel]\033[0m %s\n' "$1"
}

success() {
    printf '\033[1;32m[HivePanel]\033[0m %s\n' "$1"
}

warn() {
    printf '\033[1;33m[HivePanel] WARNING:\033[0m %s\n' "$1" >&2
}

fail() {
    printf '\033[1;31m[HivePanel] ERROR:\033[0m %s\n' "$1" >&2
    exit 1
}

random_hex() {
    openssl rand -hex "$1"
}

on_error() {
    local exit_code=$?
    local line_number="${BASH_LINENO[0]:-unknown}"
    local command="${BASH_COMMAND:-unknown}"

    printf '\n\033[1;31m[HivePanel] Installation failed.\033[0m\n' >&2
    printf 'Exit code: %s\n' "$exit_code" >&2
    printf 'Line: %s\n' "$line_number" >&2
    printf 'Command: %s\n\n' "$command" >&2

    exit "$exit_code"
}

trap on_error ERR

[[ "$EUID" -eq 0 ]] || fail "Run this installer as root or with sudo."

command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v openssl >/dev/null 2>&1 || fail "openssl is required."

if [[ ! -r /dev/tty ]]; then
    fail "An interactive terminal is required to install HivePanel."
fi

exec 3</dev/tty

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Docker and Docker Compose are already installed."

        if ! docker info >/dev/null 2>&1; then
            log "Starting Docker..."

            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable --now docker
            else
                fail "Docker is installed but is not running, and systemctl is unavailable."
            fi
        fi

        docker info >/dev/null 2>&1 || fail "Docker is installed but the Docker daemon is not responding."

        return
    fi

    log "Installing Docker Engine and Docker Compose..."

    if command -v dnf >/dev/null 2>&1; then
        dnf -y install \
            dnf-plugins-core \
            curl \
            ca-certificates

        dnf config-manager \
            --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo \
            >/dev/null 2>&1 || true

        dnf -y install \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update

        apt-get install -y \
            ca-certificates \
            curl \
            gnupg

        install -m 0755 -d /etc/apt/keyrings

        . /etc/os-release

        case "${ID:-}" in
            ubuntu|debian)
                ;;
            *)
                fail "Unsupported apt-based distribution: ${ID:-unknown}"
                ;;
        esac

        curl -fsSL \
            "https://download.docker.com/linux/${ID}/gpg" \
            -o /etc/apt/keyrings/docker.asc

        chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update

        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    else
        fail "Automatic Docker installation currently supports apt and dnf based Linux distributions."
    fi

    log "Starting Docker..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    else
        fail "Docker was installed, but systemctl is unavailable."
    fi

    command -v docker >/dev/null 2>&1 || fail "Docker was installed but the docker command is unavailable."
    docker compose version >/dev/null 2>&1 || fail "Docker Compose was installed but is unavailable."

    for attempt in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            break
        fi

        if [[ "$attempt" -eq 30 ]]; then
            fail "Docker was installed but the Docker daemon did not become ready."
        fi

        sleep 1
    done

    success "Docker Engine and Docker Compose installed successfully."
}

resolve_version() {
    if [[ -n "$REQUESTED_VERSION" ]]; then
        printf '%s' "${REQUESTED_VERSION#v}"
        return
    fi

    local tag

    tag="$(
        curl -fsSL \
            --retry 3 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: HivePanel-Installer' \
            "https://api.github.com/repos/${REPOSITORY}/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1
    )"

    [[ -n "$tag" ]] || fail "Could not determine the latest HivePanel release."

    printf '%s' "${tag#v}"
}

hivepanel_docker_state_exists() {
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^hivepanel-'; then
        return 0
    fi

    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q '^hivepanel_'; then
        return 0
    fi

    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q '^hivepanel_'; then
        return 0
    fi

    return 1
}

remove_hivepanel_docker_resources() {
    local containers
    local volumes
    local networks

    containers="$(
        docker ps -a \
            --format '{{.Names}}' \
            2>/dev/null \
        | grep '^hivepanel-' || true
    )"

    if [[ -n "$containers" ]]; then
        log "Removing existing HivePanel containers..."

        while IFS= read -r container; do
            [[ -n "$container" ]] || continue
            docker rm -f "$container" >/dev/null 2>&1 || true
        done <<< "$containers"
    fi

    volumes="$(
        docker volume ls \
            --format '{{.Name}}' \
            2>/dev/null \
        | grep '^hivepanel_' || true
    )"

    if [[ -n "$volumes" ]]; then
        log "Removing existing HivePanel data volumes..."

        while IFS= read -r volume; do
            [[ -n "$volume" ]] || continue
            docker volume rm -f "$volume" >/dev/null 2>&1 || true
        done <<< "$volumes"
    fi

    networks="$(
        docker network ls \
            --format '{{.Name}}' \
            2>/dev/null \
        | grep '^hivepanel_' || true
    )"

    if [[ -n "$networks" ]]; then
        log "Removing existing HivePanel Docker networks..."

        while IFS= read -r network; do
            [[ -n "$network" ]] || continue
            docker network rm "$network" >/dev/null 2>&1 || true
        done <<< "$networks"
    fi
}

handle_existing_installation() {
    local directory_exists=false
    local docker_state_exists=false
    local answer
    local confirmation

    if [[ -e "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
        directory_exists=true
    fi

    if hivepanel_docker_state_exists; then
        docker_state_exists=true
    fi

    if [[ "$directory_exists" == false && "$docker_state_exists" == false ]]; then
        return
    fi

    printf '\n'
    log "An existing or incomplete HivePanel installation was detected."
    printf '\n'

    if [[ "$directory_exists" == true ]]; then
        printf '  Installation directory: %s\n' "$INSTALL_DIR"
    fi

    if [[ "$docker_state_exists" == true ]]; then
        printf '  Existing HivePanel Docker resources were detected.\n'
    fi

    printf '\n'
    printf '\033[1;31mWARNING:\033[0m Reinstalling will permanently delete the existing HivePanel database and application data.\n'
    printf '\n'

    read -r -u 3 -p "Remove the existing installation and reinstall HivePanel? [y/N]: " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        fail "Installation cancelled. The existing HivePanel installation was not changed."
    fi

    printf '\n'
    read -r -u 3 -p "Type REINSTALL to confirm permanent deletion: " confirmation

    if [[ "$confirmation" != "REINSTALL" ]]; then
        fail "Reinstallation cancelled. The existing HivePanel installation was not changed."
    fi

    printf '\n'
    log "Removing existing HivePanel installation..."

    if [[ -f "${INSTALL_DIR}/compose.yaml" ]]; then
        log "Stopping existing HivePanel Compose project..."

        (
            cd "$INSTALL_DIR"
            docker compose down --volumes --remove-orphans || true
        )
    fi

    remove_hivepanel_docker_resources

    if [[ -d "$INSTALL_DIR" ]]; then
        log "Removing existing HivePanel files..."
        rm -rf "$INSTALL_DIR"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now hivepanel-update.path >/dev/null 2>&1 || true
        systemctl stop hivepanel-update.service >/dev/null 2>&1 || true
    fi

    rm -f \
        /usr/local/sbin/hivepanel-update \
        /etc/systemd/system/hivepanel-update.service \
        /etc/systemd/system/hivepanel-update.path

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    success "Previous HivePanel installation removed."
}

configure_firewall() {
    local configured=false

    if command -v firewall-cmd >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
            log "Configuring firewalld..."

            firewall-cmd \
                --permanent \
                --add-service=http \
                >/dev/null

            if [[ "$ENABLE_HTTPS" =~ ^[Yy]$ ]]; then
                firewall-cmd \
                    --permanent \
                    --add-service=https \
                    >/dev/null
            fi

            firewall-cmd --reload >/dev/null

            configured=true

            success "firewalld configured for HivePanel."
        fi
    fi

    if [[ "$configured" == false ]] && command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            log "Configuring UFW..."

            ufw allow 80/tcp >/dev/null

            if [[ "$ENABLE_HTTPS" =~ ^[Yy]$ ]]; then
                ufw allow 443/tcp >/dev/null
            fi

            configured=true

            success "UFW configured for HivePanel."
        fi
    fi

    if [[ "$configured" == false ]]; then
        log "No active supported host firewall detected."
    fi
}

wait_for_application() {
    log "Waiting for the HivePanel application container..."

    for attempt in $(seq 1 60); do
        if docker compose exec -T panel php artisan about >/dev/null 2>&1; then
            return
        fi

        if [[ "$attempt" -eq 60 ]]; then
            docker compose logs --tail=100 panel || true
            fail "The HivePanel application container did not become ready. Run: cd ${INSTALL_DIR} && docker compose logs panel"
        fi

        sleep 2
    done
}

wait_for_database() {
    log "Waiting for the HivePanel database..."

    for attempt in $(seq 1 60); do
        if docker compose exec -T mariadb mariadb-admin ping \
            -h 127.0.0.1 \
            -u root \
            "-p${DB_ROOT_PASSWORD}" \
            --silent \
            >/dev/null 2>&1
        then
            return
        fi

        if [[ "$attempt" -eq 60 ]]; then
            docker compose logs --tail=100 mariadb || true
            fail "MariaDB did not become ready."
        fi

        sleep 2
    done
}

printf '\n'
printf 'HivePanel Installer\n'
printf '===================\n'
printf '\n'

install_docker

handle_existing_installation

VERSION="$(resolve_version)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)(\.[0-9]+)?)?$ ]] || fail "Invalid HivePanel version: ${VERSION}"

TAG="v${VERSION}"

printf '\n'

read -r -u 3 -p "Panel domain (for example panel.example.com): " DOMAIN

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"

[[ -n "$DOMAIN" ]] || fail "A panel domain is required."

read -r -u 3 -p "Administrator name: " ADMIN_NAME

[[ -n "$ADMIN_NAME" ]] || fail "An administrator name is required."

read -r -u 3 -p "Administrator email: " ADMIN_EMAIL

[[ -n "$ADMIN_EMAIL" ]] || fail "An administrator email is required."

read -r -s -u 3 -p "Administrator password: " ADMIN_PASSWORD
printf '\n'

read -r -s -u 3 -p "Confirm administrator password: " ADMIN_PASSWORD_CONFIRM
printf '\n'

[[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]] || fail "Administrator passwords do not match."
[[ ${#ADMIN_PASSWORD} -ge 8 ]] || fail "Administrator password must be at least 8 characters."

read -r -u 3 -p "Enable Let's Encrypt HTTPS? [Y/n]: " ENABLE_HTTPS

ENABLE_HTTPS="${ENABLE_HTTPS:-Y}"

CERT_EMAIL=""
APP_SCHEME="http"

if [[ "$ENABLE_HTTPS" =~ ^[Yy]$ ]]; then
    APP_SCHEME="https"

    read -r -u 3 -p "Let's Encrypt email [$ADMIN_EMAIL]: " CERT_EMAIL

    CERT_EMAIL="${CERT_EMAIL:-$ADMIN_EMAIL}"
fi

configure_firewall

log "Installing HivePanel v${VERSION}..."

mkdir -p \
    "$INSTALL_DIR/runtime" \
    "$INSTALL_DIR/backups"

chown 33:33 "$INSTALL_DIR/runtime"
chmod 0770 "$INSTALL_DIR/runtime"

cd "$INSTALL_DIR"

RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${TAG}"

log "Downloading HivePanel deployment configuration..."

curl -fsSL \
    --retry 3 \
    "${RAW_BASE}/compose.yaml" \
    -o compose.yaml

APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
DB_PASSWORD="$(random_hex 24)"
DB_ROOT_PASSWORD="$(random_hex 32)"
REDIS_PASSWORD="$(random_hex 24)"

cat > .env <<ENV
HIVEPANEL_IMAGE=ghcr.io/hivedevelopment/hivepanel
HIVEPANEL_NGINX_IMAGE=ghcr.io/hivedevelopment/hivepanel-nginx
HIVEPANEL_VERSION=${VERSION}
HIVEPANEL_REPOSITORY=${REPOSITORY}
HIVEPANEL_UPDATE_REQUEST_PATH=/var/lib/hivepanel-host/update-request.json
HIVEPANEL_UPDATE_STATUS_PATH=/var/lib/hivepanel-host/update-status.json
PANEL_DOMAIN=${DOMAIN}
APP_NAME=HivePanel
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=${APP_SCHEME}://${DOMAIN}
APP_LOCALE=en
APP_FALLBACK_LOCALE=en
LOG_CHANNEL=daily
LOG_LEVEL=warning
DB_CONNECTION=mysql
DB_HOST=mariadb
DB_PORT=3306
DB_DATABASE=hivepanel
DB_USERNAME=hivepanel
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
SESSION_DRIVER=redis
SESSION_LIFETIME=120
CACHE_STORE=redis
QUEUE_CONNECTION=redis
REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_PORT=6379
BROADCAST_CONNECTION=log
FILESYSTEM_DISK=local
MAIL_MAILER=log
MAIL_FROM_ADDRESS=${ADMIN_EMAIL}
MAIL_FROM_NAME=HivePanel
VITE_APP_NAME=HivePanel
HTTP_PORT=80
HTTPS_PORT=443
ENV

chmod 0600 .env

log "Pulling HivePanel containers..."

docker compose pull

log "Starting database and Redis..."

docker compose up -d mariadb redis

wait_for_database

log "Starting HivePanel application..."

docker compose up -d panel

wait_for_application

log "Running database migrations..."

docker compose exec -T panel php artisan migrate --force

log "Optimising HivePanel..."

docker compose exec -T panel php artisan optimize

log "Creating administrator..."

docker compose exec \
    -T \
    -e HIVEPANEL_ADMIN_NAME="$ADMIN_NAME" \
    -e HIVEPANEL_ADMIN_EMAIL="$ADMIN_EMAIL" \
    -e HIVEPANEL_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    panel \
    php artisan hivepanel:create-admin

log "Starting background services..."

docker compose up -d queue scheduler

log "Starting Nginx..."

docker compose up -d --force-recreate nginx

log "Writing managed installation metadata..."

cat > "${INSTALL_DIR}/runtime/installation.json" <<JSON
{
  "managed": true,
  "method": "docker",
  "channel": "stable",
  "version": "${VERSION}",
  "repository": "${REPOSITORY}",
  "installer_repository": "${INSTALLER_REPOSITORY}",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

chown 33:33 "${INSTALL_DIR}/runtime/installation.json"
chmod 0660 "${INSTALL_DIR}/runtime/installation.json"

log "Installing the host update runner..."

INSTALLER_RAW="https://raw.githubusercontent.com/${INSTALLER_REPOSITORY}/main"

curl -fsSL \
    --retry 3 \
    "${INSTALLER_RAW}/host/hivepanel-update" \
    -o /usr/local/sbin/hivepanel-update

curl -fsSL \
    --retry 3 \
    "${INSTALLER_RAW}/host/hivepanel-update.service" \
    -o /etc/systemd/system/hivepanel-update.service

curl -fsSL \
    --retry 3 \
    "${INSTALLER_RAW}/host/hivepanel-update.path" \
    -o /etc/systemd/system/hivepanel-update.path

chmod 0755 /usr/local/sbin/hivepanel-update

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now hivepanel-update.path
else
    warn "systemd is unavailable. The HivePanel automatic update runner could not be enabled."
fi

if [[ "$ENABLE_HTTPS" =~ ^[Yy]$ ]]; then
    log "Requesting Let's Encrypt certificate..."

    if docker compose --profile tools run \
        --rm \
        certbot \
        certonly \
        --webroot \
        --webroot-path /var/www/certbot \
        --domain "$DOMAIN" \
        --email "$CERT_EMAIL" \
        --agree-tos \
        --no-eff-email
    then
        log "Let's Encrypt certificate issued."

        docker compose up -d --force-recreate nginx

        success "HTTPS enabled."
    else
        warn "Certificate request failed. HivePanel will remain available over HTTP until HTTPS is configured."

        APP_SCHEME="http"

        sed -i "s#^APP_URL=.*#APP_URL=http://${DOMAIN}#" .env

        log "Recreating HivePanel application services..."

        docker compose up -d --force-recreate panel queue scheduler

        wait_for_application

        docker compose up -d --force-recreate nginx
    fi
fi

# The panel container may receive a different Docker address when recreated.
# Recreating Nginx here ensures its FastCGI upstream points to the current
# HivePanel application container.
log "Finalising web services..."

docker compose up -d --force-recreate nginx

log "Checking HivePanel health..."

for attempt in $(seq 1 60); do
    if curl -fsS \
        -H "Host: ${DOMAIN}" \
        "http://127.0.0.1/up" \
        >/dev/null 2>&1
    then
        break
    fi

    if [[ "$attempt" -eq 60 ]]; then
        printf '\n'
        docker compose ps || true
        printf '\n'
        docker compose logs --tail=100 nginx panel || true

        fail "HivePanel started but did not pass its health check. Run: cd ${INSTALL_DIR} && docker compose logs"
    fi

    sleep 2
done

printf '\n'
printf '\033[1;32mHivePanel v%s installation complete.\033[0m\n' "$VERSION"
printf '\n'
printf 'Panel: %s://%s\n' "$APP_SCHEME" "$DOMAIN"
printf 'Install directory: %s\n' "$INSTALL_DIR"
printf 'Updates: Admin -> Updates\n'
printf '\n'