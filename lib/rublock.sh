#!/bin/bash
# Российские сервисы: на ноде — отрезаны, у клиента — мимо VPN.
#
# Зачем: российские приложения узнают IP сервера, через который к ним пришли, и
# сдают его — адрес ноды блокируют на недели. Нода не должна быть видна им ни
# при каких условиях, поэтому два слоя из ОДНОГО списка ниже:
#   • сервер: все три движка (Xray, sing-box, Hysteria) отбивают соединения к
#     РФ-доменам и РФ-IP — даже если клиент правила не применил, адрес ноды
#     российский сервис не увидит (увидит ошибку соединения);
#   • подписка: клиенты, которые умеют брать маршрутизацию из заголовка (Happ,
#     v2RayTun), отправляют тот же список напрямую — у человека всё работает.
# Выключатель — RU_BLOCK=0 в node.conf (только сервер; подписку не трогает).
# Подробности — docs/guide/RU-BLOCK.md.

# Единственный источник правды: что считаем российским.
RUBLOCK_GEOSITE="category-ru"
RUBLOCK_TLDS="ru su xn--p1ai"          # xn--p1ai = .рф
RUBLOCK_GEOIP="ru"
RUBLOCK_GEO_DIR="${RUBLOCK_GEO_DIR:-/usr/local/share/xray}"   # geoip.dat/geosite.dat ставит Xray
RUBLOCK_SRS_URL="https://raw.githubusercontent.com/SagerNet"

rublock_enabled() { [ "$(node_get RU_BLOCK 2>/dev/null)" != "0" ]; }

# ---------- Xray: блок outbounds и routing.rules (дописывается к конфигу) ----------
# Порядок правил: домены до IP — клиент почти всегда присылает имя, а не адрес,
# и резолвить каждое имя ради geoip (IPIfNonMatch) — лишняя задержка на всём
# трафике. Сырой IP ловит geoip.
_rublock_xray_domains() {
    local t out="\"geosite:${RUBLOCK_GEOSITE}\""
    for t in $RUBLOCK_TLDS; do out+=",\"domain:$t\""; done
    printf '%s' "$out"
}
rublock_xray_outbound() {   # печатает ',{blackhole}' или ничего
    rublock_enabled && printf ',{ "protocol": "blackhole", "tag": "block" }'
}
rublock_xray_rules() {      # печатает ',правило,правило' или ничего
    rublock_enabled || return 0
    printf ',{ "type": "field", "outboundTag": "block", "domain": [%s] }' "$(_rublock_xray_domains)"
    printf ',{ "type": "field", "outboundTag": "block", "ip": ["geoip:%s"] }' "$RUBLOCK_GEOIP"
}

# ---------- sing-box: секция route ----------
# sing-box ≥1.12 не читает geoip.dat — только rule-set (.srs). Скачиваем их в
# PROTO_DIR и обновляем раз в неделю; нет файла (GitHub недоступен) — правило по
# нему не пишем, остаются домены: sing-box с битым путём не стартовал бы вовсе.
_rublock_srs() {   # name repo -> путь к файлу или пусто
    local f="$PROTO_DIR/$1.srs"
    if [ ! -s "$f" ] || [ -n "$(find "$f" -mtime +7 2>/dev/null)" ]; then
        curl -fsSL --max-time 30 "$RUBLOCK_SRS_URL/$2/rule-set/$1.srs" -o "$f.tmp" 2>/dev/null \
            && [ -s "$f.tmp" ] && mv -f "$f.tmp" "$f"
        rm -f "$f.tmp"
    fi
    [ -s "$f" ] && printf '%s' "$f"
}
rublock_singbox_route() {   # печатает ',"route":{...}' или ничего
    rublock_enabled || return 0
    local t sfx="" sets="" tags="" f
    for t in $RUBLOCK_TLDS; do sfx+="${sfx:+,}\".$t\""; done
    for f in "geosite-${RUBLOCK_GEOSITE}:sing-geosite" "geoip-${RUBLOCK_GEOIP}:sing-geoip"; do
        local p; p=$(_rublock_srs "${f%%:*}" "${f#*:}") || continue
        [ -n "$p" ] || continue
        sets+="${sets:+,}{\"tag\":\"${f%%:*}\",\"type\":\"local\",\"format\":\"binary\",\"path\":\"$p\"}"
        tags+="${tags:+,}\"${f%%:*}\""
    done
    local by_set=""
    [ -n "$tags" ] && by_set=", { \"rule_set\": [$tags], \"action\": \"reject\" }"
    printf ',\n  "route": { "rule_set": [%s], "rules": [ { "action": "sniff" }, { "domain_suffix": [%s], "action": "reject" }%s ] }' \
        "$sets" "$sfx" "$by_set"
}

# ---------- Hysteria: блок acl в /etc/hysteria/config.yaml ----------
# Конфиг Hysteria правят руками и sed'ом (perf.sh, migration.sh), целиком его
# никто не генерирует — поэтому свой блок держим между маркерами и заменяем
# только его. Рестарт — только если файл реально изменился: он рвёт все сессии.
# Полные geoip.dat/geosite.dat (30 МБ) Hysteria разворачивает в память целиком:
# процесс вырастает с ~20 до ~250 МБ, а это седьмая часть ОЗУ ноды. Поэтому
# отдаём ей вырезку — только нужные коды. Формат .dat — protobuf-список
# {entry=1 {country_code=1, ...}}: копируем записи верхнего уровня как есть,
# отбирая по первому полю. Пересобираем, когда исходник Xray обновился.
_rublock_trim_dat() {   # kind(geoip|geosite) code -> путь к вырезке
    local src="$RUBLOCK_GEO_DIR/$1.dat" dst="$PROTO_DIR/rublock-$1-$2.dat"
    [ -s "$src" ] || return 1
    if [ ! -s "$dst" ] || [ "$src" -nt "$dst" ]; then
        mkdir -p "$PROTO_DIR"
        python3 - "$src" "$dst.tmp" "$2" <<'PY' && [ -s "$dst.tmp" ] && mv -f "$dst.tmp" "$dst" || { rm -f "$dst.tmp"; return 1; }
import sys
def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1; r |= (c & 0x7f) << s; s += 7
        if c < 0x80: return r, i
data, want, out, i = open(sys.argv[1], 'rb').read(), sys.argv[3].upper(), bytearray(), 0
while i < len(data):
    st = i; i += 1; n, i = varint(data, i); e = data[i:i + n]; i += n
    ln, j = varint(e, 1)
    if e[0] == 0x0a and e[j:j + ln].decode(errors='ignore').upper() == want:
        out += data[st:i]
sys.exit(0 if out and open(sys.argv[2], 'wb').write(out) else 1)
PY
        chmod 644 "$dst"
    fi
    printf '%s' "$dst"
}

_RUBLOCK_MARK_B="# >>> hy2-manager rublock"
_RUBLOCK_MARK_E="# <<< hy2-manager rublock"
_rublock_hysteria_block() {   # geoip_dat geosite_dat
    local t
    printf '%s\nacl:\n  geoip: %s\n  geosite: %s\n  inline:\n' "$_RUBLOCK_MARK_B" "$1" "$2"
    printf '    - reject(geosite:%s)\n' "$RUBLOCK_GEOSITE"
    for t in $RUBLOCK_TLDS; do printf '    - reject(suffix:%s)\n' "$t"; done
    printf '    - reject(geoip:%s)\n%s\n' "$RUBLOCK_GEOIP" "$_RUBLOCK_MARK_E"
}
rublock_hysteria_apply() {
    [ -f "$CONFIG" ] || return 0
    local tmp; tmp=$(mktemp) || return 1
    sed "/^$_RUBLOCK_MARK_B\$/,/^$_RUBLOCK_MARK_E\$/d" "$CONFIG" > "$tmp"
    # Чужой (ручной) acl не перетираем: два ключа acl в YAML — сломанный конфиг.
    local gi gs
    if rublock_enabled && ! grep -q '^acl:' "$tmp" \
        && gi=$(_rublock_trim_dat geoip "$RUBLOCK_GEOIP") \
        && gs=$(_rublock_trim_dat geosite "$RUBLOCK_GEOSITE"); then
        _rublock_hysteria_block "$gi" "$gs" >> "$tmp"
    fi
    if cmp -s "$tmp" "$CONFIG"; then rm -f "$tmp"; return 0; fi
    cat "$tmp" > "$CONFIG"; rm -f "$tmp"
    systemctl restart hysteria-server >/dev/null 2>&1
}

# ---------- Догнать настройку (из cluster_sync, раз в 5 мин) ----------
# Конфиги Xray/sing-box пересобирает proto_sync_users, а его зовут только при
# смене юзеров. Проверяем дёшево — есть ли наш след в конфиге — и пересобираем,
# только если он расходится с RU_BLOCK. Hysteria сравнивается файлом целиком.
rublock_sync() {
    local want=0 x=0 s=0
    rublock_enabled && want=1
    rublock_hysteria_apply
    proto_xray_needed 2>/dev/null && grep -q '"blackhole"' "$XRAY_CONFIG" 2>/dev/null && x=1
    proto_tuic_enabled 2>/dev/null && grep -q '"reject"' "$SINGBOX_CONFIG" 2>/dev/null && s=1
    { proto_xray_needed 2>/dev/null && [ "$x" != "$want" ]; } \
        || { proto_tuic_enabled 2>/dev/null && [ "$s" != "$want" ]; } \
        && proto_sync_users
    return 0
}

# ---------- Подписка: исключения для клиента ----------
# Оба клиента читают заголовок с одним именем `routing`, но формат разный:
# Happ — диплинк happ://routing/onadd/<base64 профиля>, v2RayTun — base64 объекта
# маршрутизации Xray. Поэтому выдаём по User-Agent. Печатает строки для блока
# handle /sub/* в Caddy (сниппет write_sub_titles).
_rublock_happ_profile() {
    local t sites="\"geosite:${RUBLOCK_GEOSITE}\""
    for t in $RUBLOCK_TLDS; do sites+=",\"domain:$t\""; done
    printf '{"Name":"%s","GlobalProxy":"true","DirectSites":[%s],"DirectIp":["geoip:%s","geoip:private"],"ProxySites":[],"ProxyIp":[],"BlockSites":[],"BlockIp":[],"DomainStrategy":"IPIfNonMatch","FakeDNS":"false"}' \
        "RU напрямую" "$sites" "$RUBLOCK_GEOIP"
}
_rublock_v2raytun_routing() {
    printf '{"name":"RU напрямую","id":"5D1C9A4E-6B2F-4E1A-9C3D-2A7B8E0F1C10","domainStrategy":"IPIfNonMatch","domainMatcher":"hybrid","balancers":[],"rules":[{"type":"field","outboundTag":"freedom","__name__":"ru-domains","__id__":"5D1C9A4E-6B2F-4E1A-9C3D-2A7B8E0F1C11","domain":[%s]},{"type":"field","outboundTag":"freedom","__name__":"ru-ip","__id__":"5D1C9A4E-6B2F-4E1A-9C3D-2A7B8E0F1C12","ip":["geoip:%s","geoip:private"]}]}' \
        "$(_rublock_xray_domains)" "$RUBLOCK_GEOIP"
}
rublock_sub_headers() {
    printf '\t@rub_happ header_regexp User-Agent (?i)^happ\n'
    printf '\theader @rub_happ routing "happ://routing/onadd/%s"\n' "$(_sub_b64 "$(_rublock_happ_profile)")"
    printf '\t@rub_v2rt header_regexp User-Agent (?i)^v2raytun\n'
    printf '\theader @rub_v2rt routing "%s"\n' "$(_sub_b64 "$(_rublock_v2raytun_routing)")"
}
