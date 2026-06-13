# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Установка необходимых пакетов..."
if command_exists apt-get; then
    install_packages \
        curl gnupg lsb-release ca-certificates apt-transport-https \
        python3 sqlite3 apache2-utils dnsutils cron \
        || die "Не удалось установить необходимые пакеты для Debian/Ubuntu."
elif command_exists yum; then
    install_packages \
        curl python3 sqlite gnupg2 redhat-lsb-core ca-certificates bind-utils cronie \
        || die "Не удалось установить необходимые пакеты для RHEL/CentOS."
else
    die "Пакетный менеджер не найден. Нужен apt-get или yum."
fi

if command_exists systemctl; then
    if command_exists cron || command_exists crond; then
        systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
    fi
fi

command_exists crontab || die "Команда crontab не найдена после установки cron/cronie."

success "Необходимые пакеты установлены."
