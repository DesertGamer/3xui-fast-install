# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Установка Docker Engine и Docker Compose..."

get_linux_release() {
    if command -v lsb_release &>/dev/null; then
        printf '%s\n%s\n' "$(lsb_release -is | tr '[:upper:]' '[:lower:]')" "$(lsb_release -cs)"
    elif [[ -r /etc/os-release ]]; then
        . /etc/os-release
        printf '%s\n%s\n' "${ID:-}" "${VERSION_CODENAME:-}"
    fi
}

refresh_docker_keyring() {
    ensure_dns "Установка Docker" "download.docker.com"
    mkdir -p /etc/apt/keyrings

    local distro_id
    { read -r distro_id; read -r _; } < <(get_linux_release)

    local tmp_key
    tmp_key=$(mktemp)
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
        "https://download.docker.com/linux/${distro_id}/gpg" \
        -o "$tmp_key" \
        || die "Не удалось скачать ключ Docker."
    gpg --batch --yes --dearmor \
        -o /etc/apt/keyrings/docker.gpg \
        "$tmp_key" \
        || die "Не удалось записать keyring Docker."
    chmod 644 /etc/apt/keyrings/docker.gpg
    rm -f "$tmp_key"
}

write_docker_repo() {
    local distro_id="$1" codename="$2" arch
    arch=$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro_id} ${codename} stable
EOF
}

apt_update_with_docker_retry() {
    local output
    if output=$(apt-get update 2>&1); then
        printf '%s\n' "$output"
        return 0
    fi

    printf '%s\n' "$output"
    if grep -q "NO_PUBKEY" <<<"$output"; then
        warn "apt update вернул NO_PUBKEY для Docker, пересобираю keyring и повторяю..."
        refresh_docker_keyring
        output=$(apt-get update 2>&1) || {
            printf '%s\n' "$output"
            die "Не удалось обновить apt-кэш после восстановления keyring Docker."
        }
        printf '%s\n' "$output"
        return 0
    fi

    die "apt update для Docker не удался. Проверьте сеть и DNS."
}

install_docker_official() {
    ensure_dns "Установка Docker" "download.docker.com"

    local distro_id codename
    { read -r distro_id; read -r codename; } < <(get_linux_release)
    if [[ -z "$distro_id" || -z "$codename" ]]; then
        die "Не удалось определить Linux release для установки Docker."
    fi
    case "$distro_id" in
        debian|ubuntu) ;;
        *)
            die "Docker-репозиторий настроен только для Debian/Ubuntu, обнаружено: ${distro_id}."
            ;;
    esac

    if dpkg -s docker.io &>/dev/null; then
        warn "Обнаружен пакет docker.io. Удаляю его, чтобы установить официальный Docker Engine."
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc &>/dev/null || true
    fi

    refresh_docker_keyring
    write_docker_repo "$distro_id" "$codename"
    apt_update_with_docker_retry

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        || die "Не удалось установить Docker Engine из официального репозитория."

    systemctl enable --now docker
    systemctl is-active --quiet docker || die "Docker service не запустился после установки."
}

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    info "Docker и Docker Compose уже установлены, пропускаем."
else
    install_docker_official
    command -v docker &>/dev/null || die "docker binary не найден после установки."
    docker version &>/dev/null || die "docker version завершился с ошибкой после установки."
    docker compose version &>/dev/null || die "Docker Compose V2 недоступен после установки."
    success "Docker Engine и Docker Compose установлены."
fi
