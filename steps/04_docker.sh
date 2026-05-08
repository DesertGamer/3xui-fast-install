# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Шаг 4/7: Установка Docker и Docker Compose..."

if command -v docker &>/dev/null; then
    info "Docker уже установлен, пропускаем."
else
    bash <(curl -sSL https://get.docker.com) || die "Не удалось установить Docker."
    systemctl enable --now docker
    success "Docker установлен."
fi

if docker compose version &>/dev/null 2>&1; then
    info "Docker Compose plugin уже доступен, пропускаем."
else
    info "Устанавливаю docker-compose-plugin..."
    . /etc/os-release
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-compose-plugin \
        || die "Не удалось установить docker-compose-plugin."
    docker compose version &>/dev/null || die "Docker Compose V2 недоступен после установки плагина."
    success "Docker Compose plugin установлен."
fi

# ── fail2ban ──────────────────────────────────────────────────────────────────
if command -v fail2ban-server &>/dev/null; then
    info "fail2ban уже установлен, пропускаем."
else
    info "Устанавливаю fail2ban..."
    apt-get install -y -qq fail2ban \
        || warn "Не удалось установить fail2ban — пропускаю."
    command -v fail2ban-server &>/dev/null && {
        systemctl enable --now fail2ban
        success "fail2ban установлен и запущен."
    }
fi
