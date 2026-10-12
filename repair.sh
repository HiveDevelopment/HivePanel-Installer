#!/usr/bin/env bash
set -Eeuo pipefail
INSTALL_DIR="${HIVEPANEL_INSTALL_DIR:-/opt/hivepanel}"
INSTALLER_REPOSITORY="${HIVEPANEL_INSTALLER_REPOSITORY:-HiveDevelopment/HivePanel-Installer}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install_host_tools() {
    local stage name
    [[ "$INSTALL_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Install directory must be an absolute path without spaces or systemd special characters.' >&2; return 1; }
    command -v python3 >/dev/null || { echo 'python3 is required for host update tools.' >&2; return 1; }
    command -v flock >/dev/null || { echo 'flock (util-linux) is required.' >&2; return 1; }
    command -v systemctl >/dev/null || { echo 'systemd is required for the Linux host updater.' >&2; return 1; }
    stage="$(mktemp -d)"
    for name in hivepanel-update hivepanel-common.sh hivepanel-host.py; do
        if [[ -f "$SCRIPT_DIR/host/$name" ]]; then
            cp "$SCRIPT_DIR/host/$name" "$stage/$name" || { rm -rf "$stage"; return 1; }
        else
            curl -fsSL --retry 3 "https://raw.githubusercontent.com/${INSTALLER_REPOSITORY}/main/host/${name}" -o "$stage/$name" || { rm -rf "$stage"; return 1; }
        fi
    done
    if ! { bash -n "$stage/hivepanel-update" && bash -n "$stage/hivepanel-common.sh" && python3 - "$stage/hivepanel-host.py" <<'PY'
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text())
PY
    }; then rm -rf "$stage"; return 1; fi
    # Do not replace scripts while an update is running.
    if systemctl is-active --quiet hivepanel-update.service; then
        echo 'An update is running. Wait for it to finish before repairing host tools.' >&2
        rm -rf "$stage"
        return 1
    fi
    install -d -m 0755 /usr/local/lib/hivepanel
    install -m 0755 "$stage/hivepanel-update" /usr/local/sbin/hivepanel-update
    install -m 0644 "$stage/hivepanel-common.sh" "$stage/hivepanel-host.py" /usr/local/lib/hivepanel/
    cat > /etc/systemd/system/hivepanel-update.service <<UNIT
[Unit]
Description=HivePanel Update Runner
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hivepanel-update
Environment=HIVEPANEL_INSTALL_DIR=${INSTALL_DIR}
TimeoutStartSec=infinity
UMask=0077
UNIT
    cat > /etc/systemd/system/hivepanel-update.path <<UNIT
[Unit]
Description=Watch for approved HivePanel update requests

[Path]
PathExists=${INSTALL_DIR}/runtime/update-request.json
Unit=hivepanel-update.service

[Install]
WantedBy=multi-user.target
UNIT
    rm -rf "$stage"
    systemctl daemon-reload
    systemctl reset-failed hivepanel-update.service hivepanel-update.path || true
    systemctl enable --now hivepanel-update.path
}

repair_main() {
    local check=false yes=false issues=0 name id state stamp archive backup_dir watcher=false
    for name in "$@"; do
        case "$name" in
            --check) check=true ;;
            --yes) yes=true ;;
            *) echo "Usage: repair.sh [--check] [--yes]" >&2; return 2 ;;
        esac
    done
    [[ "$EUID" -eq 0 ]] || { echo 'Run repair as root.' >&2; return 1; }
    [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/.env" && -f "$INSTALL_DIR/compose.yaml" ]] || { echo 'Existing .env and compose.yaml are required. Repair will not invent credentials or replace missing configuration.' >&2; return 1; }
    cd "$INSTALL_DIR"
    command -v docker >/dev/null && docker compose version >/dev/null && docker info >/dev/null || { echo 'Docker/Compose is missing or the daemon is unavailable. Start or install Docker first; repair will not install packages or alter daemon settings.' >&2; return 1; }
    command -v python3 >/dev/null && command -v flock >/dev/null && command -v systemctl >/dev/null || { echo 'python3, flock and systemd are required.' >&2; return 1; }
    docker compose config --quiet || { echo 'Compose/.env validation failed. Repair will not overwrite configuration.' >&2; return 1; }
    local services
    services="$(docker compose config --services)"
    for name in panel queue scheduler nginx mariadb redis; do
        if ! [[ $'\n'"$services"$'\n' == *$'\n'"$name"$'\n'* ]]; then
            echo "Required Compose service missing: $name" >&2; return 1
        fi
    done
    echo 'Configuration is valid. Diagnosing existing services:'
    docker compose ps -a
    for name in panel queue scheduler nginx mariadb redis; do
        id="$(docker compose ps -a -q "$name")"
        if [[ -z "$id" ]]; then echo "$name: missing"; issues=$((issues + 1)); continue; fi
        state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")"
        echo "$name: $state"
        if [[ "$state" != running* || "$state" == *unhealthy* ]]; then issues=$((issues + 1)); fi
    done
    for name in runtime backups; do
        [[ -d "$name" ]] || { echo "Missing directory: $name"; issues=$((issues + 1)); }
    done
    if [[ ! -x /usr/local/sbin/hivepanel-update || ! -f /usr/local/lib/hivepanel/hivepanel-host.py ]] || ! systemctl is-active --quiet hivepanel-update.path; then
        echo 'Host update tooling or watcher needs repair.'; issues=$((issues + 1))
    fi
    # Use bundled/current helpers without installing anything in check mode.
    if [[ -f "$SCRIPT_DIR/host/hivepanel-common.sh" ]]; then
        HIVEPANEL_HOST_HELPER="$SCRIPT_DIR/host/hivepanel-host.py"
        source "$SCRIPT_DIR/host/hivepanel-common.sh"
    elif [[ -f /usr/local/lib/hivepanel/hivepanel-common.sh ]]; then
        source /usr/local/lib/hivepanel/hivepanel-common.sh
    else
        echo 'HTTP health check unavailable until host tools are repaired.'
    fi
    if [[ -f "${HOST_HELPER:-}" ]]; then
        python3 "$HOST_HELPER" validate-env .env || { echo 'Required environment values need manual correction; secrets were not changed.' >&2; return 1; }
    else
        for name in HIVEPANEL_VERSION PANEL_DOMAIN APP_KEY DB_PASSWORD DB_ROOT_PASSWORD REDIS_PASSWORD; do
            if ! grep -Eq "^${name}=.+" .env; then echo "Required environment value missing: $name" >&2; return 1; fi
        done
    fi
    if declare -F health_check >/dev/null; then
        health_check || { echo 'Panel HTTP health check failed.'; issues=$((issues + 1)); }
    fi
    if ! docker compose exec -T panel php -r 'require "vendor/autoload.php"; $app=require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap(); Illuminate\Support\Facades\DB::select("SELECT 1"); Illuminate\Support\Facades\Redis::connection()->ping();' >/dev/null 2>&1; then
        echo 'Application database/Redis connectivity check failed.'; issues=$((issues + 1))
    fi
    docker compose exec -T nginx nginx -t || { echo 'Nginx configuration needs manual correction.'; issues=$((issues + 1)); }
    if [[ "$check" == true ]]; then
        echo "Diagnostic check complete: $issues issue(s). No changes applied."
        (( issues == 0 )); return
    fi
    cat <<'PLAN'
Repair plan:
  Back up host tools and systemd units; preserve .env and Compose unchanged.
  Stop the watcher; archive any pending request without replaying it.
  Recreate runtime/backups directories and fix runtime ownership for UID 33.
  Install corrected host tools and units, then re-enable the watcher.
  Start missing/stopped containers using existing images/configuration.
  Restart only containers reported unhealthy; validate and reload Nginx.
  Check panel HTTP health and application database/Redis connectivity.
No migrations, volume deletion, image pulls, secret regeneration or database restore.
PLAN
    if [[ "$yes" != true ]]; then
        local answer
        read -r -p 'Apply this repair? [y/N]: ' answer </dev/tty
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
    fi
    REPAIR_BACKUP_DIR=""
    repair_exit() {
        local result=$?
        if (( result != 0 )); then
            printf 'Repair did not complete. Configuration/data were retained; inspect the reported error and watcher state before retrying.\n' >&2
            [[ -z "$REPAIR_BACKUP_DIR" ]] || printf 'Previous host configuration: %s\n' "$REPAIR_BACKUP_DIR" >&2
        fi
    }
    trap repair_exit EXIT
    # Prevent an old PathExists loop starting another update while repairing.
    systemctl is-active --quiet hivepanel-update.path && watcher=true
    systemctl stop hivepanel-update.path
    if systemctl is-active --quiet hivepanel-update.service; then
        [[ "$watcher" == false ]] || systemctl start hivepanel-update.path
        echo 'Update runner is active. Wait for completion; repair did not interrupt it.' >&2
        return 1
    fi
    mkdir -p runtime backups backups/update-history
    exec 8>backups/update.lock
    if ! flock -n 8; then
        [[ "$watcher" == false ]] || systemctl start hivepanel-update.path
        echo 'Another update/repair holds the lock.' >&2; return 1
    fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    backup_dir="$INSTALL_DIR/backups/repair-${stamp}"
    mkdir -m 0700 "$backup_dir"
    REPAIR_BACKUP_DIR="$backup_dir"
    for name in /usr/local/sbin/hivepanel-update /usr/local/lib/hivepanel /etc/systemd/system/hivepanel-update.service /etc/systemd/system/hivepanel-update.path; do
        [[ ! -e "$name" ]] || cp -a --parents "$name" "$backup_dir/"
    done
    cp -p .env compose.yaml "$backup_dir/"
    chmod 0700 backups backups/update-history
    chown 33:33 runtime
    chmod 0770 runtime
    if [[ -e runtime/update-request.json ]]; then
        archive="$INSTALL_DIR/backups/update-history/repair-${stamp}.json"
        mv runtime/update-request.json "$archive"
        if [[ ! -L "$archive" ]]; then chmod 0600 "$archive"; fi
        echo "Pending request retained at $archive. Submit a fresh request after repair."
        if declare -F status >/dev/null; then
            STATUS_FILE="$INSTALL_DIR/runtime/update-status.json"; VERSION=""; BACKUP_FILE=""
            status failed 'Pending update was cancelled by host repair; submit a fresh request to retry.'
        fi
    fi
    for name in update-status.json installation.json; do
        if [[ -f "runtime/$name" && ! -L "runtime/$name" ]]; then chown 33:33 "runtime/$name"; chmod 0660 "runtime/$name"; fi
    done
    install_host_tools
    unset HIVEPANEL_HOST_HELPER
    source /usr/local/lib/hivepanel/hivepanel-common.sh
    docker compose up -d --no-recreate --pull never mariadb redis panel queue scheduler nginx
    for name in mariadb redis panel queue scheduler nginx; do
        id="$(docker compose ps -q "$name")"
        [[ -n "$id" ]] || continue
        state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")"
        if [[ "$state" == unhealthy ]]; then docker compose restart "$name"; fi
    done
    for name in $(seq 1 30); do
        docker compose exec -T panel php artisan about >/dev/null 2>&1 && break
        [[ "$name" -lt 30 ]] || { echo 'Panel readiness failed; inspect Compose logs.' >&2; return 1; }
        sleep 2
    done
    refresh_nginx || { echo 'Nginx configuration is invalid; existing configuration retained for manual correction.' >&2; return 1; }
    for name in $(seq 1 30); do
        health_check && break
        [[ "$name" -lt 30 ]] || { echo 'HTTP health check still fails; inspect Nginx/panel logs.' >&2; return 1; }
        sleep 2
    done
    docker compose exec -T panel php -r 'require "vendor/autoload.php"; $app=require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap(); Illuminate\Support\Facades\DB::select("SELECT 1"); Illuminate\Support\Facades\Redis::connection()->ping();'
    echo "Repair complete. Previous host configuration retained in $backup_dir."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then repair_main "$@"; fi
