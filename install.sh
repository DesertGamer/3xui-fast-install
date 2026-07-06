#!/usr/bin/env bash
# =============================================================================
# install.sh — запускает установку прямо на сервере без deploy.sh
#
# Использование на VPS:
#   DOMAIN=vpn.example.com bash install.sh
#   VLESS_PORT=8443 HY2_PORT=63001 DOMAIN=vpn.example.com bash install.sh
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="$SCRIPT_ROOT/steps"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Запустите скрипт от root: sudo bash install.sh"
[[ -d "$STEPS_DIR" ]] || die "Папка steps не найдена рядом с install.sh."
[[ -f "$STEPS_DIR/setup.sh" ]] || die "Файл steps/setup.sh не найден."

if [[ -z "${DOMAIN:-}" ]]; then
    read -rp "Введите домен (например vpn.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && die "Домен не может быть пустым."
    export DOMAIN
fi

chmod +x "$STEPS_DIR"/*.sh

if bash "$STEPS_DIR/setup.sh"; then
    true
else
    die "Установка не завершена. Лог: /root/3xui-install-full.log"
fi
