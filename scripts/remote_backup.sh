#!/usr/bin/env bash
# Запускается на удалённом сервере. Создаёт архив и сохраняет в REMOTE_TMP.
set -euo pipefail

XUI_DIR="/root"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
REMOTE_TMP="/tmp/3xui_backup_${TIMESTAMP}.tar.gz"
COMPOSE_FILE="${XUI_DIR}/docker-compose.yml"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

[[ -d "${XUI_DIR}/db"   ]] && cp -a "${XUI_DIR}/db"   "$TMP_DIR/"
[[ -d "${XUI_DIR}/cert" ]] && cp -a "${XUI_DIR}/cert" "$TMP_DIR/"
[[ -f "$COMPOSE_FILE"   ]] && cp "$COMPOSE_FILE"       "$TMP_DIR/"

if [[ -d /opt/caddy ]]; then
    mkdir -p "$TMP_DIR/caddy"
    rsync -a --exclude='logs/' /opt/caddy/ "$TMP_DIR/caddy/"
fi

[[ -f /root/3xui-credentials.txt ]] && cp /root/3xui-credentials.txt "$TMP_DIR/"

# UFW правила
if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    ufw status numbered > "$TMP_DIR/ufw-rules.txt"
    cp /etc/ufw/user.rules "$TMP_DIR/ufw-user.rules" 2>/dev/null || true
    cp /etc/ufw/user6.rules "$TMP_DIR/ufw-user6.rules" 2>/dev/null || true
fi

tar -czf "$REMOTE_TMP" -C "$TMP_DIR" .
