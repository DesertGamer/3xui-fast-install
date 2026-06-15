#!/usr/bin/env bash
# =============================================================================
# restore.sh — восстанавливает 3x-ui из локального бекапа на сервер
#
# Использование:
#   bash restore.sh <IP> <файл_бекапа.tar.gz>
#   bash restore.sh <IP> <файл_бекапа.tar.gz> -i ~/.ssh/id_rsa
#   SSH_PORT=2222 bash restore.sh <IP> <файл_бекапа.tar.gz>
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/local_lib.sh
source "$SCRIPT_ROOT/scripts/local_lib.sh"

SERVER_IP="${1:-}"
BACKUP_FILE="${2:-}"
[[ -z "$SERVER_IP"   ]] && die "Укажите IP: bash restore.sh <IP> <backup.tar.gz>"
[[ -z "$BACKUP_FILE" ]] && die "Укажите файл бекапа: bash restore.sh <IP> <backup.tar.gz>"
[[ -f "$BACKUP_FILE" ]] || die "Файл не найден: $BACKUP_FILE"
shift 2

SSH_EXTRA=("$@")
init_ssh_options

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REMOTE_TMP="/tmp/3xui_restore_${TIMESTAMP}.tar.gz"

echo
warn "ВНИМАНИЕ: текущие данные на ${SERVER_IP} будут заменены содержимым бекапа."
warn "Файл: ${BACKUP_FILE}"
read -rp "Продолжить? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { info "Отменено."; exit 0; }

info "Загружаю архив на сервер..."
scp "${SCP_OPTS[@]}" "$BACKUP_FILE" "${SSH_USER}@${SERVER_IP}:${REMOTE_TMP}"

XUI_DIR="/root"

info "Восстанавливаю данные на сервере..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    XUI_DIR="${XUI_DIR}" REMOTE_TMP="${REMOTE_TMP}" bash <<'REMOTE'
set -euo pipefail

# Останавливаем сервисы
echo "[INFO] Останавливаю сервисы..."
systemctl stop x-ui 2>/dev/null || true
systemctl stop caddy 2>/dev/null || true

# Распаковываем во временную директорию
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
tar -xzf "$REMOTE_TMP" -C "$TMP_DIR"

# Восстанавливаем БД нативного x-ui (/etc/x-ui), с поддержкой старого формата (db/)
if [[ -d "$TMP_DIR/etc-x-ui" ]]; then
    echo "[INFO] Восстанавливаю /etc/x-ui/..."
    mkdir -p /etc/x-ui
    cp -a "$TMP_DIR/etc-x-ui/." /etc/x-ui/
elif [[ -d "$TMP_DIR/db" ]]; then
    echo "[INFO] Восстанавливаю БД из старого бекапа (db/) в /etc/x-ui/..."
    mkdir -p /etc/x-ui
    cp -a "$TMP_DIR/db/." /etc/x-ui/
fi

# Восстанавливаем сертификаты
if [[ -d "$TMP_DIR/cert" ]]; then
    echo "[INFO] Восстанавливаю ${XUI_DIR}/cert/..."
    mkdir -p "${XUI_DIR}/cert"
    cp -a "$TMP_DIR/cert/." "${XUI_DIR}/cert/"
    find "${XUI_DIR}/cert" \( -name "*.key" -o -name "privkey.pem" \) -print | xargs -r chmod 600
    find "${XUI_DIR}/cert" \( \( -name "*.pem" ! -name "privkey.pem" \) -o -name "*.crt" \) -print | xargs -r chmod 644
fi

# Восстанавливаем Caddy (конфиг, сайт-заглушка, ACME-данные)
if [[ -f "$TMP_DIR/caddy-etc/Caddyfile" ]]; then
    echo "[INFO] Восстанавливаю /etc/caddy/Caddyfile..."
    mkdir -p /etc/caddy
    cp "$TMP_DIR/caddy-etc/Caddyfile" /etc/caddy/Caddyfile
fi
if [[ -d "$TMP_DIR/caddy-www" ]]; then
    echo "[INFO] Восстанавливаю /var/www/html/..."
    mkdir -p /var/www/html
    cp -a "$TMP_DIR/caddy-www/." /var/www/html/
    id caddy &>/dev/null && chown -R caddy:caddy /var/www/html 2>/dev/null || true
fi
if [[ -d "$TMP_DIR/caddy-data" ]]; then
    echo "[INFO] Восстанавливаю /var/lib/caddy/ (сертификат ACME)..."
    mkdir -p /var/lib/caddy
    cp -a "$TMP_DIR/caddy-data/." /var/lib/caddy/
    id caddy &>/dev/null && chown -R caddy:caddy /var/lib/caddy 2>/dev/null || true
fi

# Восстанавливаем файл доступов
if [[ -f "$TMP_DIR/3xui-credentials.txt" ]]; then
    cp "$TMP_DIR/3xui-credentials.txt" /root/3xui-credentials.txt
    chmod 600 /root/3xui-credentials.txt
fi

# Восстанавливаем UFW правила
if [[ -f "$TMP_DIR/ufw-user.rules" ]] && command -v ufw &>/dev/null; then
    echo "[INFO] Восстанавливаю правила UFW..."
    cp "$TMP_DIR/ufw-user.rules"  /etc/ufw/user.rules
    [[ -f "$TMP_DIR/ufw-user6.rules" ]] && cp "$TMP_DIR/ufw-user6.rules" /etc/ufw/user6.rules
    ufw reload && echo "[OK] UFW правила восстановлены."
fi

# Стартуем сервисы
echo "[INFO] Запускаю сервисы..."
systemctl start caddy 2>/dev/null && echo "[OK] Caddy запущен." || echo "[WARN] не удалось запустить caddy (установлен ли он?)."
systemctl start x-ui 2>/dev/null && echo "[OK] 3x-ui запущен." || echo "[WARN] не удалось запустить x-ui (установлен ли он?)."

rm -f "$REMOTE_TMP"
echo "[OK] Восстановление завершено."
REMOTE

echo
success "Восстановление завершено."
