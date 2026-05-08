# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Шаг 3c: Установка Tor..."

# Idempotency: если Tor уже слушает нужный порт — пропускаем
if systemctl is-active --quiet tor 2>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${TOR_PORT}"; then
    info "Tor уже запущен на порту ${TOR_PORT}, пропускаем."
    exit 0
fi

if command -v apt-get &>/dev/null; then
    apt-get install -y -qq tor
elif command -v yum &>/dev/null; then
    yum install -y tor
else
    die "Не удалось установить Tor: пакетный менеджер не найден."
fi

# Минимальный torrc — только SOCKS5 на localhost
cat > /etc/tor/torrc <<EOF
SocksPort 127.0.0.1:${TOR_PORT}
SocksPolicy accept 127.0.0.1
Log notice syslog
DataDirectory /var/lib/tor
EOF

systemctl enable tor
systemctl restart tor

# Ждём запуска
for i in $(seq 1 30); do
    ss -tlnp 2>/dev/null | grep -q ":${TOR_PORT}" && break
    sleep 1
done

if ss -tlnp 2>/dev/null | grep -q ":${TOR_PORT}"; then
    success "Tor запущен. SOCKS5: 127.0.0.1:${TOR_PORT}"
else
    warn "Tor не слушает порт ${TOR_PORT}. Проверьте: systemctl status tor"
fi
