#!/usr/bin/env bash
# Прогон add-protocols.sh против фейковой панели: api() подменён, ответы — фикстуры.
# Запуск: bash test.sh   (нужны bash, jq, openssl; root/docker не нужны)
set -uo pipefail
cd "$(dirname "$0")"

LOG=$(mktemp)
# shellcheck source=/dev/null
source <(sed '$d' add-protocols.sh)   # всё, кроме вызова main

preflight() { ON_NODE=0; }
RW_URL=http://mock RW_TOKEN=t

PROFILE='{"uuid":"11111111-1111-1111-1111-111111111111","name":"Default-Profile","inbounds":[{"uuid":"22222222-2222-2222-2222-222222222222","tag":"Steal"}],
 "config":{"inbounds":[{"tag":"Steal","port":443,"protocol":"vless","streamSettings":{"network":"tcp","security":"reality",
 "realitySettings":{"xver":1,"dest":"/dev/shm/nginx.sock","privateKey":"PRIV","shortIds":["ab"],"serverNames":["node.example.com"]}}}],"outbounds":[]}}'

api() {
    echo "$1 $2 ${3:-}" >>"$LOG"
    case "$1 $2" in
        "GET /api/config-profiles") jq -nc --argjson p "$PROFILE" '{response: {total: 1, configProfiles: [$p]}}' ;;
        "PATCH /api/config-profiles")
            jq -c '{response: {uuid, inbounds: [.config.inbounds | to_entries[] | {uuid: "33333333-3333-3333-3333-33333333333\(.key)", tag: .value.tag}]}}' <<<"$3" ;;
        "GET /api/nodes") echo '{"response":[{"uuid":"44444444-4444-4444-4444-444444444444","name":"NL","address":"node.example.com",
            "configProfile":{"activeConfigProfileUuid":"11111111-1111-1111-1111-111111111111","activeInbounds":[{"uuid":"22222222-2222-2222-2222-222222222222"}]}}]}' ;;
        "GET /api/internal-squads") echo '{"response":{"total":1,"internalSquads":[{"uuid":"55555555-5555-5555-5555-555555555555","name":"Default-Squad","inbounds":[{"uuid":"22222222-2222-2222-2222-222222222222"}]}]}}' ;;
        *) echo '{"response":{"uuid":"66666666-6666-6666-6666-666666666666"}}' ;;
    esac
}
prepare_cert() { CERT_DIR=/etc/letsencrypt/live/node.example.com; }

# профиль 1, домен Enter, все протоколы, порты: 443 занят -> 9443, остальные Enter, применить, префикс Enter, сквады все
printf '1\n\n\n9443\n\n\n\n\n\n\ny\n\n\n' | main >/dev/null 2>&1 || { echo "FAIL: main упал"; cat "$LOG"; exit 1; }

cfg=$(grep '^PATCH /api/config-profiles' "$LOG" | cut -d' ' -f3-)
node=$(grep '^PATCH /api/nodes' "$LOG" | cut -d' ' -f3-)
squad=$(grep '^PATCH /api/internal-squads' "$LOG" | cut -d' ' -f3-)

check() { if jq -e "$2" >/dev/null <<<"$3"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi; }
FAILED=0
check "8 инбаундов в профиле"         '.config.inbounds | length == 8'                                  "$cfg"
check "tag = ПРОТОКОЛ_ПРОФИЛЬ"          '[.config.inbounds[].tag] | index("VLESS_GRPC_TLS_DEFAULT_PROFILE")' "$cfg"
check "TCP Reality на 9443"            '.config.inbounds[] | select(.tag=="VLESS_TCP_REALITY_DEFAULT_PROFILE") | .port == 9443' "$cfg"
check "Reality-ключ переиспользован"   '[.config.inbounds[] | select(.streamSettings.security=="reality") | .streamSettings.realitySettings.privateKey] | all(. == "PRIV")' "$cfg"
check "HY2 = hysteria v2 + h3"         '.config.inbounds[] | select(.protocol=="hysteria") | .settings.version == 2 and .streamSettings.tlsSettings.alpn == ["h3"]' "$cfg"
check "gRPC serviceName задан"         '.config.inbounds[] | select(.tag=="VLESS_GRPC_TLS_DEFAULT_PROFILE") | .streamSettings.grpcSettings.serviceName | length == 12' "$cfg"
check "нода: 8 активных инбаундов"     '.configProfile.activeInbounds | length == 8'                     "$node"
check "сквад: 8 инбаундов"             '.inbounds | length == 8'                                          "$squad"
hosts=$(grep -c '^POST /api/hosts' "$LOG")
[[ $hosts == 7 ]] && echo "ok   7 хостов" || { echo "FAIL хостов: $hosts"; FAILED=1; }
grep '^POST /api/hosts' "$LOG" | head -1 | cut -d' ' -f3- | jq -e '.nodes == ["44444444-4444-4444-4444-444444444444"]' >/dev/null &&
    echo "ok   хост привязан к ноде" || { echo "FAIL хост без ноды"; FAILED=1; }
rm -f "$LOG"
exit $FAILED
