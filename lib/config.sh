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
    config_migrate_settings
    config_migrate_rules
}

config_default_settings() {
    local region; region="$(network_region_effective)"
    jq -n --arg secret "$(rand_hex 8)" --arg region "$region" '{
        intercept_mode: "tun",
        mixed_port: 7890,
        allow_lan: false,
        controller: "127.0.0.1:9090",
        secret: $secret,
        external_ui: "",
        log_level: "warning",
        ipv6: false,
        tcp_concurrent: true,
        unified_delay: true,
        quic_policy: "block",
        tun: { stack: "mixed", mtu: 1500, auto_redirect: true, strict_route: true },
        dns: {
            enable: true,
            ipv6: false,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": ["*.lan", "*.local", "+.pool.ntp.org",
                               "rule-set:private", "rule-set:direct", "rule-set:china"],
            "default-nameserver": (if $region == "CN" then
                ["223.5.5.5", "119.29.29.29"]
              else ["1.1.1.1", "8.8.8.8"] end),
            # Outside CN every resolver is pinned #DIRECT: with respect-rules
            # an untagged DoH server falls through to the final policy (PROXY),
            # so answers get geolocated to the proxy exit instead of locally.
            nameserver: (if $region == "CN" then
                ["https://1.1.1.1/dns-query#PROXY", "https://8.8.8.8/dns-query#PROXY"]
              else ["https://1.1.1.1/dns-query#DIRECT", "https://8.8.8.8/dns-query#DIRECT"] end),
            "direct-nameserver": (if $region == "CN" then
                ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]
              else ["https://1.1.1.1/dns-query#DIRECT", "https://8.8.8.8/dns-query#DIRECT"] end),
            "proxy-server-nameserver": (if $region == "CN" then
                ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]
              else ["https://1.1.1.1/dns-query#DIRECT", "https://8.8.8.8/dns-query#DIRECT"] end),
            "respect-rules": true,
            "nameserver-policy": {
                "rule-set:tracking,advertising": "rcode://success",
                "rule-set:private,direct,download,apple_cn,china":
                    (if $region == "CN" then
                        ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]
                     else ["https://1.1.1.1/dns-query#DIRECT", "https://8.8.8.8/dns-query#DIRECT"] end),
                "rule-set:ai,telegram,social,games,netflix,youtube,streaming,apple,google,microsoft,proxy":
                    (if $region == "CN" then
                        ["https://1.1.1.1/dns-query#PROXY", "https://8.8.8.8/dns-query#PROXY"]
                     else ["https://1.1.1.1/dns-query#DIRECT", "https://8.8.8.8/dns-query#DIRECT"] end)
            }
        }
    }'
}

# Add newly introduced performance settings without replacing deliberate user
# customisation. The stock DNS layouts shipped by older releases (two legacy
# CN lists, plus the untagged non-CN DoH list that leaked queries through the
# proxy) are recognised and upgraded; any other nameserver list is treated as
# user-managed.
config_migrate_settings() {
    [[ -f "$SETTINGS_JSON" ]] || return 0
    local defaults tmp
    defaults="$(config_default_settings)" || return 1
    tmp="$(mktemp)"
    if jq --argjson d "$defaults" '
        . as $old
        | ($d * .)
        | .tun = ($d.tun * ($old.tun // {}))
        | (($old.dns // {}) as $dns
           | (($dns["respect-rules"] // null) == null
              and ($dns["proxy-server-nameserver"] // null) == null
              and (($dns.nameserver // []) == ["223.5.5.5", "119.29.29.29"]
                   or ($dns.nameserver // []) == ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]))
          ) as $legacy_dns
        | (($old.dns // {} | .nameserver // [])
             == ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
          ) as $stock_global_dns
        | if $legacy_dns or $stock_global_dns then
              .dns = ($d.dns * ($old.dns // {}))
              | .dns.nameserver = $d.dns.nameserver
              | .dns["direct-nameserver"] = $d.dns["direct-nameserver"]
              | .dns["proxy-server-nameserver"] = $d.dns["proxy-server-nameserver"]
              | .dns["nameserver-policy"] = $d.dns["nameserver-policy"]
              | .dns["respect-rules"] = true
              | .dns |= del(.fallback)
          else
              .dns = ($d.dns * ($old.dns // {}))
          end
    ' "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SETTINGS_JSON"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Curated domain and IP categories based on the compact structure used by
# MIHOMO_YAMLS. Service categories initially share PROXY; users can prepend a
# custom rule from the menu to bind any category to a dedicated node/group.
config_default_rules() {
    local base="https://github.com/666OS/rules/raw/release/mihomo"
    jq -n --arg base "$base" '{
        schema_version: 2,
        mode: "rule",
        final: "PROXY",
        groups: [],
        rule_providers: {
            tracking:     {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Tracking.mrs"),path:"./ruleset/tracking.mrs"},
            advertising:  {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Advertising.mrs"),path:"./ruleset/advertising.mrs"},
            private:      {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Private.mrs"),path:"./ruleset/private.mrs"},
            direct:       {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Direct.mrs"),path:"./ruleset/direct.mrs"},
            download:     {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Download.mrs"),path:"./ruleset/download.mrs"},
            apple_cn:     {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/AppleCN.mrs"),path:"./ruleset/apple_cn.mrs"},
            ai:           {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/AI.mrs"),path:"./ruleset/ai.mrs"},
            telegram:     {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Telegram.mrs"),path:"./ruleset/telegram.mrs"},
            social:       {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/SocialMedia.mrs"),path:"./ruleset/social.mrs"},
            games:        {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Games.mrs"),path:"./ruleset/games.mrs"},
            netflix:      {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Netflix.mrs"),path:"./ruleset/netflix.mrs"},
            youtube:      {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/YouTube.mrs"),path:"./ruleset/youtube.mrs"},
            streaming:    {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Streaming.mrs"),path:"./ruleset/streaming.mrs"},
            apple:        {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Apple.mrs"),path:"./ruleset/apple.mrs"},
            google:       {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Google.mrs"),path:"./ruleset/google.mrs"},
            microsoft:    {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Microsoft.mrs"),path:"./ruleset/microsoft.mrs"},
            proxy:        {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/Proxy.mrs"),path:"./ruleset/proxy.mrs"},
            china:        {type:"http",behavior:"domain",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/domain/China.mrs"),path:"./ruleset/china.mrs"},
            advertising_ip:{type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Advertising.mrs"),path:"./ruleset/advertising_ip.mrs"},
            private_ip:   {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Private.mrs"),path:"./ruleset/private_ip.mrs"},
            ai_ip:        {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/AI.mrs"),path:"./ruleset/ai_ip.mrs"},
            telegram_ip:  {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Telegram.mrs"),path:"./ruleset/telegram_ip.mrs"},
            social_ip:    {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/SocialMedia.mrs"),path:"./ruleset/social_ip.mrs"},
            netflix_ip:   {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Netflix.mrs"),path:"./ruleset/netflix_ip.mrs"},
            streaming_ip: {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Streaming.mrs"),path:"./ruleset/streaming_ip.mrs"},
            google_ip:    {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Google.mrs"),path:"./ruleset/google_ip.mrs"},
            proxy_ip:     {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/Proxy.mrs"),path:"./ruleset/proxy_ip.mrs"},
            china_ip:     {type:"http",behavior:"ipcidr",format:"mrs",interval:86400,proxy:"PROXY",url:($base+"/ip/China.mrs"),path:"./ruleset/china_ip.mrs"}
        },
        rules: [
            {type:"RULE-SET",payload:"tracking",policy:"REJECT"},
            {type:"RULE-SET",payload:"advertising",policy:"REJECT"},
            {type:"RULE-SET",payload:"private",policy:"DIRECT"},
            {type:"RULE-SET",payload:"direct",policy:"DIRECT"},
            {type:"RULE-SET",payload:"download",policy:"DIRECT"},
            {type:"RULE-SET",payload:"apple_cn",policy:"DIRECT"},
            {type:"RULE-SET",payload:"ai",policy:"PROXY"},
            {type:"RULE-SET",payload:"telegram",policy:"PROXY"},
            {type:"RULE-SET",payload:"social",policy:"PROXY"},
            {type:"RULE-SET",payload:"games",policy:"PROXY"},
            {type:"RULE-SET",payload:"netflix",policy:"PROXY"},
            {type:"RULE-SET",payload:"youtube",policy:"PROXY"},
            {type:"RULE-SET",payload:"streaming",policy:"PROXY"},
            {type:"RULE-SET",payload:"apple",policy:"PROXY"},
            {type:"RULE-SET",payload:"google",policy:"PROXY"},
            {type:"RULE-SET",payload:"microsoft",policy:"PROXY"},
            {type:"RULE-SET",payload:"proxy",policy:"PROXY"},
            {type:"RULE-SET",payload:"china",policy:"DIRECT"},
            {type:"RULE-SET",payload:"advertising_ip",policy:"REJECT",no_resolve:true},
            {type:"RULE-SET",payload:"private_ip",policy:"DIRECT",no_resolve:true},
            {type:"RULE-SET",payload:"ai_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"telegram_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"social_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"netflix_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"streaming_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"google_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"proxy_ip",policy:"PROXY",no_resolve:true},
            {type:"RULE-SET",payload:"china_ip",policy:"DIRECT",no_resolve:true}
        ]
    }'
}

config_migrate_rules() {
    [[ -f "$RULES_JSON" ]] || return 0
    local defaults tmp
    defaults="$(config_default_rules)" || return 1
    tmp="$(mktemp)"
    if jq --argjson d "$defaults" '
        . as $old
        | (["private","reject","proxy","cn_domain","cn_ip"]
           | all(. as $k | ($old.rule_providers[$k] != null))) as $legacy_stock
        | if (($old.schema_version // 1) < 2 and $legacy_stock) then
              (["private","reject","proxy","cn_domain","cn_ip"]) as $old_keys
              | ($old.rule_providers // {} | with_entries(select(.key as $k | ($old_keys | index($k) | not)))) as $custom_providers
              | ($old.rules // [] | map(select((.type != "RULE-SET") or (.payload as $p | ($old_keys | index($p) | not))))) as $custom_rules
              | $d
              | .mode = ($old.mode // .mode)
              | .final = ($old.final // .final)
              | .groups = ($old.groups // [])
              | .rule_providers += $custom_providers
              | .rules = ($custom_rules + .rules)
          else $old end
    ' "$RULES_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$RULES_JSON"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Restore official URLs for this project's stock rule providers and make mihomo
# fetch them through PROXY. Custom providers remain untouched.
config_route_default_github_urls() {
    [[ -f "$RULES_JSON" ]] || return 0
    local proxy_url tmp
    proxy_url='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/geolocation-!cn.mrs'
    tmp="$(mktemp)"
    if jq --arg proxy_url "$proxy_url" '
        .rule_providers.proxy //= {
            type:"http", behavior:"domain", format:"mrs", interval:86400, proxy:"PROXY",
            url:$proxy_url, path:"./ruleset/proxy.mrs"
        }
        | if any(.rules[]?; .type == "RULE-SET" and .payload == "proxy")
          then .
          else .rules = ((.rules // []) + [{type:"RULE-SET", payload:"proxy", policy:"PROXY"}])
          end
        |
        .rule_providers |= with_entries(
            if (.value.url | type) == "string"
               and ((.value.url | contains("https://github.com/MetaCubeX/meta-rules-dat/"))
                    or (.value.url | contains("https://github.com/666OS/rules/")))
            then .value.url |= capture("(?<direct>https://github\\.com/(MetaCubeX/meta-rules-dat|666OS/rules)/.*)").direct
                 | .value.proxy = "PROXY"
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

    # Geo auto-update is disabled. The bootstrap path pre-fetches the MMDB when
    # needed; keep official URLs in the generated runtime config.
    local geo_base="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
    local geox_mmdb geox_geoip geox_geosite geox_asn
    geox_mmdb="$geo_base/country.mmdb"
    geox_geoip="$geo_base/geoip.dat"
    geox_geosite="$geo_base/geosite.dat"
    geox_asn="$geo_base/GeoLite2-ASN.mmdb"

    jq -n \
        --argjson s "$settings" \
        --argjson nodes "$nodes" \
        --arg geox_mmdb "$geox_mmdb" --arg geox_geoip "$geox_geoip" \
        --arg geox_geosite "$geox_geosite" --arg geox_asn "$geox_asn" \
        --argjson r "$rules" '
        def valid_rule_set_ref($providers):
            if startswith("rule-set:") then
                (ltrimstr("rule-set:") | split(",")
                 | all(. as $name | ($providers | index($name)) != null))
            else true end;
        ($nodes | map(.proxy)) as $proxies
        | ($nodes | map(.tag))  as $tags
        | ($r.rule_providers // {} | keys) as $provider_names
        | ($s.intercept_mode // "tun") as $mode
        | {
            "mixed-port":          ($s.mixed_port // 7890),
            "allow-lan":           ($s.allow_lan // false),
            "ipv6":                ($s.ipv6 // false),
            "tcp-concurrent":      ($s.tcp_concurrent // true),
            "unified-delay":       ($s.unified_delay // true),
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
                    mtu: ($s.tun.mtu // 1500),
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
        + { dns: (($s.dns // { enable: true, "enhanced-mode": "fake-ip",
                               "fake-ip-range": "198.18.0.1/16",
                               nameserver: ["223.5.5.5", "119.29.29.29"] })
              | if (."fake-ip-filter" | type) == "array" then
                    ."fake-ip-filter" |= map(select(valid_rule_set_ref($provider_names)))
                else . end
              | if (."nameserver-policy" | type) == "object" then
                    ."nameserver-policy" |= with_entries(
                        select(.key | valid_rule_set_ref($provider_names)))
                else . end
              | if ."nameserver-policy" == {} then del(."nameserver-policy") else . end) }
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
              (if ($s.quic_policy // "block") == "block" then
                   ["AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"]
               else [] end)
              + ( ($r.rules // []) | map(
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
