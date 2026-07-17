# mclient

A pure-**mihomo** proxy **client** manager for Linux — menu-driven, for self-built
nodes, with easy add/delete/modify and rule-based traffic splitting (分流).

It is the client-side counterpart to a server tool like proxy-stack: a JSON node
store is the single source of truth, from which a mihomo `config.yaml` is
regenerated, validated (`mihomo -t`), and applied transactionally (auto-rollback
on failure). The generated config is JSON — valid YAML, which mihomo reads
directly — so the whole pipeline stays `jq`-driven and snapshot-testable.

## Quick start

```bash
git clone https://github.com/jinqians/mclient.git && cd mclient
sudo ./install.sh     # deps + mihomo binary + systemd unit + first node
mclient               # management menu (or `mc` when that name was free)
```

The installer drops a `mclient` shortcut (and `mc` unless something else — e.g.
Midnight Commander — already owns that name) into /usr/local/bin. When the
checkout is a git clone, the shortcut runs `git pull --ff-only` (10 s cap)
before opening the menu, so the tooling self-updates on every launch; runtime
state lives in gitignored `config/` and is never touched by updates. The
mihomo core itself updates from 服务管理 → 更新 mihomo 内核.

## Features

- **Nodes** — import by pasting (single, bulk, or a subscription URL), or add
  nodes through a multi-protocol wizard (VLESS+Reality / Snell / SS / Trojan /
  Hysteria2 / AnyTLS / TUIC / SOCKS5); list / modify / delete; latency test via
  the running mihomo. The paste box accepts three formats, freely mixed, one
  per line:
  1. **Share links** (schemes below); `vless://` links from proxy-stack's
     "show URI" import as-is.
  2. **Surge proxy lines** — `Name = snell, host, port, psk=…, version=4, …`
     (snell/ss/trojan/vmess/hysteria2/tuic/http/socks5) — the usual way
     link-less protocols like snell are handed out.
  3. **mihomo JSON proxy dicts** — `{"name":"n","type":"ssh","server":…}`;
     the store's `.proxy` is a raw mihomo dict, so ANY protocol mihomo
     supports can be imported this way even without a link format.
  Supported link schemes:
  - `vless://` — tcp / ws / httpupgrade / grpc / h2 / http / xhttp(splithttp),
    TLS & Reality, flow, packet-encoding
  - `vmess://` — v2rayN base64(JSON) with the same transports, plus the
    Shadowrocket base64 form
  - `trojan://` (tcp/ws/grpc, TLS & Reality), `anytls://`
  - `hysteria2://` / `hy2://` (obfs, port-hopping), `hysteria://` (v1),
    `tuic://` (v5 uuid:password and v4 token)
  - `ss://` — SIP002 incl. `2022-blake3-*` ciphers, `udp-over-tcp`, and the
    obfs / v2ray-plugin / shadow-tls plugins; legacy base64 form; `ssr://`
  - `snell://` (v1–v5, shadow-tls obfs), `socks://` / `socks5://`,
    `http(s)://user:pass@host` proxy links, `wireguard://` / `wg://`
- **Routing / 分流** — default policy is *China direct + ads rejected + rest via
  proxy* using MetaCubeX geosite/geoip rule-sets; add custom rules, switch
  rule/global/direct. Surge-style controls:
  - **Primary node** — pick which node the PROXY group exits through (menu:
    节点管理 → 设为主用节点); persists across restarts via
    `profile.store-selected`, live-switches the running core.
  - **Rule-set → exit binding** — add any remote rule-set (.mrs/.yaml/.list,
    GitHub URLs auto-mirrored) and bind it straight to a node, a group, or
    PROXY/DIRECT/REJECT.
  - **Groups** — select / url-test / fallback / load-balance / **smart**
    (mihomo's adaptive Surge-like group, with optional `policy-priority`
    weights, e.g. `HK:1.5`); rules can target groups by name.
- **Service & mode** — systemd service; interception mode is a pluggable seam:
  **TUN** (default, whole-host transparent) and **system-proxy** (mixed-port)
  work today; **tproxy / LAN-gateway (旁路由)** is reserved — the generator
  already emits its port, only the firewall wiring is left to add.
- **Dashboard** — external-controller API + optional local metacubexd Web UI:
  install/update, enable, disable, and uninstall from the menu. Binds
  127.0.0.1 only (never public); reach it remotely via an SSH tunnel
  (`ssh -L 9090:127.0.0.1:9090 user@server` → http://127.0.0.1:9090/ui/), the
  menu prints the exact command. Node switching, latency, connections, and
  policy-group selection are all live-editable there; selections persist via
  `profile.store-selected`.

## Layout

```
mc.sh  install.sh  uninstall.sh
lib/  common.sh i18n.sh core.sh config.sh nodes.sh routing.sh service.sh dashboard.sh
lang/ zh.sh en.sh
config/   runtime state (nodes.json / rules.json / settings.json / config.yaml) — gitignored
tests/    config-regression.sh (snapshot) + uri-parse.sh
```

## Tests

```bash
bash tests/config-regression.sh
bash tests/uri-parse.sh
bash tests/core-timeout.sh
bash tests/github-routing.sh
```

## Install troubleshooting

Pasted links finish on a whitespace-only line (including terminals that send a
carriage return). After import, mclient prints a separate config-validation
step. Validation is limited to 45 seconds by default so unreachable remote rule
providers cannot freeze the installer indefinitely. Override it when needed:

```bash
sudo MIHOMO_TEST_TIMEOUT=90 ./install.sh
```

The installer detects whether the public IP is in mainland China. Mainland
hosts try a list of GitHub mirrors in order (`https://cf.jinqians.com`,
`https://ghfast.top`, `https://gh-proxy.com`, `https://ghproxy.net`) for mihomo
releases, stock rule sets, and the dashboard; direct GitHub remains the final
automatic fallback. Other regions try direct GitHub first, then the mirrors.
Before a large download (mihomo binary, dashboard) every candidate source is
speed-probed in parallel (first 256 KB each, ≤8 s) and the fastest wins — a
slow preferred mirror is automatically demoted, not just waited on. The
transfer itself aborts only when it genuinely stalls (below 8 KB/s for 30 s)
rather than on a fixed total timeout, and failures move on to the next-fastest
source. Detection and the mirrors can be overridden explicitly:

```bash
sudo MC_REGION=CN MC_GITHUB_MIRROR=https://cf.jinqians.com ./install.sh   # primary mirror
sudo MC_GITHUB_MIRRORS="https://m1.example.com https://m2.example.com" ./install.sh  # full list
sudo MC_REGION=GLOBAL ./install.sh
```

## Extending to a LAN gateway (旁路由) later

Set interception mode `tproxy` in `settings.json`; `config.sh` already emits a
`tproxy-port`. The remaining work is the nftables/iptables redirect + firewall
rules in `service.sh` (marked as the extension seam) plus `allow-lan: true`.
