#!/usr/bin/env bash
# Sourced by the updater and repair tool. Compose retains the existing project.
HOST_HELPER="${HIVEPANEL_HOST_HELPER:-/usr/local/lib/hivepanel/hivepanel-host.py}"
env_value() { python3 "$HOST_HELPER" env "$INSTALL_DIR/.env" "$1"; }
status() { python3 "$HOST_HELPER" status "$STATUS_FILE" "$1" "${VERSION:-}" "$2" "${BACKUP_FILE:-}"; }
health_check() {
    local binding port domain
    domain="$(env_value PANEL_DOMAIN)" || return 1
    binding="$(docker compose port nginx 80 2>/dev/null | head -n1)" || return 1
    port="${binding##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port > 0 && 10#$port <= 65535 )) || return 1
    local address="${binding%:*}"
    case "$address" in
        0.0.0.0) address=127.0.0.1 ;;
        '[::]'|::) address='[::1]' ;;
        *:*) [[ "$address" == \[*\] ]] || address="[$address]" ;;
    esac
    local code
    code="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 10 --output /dev/null --write-out '%{http_code}' \
        -H "Host: ${domain}" "http://${address}:${port}/up" 2>/dev/null)" || return 1
    [[ "$code" == 200 ]]
}
refresh_nginx() {
    docker compose exec -T nginx nginx -t && docker compose exec -T nginx nginx -s reload
}
