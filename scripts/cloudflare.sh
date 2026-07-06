#!/usr/bin/env bash
# =============================================================================
# cloudflare.sh — создаёт/обновляет A-запись домена в Cloudflare и ждёт
# пока DNS резолвится на нужный IP.
#
# Использование (вызывается из deploy.sh):
#   CF_API_TOKEN=xxx CF_ZONE_ID=xxx cf_setup_dns "$DOMAIN" "$SERVER_IP"
# =============================================================================

# cf_upsert_dns <domain> <ip> — создаёт или обновляет A-запись через Cloudflare API.
# Требует: CF_API_TOKEN, CF_ZONE_ID в окружении.
cf_upsert_dns() {
    local domain="$1" ip="$2"

    [[ -z "${CF_API_TOKEN:-}" ]] && die "CF_API_TOKEN не задан."
    [[ -z "${CF_ZONE_ID:-}"   ]] && die "CF_ZONE_ID не задан."

    local api="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
    local auth_header="Authorization: Bearer ${CF_API_TOKEN}"

    # Ищем существующую A-запись для домена
    local existing_id
    existing_id=$(curl -fsSL --connect-timeout 10 --max-time 15 \
        -H "$auth_header" -H "Content-Type: application/json" \
        "${api}?type=A&name=${domain}" \
        | grep -o '"id":"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' || true)

    if [[ -n "$existing_id" ]]; then
        info "Cloudflare: обновляю A-запись ${domain} → ${ip} (id: ${existing_id})"
        curl -fsSL --connect-timeout 10 --max-time 15 \
            -X PUT -H "$auth_header" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${domain}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}" \
            "${api}/${existing_id}" >/dev/null \
            || die "Cloudflare: не удалось обновить A-запись."
    else
        info "Cloudflare: создаю A-запись ${domain} → ${ip}"
        curl -fsSL --connect-timeout 10 --max-time 15 \
            -X POST -H "$auth_header" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${domain}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}" \
            "$api" >/dev/null \
            || die "Cloudflare: не удалось создать A-запись."
    fi

    success "Cloudflare: A-запись ${domain} → ${ip} установлена."
}

# cf_wait_dns <domain> <ip> — ждёт пока публичные резолверы вернут нужный IP.
# Опрашивает 1.1.1.1 и 8.8.8.8 каждые 5 секунд, таймаут 3 минуты.
cf_wait_dns() {
    local domain="$1" ip="$2"
    local waited=0 max=180 step=5 resolved

    info "Cloudflare: жду пока ${domain} резолвится в ${ip}..."
    while (( waited < max )); do
        resolved=$(dig +short A "$domain" @1.1.1.1 +time=3 +tries=1 2>/dev/null | grep -F "$ip" || true)
        if [[ -n "$resolved" ]]; then
            success "Cloudflare: ${domain} резолвится в ${ip} (через ${waited}с)."
            return 0
        fi
        sleep "$step"
        (( waited += step ))
        info "Cloudflare: ещё не резолвится, жду... (${waited}/${max}с)"
    done

    warn "Cloudflare: ${domain} не резолвится в ${ip} за ${max}с — продолжаю деплой, Caddy будет ждать сам."
}

# cf_setup_dns <domain> <ip> — точка входа: upsert + wait.
cf_setup_dns() {
    local domain="$1" ip="$2"
    cf_upsert_dns "$domain" "$ip"
    cf_wait_dns   "$domain" "$ip"
}
