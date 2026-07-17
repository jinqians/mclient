#!/usr/bin/env bash
# config.sh — render mihomo config from the three JSON stores.
#
# nodes.json + rules.json + settings.json  ──►  config.yaml
#
# The output is JSON. JSON is a strict subset of YAML 1.2, so mihomo's YAML
# parser reads it verbatim; keeping it JSON lets the whole pipeline stay jq-only
# (no yq dependency) and makes the generator snapshot-testable. The node store is
# the single source of truth — config.yaml is disposable and always regenerated.
[[ -n "${_MC_CONFIG_LOADED:-}" ]] && return 0
_MC_CONFIG_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Seed default stores on first run ─────────────────────────────────────────
config_init_defaults() {
    mkdir -p "$MC_CONF_DIR"
    [[ -f "$NODES_JSON" ]]    || echo '[]' > "$NODES_JSON"
    [[ -f "$SETTINGS_JSON" ]] || config_default_settings > "$SETTINGS_JSON"
    [[ -f "$RULES_JSON" ]]    || config_default_rules    > "$RULES_JSON"
}

config_default_settings() {
    jq -n --arg secret "$(rand_hex 8)" '{
        intercept_mode: "tun",
        mixed_port: 7890,
        allow_lan: false,
        controller: "127.0.0.1:9090",
        secret: $secret,
        external_ui: "",
        log_level: "warning",
        ipv6: false,
        tcp_concurrent: true,
        tun: { stack: "mixed", auto_redirect: true, strict_route: true },
        dns: {
            enable: true,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": ["*.lan", "*.local", "+.pool.ntp.org"],
            "default-nameserver": ["223.5.5.5", "119.29.29.29"],
            nameserver: ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"],
            fallback: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
        }
    }'
}

# MetaCubeX meta-rules-dat .mrs sets: LAN/private + ads + China domains/IPs direct.
config_default_rules() {
    local base="https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo" \
          private_url reject_url proxy_url cn_domain_url cn_ip_url
    private_url="$(github_preferred_url "$base/geoip/private.mrs")"
    reject_url="$(github_preferred_url "$base/geosite/category-ads-all.mrs")"
    proxy_url="$(github_preferred_url "$base/geosite/geolocation-!cn.mrs")"
    cn_domain_url="$(github_preferred_url "$base/geosite/cn.mrs")"
    cn_ip_url="$(github_preferred_url "$base/geoip/cn.mrs")"
    jq -n \
        --arg private_url "$private_url" --arg reject_url "$reject_url" \
        --arg proxy_url "$proxy_url" --arg cn_domain_url "$cn_domain_url" --arg cn_ip_url "$cn_ip_url" '{
        mode: "rule",
        final: "PROXY",
        groups: [],
        rule_providers: {
            private:   { type:"http", behavior:"ipcidr", format:"mrs", interval:86400,
                         url:$private_url,
                         path:"./ruleset/private.mrs" },
            reject:    { type:"http", behavior:"domain", format:"mrs", interval:86400,
                         url:$reject_url,
                         path:"./ruleset/reject.mrs" },
            proxy:     { type:"http", behavior:"domain", format:"mrs", interval:86400,
                         url:$proxy_url,
                         path:"./ruleset/proxy.mrs" },
            cn_domain: { type:"http", behavior:"domain", format:"mrs", interval:86400,
                         url:$cn_domain_url,
                         path:"./ruleset/cn_domain.mrs" },
            cn_ip:     { type:"http", behavior:"ipcidr", format:"mrs", interval:86400,
                         url:$cn_ip_url,
                         path:"./ruleset/cn_ip.mrs" }
        },
        rules: [
            { type:"RULE-SET", payload:"private",   policy:"DIRECT" },
            { type:"RULE-SET", payload:"reject",    policy:"REJECT" },
            { type:"RULE-SET", payload:"proxy",     policy:"PROXY" },
            { type:"RULE-SET", payload:"cn_domain", policy:"DIRECT" },
            { type:"RULE-SET", payload:"cn_ip",     policy:"DIRECT", no_resolve:true }
        ]
    }'
}

# Rewrite only this project's stock MetaCubeX provider URLs. Custom providers
# remain untouched. This also migrates existing installs when their region or
# mirror preference changes.
config_route_default_github_urls() {
    [[ -f "$RULES_JSON" ]] || return 0
    local region mirror proxy_url tmp
    region="$(network_region_effective)"; mirror="${MC_GITHUB_MIRROR%/}"
    proxy_url="$(github_preferred_url 'https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/geolocation-!cn.mrs')"
    tmp="$(mktemp)"
    if jq --arg region "$region" --arg mirror "$mirror" --arg proxy_url "$proxy_url" '
        .rule_providers.proxy //= {
            type:"http", behavior:"domain", format:"mrs", interval:86400,
            url:$proxy_url, path:"./ruleset/proxy.mrs"
        }
        | if any(.rules[]?; .type == "RULE-SET" and .payload == "proxy")
          then .
          else .rules = ((.rules // []) + [{type:"RULE-SET", payload:"proxy", policy:"PROXY"}])
          end
        |
        .rule_providers |= with_entries(
            if (.value.url | type) == "string"
               and (.value.url | contains("https://github.com/MetaCubeX/meta-rules-dat/"))
            then .value.url |= (
                capture("(?<direct>https://github\\.com/MetaCubeX/meta-rules-dat/.*)").direct as $direct
                | if $region == "CN" then $mirror + "/" + $direct else $direct end
            )
            else . end
        )
    ' "$RULES_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$RULES_JSON"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ── Pure builder: stores → mihomo config JSON on stdout (snapshot-testable) ───
# Node shape: { tag, groups:[...], proxy:{ mihomo proxy dict, .name == tag } }.
# proxies = every node's .proxy; PROXY/AUTO groups collect all node tags; extra
# per-region groups come from rules.groups. rules become "TYPE,payload,policy"
# lines with a trailing MATCH,<final>.
config_build() {
    local settings nodes rules
    settings=$(cat "$SETTINGS_JSON") || return 1
    nodes=$(cat "$NODES_JSON")       || return 1
    rules=$(cat "$RULES_JSON")       || return 1

    # mihomo's built-in geo downloader is mirror-unaware; point it at the
    # region-preferred URLs so a missing MMDB can never hang startup/validation
    # behind a blocked GitHub (dns.fallback's default fallback-filter needs it).
    local geo_base="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
    local geox_mmdb geox_geoip geox_geosite geox_asn
    geox_mmdb="$(github_preferred_url "$geo_base/country.mmdb")"
    geox_geoip="$(github_preferred_url "$geo_base/geoip.dat")"
    geox_geosite="$(github_preferred_url "$geo_base/geosite.dat")"
    geox_asn="$(github_preferred_url "$geo_base/GeoLite2-ASN.mmdb")"

    jq -n \
        --argjson s "$settings" \
        --argjson nodes "$nodes" \
        --arg geox_mmdb "$geox_mmdb" --arg geox_geoip "$geox_geoip" \
        --arg geox_geosite "$geox_geosite" --arg geox_asn "$geox_asn" \
        --argjson r "$rules" '
        ($nodes | map(.proxy)) as $proxies
        | ($nodes | map(.tag))  as $tags
        | ($s.intercept_mode // "tun") as $mode
        | {
            "mixed-port":          ($s.mixed_port // 7890),
            "allow-lan":           ($s.allow_lan // false),
            "ipv6":                ($s.ipv6 // false),
            "tcp-concurrent":      ($s.tcp_concurrent // true),
            "mode":                ($r.mode // "rule"),
            "log-level":           ($s.log_level // "warning"),
            "external-controller": ($s.controller // "127.0.0.1:9090"),
            "secret":              ($s.secret // ""),
            "geo-auto-update":     false,
            "geox-url": {
                mmdb:    $geox_mmdb,
                geoip:   $geox_geoip,
                geosite: $geox_geosite,
                asn:     $geox_asn
            }
          }
        + (if ($s.external_ui // "") != "" then { "external-ui": $s.external_ui } else {} end)
        # ── interception mode (pluggable): tun today, system also supported,
        #    tproxy/gateway reserved for a later extension ──
        + (if $mode == "tun" then
              { tun: {
                    enable: true,
                    stack: ($s.tun.stack // "mixed"),
                    "auto-route": true,
                    "auto-redirect": ($s.tun.auto_redirect // true),
                    "strict-route": ($s.tun.strict_route // true),
                    "auto-detect-interface": true,
                    "dns-hijack": ["any:53", "tcp://any:53"]
              } }
           elif $mode == "tproxy" then
              { "tproxy-port": ($s.tproxy_port // 7895) }   # gateway mode: firewall wiring lives in service.sh
           else {} end)
        + { sniffer: {
              enable: true,
              "force-dns-mapping": true,
              "parse-pure-ip": true,
              sniff: {
                  HTTP: { ports: [80, "8080-8880"], "override-destination": true },
                  TLS:  { ports: [443, 8443] },
                  QUIC: { ports: [443, 8443] }
              }
          } }
        + { dns: ($s.dns // { enable: true, "enhanced-mode": "fake-ip",
                              "fake-ip-range": "198.18.0.1/16",
                              nameserver: ["223.5.5.5", "119.29.29.29"] }) }
        + { profile: { "store-selected": true, "store-fake-ip": true } }
        + { proxies: $proxies }
        + { "proxy-groups": (
              ($s.primary_node // "") as $primary
              | (["AUTO"] + $tags + ["DIRECT"]) as $proxy_list
              | [ { name: "PROXY", type: "select",
                    # The first entry is the boot-time default; a chosen primary
                    # node moves to the front (live switching persists via
                    # profile.store-selected).
                    proxies: (if $primary != "" and ($proxy_list | index($primary)) != null
                              then [$primary] + ($proxy_list | map(select(. != $primary)))
                              else $proxy_list end) },
                  { name: "AUTO", type: "url-test",
                    url: "http://www.gstatic.com/generate_204",
                    interval: 300, tolerance: 50,
                    proxies: (if ($tags | length) > 0 then $tags else ["DIRECT"] end) }
              ]
              + ( ($r.groups // []) | map(
                    . as $g
                    | ($g.type // "select") as $gt
                    | { name: $g.name, type: $gt, proxies: ($g.proxies // ["DIRECT"]) }
                    + (if (["url-test","fallback","load-balance"] | index($gt)) != null then
                          { url: ($g.url // "http://www.gstatic.com/generate_204"),
                            interval: ($g.interval // 300) }
                       else {} end)
                    # Pass through any extra tuning keys untouched
                    # (e.g. smart policy-priority, load-balance strategy).
                    + ($g | del(.name, .type, .proxies, .url, .interval))
                ) )
          ) }
        + { "rule-providers": ($r.rule_providers // {}) }
        + { rules: (
              ( ($r.rules // []) | map(
                  [ .type, (.payload // empty), .policy,
                    (if .no_resolve then "no-resolve" else empty end) ]
                  | join(",")
              ) )
              + [ "MATCH," + ($r.final // "PROXY") ]
          ) }
    '
}

# Write the generated config to $MIHOMO_CFG (used by the "regenerate" action and
# by mc_apply's transactional path in core.sh).
config_generate() {
    mkdir -p "$MC_CONF_DIR"
    local tmp; tmp=$(mktemp)
    if config_build > "$tmp" && jq -e . "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$MIHOMO_CFG"
        return 0
    fi
    rm -f "$tmp"
    log_error "$(t config.gen_fail)"
    return 1
}
