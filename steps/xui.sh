# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Установка 3x-ui..."

XUI_ARCH=$(xui_arch)
XUI_TARBALL="x-ui-linux-${XUI_ARCH}.tar.gz"
# XUI_VERSION=latest → /releases/latest/download (без тега); иначе пин по тегу vX.Y.Z
if [[ "${XUI_VERSION}" == "latest" ]]; then
    XUI_URL="https://github.com/MHSanaei/3x-ui/releases/latest/download/${XUI_TARBALL}"
else
    XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v${XUI_VERSION}/${XUI_TARBALL}"
fi
XRAY_BIN="${XUI_NATIVE_DIR}/bin/xray-linux-${XUI_ARCH}"

ensure_dns "Скачивание 3x-ui" "github.com"
ensure_dns "Скачивание 3x-ui" "objects.githubusercontent.com"
ensure_dns "Скачивание 3x-ui" "release-assets.githubusercontent.com"

mkdir -p "$XUI_DB_DIR"

XUI_XRAY_LOG_LEVEL="${XUI_LOG_LEVEL:-info}"
if truthy "${LOW_POWER_MODE:-0}"; then
    XUI_XRAY_LOG_LEVEL="${XUI_LOG_LEVEL:-warning}"
fi

# Останавливаем сервис, если уже установлен (идемпотентная переустановка)
systemctl stop x-ui 2>/dev/null || true

# ── Скачивание релиза с ретраями ─────────────────────────────────────────────
xui_tmp=$(mktemp -d)
trap 'rm -rf "$xui_tmp"' EXIT

_dl_retries=3
for _dl_attempt in $(seq 1 "$_dl_retries"); do
    curl -fL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
        "$XUI_URL" -o "${xui_tmp}/${XUI_TARBALL}" && break
    if [[ "$_dl_attempt" -eq "$_dl_retries" ]]; then
        die "Не удалось скачать ${XUI_TARBALL} после ${_dl_retries} попыток (${XUI_URL})."
    fi
    warn "Попытка ${_dl_attempt}/${_dl_retries} скачать x-ui не удалась, повтор через 10с..."
    sleep 10
done

# ── Распаковка в /usr/local/x-ui ─────────────────────────────────────────────
tar -xzf "${xui_tmp}/${XUI_TARBALL}" -C "$xui_tmp" \
    || die "Не удалось распаковать ${XUI_TARBALL}."
[[ -d "${xui_tmp}/x-ui" ]] || die "В архиве x-ui нет ожидаемой папки x-ui/."

rm -rf "$XUI_NATIVE_DIR"
mv "${xui_tmp}/x-ui" "$XUI_NATIVE_DIR"
chmod +x "${XUI_NATIVE_DIR}/x-ui" "$XRAY_BIN" 2>/dev/null || true
[[ -x "$XRAY_BIN" ]] || die "Бинарь xray не найден: ${XRAY_BIN}."

# Менеджер-скрипт x-ui для пользователя (start/stop/restart/settings)
if [[ -f "${XUI_NATIVE_DIR}/x-ui.sh" ]]; then
    cp -f "${XUI_NATIVE_DIR}/x-ui.sh" /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
fi

# ── systemd-сервис ───────────────────────────────────────────────────────────
if [[ -f "${XUI_NATIVE_DIR}/x-ui.service" ]]; then
    cp -f "${XUI_NATIVE_DIR}/x-ui.service" /etc/systemd/system/x-ui.service
else
    cat > /etc/systemd/system/x-ui.service <<'UNIT'
[Unit]
Description=x-ui Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
fi

# Drop-in с переменными окружения (и лимитом CPU в LOW_POWER_MODE)
mkdir -p /etc/systemd/system/x-ui.service.d
{
    printf '[Service]\n'
    printf 'Environment=XRAY_VMESS_AEAD_FORCED=false\n'
    printf 'Environment=TZ=%s\n' "${TZ:-Europe/Moscow}"
    if truthy "${LOW_POWER_MODE:-0}" && [[ -n "${XUI_CPUS_LIMIT:-}" ]]; then
        printf 'CPUQuota=%s%%\n' "$(awk "BEGIN{printf \"%d\", ${XUI_CPUS_LIMIT}*100}")"
    fi
} > /etc/systemd/system/x-ui.service.d/override.conf

systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1 || true

# ── Первый старт: x-ui создаёт БД /etc/x-ui/x-ui.db ──────────────────────────
systemctl restart x-ui || die "Не удалось запустить сервис x-ui."

for i in $(seq 1 30); do
    [[ -f "$XUI_DB" ]] && break
    sleep 1
done
[[ -f "$XUI_DB" ]] || die "БД x-ui не появилась в ${XUI_DB} за 30 секунд."

# ── Reality-ключи (локальный бинарь xray) ────────────────────────────────────
REALITY_KEYS=""
for i in $(seq 1 10); do
    REALITY_KEYS=$("$XRAY_BIN" x25519 2>/dev/null || true)
    [[ "$REALITY_KEYS" == *"PrivateKey"* ]] && break
    REALITY_KEYS=""
    sleep 2
done
if [[ -z "$REALITY_KEYS" ]]; then
    warn "Вывод xray x25519:"
    "$XRAY_BIN" x25519 2>&1 || true
    die "Не удалось сгенерировать Reality-ключи (xray x25519)."
fi
REALITY_PRIVATE=$(echo "$REALITY_KEYS" | awk '/PrivateKey:/ {print $2}' | tr -d '[:space:]')
REALITY_PUBLIC=$(echo "$REALITY_KEYS"  | awk '/Password \(PublicKey\):/ {print $NF}' | tr -d '[:space:]')
[[ -z "$REALITY_PRIVATE" ]] && die "Не удалось извлечь приватный ключ: $REALITY_KEYS"
[[ -z "$REALITY_PUBLIC"  ]] && die "Не удалось извлечь публичный ключ: $REALITY_KEYS"

# Останавливаем сервис для прямой правки БД
systemctl stop x-ui || die "Не удалось остановить сервис x-ui перед правкой БД."

# ── sqlite3 ──────────────────────────────────────────────────────────────────
if ! command_exists sqlite3; then
    die "sqlite3 не найден. Установите prereqs или добавьте sqlite3 вручную."
fi

# ShortIds
SIDS_JSON=""
for n in 7 2 5 8 6 3 1 4; do
    sid=$(openssl rand -hex "$n")
    SIDS_JSON+="\"${sid}\", "
done
SIDS_JSON="[${SIDS_JSON%, }]"

# ── Xray config ──────────────────────────────────────────────────────────────
XRAY_CONFIG=$(cat <<__JSON__
{
  "log": {"access": "./access.log", "dnsLog": false, "error": "", "loglevel": "${XUI_XRAY_LOG_LEVEL}"},
  "api": {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
  "inbounds": [{"tag": "api", "listen": "127.0.0.1", "port": $XRAY_API_PORT, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}],
  "outbounds": [
    {"tag": "blocked", "protocol": "blackhole", "settings": {}},
    {"protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": $WARP_PROXY_PORT, "users": []}]}, "tag": "warp"},
    {"protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": $OPERA_PROXY_PORT, "users": []}]}, "tag": "opera"},
    {"protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": $TOR_PORT, "users": []}]}, "tag": "tor"},
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}}
  ],
  "policy": {"levels": {"0": {"statsUserDownlink": true, "statsUserUplink": true}}, "system": {"statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": true, "statsOutboundUplink": true}},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "outboundTag": "blocked", "domain": ["geosite:category-ads-all", "ext:geosite_IR.dat:malware", "ext:geosite_IR.dat:phishing", "ext:geosite_IR.dat:cryptominers"]},
      {"type": "field", "outboundTag": "warp", "domain": ["ext:geosite_RU.dat:ru-available-only-inside", "regexp:.*\\\\.ru\$", "regexp:.*\\\\.su\$", "regexp:.*\\\\.xn--p1ai\$", "domain:ntc.party"]},
      {"type": "field", "ip": ["ext:geoip_RU.dat:ru"], "outboundTag": "warp"},
      {"type": "field", "outboundTag": "tor", "domain": ["regexp:.*\\\\.onion\$", "domain:check.torproject.org"]},
      {"type": "field", "outboundTag": "opera", "domain": ["geosite:disney", "geosite:reddit", "domain:disneyplus.com", "domain:reddit.com", "domain:redd.it", "domain:redditmedia.com", "domain:redditstatic.com", "domain:reddituploads.com"]},
      {"type": "field", "outboundTag": "direct", "network": "tcp,udp"}
    ]
  },
  "stats": {},
  "metrics": {"tag": "metrics"},
  "dns": {"hosts": {"dns.google": ["8.8.8.8", "8.8.4.4"], "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]}, "servers": ["https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query", "8.8.8.8", "1.1.1.1"], "queryStrategy": "UseIP", "tag": "dns_inbound"},
  "fakedns": null
}
__JSON__
)

VLESS_REALITY_KEYS_SETTINGS="\"show\":false,\"xver\":0,\"target\":\"127.0.0.1:9443\",\"serverNames\":[\"$DOMAIN\"],\"privateKey\":\"$REALITY_PRIVATE\",\"minClientVer\":\"\",\"maxClientVer\":\"\",\"maxTimediff\":0,\"shortIds\":$SIDS_JSON,\"mldsa65Seed\":\"\",\"settings\":{\"publicKey\":\"$REALITY_PUBLIC\",\"fingerprint\":\"firefox\",\"serverName\":\"\",\"spiderX\":\"/\",\"mldsa65Verify\":\"\"}"

ROUTING='happ://routing/onadd/eyJOYW1lIjoiUm9zY29tVlBOIiwiR2xvYmFsUHJveHkiOiJ0cnVlIiwiVXNlQ2h1bmtGaWxlcyI6InRydWUiLCJSZW1vdGVEbnMiOiI4LjguOC44IiwiRG9tZXN0aWNEbnMiOiI3Ny44OC44LjgiLCJSZW1vdGVETlNUeXBlIjoiRG9IIiwiUmVtb3RlRE5TRG9tYWluIjoiaHR0cHM6Ly84LjguOC44L2Rucy1xdWVyeSIsIlJlbW90ZUROU0lQIjoiOC44LjguOCIsIkRvbWVzdGljRE5TVHlwZSI6IkRvSCIsIkRvbWVzdGljRE5TRG9tYWluIjoiaHR0cHM6Ly83Ny44OC44LjgvZG5zLXF1ZXJ5IiwiRG9tZXN0aWNETlNJUCI6Ijc3Ljg4LjguOCIsIkdlb2lwdXJsIjoiaHR0cHM6Ly9jZG4uanNkZWxpdnIubmV0L2doL2h5ZHJhcG9uaXF1ZS9yb3Njb212cG4tZ2VvaXBAMjAyNjA0MjQwNTQyL3JlbGVhc2UvZ2VvaXAuZGF0IiwiR2Vvc2l0ZXVybCI6Imh0dHBzOi8vY2RuLmpzZGVsaXZyLm5ldC9naC9oeWRyYXBvbmlxdWUvcm9zY29tdnBuLWdlb3NpdGVAMjAyNjA0MTUyMjM1L3JlbGVhc2UvZ2Vvc2l0ZS5kYXQiLCJMYXN0VXBkYXRlZCI6IjE3NzcwMDkzOTAiLCJEbnNIb3N0cyI6eyJsa2ZsMi5uYWxvZy5ydSI6IjIxMy4yNC42NC4xNzUiLCJsa25wZC5uYWxvZy5ydSI6IjIxMy4yNC42NC4xODEifSwiUm91dGVPcmRlciI6ImJsb2NrLXByb3h5LWRpcmVjdCIsIkRpcmVjdFNpdGVzIjpbImdlb3NpdGU6cHJpdmF0ZSIsImdlb3NpdGU6Y2F0ZWdvcnktcnUiLCJnZW9zaXRlOndoaXRlbGlzdCIsImdlb3NpdGU6bWljcm9zb2Z0IiwiZ2Vvc2l0ZTphcHBsZSIsImdlb3NpdGU6ZXBpY2dhbWVzIiwiZ2Vvc2l0ZTpyaW90IiwiZ2Vvc2l0ZTplc2NhcGVmcm9tdGFya292IiwiZ2Vvc2l0ZTpzdGVhbSIsImdlb3NpdGU6dHdpdGNoIiwiZ2Vvc2l0ZTpwaW50ZXJlc3QiLCJnZW9zaXRlOmZhY2VpdCJdLCJEaXJlY3RJcCI6WyJnZW9pcDpwcml2YXRlIiwiZ2VvaXA6ZGlyZWN0Il0sIlByb3h5U2l0ZXMiOlsiZ2Vvc2l0ZTpnb29nbGUtcGxheSIsImdlb3NpdGU6Z2l0aHViIiwiZ2Vvc2l0ZTp0d2l0Y2gtYWRzIiwiZ2Vvc2l0ZTp5b3V0dWJlIiwiZ2Vvc2l0ZTp0ZWxlZ3JhbSJdLCJQcm94eUlwIjpbXSwiQmxvY2tTaXRlcyI6WyJnZW9zaXRlOndpbi1zcHkiLCJnZW9zaXRlOnRvcnJlbnQiLCJnZW9zaXRlOmNhdGVnb3J5LWFkcyJdLCJCbG9ja0lwIjpbXSwiRG9tYWluU3RyYXRlZ3kiOiJJUElmTm9uTWF0Y2giLCJGYWtlRE5TIjoiZmFsc2UifQo='

XRAY_CONFIG_1L=$(printf '%s' "$XRAY_CONFIG" | tr -d '\n')

# ── Запись настроек в БД ─────────────────────────────────────────────────────
xui_db_set() {
    local key="$1"
    local val
    val=$(sql_escape "$2")
    sqlite3 "$XUI_DB" \
        "DELETE FROM settings WHERE key='${key}'; INSERT INTO settings(key,value) VALUES('${key}','${val}');" \
        || die "Ошибка записи '$key' в БД"
}

sqlite3 "$XUI_DB" "DELETE FROM settings WHERE rowid NOT IN (SELECT MAX(rowid) FROM settings GROUP BY key);"

# Сертификат Caddy — один на всё: панель, подписка, Hysteria2, Trojan-WS. Caddy его
# выпустил на шаге Selfsteal и сам продлевает на месте; xray/x-ui читают файл напрямую
# (oneTimeLoading:false у inbound'ов, веб-сервер перечитывает при рестарте x-ui).
CADDY_CERT_FILE=$(caddy_cert_file)
CADDY_KEY_FILE=$(caddy_key_file)
[[ -f "$CADDY_CERT_FILE" && -f "$CADDY_KEY_FILE" ]] \
    || die "Сертификат Caddy для ${DOMAIN} не найден в ${CADDY_DATA_DIR}. Сначала должен отработать шаг Selfsteal."

# Панель и подписка работают за нативным Caddy на 443 (reverse_proxy по пути).
# x-ui слушает только localhost. Сертификат зашит (web/subCertFile) → внутри 3x-ui
# работает кнопка «взять сертификат панели», а x-ui отдаёт HTTPS на localhost —
# поэтому Caddy проксирует на https-бэкенд (см. steps/selfsteal.sh).
xui_db_set webPort            "$PANEL_PORT"
xui_db_set webListen          "127.0.0.1"
xui_db_set webDomain          ""
xui_db_set webBasePath        "$PANEL_PATH"
xui_db_set subPort            "$SUB_PORT"
xui_db_set subListen          "127.0.0.1"
xui_db_set subDomain          ""
xui_db_set subEnable          "true"
xui_db_set subJsonEnable      "false"
xui_db_set subTitle           "$SUB_TITLE"
xui_db_set subAnnounce        "$SUB_ANNOUNCE"
xui_db_set subPath            "$SUB_PATH"
xui_db_set subURI             "https://${DOMAIN}${SUB_PATH}"
xui_db_set subUpdates         "1"
xui_db_set subRoutingRules    "$ROUTING"
xui_db_set subEnableRouting   "true"
xui_db_set xrayTemplateConfig "$XRAY_CONFIG_1L"
# Сертификат Caddy для панели и подписки (HTTPS на localhost + кнопка в UI).
xui_db_set webCertFile        "$CADDY_CERT_FILE"
xui_db_set webKeyFile         "$CADDY_KEY_FILE"
xui_db_set subCertFile        "$CADDY_CERT_FILE"
xui_db_set subKeyFile         "$CADDY_KEY_FILE"
# Шаблон названия конфигурации в подписке — только имя инбаунда, без email клиента.
xui_db_set remarkTemplate     "{{INBOUND}}"

# ── VLESS Reality ────────────────────────────────────────────────────────────
# В новой версии 3x-ui клиенты хранятся в отдельных таблицах clients/client_inbounds/client_traffics
VLESS_REALITY_SETTINGS="{\"clients\":[],\"decryption\":\"none\",\"encryption\":\"none\",\"fallbacks\":[]}"
VLESS_REALITY_STREAM="{\"network\":\"grpc\",\"security\":\"reality\",\"externalProxy\":[],\"realitySettings\":{${VLESS_REALITY_KEYS_SETTINGS}},\"grpcSettings\":{\"serviceName\":\"\",\"multiMode\":false,\"idle_timeout\":60,\"health_check_timeout\":20,\"permit_without_stream\":false,\"initial_windows_size\":0}}"
VLESS_REALITY_SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

VLESS_REALITY_SE_SQL="${VLESS_REALITY_SETTINGS//\'/\'\'}"
VLESS_REALITY_SS_SQL="${VLESS_REALITY_STREAM//\'/\'\'}"
VLESS_REALITY_SN_SQL="${VLESS_REALITY_SNIFFING//\'/\'\'}"

# Чистим всех клиентов и связанные данные перед пересозданием инбаундов
sqlite3 "$XUI_DB" \
    "DELETE FROM client_traffics;
     DELETE FROM client_inbounds;
     DELETE FROM clients;
     DELETE FROM inbounds;" \
    || die "Ошибка очистки клиентов и инбаундов в БД"

VLESS_REMARK="${LOCATION_LABEL} | Vless"
VLESS_REMARK_SQL=$(sql_escape "$VLESS_REMARK")

sqlite3 "$XUI_DB" \
    "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,traffic_reset,listen,port,protocol,settings,stream_settings,tag,sniffing)
     VALUES (1,0,0,0,'${VLESS_REMARK_SQL}',1,0,'${TRAFFIC_RESET}','',${VLESS_PORT},'vless','${VLESS_REALITY_SE_SQL}','${VLESS_REALITY_SS_SQL}','in-${VLESS_PORT}-grpc','${VLESS_REALITY_SN_SQL}');" \
    || die "Ошибка INSERT VLESS Reality inbound в БД"

# ── Hysteria2 ─────────────────────────────────────────────────────────────────
# Сертификат для Hysteria2 — общий с панелью/подпиской/Trojan (CADDY_CERT_FILE выше).
HY2_CERT_FILE="$CADDY_CERT_FILE"
HY2_KEY_FILE="$CADDY_KEY_FILE"

HYSTERIA2_SETTINGS="{\"clients\":[],\"version\":2}"
# quicParams: при включённом port hopping добавляем udpHop (диапазон портов + интервал
# переключения). Этот форк Xray поддерживает hopping нативно и прокидывает его в ссылку
# клиента. ports в udpHop — через дефис (63000-63999), поэтому конвертируем из start:end.
# Интервал переключения фиксированный (сек, формат min-max).
HY2_HOP_INTERVAL="5-10"
if truthy "$HY2_HOP"; then
    HY2_QUIC_PARAMS="{\"congestion\":\"bbr\",\"udpHop\":{\"ports\":\"${HY2_HOP_RANGE/:/-}\",\"interval\":\"${HY2_HOP_INTERVAL}\"}}"
else
    HY2_QUIC_PARAMS="{\"congestion\":\"bbr\"}"
fi
HYSTERIA2_STREAM="{\"network\":\"hysteria\",\"security\":\"tls\",\"externalProxy\":[],\"tlsSettings\":{\"serverName\":\"$DOMAIN\",\"minVersion\":\"1.2\",\"maxVersion\":\"1.3\",\"cipherSuites\":\"\",\"rejectUnknownSni\":true,\"disableSystemRoot\":false,\"enableSessionResumption\":true,\"certificates\":[{\"certificateFile\":\"${HY2_CERT_FILE}\",\"keyFile\":\"${HY2_KEY_FILE}\",\"oneTimeLoading\":false,\"usage\":\"encipherment\",\"buildChain\":false}],\"alpn\":[\"h3\"],\"echServerKeys\":\"\",\"settings\":{\"fingerprint\":\"firefox\",\"echConfigList\":\"\"}},\"hysteriaSettings\":{\"version\":2,\"auth\":\"$CLIENT_HY2_AUTH\",\"udpIdleTimeout\":60,\"masquerade\":{\"type\":\"proxy\",\"dir\":\"\",\"url\":\"twitch.tv\",\"rewriteHost\":true,\"insecure\":false,\"content\":\"\",\"headers\":{},\"statusCode\":0}},\"finalmask\":{\"udp\":[],\"quicParams\":${HY2_QUIC_PARAMS}}}"
HYSTERIA2_SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

HYSTERIA2_SE_SQL="${HYSTERIA2_SETTINGS//\'/\'\'}"
HYSTERIA2_SS_SQL="${HYSTERIA2_STREAM//\'/\'\'}"
HYSTERIA2_SN_SQL="${HYSTERIA2_SNIFFING//\'/\'\'}"

HY2_REMARK="${LOCATION_LABEL} | Hy2"
HY2_REMARK_SQL=$(sql_escape "$HY2_REMARK")

sqlite3 "$XUI_DB" \
    "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,traffic_reset,listen,port,protocol,settings,stream_settings,tag,sniffing)
     VALUES (1,0,0,0,'${HY2_REMARK_SQL}',1,0,'${TRAFFIC_RESET}','',${HY2_PORT},'hysteria','${HYSTERIA2_SE_SQL}','${HYSTERIA2_SS_SQL}','in-${HY2_PORT}-udp','${HYSTERIA2_SN_SQL}');" \
    || die "Ошибка INSERT Hysteria2 inbound в БД"

# ── Клиент ───────────────────────────────────────────────────────────────────
CLIENT_EMAIL="moy-client"
CLIENT_EMAIL_SQL=$(sql_escape "$CLIENT_EMAIL")
CLIENT_UUID_SQL=$(sql_escape "$CLIENT_UUID")
CLIENT_SUB_ID_SQL=$(sql_escape "$CLIENT_SUB_ID")
CLIENT_HY2_AUTH_SQL=$(sql_escape "$CLIENT_HY2_AUTH")
NOW_MS=$(date +%s)000

sqlite3 "$XUI_DB" \
    "INSERT INTO clients (email,sub_id,uuid,password,auth,flow,security,limit_ip,total_gb,expiry_time,enable,tg_id,group_name,comment,reset,created_at,updated_at)
     VALUES ('${CLIENT_EMAIL_SQL}','${CLIENT_SUB_ID_SQL}','${CLIENT_UUID_SQL}','','${CLIENT_HY2_AUTH_SQL}','','auto',0,0,0,1,0,'','',0,${NOW_MS},${NOW_MS});
     INSERT INTO client_inbounds (client_id,inbound_id,flow_override,created_at)
     VALUES ((SELECT id FROM clients WHERE email='${CLIENT_EMAIL_SQL}'),(SELECT id FROM inbounds WHERE tag='in-${VLESS_PORT}-grpc'),'',${NOW_MS});
     INSERT INTO client_inbounds (client_id,inbound_id,flow_override,created_at)
     VALUES ((SELECT id FROM clients WHERE email='${CLIENT_EMAIL_SQL}'),(SELECT id FROM inbounds WHERE tag='in-${HY2_PORT}-udp'),'',${NOW_MS});
     INSERT INTO client_traffics (inbound_id,enable,email,up,down,expiry_time,total,reset)
     VALUES ((SELECT id FROM inbounds WHERE tag='in-${VLESS_PORT}-grpc'),1,'${CLIENT_EMAIL_SQL}',0,0,0,0,0);" \
    || die "Ошибка INSERT клиента в БД"

CLIENT_JSON="{\"id\":\"${CLIENT_UUID}\",\"auth\":\"${CLIENT_HY2_AUTH}\",\"flow\":\"\",\"security\":\"auto\",\"email\":\"${CLIENT_EMAIL}\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":0,\"subId\":\"${CLIENT_SUB_ID}\",\"comment\":\"\",\"reset\":0,\"created_at\":${NOW_MS},\"updated_at\":${NOW_MS},\"password\":\"\"}"
CLIENT_JSON_SQL=$(sql_escape "$CLIENT_JSON")
sqlite3 "$XUI_DB" \
    "UPDATE inbounds SET settings=json_set(settings,'$.clients',json_array(json('${CLIENT_JSON_SQL}'))) WHERE tag='in-${VLESS_PORT}-grpc';
     UPDATE inbounds SET settings=json_set(settings,'$.clients',json_array(json('${CLIENT_JSON_SQL}'))) WHERE tag='in-${HY2_PORT}-udp';" \
    || die "Ошибка обновления settings инбаундов с клиентом"

# ── Хэш пароля (до старта сервиса) ──────────────────────────────────────────
if ! command_exists htpasswd; then
    die "htpasswd не найден. Установите prereqs или добавьте apache2-utils вручную."
fi
PANEL_PASS_HASH=$(htpasswd -bnBC 10 "" "$PANEL_PASS" | tr -d ':\n') \
    || die "Не удалось сгенерировать bcrypt-хэш пароля."
[[ -n "$PANEL_PASS_HASH" ]] || die "bcrypt-хэш пустой."

# Таблица users уже должна быть — она создаётся при первом старте выше
# (сервис x-ui сейчас остановлен для прямой правки БД).
PANEL_USER_SQL=$(sql_escape "$PANEL_USER")
PANEL_PASS_HASH_SQL=$(sql_escape "$PANEL_PASS_HASH")
sqlite3 "$XUI_DB" \
    "UPDATE users SET username='${PANEL_USER_SQL}', password='${PANEL_PASS_HASH_SQL}' WHERE id=1;" \
    || die "Не удалось задать логин/пароль в БД."

# ── API-токен для панели ─────────────────────────────────────────────────────
# Plaintext: 48 символов из алфавита [0-9a-zA-Z] — идентично random.Seq(48) в 3x-ui.
# В БД хранится SHA-256(plaintext) hex; plaintext показывается только здесь.
API_TOKEN=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 48)
[[ ${#API_TOKEN} -eq 48 ]] || die "Не удалось сгенерировать API-токен (openssl)."
API_TOKEN_HASH=$(printf '%s' "$API_TOKEN" | sha256sum | awk '{print $1}')
API_TOKEN_NOW=$(date +%s)
API_TOKEN_NAME_SQL=$(sql_escape "installer")
API_TOKEN_HASH_SQL=$(sql_escape "$API_TOKEN_HASH")
sqlite3 "$XUI_DB" \
    "INSERT OR IGNORE INTO api_tokens (name, token, enabled, created_at)
     VALUES ('${API_TOKEN_NAME_SQL}','${API_TOKEN_HASH_SQL}',1,${API_TOKEN_NOW});" \
    || die "Ошибка INSERT API-токена в БД."
# Сохраняем plaintext для родительского setup.sh (export не работает через границу подпроцесса).
printf '%s' "$API_TOKEN" > /root/.xui_api_token
chmod 600 /root/.xui_api_token

# ── Финальный старт ──────────────────────────────────────────────────────────
systemctl start x-ui || die "Не удалось запустить сервис x-ui."
sleep 3
systemctl is-active --quiet x-ui \
    || die "Сервис x-ui не активен после старта. Проверьте: journalctl -u x-ui -n 100"
success "3x-ui запущен (нативно). Управление: x-ui  |  systemctl {status,restart,stop} x-ui"
