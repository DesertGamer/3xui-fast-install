# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Установка WARP..."

get_debian_codename() {
    if command -v lsb_release &>/dev/null; then
        lsb_release -cs
    elif [[ -r /etc/os-release ]]; then
        . /etc/os-release
        printf '%s' "${VERSION_CODENAME:-}"
    fi
}

refresh_warp_keyring() {
    ensure_dns "Установка WARP" "pkg.cloudflareclient.com"
    mkdir -p /usr/share/keyrings

    local tmp_key
    tmp_key=$(mktemp)
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
        https://pkg.cloudflareclient.com/pubkey.gpg \
        -o "$tmp_key" \
        || die "Не удалось скачать ключ Cloudflare WARP."
    gpg --batch --yes --dearmor \
        -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        "$tmp_key" \
        || die "Не удалось записать keyring Cloudflare WARP."
    chmod 644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f "$tmp_key"
}

write_warp_repo() {
    local codename="$1"
    cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
}

apt_update_with_warp_retry() {
    local output
    if output=$(apt-get update 2>&1); then
        printf '%s\n' "$output"
        return 0
    fi

    printf '%s\n' "$output"
    if grep -q "NO_PUBKEY" <<<"$output"; then
        warn "apt update вернул NO_PUBKEY для WARP, пересобираю keyring и повторяю..."
        refresh_warp_keyring
        output=$(apt-get update 2>&1) || {
            printf '%s\n' "$output"
            die "Не удалось обновить apt-кэш после восстановления keyring WARP."
        }
        printf '%s\n' "$output"
        return 0
    fi

    die "apt update для WARP не удался. Проверьте сеть и DNS."
}

install_warp_deb() {
    ensure_dns "Установка WARP" "pkg.cloudflareclient.com"

    local codename
    codename=$(get_debian_codename)
    if [[ -z "$codename" ]]; then
        die "Не удалось определить кодовое имя Debian/Ubuntu для установки WARP."
    fi

    apt-get update -qq
    apt-get install -y --no-install-recommends lsb-release ca-certificates apt-transport-https

    refresh_warp_keyring
    write_warp_repo "$codename"
    apt_update_with_warp_retry
    apt-get install -y cloudflare-warp
}

install_warp_rpm() {
    ensure_dns "Установка WARP" "pkg.cloudflareclient.com"
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
        https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
        -o /etc/yum.repos.d/cloudflare-warp.repo
    yum install -y cloudflare-warp
}

if command -v apt-get &>/dev/null; then
    install_warp_deb
elif command -v yum &>/dev/null; then
    install_warp_rpm
else
    die "Не удалось установить WARP: пакетный менеджер не найден (нужен apt или yum)."
fi

if ! command -v warp-cli &>/dev/null; then
    warn "warp-cli не найден: WARP не установлен. Пропускаем настройку WARP."
    exit 0
fi

systemctl enable --now warp-svc

if ! warp-cli --accept-tos registration show &>/dev/null; then
    warp-cli --accept-tos registration new
fi

warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port "$WARP_PROXY_PORT"
warp-cli --accept-tos connect

for i in $(seq 1 30); do
    status=$(warp-cli --accept-tos status 2>/dev/null || true)
    echo "$status" | grep -q "Connected" && break
    sleep 1
done

if echo "$status" | grep -q "Connected"; then
    success "WARP подключён. SOCKS5 proxy: 127.0.0.1:${WARP_PROXY_PORT}"
else
    warn "WARP установлен, но статус подключения неизвестен. Проверьте вручную: warp-cli status"
fi
