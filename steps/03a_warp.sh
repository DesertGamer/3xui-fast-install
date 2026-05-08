# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Шаг 3a: Установка WARP..."

install_warp_deb() {
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq
    apt-get install -y cloudflare-warp
}

install_warp_rpm() {
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
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
