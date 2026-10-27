#!/usr/bin/env bash
#
# add-protocols.sh — добавляет VLESS / Hysteria2 инбаунды в профиль Remnawave через API:
# инбаунды в профиль, активация на ноде, хосты, внутренние сквады, серт и порты на ноде.
#
# Запуск на сервере ноды под root:
#   bash <(curl -Ls https://raw.githubusercontent.com/Bantila/remnawave-protocols/main/add-protocols.sh)
#
# ENV (необязательно): RW_URL, RW_TOKEN, DRY_RUN=1 (только показать JSON, ничего не менять)
#
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${BLUE}[•]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_err()  { echo -e "${RED}[✗]${NC} $1" >&2; }
fatal()    { log_err "$1"; [[ -n "${2:-}" ]] && log_warn "$2"; exit 1; }

COMPOSE=/opt/remnanode/docker-compose.yml
SELFSTEAL_SOCK=/dev/shm/nginx.sock
DRY_RUN=${DRY_RUN:-0}
REALITY=""
CERT_DIR=""
CERT_MOUNT=""

PROTOS=(tcp_reality tcp_tls xhttp_reality xhttp_tls hy2 grpc_reality grpc_tls)
declare -A NAME=(
    [tcp_reality]="VLESS TCP Reality + Selfsteal"  [tcp_tls]="VLESS TCP TLS"
    [xhttp_reality]="VLESS XHTTP Reality + Selfsteal" [xhttp_tls]="VLESS XHTTP TLS"
    [hy2]="Hysteria2 + TLS"
    [grpc_reality]="VLESS gRPC Reality + Selfsteal" [grpc_tls]="VLESS gRPC TLS"
)
declare -A PREFIX=(
    [tcp_reality]=VLESS_TCP_REALITY [tcp_tls]=VLESS_TCP_TLS
    [xhttp_reality]=VLESS_XHTTP_REALITY [xhttp_tls]=VLESS_XHTTP_TLS
    [hy2]=HYSTERIA2
    [grpc_reality]=VLESS_GRPC_REALITY [grpc_tls]=VLESS_GRPC_TLS
)
declare -A PORT=(
    [tcp_reality]=443 [tcp_tls]=8444 [xhttp_reality]=4443 [xhttp_tls]=2083
    [hy2]=443 [grpc_reality]=8443 [grpc_tls]=2087
)
declare -A TAG

is_reality() { [[ $1 == *_reality ]]; }
is_tls()     { [[ $1 == *_tls || $1 == hy2 ]]; }
proto_l4()   { [[ $1 == hy2 ]] && echo udp || echo tcp; }

# ---------- API ----------

# Токен и тело идут через fd/stdin, а не argv — не видны в ps (приём из eGamesAPI).
api() {
    local method=$1 path=$2 data=${3:-} hdr
    hdr=$(printf 'Authorization: Bearer %s\nContent-Type: application/json\nX-Forwarded-For: 127.0.0.1\nX-Forwarded-Proto: https\nX-Remnawave-Client-Type: browser\n' "$RW_TOKEN")
    if [[ -n $data ]]; then
        printf '%s' "$data" | curl -sS --connect-timeout 10 --max-time 60 -X "$method" "${RW_URL%/}$path" \
            -H @<(printf '%s' "$hdr") --data-binary @-
    else
        curl -sS --connect-timeout 10 --max-time 60 -X "$method" "${RW_URL%/}$path" -H @<(printf '%s' "$hdr")
    fi
}

# Печатает .response, при ошибке API — выход.
api_call() {
    local out
    out=$(api "$@") || fatal "Нет ответа от панели: $1 $2"
    if ! jq -e '.response' >/dev/null 2>&1 <<<"$out"; then
        fatal "Ошибка API $1 $2: $(jq -r '.message // .' <<<"$out" 2>/dev/null || echo "$out")"
    fi
    jq -c '.response' <<<"$out"
}

# ---------- ввод ----------

ask() { # ask "вопрос" "дефолт" -> echo ответ
    local reply
    read -rp "$(echo -e "${BLUE}?${NC} $1${2:+ [$2]}: ")" reply
    echo "${reply:-$2}"
}

confirm() { # confirm "вопрос" -> 0 если да (Enter = да)
    local reply
    read -rp "$(echo -e "${YELLOW}?${NC} $1 [Y/n]: ")" reply
    [[ -z $reply || $reply =~ ^[YyДд] ]]
}

choose_index() { # choose_index "заголовок" <json-массив строк> -> echo индекс
    local title=$1 list=$2 n i
    n=$(jq 'length' <<<"$list")
    (( n > 0 )) || fatal "$title: список пуст"
    echo "" >&2; log_info "$title" >&2
    for ((i = 0; i < n; i++)); do echo -e "  ${BLUE}[$((i + 1))]${NC} $(jq -r ".[$i]" <<<"$list")" >&2; done
    while true; do
        i=$(ask "Номер" "1")
        [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= n )) && { echo $((i - 1)); return; }
        log_warn "Введите число 1-$n" >&2
    done
}

# ---------- шаги ----------

preflight() {
    [[ $EUID -eq 0 ]] || fatal "Нужны права root" "sudo bash $0"
    for bin in curl openssl; do command -v $bin &>/dev/null || fatal "Не найден $bin"; done
    if ! command -v jq &>/dev/null; then
        log_warn "jq не найден, ставлю..."
        apt-get update -qq && apt-get install -y -qq jq >/dev/null || fatal "Не удалось установить jq"
    fi
    if command -v docker &>/dev/null && [[ $(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null) == running ]]; then
        log_ok "Контейнер remnanode запущен"
        ON_NODE=1
    else
        log_warn "Контейнер remnanode не найден — подготовка ноды (серт, порты) будет пропущена"
        ON_NODE=0
    fi
}

panel_login() {
    if [[ -z ${RW_URL:-} ]]; then
        local def=""
        curl -s -o /dev/null --max-time 3 http://127.0.0.1:3000 && def="http://127.0.0.1:3000"
        RW_URL=$(ask "URL панели (https://panel.example.com)" "$def")
    fi
    [[ -n $RW_URL ]] || fatal "URL панели не задан"
    if [[ -z ${RW_TOKEN:-} ]]; then
        read -rsp "$(echo -e "${BLUE}?${NC} API-токен (Настройки → API-токены): ")" RW_TOKEN; echo
    fi
    [[ -n $RW_TOKEN ]] || fatal "API-токен не задан"
    PROFILES=$(api_call GET /api/config-profiles) || exit 1
    log_ok "Панель доступна"
}

pick_profile() {
    local i
    i=$(choose_index "Профиль конфигурации:" \
        "$(jq -c '[.configProfiles[] | "\(.name) — инбаундов: \(.inbounds | length)"]' <<<"$PROFILES")") || exit 1
    PROFILE_UUID=$(jq -r ".configProfiles[$i].uuid" <<<"$PROFILES")
    PROFILE_NAME=$(jq -r ".configProfiles[$i].name" <<<"$PROFILES")
    CONFIG=$(jq -c ".configProfiles[$i].config" <<<"$PROFILES")
    SUFFIX=$(tr '[:lower:]' '[:upper:]' <<<"$PROFILE_NAME" | sed -E 's/[^A-Z0-9]+/_/g; s/^_+|_+$//g')
    EXISTING_REALITY=$(jq -c '[.inbounds[]? | select(.streamSettings.security == "reality")][0] // empty' <<<"$CONFIG")
    log_ok "Профиль: $PROFILE_NAME (суффикс tag: _$SUFFIX)"
}

pick_domain() {
    local def=""
    [[ -n $EXISTING_REALITY ]] && def=$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$EXISTING_REALITY")
    DOMAIN=$(ask "Домен ноды" "$def")
    [[ -n $DOMAIN ]] || fatal "Домен не задан"
}

pick_protocols() {
    local i input
    echo ""; log_info "Протоколы (Enter — все, или номера через пробел/запятую):"
    for i in "${!PROTOS[@]}"; do
        local p=${PROTOS[$i]}
        echo -e "  ${BLUE}[$((i + 1))]${NC} ${NAME[$p]} — ${PORT[$p]}/$(proto_l4 "$p")"
    done
    read -rp "> " input
    input=${input//,/ }
    SELECTED=()
    if [[ -z ${input// /} ]]; then
        SELECTED=("${PROTOS[@]}")
    else
        for i in $input; do
            [[ $i =~ ^[1-7]$ ]] || fatal "Неверный номер: $i" "Используйте 1-7"
            [[ " ${SELECTED[*]} " == *" ${PROTOS[$((i - 1))]} "* ]] || SELECTED+=("${PROTOS[$((i - 1))]}")
        done
    fi
}

# Порты и tag'и; пропуск уже существующих.
pick_ports() {
    local used_tags used_tcp used_udp p port l4 todo=()
    used_tags=$(jq -r '.inbounds[]?.tag' <<<"$CONFIG")
    used_tcp=" $(jq -r '[.inbounds[]? | select(.protocol != "hysteria") | .port | numbers] | join(" ")' <<<"$CONFIG") "
    used_udp=" $(jq -r '[.inbounds[]? | select(.protocol == "hysteria") | .port | numbers] | join(" ")' <<<"$CONFIG") "
    echo ""; log_info "Порты (Enter — по умолчанию, s — пропустить протокол):"
    for p in "${SELECTED[@]}"; do
        TAG[$p]="${PREFIX[$p]}_$SUFFIX"
        if grep -qxF "${TAG[$p]}" <<<"$used_tags"; then
            log_warn "${TAG[$p]} уже есть в профиле — пропуск"; continue
        fi
        l4=$(proto_l4 "$p")
        while true; do
            port=$(ask "${NAME[$p]} ($l4)" "${PORT[$p]}")
            [[ $port == s ]] && { log_warn "${NAME[$p]} пропущен"; continue 2; }
            [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { log_warn "Порт 1-65535"; continue; }
            if [[ $l4 == tcp && $used_tcp == *" $port "* ]] || [[ $l4 == udp && $used_udp == *" $port "* ]]; then
                log_warn "Порт $port/$l4 уже занят в профиле"; continue
            fi
            break
        done
        PORT[$p]=$port
        [[ $l4 == tcp ]] && used_tcp+="$port " || used_udp+="$port "
        is_reality "$p" && (( port != 443 )) && log_warn "Reality не на 443 — ядро пишет warning, выше риск блокировки IP"
        todo+=("$p")
    done
    SELECTED=("${todo[@]}")
    (( ${#SELECTED[@]} > 0 )) || { log_ok "Добавлять нечего"; exit 0; }
}

prepare_reality() {
    local p need=0 key
    for p in "${SELECTED[@]}"; do is_reality "$p" && need=1; done
    (( need )) || return 0
    if [[ -n $EXISTING_REALITY ]]; then
        REALITY=$(jq -c '.streamSettings.realitySettings' <<<"$EXISTING_REALITY")
        log_ok "Reality-ключи взяты из инбаунда $(jq -r .tag <<<"$EXISTING_REALITY")"
        return
    fi
    [[ -S $SELFSTEAL_SOCK ]] || log_warn "$SELFSTEAL_SOCK не найден — selfsteal-заглушка (nginx) не поднята?"
    key=$(api_call GET /api/system/tools/x25519/generate | jq -r '.keypairs[0].privateKey')
    [[ -n $key && $key != null ]] || fatal "Не удалось получить x25519-ключ"
    REALITY=$(jq -nc --arg k "$key" --arg sid "$(openssl rand -hex 8)" --arg d "$DOMAIN" --arg t "$SELFSTEAL_SOCK" \
        '{show: false, xver: 1, dest: $t, spiderX: "", minClientVer: "0.0.0", shortIds: [$sid], privateKey: $k, serverNames: [$d]}')
    log_ok "Сгенерированы новые Reality-ключи"
}

# Ищет серт, покрывающий домен: certbot (wildcard, суффикс -0001) или загруженный eGamesAPI в /opt/remnanode/ssl.
prepare_cert() {
    local p need=0 f
    for p in "${SELECTED[@]}"; do is_tls "$p" && need=1; done
    (( need )) || return 0
    CERT_DIR=""
    for f in /etc/letsencrypt/live/*/fullchain.pem /opt/remnanode/ssl/*/fullchain.pem; do
        [[ -f $f && -f ${f%/*}/privkey.pem ]] || continue
        openssl x509 -in "$f" -noout -checkend 0 &>/dev/null || continue
        openssl x509 -in "$f" -noout -checkhost "$DOMAIN" 2>/dev/null | grep -q 'does match' && { CERT_DIR=${f%/*}; break; }
    done
    if [[ -z $CERT_DIR ]]; then
        CERT_DIR=$(ask "Не найден серт для $DOMAIN. Папка с fullchain.pem/privkey.pem" "/etc/letsencrypt/live/$DOMAIN")
    fi
    [[ -f $CERT_DIR/fullchain.pem && -f $CERT_DIR/privkey.pem ]] || fatal "Нет fullchain.pem/privkey.pem в $CERT_DIR"
    # Монтируем корень certbot целиком: симлинки live/*.pem, смонтированные по одному, после renew протухают.
    [[ $CERT_DIR == /etc/letsencrypt/* ]] && CERT_MOUNT=/etc/letsencrypt || CERT_MOUNT=${CERT_DIR%/*}
    log_ok "Сертификат: $CERT_DIR"
}

build_inbound() {
    local p=$1 security network stream
    is_reality "$p" && security=reality || security=tls
    case $p in
        tcp_*)   network=tcp ;;
        xhttp_*) network=xhttp ;;
        grpc_*)  network=grpc ;;
        hy2)     network=hysteria ;;
    esac
    stream=$(jq -nc --arg net "$network" --arg sec "$security" --argjson reality "${REALITY:-null}" \
        --arg d "$DOMAIN" --arg cert "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/privkey.pem" \
        --arg rnd "$(openssl rand -hex 6)" --arg p "$p" '
        {network: $net, security: $sec}
        + (if $sec == "reality" then {realitySettings: $reality}
           else {tlsSettings: {
               serverName: $d,
               alpn: (if $p == "hy2" then ["h3"] elif $p == "grpc_tls" then ["h2"] else ["h2", "http/1.1"] end),
               certificates: [{certificateFile: $cert, keyFile: $key}]}} end)
        + (if $net == "xhttp" then {xhttpSettings: {mode: "auto", path: "/\($rnd)"}}
           elif $net == "grpc" then {grpcSettings: {serviceName: $rnd}}
           elif $net == "hysteria" then {hysteriaSettings: {version: 2}, finalmask: {quicParams: {congestion: "bbr"}}}
           else {} end)')
    if [[ $p == hy2 ]]; then
        jq -nc --arg tag "${TAG[$p]}" --argjson port "${PORT[$p]}" --argjson s "$stream" \
            '{tag: $tag, port: $port, listen: "0.0.0.0", protocol: "hysteria",
              settings: {clients: [], version: 2}, streamSettings: $s}'
    else
        jq -nc --arg tag "${TAG[$p]}" --argjson port "${PORT[$p]}" --argjson s "$stream" \
            '{tag: $tag, port: $port, protocol: "vless",
              settings: {clients: [], decryption: "none"},
              sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
              streamSettings: $s}'
    fi
}

# Bind-источник, которого нет на хосте, docker создаст пустой папкой — нода не поднимется.
check_compose_paths() {
    local src bad=0
    while read -r src; do
        [[ $src == ./* ]] && src=/opt/remnanode/${src#./}
        [[ -e $src ]] || { log_err "В $COMPOSE путь не существует: $src"; bad=1; }
    done < <(sed -nE 's|^[[:space:]]*- (\.?/[^:]+):.*|\1|p' "$COMPOSE")
    (( bad == 0 )) || fatal "Исправьте volumes в $COMPOSE" "Удалите или поправьте строки с несуществующими путями и запустите скрипт снова"
}

prepare_node() {
    local p need=0 hook=/etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh
    for p in "${SELECTED[@]}"; do is_tls "$p" && need=1; done
    (( need && ON_NODE )) || return 0
    [[ -f $COMPOSE ]] || fatal "Нет $COMPOSE" "Добавьте в volumes remnanode: - $CERT_MOUNT:$CERT_MOUNT:ro"
    if grep -qF -- "- $CERT_MOUNT:$CERT_MOUNT" "$COMPOSE"; then
        log_ok "$CERT_MOUNT уже смонтирован в remnanode"
    else
        check_compose_paths
        cp "$COMPOSE" "$COMPOSE.bak"
        sed -i -E "s|^([[:space:]]*)- /var/log/remnanode:/var/log/remnanode\$|&\n\1- $CERT_MOUNT:$CERT_MOUNT:ro|" "$COMPOSE"
        grep -qF -- "- $CERT_MOUNT:$CERT_MOUNT" "$COMPOSE" ||
            fatal "Не удалось добавить volume в $COMPOSE" "Добавьте вручную в volumes remnanode: - $CERT_MOUNT:$CERT_MOUNT:ro"
        log_info "Пересоздаю remnanode..."
        (cd /opt/remnanode && docker compose up -d remnanode) >/dev/null 2>&1 ||
            fatal "docker compose up не прошёл" "Бэкап: $COMPOSE.bak"
        log_ok "Volume $CERT_MOUNT добавлен (бэкап: $COMPOSE.bak)"
    fi
    if [[ $CERT_MOUNT == /etc/letsencrypt && ! -f $hook ]]; then
        mkdir -p "$(dirname "$hook")"
        printf '#!/bin/sh\ndocker restart remnanode\n' >"$hook" && chmod +x "$hook"
        log_ok "Хук перезапуска ноды после renew: $hook"
    fi
}

open_ports() {
    local p port l4
    (( ON_NODE )) && command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active' ||
        { log_warn "UFW не активен — откройте порты вручную при необходимости"; return 0; }
    for p in "${SELECTED[@]}"; do
        port=${PORT[$p]}; l4=$(proto_l4 "$p")
        if ufw status | grep -qE "^$port/$l4[[:space:]]+ALLOW"; then
            log_ok "Порт $port/$l4 уже открыт"
        else
            ufw allow "$port/$l4" >/dev/null && log_ok "Порт $port/$l4 открыт" || log_err "Не удалось открыть $port/$l4"
        fi
    done
}

pick_node() {
    local nodes ip matches i
    nodes=$(api_call GET /api/nodes) || exit 1
    ip=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
    matches=$(jq -c --arg d "$DOMAIN" --arg ip "$ip" '[.[] | select(.address == $d or .address == $ip)]' <<<"$nodes")
    if [[ $(jq length <<<"$matches") == 1 ]]; then
        NODE=$(jq -c '.[0]' <<<"$matches")
    else
        i=$(choose_index "Нода:" "$(jq -c '[.[] | "\(.name) — \(.address)"]' <<<"$nodes")") || exit 1
        NODE=$(jq -c ".[$i]" <<<"$nodes")
    fi
    log_ok "Нода: $(jq -r '"\(.name) (\(.address))"' <<<"$NODE")"
}

# Новые инбаунды профиля не работают, пока не включены в activeInbounds ноды.
activate_on_node() {
    local active
    if [[ $(jq -r '.configProfile.activeConfigProfileUuid // ""' <<<"$NODE") == "$PROFILE_UUID" ]]; then
        active=$(jq -c --argjson new "$NEW_UUIDS" '[.configProfile.activeInbounds[].uuid] + $new | unique' <<<"$NODE")
    else
        log_warn "На ноде активен другой профиль — будет переключена на «$PROFILE_NAME» со всеми его инбаундами"
        confirm "Переключить?" || { log_warn "Нода не изменена — включите инбаунды в панели вручную"; return; }
        active=$(jq -c '[.inbounds[].uuid]' <<<"$UPDATED_PROFILE")
    fi
    api_call PATCH /api/nodes "$(jq -nc --arg u "$(jq -r .uuid <<<"$NODE")" --arg pu "$PROFILE_UUID" --argjson a "$active" \
        '{uuid: $u, configProfile: {activeConfigProfileUuid: $pu, activeInbounds: $a}}')" >/dev/null
    log_ok "Инбаунды активированы на ноде"
}

create_hosts() {
    local p uuid prefix node_uuid
    node_uuid=$(jq -r .uuid <<<"$NODE")
    prefix=$(ask "Префикс названий хостов" "$(jq -r .name <<<"$NODE")")
    for p in "${SELECTED[@]}"; do
        uuid=$(jq -r --arg t "${TAG[$p]}" '.inbounds[] | select(.tag == $t) | .uuid' <<<"$UPDATED_PROFILE")
        api_call POST /api/hosts "$(jq -nc --arg pu "$PROFILE_UUID" --arg iu "$uuid" --arg r "$prefix ${NAME[$p]}" \
            --arg d "$DOMAIN" --argjson port "${PORT[$p]}" --arg n "$node_uuid" '
            {inbound: {configProfileUuid: $pu, configProfileInboundUuid: $iu},
             remark: $r[0:100], address: $d, port: $port, sni: $d,
             fingerprint: "chrome", securityLayer: "DEFAULT", nodes: [$n]}')" >/dev/null
        log_ok "Хост: $prefix ${NAME[$p]}"
    done
}

update_squads() {
    local squads n i input picked=() s body
    squads=$(api_call GET /api/internal-squads) || exit 1
    n=$(jq '.internalSquads | length' <<<"$squads")
    (( n > 0 )) || { log_warn "Внутренних сквадов нет — добавьте инбаунды в сквад вручную"; return; }
    echo ""; log_info "Внутренние сквады (Enter — все, или номера):"
    for ((i = 0; i < n; i++)); do echo -e "  ${BLUE}[$((i + 1))]${NC} $(jq -r ".internalSquads[$i].name" <<<"$squads")"; done
    read -rp "> " input
    input=${input//,/ }
    if [[ -z ${input// /} ]]; then
        for ((i = 0; i < n; i++)); do picked+=("$i"); done
    else
        for i in $input; do
            [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= n )) || { log_warn "Пропуск неверного номера: $i"; continue; }
            picked+=("$((i - 1))")
        done
    fi
    for i in "${picked[@]}"; do
        s=$(jq -c ".internalSquads[$i]" <<<"$squads")
        body=$(jq -c --argjson new "$NEW_UUIDS" '{uuid, inbounds: ([.inbounds[].uuid] + $new | unique)}' <<<"$s")
        api_call PATCH /api/internal-squads "$body" >/dev/null
        log_ok "Сквад: $(jq -r .name <<<"$s")"
    done
}

summary() {
    local p
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${GREEN}✓ Готово${NC} — профиль «$PROFILE_NAME», домен $DOMAIN"
    for p in "${SELECTED[@]}"; do printf '   • %-34s %5s/%s  %s\n' "${NAME[$p]}" "${PORT[$p]}" "$(proto_l4 "$p")" "${TAG[$p]}"; done
    if [[ " ${SELECTED[*]} " == *" hy2 "* ]]; then
        echo ""
        log_warn "Hysteria2 работает в Happ и INCY. Включите в панели: Настройки → Доп. опции → «Использовать JSON в базовой подписке»"
    fi
    echo "═══════════════════════════════════════════════════════════"
}

main() {
    echo -e "${BLUE}Remnawave — добавление протоколов${NC}\n"
    preflight
    panel_login
    pick_profile
    pick_domain
    pick_protocols
    pick_ports
    prepare_reality
    prepare_cert

    local p inbounds="[]"
    for p in "${SELECTED[@]}"; do
        inbounds=$(jq -c --argjson i "$(build_inbound "$p")" '. + [$i]' <<<"$inbounds")
    done

    if [[ $DRY_RUN == 1 ]]; then
        log_info "DRY_RUN: новые инбаунды (ничего не изменено):"
        jq . <<<"$inbounds"
        exit 0
    fi

    echo ""
    for p in "${SELECTED[@]}"; do echo "   • ${NAME[$p]} — ${PORT[$p]}/$(proto_l4 "$p") — ${TAG[$p]}"; done
    confirm "Применить?" || exit 0

    pick_node
    prepare_node
    UPDATED_PROFILE=$(api_call PATCH /api/config-profiles \
        "$(jq -nc --arg u "$PROFILE_UUID" --argjson c "$CONFIG" --argjson add "$inbounds" '{uuid: $u, config: ($c | .inbounds += $add)}')") || exit 1
    log_ok "Инбаунды добавлены в профиль"
    NEW_UUIDS=$(jq -c --argjson tags "$(jq -c '[.[].tag]' <<<"$inbounds")" \
        '[.inbounds[] | select(.tag as $t | $tags | index($t)) | .uuid]' <<<"$UPDATED_PROFILE")

    activate_on_node
    create_hosts
    update_squads
    open_ports
    summary
}

main "$@"
