#!/usr/bin/env bash
# =============================================================================
# deploy.sh — заливает steps/ на сервер и запускает setup.sh
#
# Использование:
#   bash deploy.sh <IP>
#   bash deploy.sh <IP> -i ~/.ssh/id_rsa   # явно указать ключ
#   SSH_PORT=2222 bash deploy.sh <IP>       # нестандартный порт
#   DOMAIN=vpn.example.com bash deploy.sh <IP>
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/local_lib.sh
source "$SCRIPT_ROOT/scripts/local_lib.sh"

# ─── Аргументы ────────────────────────────────────────────────────────────────
SERVER_IP="${1:-}"
[[ -z "$SERVER_IP" ]] && die "Укажите IP сервера: bash deploy.sh <IP>"
shift

REMOTE_DIR="${REMOTE_DIR:-/root/3xui-setup}"
SSH_EXTRA=("$@")
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
init_ssh_options

STEPS_DIR="$SCRIPT_ROOT/steps"

# ─── Домен ────────────────────────────────────────────────────────────────────
if [[ -z "${DOMAIN:-}" ]]; then
    read -rp "Введите домен (например vpn.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && die "Домен не может быть пустым."
fi

# Локальные переопределения должны попасть в удалённый setup.sh.
REMOTE_ENV_VARS=(
    DOMAIN
    PANEL_PORT PANEL_USER PANEL_PASS PANEL_PATH
    SUB_PORT SUB_PATH SUB_TITLE SUB_ANNOUNCE
    CLIENT_EMAIL CLIENT_UUID CLIENT_SUB_ID CLIENT_HY2_AUTH
    OPERA_REGION HY2_PORT HY2_HOP HY2_HOP_RANGE
    VLESS_PORT TRAFFIC_RESET
    LOCATION
)
remote_env_assignments=()
for var_name in "${REMOTE_ENV_VARS[@]}"; do
    var_value="${!var_name:-}"
    [[ -z "$var_value" ]] && continue
    remote_env_assignments+=("${var_name}=$(shell_quote "$var_value")")
done
remote_env_prefix="${remote_env_assignments[*]}"

# ─── Ожидание SSH ─────────────────────────────────────────────────────────────
info "Ожидаю SSH ${SSH_USER}@${SERVER_IP}:${SSH_PORT}..."
WAIT_MAX=30; WAIT_STEP=5; elapsed=0
while true; do
    ssh_error=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" 'exit 0' 2>&1) && break
    if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" <<<"$ssh_error"; then
        warn "SSH host key для ${SERVER_IP} изменился (сервер переустановлен?)."
        read -rp "Удалить старый ключ и продолжить? [Y/n] " _key_ans
        if [[ -z "$_key_ans" || "$(echo "$_key_ans" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
            ssh-keygen -R "${SERVER_IP}" 2>/dev/null || true
            info "Старый ключ удалён, повторяю подключение..."
            continue
        fi
        die "Прервано. Удалите вручную: ssh-keygen -R ${SERVER_IP}"
    fi
    (( elapsed >= WAIT_MAX )) && die "SSH недоступен после ${WAIT_MAX}с."
    warn "Нет соединения, повтор через ${WAIT_STEP}с... (${elapsed}/${WAIT_MAX}с)"
    sleep "$WAIT_STEP"
    (( elapsed += WAIT_STEP ))
done
success "SSH доступен."

# ─── Бэкап при повторном деплое ──────────────────────────────────────────────
_has_existing=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    'test -f /root/3xui-credentials.txt && echo yes || echo no' 2>/dev/null || echo no)
if [[ "$_has_existing" == "yes" ]]; then
    warn "На сервере обнаружена существующая установка."
    read -rp "Создать бэкап перед деплоем? [Y/n] " _bk_ask
    if [[ -z "$_bk_ask" || "$(echo "$_bk_ask" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
        if SSH_PORT="$SSH_PORT" SSH_USER="$SSH_USER" \
           bash "$SCRIPT_ROOT/backup.sh" "$SERVER_IP" ${SSH_EXTRA[@]+"${SSH_EXTRA[@]}"}; then
            success "Бэкап создан."
        else
            warn "Бэкап не удался."
            read -rp "Продолжить деплой без бэкапа? [Y/n] " _bk_ans
            [[ -z "$_bk_ans" || "$(echo "$_bk_ans" | tr '[:upper:]' '[:lower:]')" == "y" ]] || die "Прервано."
        fi
    else
        warn "Бэкап пропущен."
    fi
fi

# ─── Копирование ──────────────────────────────────────────────────────────────
echo
info "Копирую файлы → ${REMOTE_DIR}/..."
remote_dir_q=$(shell_quote "$REMOTE_DIR")
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "mkdir -p ${remote_dir_q}"
scp "${SCP_OPTS[@]}" "$STEPS_DIR"/*.sh "${SSH_USER}@${SERVER_IP}:${remote_dir_q}/"
success "Файлы скопированы."

# ─── Запуск ───────────────────────────────────────────────────────────────────
echo
info "Запускаю setup.sh на сервере (домен: ${DOMAIN})..."
echo

info "Прогресс ниже, подробный лог: /root/3xui-install-full.log (Ctrl+C — остановить установку)..."
echo

if ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    "find ${remote_dir_q} -name '*.sh' -exec chmod +x {} +; \
     rm -f /root/3xui-install.log /root/3xui-install-full.log; \
     touch /root/3xui-install.log; \
     ${remote_env_prefix} bash ${remote_dir_q}/setup.sh"; then
    echo
    success "Деплой завершён."

    # ─── Итог ─────────────────────────────────────────────────────────────────────
    echo
    info "Доступы:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "cat /root/3xui-credentials.txt 2>/dev/null || echo '(файл доступов не найден)'"

    # ─── Healthcheck ──────────────────────────────────────────────────────────
    # Проверяем ЛОКАЛЬНЫЙ HTTPS-бэкенд x-ui (минует hairpin NAT: курлить публичный
    # домен с самого сервера ненадёжно — многие VPS не маршрутизируют свой же IP).
    echo
    info "Проверяю доступность панели..."
    _hc_code=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" bash <<'HCHECK' 2>/dev/null || echo error
db=/etc/x-ui/x-ui.db
command -v sqlite3 >/dev/null 2>&1 || { echo no_sqlite; exit 0; }
[[ -f "$db" ]] || { echo no_db; exit 0; }
port=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
base=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null)
[[ -z "$port" ]] && { echo no_port; exit 0; }
curl -sk --max-time 15 "https://127.0.0.1:${port}${base}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo 000
HCHECK
    )
    if [[ "$_hc_code" =~ ^[23][0-9]{2}$ ]]; then
        success "Панель (локально) отвечает: HTTP ${_hc_code}. Снаружи открывайте по URL из доступов."
    elif [[ "$_hc_code" == no_* ]]; then
        warn "Healthcheck пропущен (${_hc_code}). Проверьте панель по URL из доступов вручную."
    else
        warn "Локальный бэкенд панели не отвечает (код: ${_hc_code}). Проверьте: systemctl status x-ui; journalctl -u x-ui -n 100"
    fi
else
    echo
    die "Деплой не завершён. Проверьте лог на сервере: /root/3xui-install-full.log"
fi
