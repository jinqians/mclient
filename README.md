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
- **Routing / 分流** — compact enhanced categories inspired by
  [MIHOMO_YAMLS](https://github.com/HenryChiao/MIHOMO_YAMLS), backed by the
  maintained `666OS/rules` MRS data: ads/tracking, private/direct/download,
  AI, Telegram/social, games, Netflix/YouTube/streaming, Apple/Google/Microsoft,
  generic proxy and China domain/IP rules. Custom rules can override any
  category; rule/global/direct modes remain available. Surge-style controls:
  - **Primary node** — pick which node the PROXY group exits through (menu:
    节点管理 → 设为主用节点); persists across restarts via
    `profile.store-selected`, live-switches the running core.
  - **Rule-set → exit binding** — add any remote rule-set (.mrs/.yaml/.list).
    GitHub providers keep their official URLs and update through `PROXY`; bind
    each rule-set straight to a node, a group, or PROXY/DIRECT/REJECT.
  - **Groups** — select / url-test / fallback / load-balance / **smart**
    (mihomo's adaptive Surge-like group, with optional `policy-priority`
    weights, e.g. `HK:1.5`); rules can target groups by name.
  - **Chained proxy (链式代理)** — a standalone node-menu entry (not tied to
    node adding) attaches a front node to a landing node via mihomo's
    `dialer-proxy`: traffic flows local → front → landing → target. Loops are
    rejected up front; clearing the chain is the same entry with `-`.
- **Service & mode** — systemd service; interception mode is a pluggable seam:
  **TUN** (default, whole-host transparent) and **system-proxy** (mixed-port)
  work today; tproxy stays reserved. The **LAN gateway / 旁路由** is an
  *optional add-on toggle* on top of TUN — off by default, never part of the
  install flow (see its section below). A "Regenerate and apply config" menu
  entry rebuilds config.yaml with validation + rollback (plain restart alone
  never regenerates). Fresh installs use MTU 1500 and block website QUIC/UDP
  443 by default so TCP-based proxies can fall back to the usually more stable
  HTTPS/TCP path; both editable from Service & Mode. The two latency-test URLs
  have their own "Edit test URLs" entry in the node menu, next to the latency
  test itself: nodes/AUTO use a foreign endpoint, and DIRECT — being simply
  the no-proxy case — shares it, except in mainland CN where the direct path
  cannot reach it and a domestic endpoint is used instead.
- **Region-aware DNS** — TUN hijacks system DNS into fake-IP mode. In mainland
  China, foreign DoH queries go through `PROXY`, while direct traffic and proxy
  server hostnames use Ali/Tencent DoH to avoid a DNS dependency loop. Outside
  mainland China, Cloudflare/Google DNS is used directly. DNS policy and fake-IP
  filtering follow the same direct/proxy/ad rule sets. Existing stock DNS and
  the previous five-rule layout migrate automatically; custom nameservers,
  custom rules and custom groups are preserved.
- **IPv6 / WebRTC leak guard** — traffic that goes through mihomo can only
  ever show the proxy exit's IP, so a WebRTC "real IP" leak means traffic
  bypassed the TUN — in practice native IPv6, which `ipv6: false` mihomo does
  not capture. While proxying is v4-only, mclient disables host IPv6
  (persisted via `/etc/sysctl.d/98-mclient-ipv6.conf`, synced on every apply);
  the guard stands down automatically if IPv6 proxying is enabled, and can be
  toggled in the network settings. In side-router mode LAN clients' own IPv6
  still bypasses this host — disable IPv6/DHCPv6 on the main router. (A
  browser listing a `192.168.x.x` host candidate is local-only mDNS info, not
  a proxy leak.)
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

The installer detects whether the public IP is in mainland China. Before the
proxy service exists, mainland hosts try a list of GitHub mirrors in order
(`https://cf.jinqians.com`, `https://ghfast.top`, `https://gh-proxy.com`,
`https://ghproxy.net`), with direct GitHub as the final fallback. Once mclient
is running, direct GitHub is tried first through TUN and mirrors become fallback
sources only. Runtime rule providers always keep official GitHub URLs and fetch
through `PROXY`. Other regions also try direct GitHub first. Before a large
download (mihomo binary, dashboard) every candidate source is
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

The region is detected once at install and cached. If the box later moves
(e.g. overseas → mainland), switch it from the main menu ("Network region"):
picking CN/GLOBAL — or re-detecting, best with the service stopped so the
probe does not report the proxy exit's location — re-derives every stock
region-dependent setting (DNS layout, DIRECT test endpoint, mirror
preference) while custom values are left untouched.

## LAN gateway (旁路由) add-on

Optional and off by default — single-host use never needs it. Toggle it under
服务与模式 → 网关/旁路由开关. When enabled, mihomo keeps running in TUN but
additionally opens `allow-lan`, listens for LAN DNS on `0.0.0.0:53`, and
mclient enables persistent IPv4 forwarding
(`/etc/sysctl.d/99-mclient-gateway.conf`). Then point each LAN device — or the
main router's DHCP options — at this host's IP for **both gateway and DNS**.
Free local port 53 first if something like systemd-resolved holds it; a failed
start validates and rolls back automatically. Toggling off (or leaving TUN
mode, which disables the add-on automatically) removes the forwarding drop-in.
(tproxy remains a reserved seam: the generator already emits `tproxy-port`,
only the firewall wiring is left.)
