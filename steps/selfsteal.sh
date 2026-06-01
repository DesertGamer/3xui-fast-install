# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Установка Caddy selfsteal (SSL генерирует Caddy)..."

CADDY_CONTAINER="caddy-selfsteal"
mkdir -p "$CERT_DIR"

CERT_INSIDE="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN}/${DOMAIN}.crt"
KEY_INSIDE="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN}/${DOMAIN}.key"

info "Проверяю DNS: $DOMAIN → этот сервер..."
_server_ip=$(curl -fsSL -4 --connect-timeout 5 ifconfig.io 2>/dev/null \
           || curl -fsSL -4 --connect-timeout 5 icanhazip.com 2>/dev/null \
           || true)
_dns_a_records=$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
_dns_ip=$(printf '%s\n' "$_dns_a_records" | head -1)
_dns_ahosts=$(getent ahosts "$DOMAIN" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | uniq || true)
if [[ -z "$_dns_ip" && -n "$_dns_ahosts" ]]; then
    _dns_ip=$(printf '%s\n' "$_dns_ahosts" | head -1)
fi
if [[ -z "$_dns_ip" ]]; then
    die "DNS для $DOMAIN не разрешается. Убедитесь, что A-запись настроена. A-записи: $(printf '%s,' "$_dns_a_records" | sed 's/,$//') ahosts: $(printf '%s,' "$_dns_ahosts" | sed 's/,$//')"
fi
if [[ -n "$_server_ip" && "$_dns_ip" != "$_server_ip" ]]; then
    die "DNS для $DOMAIN указывает на $_dns_ip, а не на этот сервер ($_server_ip). Проверьте A-запись. A-записи: $(printf '%s,' "$_dns_a_records" | sed 's/,$//') ahosts: $(printf '%s,' "$_dns_ahosts" | sed 's/,$//')"
fi
success "DNS: $DOMAIN → $_dns_ip"

info "Запускаю selfsteal Caddy для домена $DOMAIN..."
selfsteal_tmp_dir=$(mktemp -d)
trap 'rm -rf "$selfsteal_tmp_dir"' EXIT
selfsteal_installer="${selfsteal_tmp_dir}/selfsteal.sh"
selfsteal_log="${selfsteal_tmp_dir}/selfsteal.log"

curl -fsSL https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh \
    -o "$selfsteal_installer" \
    || die "Не удалось скачать selfsteal installer."

# У upstream installer strict-mode иногда падает без полезной диагностики;
# --debug оставляет проверки, но не обрывает установку на безвредных командах.
if ! TERM=dumb bash "$selfsteal_installer" @ --debug --force --domain "$DOMAIN" install >"$selfsteal_log" 2>&1; then
    sed 's/^/[SELFSTEAL] /' "$selfsteal_log" | tail -n 80
    die "Ошибка установки selfsteal Caddy."
fi

info "Жду сертификат Let's Encrypt от Caddy (до 60 с)..."
_cert_found=0
for i in $(seq 1 60); do
    if docker exec "$CADDY_CONTAINER" test -f "$CERT_INSIDE" 2>/dev/null; then
        _cert_found=1; break
    fi
    sleep 1
done
# Fallback: Caddy может хранить cert по другому пути (ZeroSSL и др.)
if [[ "$_cert_found" -eq 0 ]]; then
    _alt=$(docker exec "$CADDY_CONTAINER" \
        find /data/caddy/certificates -name "${DOMAIN}.crt" 2>/dev/null | head -1 || true)
    if [[ -n "$_alt" ]]; then
        CERT_INSIDE="$_alt"; KEY_INSIDE="${_alt%.crt}.key"; _cert_found=1
    fi
fi
if [[ "$_cert_found" -eq 0 ]]; then
    _container_status=$(docker inspect --format '{{.State.Status}}' "$CADDY_CONTAINER" 2>/dev/null || echo "not_found")
    if [[ "$_container_status" == "not_found" ]]; then
        [[ -s "$selfsteal_log" ]] && sed 's/^/[SELFSTEAL] /' "$selfsteal_log" | tail -n 80
        die "Контейнер $CADDY_CONTAINER не создан. Selfsteal-инсталлер не запустил Caddy."
    fi
    [[ "$_container_status" != "running" ]] && \
        warn "Контейнер $CADDY_CONTAINER не запущен (статус: $_container_status)."

    # Caddy пишет в /var/log/caddy/access.log, docker logs почти пустой
    _caddy_logs=$(docker exec "$CADDY_CONTAINER" tail -n 100 /var/log/caddy/access.log 2>/dev/null \
        || docker logs --tail 100 "$CADDY_CONTAINER" 2>&1 || true)

    warn "Ошибки из лога Caddy:"
    echo "$_caddy_logs" | grep '"level":"error"' | \
        grep -oP '"(msg|error|detail)":"[^"]*"' | \
        grep -vE '"(msg|error|detail)":""' | sed 's/^/  /' || true

    if echo "$_caddy_logs" | grep -qiE "rateLimited|too many.*authorizations|retry after"; then
        _retry=$(echo "$_caddy_logs" | grep -oP 'retry after \K[0-9]{4}-[0-9-]+ [0-9:]+ UTC' | tail -1 || true)
        die "Rate limit Let's Encrypt для $DOMAIN.${_retry:+ Повторите после: $_retry (UTC).}
Решения: подождите или создайте другой поддомен."
    elif echo "$_caddy_logs" | grep -qiE "SERVFAIL|nameservers may be malfunctioning"; then
        die "DNS для $DOMAIN возвращает SERVFAIL — nameservers DuckDNS временно не отвечают.
Подождите 10-30 минут и повторите. Статус: https://www.duckdns.org/"
    elif echo "$_caddy_logs" | grep -qiE "no such host|NXDOMAIN|query timed out"; then
        die "DNS для $DOMAIN не разрешается (IP в DNS: $_dns_ip).
Проверьте A-запись и дождитесь распространения DNS."
    elif echo "$_caddy_logs" | grep -qiE "connection refused|i/o timeout|dial tcp.*:80"; then
        die "Порт 80/tcp недоступен снаружи.
Проверьте: ufw allow 80/tcp && ufw reload; порт не заблокирован провайдером."
    elif echo "$_caddy_logs" | grep -qiE "no route to host|network unreachable"; then
        die "Сервер не может достучаться до Let's Encrypt.
Проверьте: curl -v https://acme-v02.api.letsencrypt.org/directory"
    else
        die "Caddy не получил сертификат за 60 с. DNS: $DOMAIN → $_dns_ip. Контейнер: $_container_status."
    fi
fi

info "Копирую сертификат из Caddy на хост..."
docker cp "${CADDY_CONTAINER}:${CERT_INSIDE}" "$CERT_DIR/fullchain.pem" \
    || die "Не удалось скопировать сертификат из контейнера."
docker cp "${CADDY_CONTAINER}:${KEY_INSIDE}" "$CERT_DIR/privkey.pem" \
    || die "Не удалось скопировать приватный ключ из контейнера."
chmod 600 "$CERT_DIR/privkey.pem"
chmod 644 "$CERT_DIR/fullchain.pem"

RENEW_SCRIPT="/root/caddy-cert-sync.sh"
cat > "$RENEW_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
CADDY_CONTAINER="${CADDY_CONTAINER}"
CERT_DIR="${CERT_DIR}"
DOMAIN="${DOMAIN}"
CERT_INSIDE="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/\${DOMAIN}/\${DOMAIN}.crt"
KEY_INSIDE="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/\${DOMAIN}/\${DOMAIN}.key"

docker cp "\${CADDY_CONTAINER}:\${CERT_INSIDE}" "\${CERT_DIR}/fullchain.pem" 2>/dev/null || exit 1
docker cp "\${CADDY_CONTAINER}:\${KEY_INSIDE}"  "\${CERT_DIR}/privkey.pem"  2>/dev/null || exit 1
chmod 600 "\${CERT_DIR}/privkey.pem"
chmod 644 "\${CERT_DIR}/fullchain.pem"
docker restart 3xui_app 2>/dev/null || true
SCRIPT
chmod 700 "$RENEW_SCRIPT"

(crontab -l 2>/dev/null | grep -v "caddy-cert-sync" || true; echo "30 4 * * * $RENEW_SCRIPT") | crontab -

success "Selfsteal Caddy установлен. Сертификат: ${CERT_DIR}/fullchain.pem"
