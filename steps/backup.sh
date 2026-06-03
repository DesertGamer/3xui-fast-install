#!/usr/bin/env bash
# =============================================================================
# steps/backup.sh — серверный бекап 3x-ui (запускается прямо на сервере)
#
# Использование:
#   bash /root/3xui-setup/backup.sh
#   KEEP=10 bash /root/3xui-setup/backup.sh   # хранить последние N бекапов
#
# Архивы сохраняются в /root/backups/
# =============================================================================
set -euo pipefail

XUI_DIR="/root"
BACKUP_DIR="${BACKUP_DIR:-/root/backups}"
KEEP="${KEEP:-7}"            # сколько последних бекапов хранить
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="3xui_${TIMESTAMP}.tar.gz"
REMOTE_TMP="/tmp/3xui_backup_${TIMESTAMP}.tar.gz"
COMPOSE_FILE="${XUI_DIR}/docker-compose.yml"

mkdir -p "$BACKUP_DIR"

# ─── Сборка архива ────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$REMOTE_TMP"' EXIT

[[ -d "${XUI_DIR}/db"   ]] && cp -a "${XUI_DIR}/db"   "$TMP_DIR/"
[[ -d "${XUI_DIR}/cert" ]] && cp -a "${XUI_DIR}/cert" "$TMP_DIR/"
[[ -f "$COMPOSE_FILE"   ]] && cp    "$COMPOSE_FILE"    "$TMP_DIR/"

if [[ -d /opt/caddy ]]; then
    mkdir -p "$TMP_DIR/caddy"
    rsync -a --exclude='logs/' /opt/caddy/ "$TMP_DIR/caddy/"
fi

[[ -f /root/3xui-credentials.txt ]] && cp /root/3xui-credentials.txt "$TMP_DIR/"

if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    ufw status numbered > "$TMP_DIR/ufw-rules.txt"
    cp /etc/ufw/user.rules  "$TMP_DIR/ufw-user.rules"  2>/dev/null || true
    cp /etc/ufw/user6.rules "$TMP_DIR/ufw-user6.rules" 2>/dev/null || true
fi

tar -czf "$REMOTE_TMP" -C "$TMP_DIR" .
mv "$REMOTE_TMP" "${BACKUP_DIR}/${BACKUP_NAME}"
# Не даём trap удалить уже перемещённый файл
REMOTE_TMP="${BACKUP_DIR}/${BACKUP_NAME}"  # trap удалит только TMP_DIR

echo "[OK] Бекап сохранён: ${BACKUP_DIR}/${BACKUP_NAME}"
ls -lh "${BACKUP_DIR}/${BACKUP_NAME}"

# ─── Ротация старых бекапов ───────────────────────────────────────────────────
mapfile -t old_backups < <(ls -t "${BACKUP_DIR}"/3xui_*.tar.gz 2>/dev/null | tail -n +$(( KEEP + 1 )))
if [[ ${#old_backups[@]} -gt 0 ]]; then
    echo "[INFO] Удаляю старые бекапы (оставляю последние ${KEEP}):"
    for f in "${old_backups[@]}"; do
        rm -f "$f"
        echo "  - $f"
    done
fi

echo "[INFO] Бекапы в ${BACKUP_DIR}:"
ls -lht "${BACKUP_DIR}"/3xui_*.tar.gz 2>/dev/null || echo "  (нет бекапов)"
