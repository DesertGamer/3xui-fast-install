#!/usr/bin/env bash
# =============================================================================
# backup.sh — создаёт бекап 3x-ui с удалённого сервера и сохраняет локально
#
# Использование:
#   bash backup.sh <IP>
#   bash backup.sh <IP> -i ~/.ssh/id_rsa
#   SSH_PORT=2222 bash backup.sh <IP>
#   BACKUP_DIR=~/backups bash backup.sh <IP>
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/local_lib.sh
source "$SCRIPT_ROOT/scripts/local_lib.sh"

SERVER_IP="${1:-}"
[[ -z "$SERVER_IP" ]] && die "Укажите IP: bash backup.sh <IP>"
shift

SSH_EXTRA=("$@")
init_ssh_options

BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_ROOT}/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${SERVER_IP}_${TIMESTAMP}.tar.gz"
REMOTE_TMP="/tmp/3xui_backup_${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

XUI_DIR="/root"

# Устанавливаем ControlMaster — запрашивает пароль один раз
info "Подключаюсь к ${SERVER_IP}..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" true

# Копируем скрипт на сервер и запускаем
info "Создаю архив на сервере ${SERVER_IP}..."
scp "${SCP_OPTS[@]}" "${SCRIPT_ROOT}/scripts/remote_backup.sh" "${SSH_USER}@${SERVER_IP}:/tmp/remote_backup.sh" \
    || die "Не удалось скопировать remote_backup.sh"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    "TIMESTAMP=${TIMESTAMP} bash /tmp/remote_backup.sh; rm -f /tmp/remote_backup.sh" \
    || die "Ошибка при создании архива на сервере"

# Скачиваем архив
info "Скачиваю архив..."
scp "${SCP_OPTS[@]}" "${SSH_USER}@${SERVER_IP}:${REMOTE_TMP}" "${BACKUP_DIR}/${BACKUP_NAME}"

info "Удаляю временный файл на сервере..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "rm -f ${REMOTE_TMP}"

echo
success "Бекап сохранён: ${BACKUP_DIR}/${BACKUP_NAME}"
ls -lh "${BACKUP_DIR}/${BACKUP_NAME}"
