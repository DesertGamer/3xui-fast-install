#!/usr/bin/env bash
# Запускается на удалённом сервере. Создаёт архив и сохраняет в REMOTE_TMP.
set -euo pipefail

XUI_DIR="/root"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
REMOTE_TMP="/tmp/3xui_backup_${TIMESTAMP}.tar.gz"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Нативный x-ui хранит БД и настройки в /etc/x-ui (сертификат — в /var/lib/caddy ниже)
[[ -d /etc/x-ui ]] && cp -a /etc/x-ui "$TMP_DIR/etc-x-ui"

# Caddy: конфиг, сайт-заглушка и ACME-данные (сертификат)
if [[ -f /etc/caddy/Caddyfile ]]; then
    mkdir -p "$TMP_DIR/caddy-etc"
    cp /etc/caddy/Caddyfile "$TMP_DIR/caddy-etc/"
fi
[[ -d /var/www/html  ]] && cp -a /var/www/html  "$TMP_DIR/caddy-www"
[[ -d /var/lib/caddy ]] && cp -a /var/lib/caddy "$TMP_DIR/caddy-data"

[[ -f /root/3xui-credentials.txt ]] && cp /root/3xui-credentials.txt "$TMP_DIR/"

# UFW правила
if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    ufw status numbered > "$TMP_DIR/ufw-rules.txt"
    cp /etc/ufw/user.rules "$TMP_DIR/ufw-user.rules" 2>/dev/null || true
    cp /etc/ufw/user6.rules "$TMP_DIR/ufw-user6.rules" 2>/dev/null || true
fi

tar -czf "$REMOTE_TMP" -C "$TMP_DIR" .
