# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Установка Docker и Docker Compose..."

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    info "Docker и Docker Compose уже установлены, пропускаем."
else
    # ── Docker: пакет docker.io из Ubuntu-репозиториев ───────────────────────
    # download.docker.com заблокирован на ряде VPS — используем ubuntu/docker.io
    if ! command -v docker &>/dev/null; then
        info "Устанавливаю docker.io из репозитория Ubuntu..."
        apt-get update -qq
        apt-get install -y -qq docker.io \
            || die "Не удалось установить Docker."
        systemctl enable --now docker
        success "Docker установлен."
    fi

    # ── Docker Compose V2: плагин из GitHub ──────────────────────────────────
    if ! docker compose version &>/dev/null 2>&1; then
        info "Скачиваю Docker Compose plugin с GitHub..."
        _compose_url=$(curl -fsSL --max-time 30 \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null \
            | grep -o '"browser_download_url": *"[^"]*docker-compose-linux-x86_64"' \
            | grep -o 'https://[^"]*' || true)
        if [[ -n "$_compose_url" ]]; then
            mkdir -p /usr/local/lib/docker/cli-plugins
            curl -fsSL --max-time 120 -o /usr/local/lib/docker/cli-plugins/docker-compose "$_compose_url" \
                || die "Не удалось скачать docker-compose с GitHub."
            chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        else
            die "Не удалось получить URL docker-compose с GitHub API."
        fi
    fi

    docker compose version &>/dev/null || die "Docker Compose V2 недоступен после установки."
    success "Docker и Docker Compose установлены."
fi

