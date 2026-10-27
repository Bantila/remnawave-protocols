**Русский** | [English](README.en.md)

# remnawave-protocols

Интерактивный скрипт: добавляет на ноду Remnawave нужные протоколы через API панели. Делает всё за один запуск: инбаунды в профиль, активация на ноде, хосты, внутренние сквады, сертификат и порты.

Рассчитан на ноду, установленную скриптом [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) (nginx-selfsteal на `/dev/shm/nginx.sock`, сертификат Let's Encrypt, `/opt/remnanode`), как в гайде [VPN-Remna-Guide](https://github.com/Bantila/VPN-Remna-Guide).

## Протоколы

| # | Протокол | Порт по умолчанию | tag |
|---|---|---|---|
| 1 | VLESS TCP Reality + Selfsteal | 443/tcp | `VLESS_TCP_REALITY_<ПРОФИЛЬ>` |
| 2 | VLESS TCP TLS | 8444/tcp | `VLESS_TCP_TLS_<ПРОФИЛЬ>` |
| 3 | VLESS XHTTP Reality + Selfsteal | 4443/tcp | `VLESS_XHTTP_REALITY_<ПРОФИЛЬ>` |
| 4 | VLESS XHTTP TLS | 2083/tcp | `VLESS_XHTTP_TLS_<ПРОФИЛЬ>` |
| 5 | Hysteria2 + TLS | 443/udp | `HYSTERIA2_<ПРОФИЛЬ>` |
| 6 | VLESS gRPC Reality + Selfsteal | 8443/tcp | `VLESS_GRPC_REALITY_<ПРОФИЛЬ>` |
| 7 | VLESS gRPC TLS | 2087/tcp | `VLESS_GRPC_TLS_<ПРОФИЛЬ>` |

`<ПРОФИЛЬ>` — имя профиля в верхнем регистре, все символы кроме букв и цифр заменены на `_`. Пример: `Default-Profile` → `DEFAULT_PROFILE`.

## Запуск

На сервере ноды под root:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Bantila/remnawave-protocols/main/add-protocols.sh)
```

Скрипт спросит:

1. **URL панели** и **API-токен**. Токен создаётся в панели: **Настройки → API-токены**. Если панель на этом же сервере, по умолчанию предлагается `http://127.0.0.1:3000`.
2. **Профиль**, в который добавить инбаунды.
3. **Домен ноды**. По умолчанию берётся из существующего Reality-инбаунда.
4. **Протоколы**. Номера через пробел или запятую. **Enter без ввода — все.**
5. **Порт** для каждого протокола. Enter — порт по умолчанию, `s` — пропустить протокол.
6. Подтверждение, префикс названий хостов, внутренние сквады (Enter — все).

Переменные окружения (необязательно):

| Переменная | Назначение |
|---|---|
| `RW_URL` | URL панели, чтобы не вводить вручную |
| `RW_TOKEN` | API-токен |
| `DRY_RUN=1` | только показать JSON новых инбаундов, ничего не менять |

```bash
DRY_RUN=1 RW_URL=https://panel.example.com bash <(curl -Ls https://raw.githubusercontent.com/Bantila/remnawave-protocols/main/add-protocols.sh)
```

## Что делает скрипт

**В панели (API):**

- `PATCH /api/config-profiles` — добавляет инбаунды в выбранный профиль. Инбаунды с уже существующим tag пропускаются, поэтому повторный запуск безопасен.
- `PATCH /api/nodes` — включает новые инбаунды в `activeInbounds` ноды. Без этого они не работают.
- `POST /api/hosts` — создаёт хост на каждый новый инбаунд и сразу привязывает его к ноде.
- `PATCH /api/internal-squads` — добавляет инбаунды в выбранные сквады.

**Reality:** ключи, shortId и serverNames копируются из существующего Reality-инбаунда профиля. Если его нет, ключ генерируется панелью (`/api/system/tools/x25519/generate`). Selfsteal-заглушка: `/dev/shm/nginx.sock`, `xver: 1`.

**На ноде** (только если выбран TLS-протокол или Hysteria2):

- Находит сертификат Let's Encrypt, который покрывает домен ноды, в том числе wildcard.
- Добавляет volume `/etc/letsencrypt:/etc/letsencrypt:ro` в `/opt/remnanode/docker-compose.yml` и пересоздаёт `remnanode`. Бэкап: `docker-compose.yml.bak`.
- Создаёт хук `/etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh`: перезапускает ноду после обновления сертификата.
- Открывает порты в UFW, если он активен.

## Требования

- Remnawave Panel 2.x/3.x, нода с Xray-core не ниже v26.3.27 (нужен для Hysteria2).
- `bash`, `curl`, `openssl`. `jq` скрипт установит сам.
- Права root на сервере ноды.

## Важно

- **Reality не на 443** (XHTTP/gRPC Reality на 4443/8443) работает, но ядро Xray пишет предупреждение, и выше риск блокировки IP. На 443/tcp помещается только один протокол.
- **Hysteria2** работает в клиентах **Happ** и **INCY**. В панели включите **Настройки → Доп. опции → «Использовать JSON в базовой подписке»**.
- Если на ноде активен другой профиль, скрипт спросит подтверждение перед переключением.

## Проверка

```bash
bash test.sh
```

Прогон против фейковой панели: проверяет tag, порты, Reality-ключи, Hysteria2, активацию на ноде, хосты и сквады. Нужны `bash`, `jq` и `openssl`.

## Благодарности

- [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) — установщик и подход к работе с API.
- [Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2](https://github.com/Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2) — идея подготовки ноды под доп. протоколы.

## Лицензия

[MIT](LICENSE)
