#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOGFILE=/root/3xui-install.log
FULL_LOGFILE=/root/3xui-install-full.log
export LOGFILE FULL_LOGFILE
mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$FULL_LOGFILE")"
exec 3>&1 >>"$FULL_LOGFILE" 2>&1
printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] ══ start ══" >>"$FULL_LOGFILE"

# shellcheck source=steps/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# Все info/success шагов — только в лог, не в консоль.
export STEP_QUIET=1

trap '_on_err' ERR
_on_err() {
    printf '%s\n' "[$(date '+%T')] ABORT" >>"$FULL_LOGFILE"
    printf '\n  \033[31m✗\033[0m  \033[1mУстановка прервана.\033[0m Лог: %s\n' "$FULL_LOGFILE" >&3
    exit 1
}

# Шапка
printf '\n\033[1m  3x-ui installer\033[0m  \033[2m%s\033[0m\n' "$DOMAIN" >&3
printf '  \033[2m─────────────────────────────────\033[0m\n' >&3
if truthy "${LOW_POWER_MODE:-0}"; then
    printf '  \033[33m⚠\033[0m  Low-power mode\n' >&3
fi
printf '\n' >&3

_run_step() {
    local label="$1" script="$2"
    printf '%s\n' "── $label" >>"$LOGFILE"
    spinner_run "$label" bash "$script"
}

_run_step "Prereqs"      "$SCRIPT_DIR/prereqs.sh"
_run_step "BBR"          "$SCRIPT_DIR/bbr.sh"
_run_step "UFW"          "$SCRIPT_DIR/ufw.sh"
_run_step "WARP"         "$SCRIPT_DIR/warp.sh"
_run_step "Opera Proxy"  "$SCRIPT_DIR/opera-proxy.sh"
_run_step "Tor"          "$SCRIPT_DIR/tor.sh"

if truthy "${LOW_POWER_MODE:-0}"; then
    printf '  \033[2m-\033[0m  %-22s \033[2mskipped (low-power)\033[0m\n' "fail2ban" >&3
else
    _run_step "fail2ban"   "$SCRIPT_DIR/fail2ban.sh"
fi

_run_step "Selfsteal"    "$SCRIPT_DIR/selfsteal.sh"
_run_step "3x-ui"        "$SCRIPT_DIR/xui.sh"

# Сохраняем доступы
_cert_path=$(caddy_cert_file)
cat > /root/3xui-credentials.txt <<CREDS
Дата установки : $(date '+%Y-%m-%d %H:%M:%S')
Панель URL     : https://${DOMAIN}${PANEL_PATH}
Логин          : ${PANEL_USER}
Пароль         : ${PANEL_PASS}
Подписка       : https://${DOMAIN}${SUB_PATH}${CLIENT_SUB_ID}
Selfsteal      : https://${DOMAIN}
Сертификат     : ${_cert_path:-<каталог Caddy: ${CADDY_DATA_DIR}>}
WARP SOCKS5    : 127.0.0.1:${WARP_PROXY_PORT}
Opera SOCKS5   : 127.0.0.1:${OPERA_PROXY_PORT} (регион: ${OPERA_REGION})
Tor SOCKS5     : 127.0.0.1:${TOR_PORT}
CREDS
chmod 600 /root/3xui-credentials.txt

# Итог
printf '\n  \033[2m─────────────────────────────────\033[0m\n' >&3
printf '  \033[32m✓\033[0m  \033[1mГотово!\033[0m\n\n' >&3
printf '  \033[1mПанель:\033[0m   https://%s%s\n' "$DOMAIN" "$PANEL_PATH" >&3
printf '  \033[1mПодписка:\033[0m https://%s%s%s\n\n' "$DOMAIN" "$SUB_PATH" "$CLIENT_SUB_ID" >&3
printf '  \033[2mЛог: %s\033[0m\n\n' "$FULL_LOGFILE" >&3

printf '%s\n' "DONE" >>"$LOGFILE"
