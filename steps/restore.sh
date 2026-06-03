#!/usr/bin/env bash
# =============================================================================
# steps/restore.sh — серверное восстановление 3x-ui (запускается на сервере)
#
# Использование:
#   bash /root/3xui-setup/restore.sh                        # интерактивный выбор
#   bash /root/3xui-setup/restore.sh <файл.tar.gz>          # явно указать файл
#   bash /root/3xui-setup/restore.sh latest                 # последний бекап
#
# Архивы ищутся в /root/backups/
# =============================================================================
set -euo pipefail

XUI_DIR="/root"
BACKUP_DIR="${BACKUP_DIR:-/root/backups}"
COMPOSE_FILE="${XUI_DIR}/docker-compose.yml"

# ─── Выбор файла ─────────────────────────────────────────────────────────────
ARG="${1:-}"

if [[ "$ARG" == "latest" ]]; then
    BACKUP_FILE=$(ls -t "${BACKUP_DIR}"/3xui_*.tar.gz 2>/dev/null | head -1 || true)
    [[ -z "$BACKUP_FILE" ]] && { echo "[ERROR] Нет бекапов в ${BACKUP_DIR}"; exit 1; }
elif [[ -n "$ARG" ]]; then
    # Принимаем как абсолютный путь или имя файла в BACKUP_DIR
    if [[ -f "$ARG" ]]; then
        BACKUP_FILE="$ARG"
    elif [[ -f "${BACKUP_DIR}/${ARG}" ]]; then
        BACKUP_FILE="${BACKUP_DIR}/${ARG}"
    else
        echo "[ERROR] Файл не найден: $ARG"; exit 1
    fi
else
    # Интерактивный выбор
    mapfile -t backups < <(ls -t "${BACKUP_DIR}"/3xui_*.tar.gz 2>/dev/null || true)
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "[ERROR] Нет бекапов в ${BACKUP_DIR}"; exit 1
    fi
    echo "Доступные бекапы:"
    for i in "${!backups[@]}"; do
        size=$(du -sh "${backups[$i]}" 2>/dev/null | cut -f1)
        printf "  [%d] %s  (%s)\n" "$((i+1))" "$(basename "${backups[$i]}")" "$size"
    done
    read -rp "Выберите номер [1]: " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        echo "[ERROR] Неверный выбор."; exit 1
    fi
    BACKUP_FILE="${backups[$((choice-1))]}"
fi

echo
echo "[WARN] Текущие данные будут заменены содержимым бекапа."
echo "[WARN] Файл: ${BACKUP_FILE}"
read -rp "Продолжить? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "[INFO] Отменено."; exit 0; }

# ─── Восстановление ───────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[INFO] Останавливаю контейнеры..."
if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
fi
docker stop caddy-selfsteal 2>/dev/null || true

echo "[INFO] Распаковываю архив..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

if [[ -d "$TMP_DIR/db" ]]; then
    echo "[INFO] Восстанавливаю ${XUI_DIR}/db/..."
    mkdir -p "${XUI_DIR}/db"
    cp -a "$TMP_DIR/db/." "${XUI_DIR}/db/"
fi

if [[ -d "$TMP_DIR/cert" ]]; then
    echo "[INFO] Восстанавливаю ${XUI_DIR}/cert/..."
    mkdir -p "${XUI_DIR}/cert"
    cp -a "$TMP_DIR/cert/." "${XUI_DIR}/cert/"
    find "${XUI_DIR}/cert" \( -name "*.key" -o -name "privkey.pem" \) -exec chmod 600 {} +
    find "${XUI_DIR}/cert" \( \( -name "*.pem" ! -name "privkey.pem" \) -o -name "*.crt" \) -exec chmod 644 {} +
fi

if [[ -f "$TMP_DIR/docker-compose.yml" ]]; then
    echo "[INFO] Восстанавливаю docker-compose.yml..."
    cp "$TMP_DIR/docker-compose.yml" "$COMPOSE_FILE"
fi

if [[ -d "$TMP_DIR/caddy" ]]; then
    echo "[INFO] Восстанавливаю /opt/caddy/..."
    mkdir -p /opt/caddy
    cp -a "$TMP_DIR/caddy/." /opt/caddy/
fi

if [[ -f "$TMP_DIR/3xui-credentials.txt" ]]; then
    echo "[INFO] Восстанавливаю 3xui-credentials.txt..."
    cp "$TMP_DIR/3xui-credentials.txt" /root/3xui-credentials.txt
fi

echo "[INFO] Запускаю контейнеры..."
if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" up -d
fi

echo
echo "[OK] Восстановление завершено из: $(basename "$BACKUP_FILE")"
