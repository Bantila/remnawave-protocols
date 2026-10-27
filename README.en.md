[Русский](README.md) | **English**

# remnawave-protocols

An interactive script that adds protocols to a Remnawave node through the panel API. One run does everything: inbounds in the config profile, activation on the node, hosts, internal squads, certificate and ports.

It targets nodes installed with [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) (nginx selfsteal on `/dev/shm/nginx.sock`, Let's Encrypt certificate, `/opt/remnanode`), as described in [VPN-Remna-Guide](https://github.com/Bantila/VPN-Remna-Guide).

## Protocols

| # | Protocol | Default port | tag |
|---|---|---|---|
| 1 | VLESS TCP Reality + Selfsteal | 443/tcp | `VLESS_TCP_REALITY_<PROFILE>` |
| 2 | VLESS TCP TLS | 8444/tcp | `VLESS_TCP_TLS_<PROFILE>` |
| 3 | VLESS XHTTP Reality + Selfsteal | 4443/tcp | `VLESS_XHTTP_REALITY_<PROFILE>` |
| 4 | VLESS XHTTP TLS | 2083/tcp | `VLESS_XHTTP_TLS_<PROFILE>` |
| 5 | Hysteria2 + TLS | 443/udp | `HYSTERIA2_<PROFILE>` |
| 6 | VLESS gRPC Reality + Selfsteal | 8443/tcp | `VLESS_GRPC_REALITY_<PROFILE>` |
| 7 | VLESS gRPC TLS | 2087/tcp | `VLESS_GRPC_TLS_<PROFILE>` |

`<PROFILE>` is the profile name in uppercase, with every character other than letters and digits replaced by `_`. Example: `Default-Profile` → `DEFAULT_PROFILE`.

## Usage

On the node server, as root:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Bantila/remnawave-protocols/main/add-protocols.sh)
```

The script asks for:

1. **Panel URL** and **API token**. Create the token in the panel under **Settings → API tokens**. If the panel runs on the same server, `http://127.0.0.1:3000` is offered as the default.
2. **Config profile** to add the inbounds to.
3. **Node domain**. The default comes from the existing Reality inbound.
4. **Protocols**: numbers separated by spaces or commas. **Press Enter with no input to select all.**
5. **Port** for each protocol. Enter keeps the default, `s` skips the protocol.
6. Confirmation, host name prefix, internal squads (Enter selects all).

Environment variables (optional):

| Variable | Purpose |
|---|---|
| `RW_URL` | Panel URL, so you don't have to type it |
| `RW_TOKEN` | API token |
| `DRY_RUN=1` | Print the JSON of the new inbounds and change nothing |

```bash
DRY_RUN=1 RW_URL=https://panel.example.com bash <(curl -Ls https://raw.githubusercontent.com/Bantila/remnawave-protocols/main/add-protocols.sh)
```

## What it does

**In the panel (API):**

- `PATCH /api/config-profiles` adds the inbounds to the selected profile. Inbounds whose tag already exists are skipped, so running the script again is safe.
- `PATCH /api/nodes` adds the new inbounds to the node's `activeInbounds`. They don't work without this.
- `POST /api/hosts` creates one host per new inbound and binds it to the node.
- `PATCH /api/internal-squads` adds the inbounds to the selected squads.

**Reality:** the keys, shortId and serverNames are copied from the profile's existing Reality inbound. If there is none, the panel generates a key (`/api/system/tools/x25519/generate`). Selfsteal target: `/dev/shm/nginx.sock`, `xver: 1`.

**On the node** (only when a TLS protocol or Hysteria2 is selected):

- Finds the Let's Encrypt certificate that covers the node domain, wildcards included.
- Adds the `/etc/letsencrypt:/etc/letsencrypt:ro` volume to `/opt/remnanode/docker-compose.yml` and recreates `remnanode`. Backup: `docker-compose.yml.bak`.
- Creates the `/etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh` hook, which restarts the node after the certificate renews.
- Opens the ports in UFW if it is active.

## Requirements

- Remnawave Panel 2.x/3.x and a node with Xray-core v26.3.27 or later (needed for Hysteria2).
- `bash`, `curl`, `openssl`. The script installs `jq` if it is missing.
- Root access on the node server.

## Notes

- **Reality on a port other than 443** (XHTTP/gRPC Reality on 4443/8443) works, but Xray logs a warning and the IP is more likely to get blocked. Only one protocol fits on 443/tcp.
- **Hysteria2** works in the **Happ** and **INCY** clients. In the panel, turn on **Settings → Additional options → "Use JSON in base subscription"**.
- If the node runs a different profile, the script asks before switching it.

## Testing

```bash
bash test.sh
```

Runs the script against a fake panel and checks tags, ports, Reality keys, Hysteria2, node activation, hosts and squads. Requires `bash`, `jq` and `openssl`.

## Credits

- [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy): the installer and the approach to the API.
- [Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2](https://github.com/Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2): the idea of preparing the node for extra protocols.

## License

[MIT](LICENSE)
