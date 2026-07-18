#!/usr/bin/env bash
# nodes.sh — node store (single source of truth) + import from share links.
#
# A "node" is { tag, groups:[...], proxy:{...} } where .proxy is a ready-to-emit
# mihomo proxy dict whose .name equals .tag. Importers build .proxy; the config
# generator just collects them. This makes proxy-stack's exports first-class:
# its reality_show_uri emits exactly the vless:// links parsed here.
[[ -n "${_MC_NODES_LOADED:-}" ]] && return 0
_MC_NODES_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"   # mc_apply (transactional regenerate+restart)

# ── Store primitives ─────────────────────────────────────────────────────────
_nodes_load() { mkdir -p "$MC_CONF_DIR"; [[ -f "$NODES_JSON" ]] || echo '[]' > "$NODES_JSON"; cat "$NODES_JSON"; }
_nodes_save() { mkdir -p "$MC_CONF_DIR"; echo "$1" > "$NODES_JSON"; }
_nodes_count() { _nodes_load | jq 'length' 2>/dev/null; }
_nodes_get()  { _nodes_load | jq --arg t "$1" 'map(select(.tag == $t)) | .[0] // empty' 2>/dev/null; }
_nodes_tags() { _nodes_load | jq -r '.[].tag' 2>/dev/null; }

# Upsert one node JSON by tag; ensures .proxy.name tracks .tag.
_nodes_upsert() {
    local node="$1" tag
    tag=$(echo "$node" | jq -r '.tag')
    node=$(echo "$node" | jq '.proxy.name = .tag')
    local all; all=$(_nodes_load)
    all=$(echo "$all" | jq --arg t "$tag" --argjson n "$node" 'map(select(.tag != $t)) + [$n]')
    _nodes_save "$all"
}

# Give a node a unique tag if the requested one is taken (…-2, …-3, …).
_nodes_unique_tag() {
    local base="$1" tag="$1" i=2 taken
    taken="$(_nodes_tags)"
    while printf '%s\n' "$taken" | grep -qx "$tag"; do tag="${base}-${i}"; ((i++)); done
    printf '%s' "$tag"
}

# ── base64 (URL-safe tolerant), reads stdin ──────────────────────────────────
_b64d() {
    local s; s="$(cat)"; s="${s//$'\n'/}"; s="${s//-/+}"; s="${s//_//}"
    case $(( ${#s} % 4 )) in 2) s="${s}==";; 3) s="${s}=";; esac
    printf '%s' "$s" | base64 -d 2>/dev/null || printf '%s' "$s" | base64 -D 2>/dev/null
}

# _split_hostport <host[:port][/path]> [default-port] — strips any path part;
# IPv6 hosts come bracketed. Fails when the port is missing and no default given.
_split_hostport() {
    local hp="$1" def="${2:-}" host port
    hp="${hp%%/*}"
    if [[ "$hp" == \[*\]:* ]]; then
        host="${hp%%]*}"; host="${host#[}"; port="${hp##*:}"
    elif [[ "$hp" == \[*\] ]]; then
        host="${hp#[}"; host="${host%]}"; port="$def"
    elif [[ "$hp" == *:* ]]; then
        host="${hp%:*}"; port="${hp##*:}"
    else
        host="$hp"; port="$def"
    fi
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\n' "$host" "$port"
}

# _qs_into <assoc-array-name> <query-string> — decode a query string into an
# associative array without word-splitting/globbing surprises.
_qs_into() {
    local -n _qs_ref="$1"
    local query="$2" kv k v
    while [[ -n "$query" ]]; do
        kv="${query%%&*}"
        [[ "$kv" == "$query" ]] && query="" || query="${query#*&}"
        [[ -z "$kv" ]] && continue
        k="${kv%%=*}"; v=""; [[ "$kv" == *=* ]] && v="${kv#*=}"
        [[ -n "$k" ]] && _qs_ref["$k"]="$(urldecode "$v")"
    done
}

# _split_uri <uri> <scheme://> — sets REPLY_NAME (decoded fragment), REPLY_QUERY,
# REPLY_AUTHORITY (userinfo@host:port, path stripped by callers via _split_hostport).
_split_uri() {
    local uri="$1" scheme="$2" rest
    [[ "$uri" == ${scheme}* ]] || return 1
    rest="${uri#"$scheme"}"
    REPLY_NAME=""; REPLY_QUERY=""
    [[ "$rest" == *#* ]] && { REPLY_NAME="$(urldecode "${rest##*#}")"; rest="${rest%%#*}"; }
    [[ "$rest" == *\?* ]] && { REPLY_QUERY="${rest#*\?}"; rest="${rest%%\?*}"; }
    REPLY_AUTHORITY="$rest"
}

_xhttp_extra_opts() {
    local extra="$1"
    [[ -n "$extra" ]] || { printf '{}'; return; }
    printf '%s' "$extra" | jq -c '
        if type != "object" then {}
        else
          ({
            "no-grpc-header": .noGRPCHeader,
            "x-padding-bytes": .xPaddingBytes,
            "x-padding-obfs-mode": .xPaddingObfsMode,
            "x-padding-key": .xPaddingKey,
            "x-padding-header": .xPaddingHeader,
            "x-padding-placement": .xPaddingPlacement,
            "x-padding-method": .xPaddingMethod,
            "uplink-http-method": .uplinkHTTPMethod,
            "session-placement": .sessionPlacement,
            "session-key": .sessionKey,
            "session-table": .sessionTable,
            "session-length": .sessionLength,
            "seq-placement": .seqPlacement,
            "seq-key": .seqKey,
            "uplink-data-placement": .uplinkDataPlacement,
            "uplink-data-key": .uplinkDataKey,
            "uplink-chunk-size": .uplinkChunkSize,
            "sc-max-each-post-bytes": .scMaxEachPostBytes,
            "sc-min-posts-interval-ms": .scMinPostsIntervalMs
          } | with_entries(select(.value != null)))
          + (if (.xmux | type) == "object" then {
              "reuse-settings": ({
                "max-concurrency": .xmux.maxConcurrency,
                "max-connections": .xmux.maxConnections,
                "c-max-reuse-times": .xmux.cMaxReuseTimes,
                "h-max-request-times": .xmux.hMaxRequestTimes,
                "h-max-reusable-secs": .xmux.hMaxReusableSecs,
                "h-keep-alive-period": .xmux.hKeepAlivePeriod
              } | with_entries(select(.value != null)))
            } else {} end)
        end
    ' 2>/dev/null || printf '{}'
}

# ── vless:// parser → node JSON ──────────────────────────────────────────────
# vless://<uuid>@<host>:<port>?encryption=&flow=&security=&sni=&fp=&pbk=&sid=&type=&host=&path=&serviceName=&alpn=#<name>
_parse_vless() {
    local uri="$1" name query host port
    _split_uri "$uri" "vless://" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    [[ "$REPLY_AUTHORITY" == *@* ]] || return 1
    local uuid="${REPLY_AUTHORITY%%@*}"
    IFS=$'\t' read -r host port < <(_split_hostport "${REPLY_AUTHORITY#*@}" 443) || return 1

    local -A q=(); _qs_into q "$query"
    local sec="${q[security]:-none}" net="${q[type]:-tcp}" sni="${q[sni]:-${q[serverName]:-}}" fp="${q[fp]:-${q[client-fingerprint]:-chrome}}"
    local pbk="${q[pbk]:-${q[publicKey]:-${q[realityPublicKey]:-}}}" sid="${q[sid]:-${q[shortId]:-${q[realityShortId]:-}}}"
    local flow="${q[flow]:-}" alpn="${q[alpn]:-}" http_upgrade=false
    local hh="${q[host]:-}" path="${q[path]:-}" svc="${q[serviceName]:-${q[service]:-}}"
    local encryption="${q[encryption]:-}" insecure="${q[allowInsecure]:-${q[insecure]:-0}}"
    local packet_encoding="${q[packetEncoding]:-${q[packet-encoding]:-}}"
    local xmode="${q[mode]:-}" xextra="${q[extra]:-}" xextra_opts xhttp_opts
    case "$net" in
        raw) net="tcp" ;;
        splithttp) net="xhttp" ;;
        httpupgrade) net="ws"; http_upgrade=true ;;
    esac
    [[ "$flow" == "xtls-rprx-vision-udp443" ]] && flow="xtls-rprx-vision"
    xextra_opts="$(_xhttp_extra_opts "$xextra")"
    xhttp_opts=$(jq -n --arg path "$path" --arg host "$hh" --arg mode "$xmode" --argjson extra "$xextra_opts" '
        ({ path: (if $path != "" then $path else "/" end) }
         + (if $host != "" then {host:$host} else {} end)
         + (if $mode != "" then {mode:$mode} else {} end)) + $extra
    ')
    [[ -z "$name" ]] && name="vless-${host}"

    local proxy
    proxy=$(jq -n \
        --arg name "$name" --arg server "$host" --argjson port "$port" --arg uuid "$uuid" \
        --arg net "$net" --arg flow "$flow" --arg sni "$sni" --arg fp "$fp" \
        --arg pbk "$pbk" --arg sid "$sid" --arg alpn "$alpn" \
        --arg hh "$hh" --arg path "$path" --arg svc "$svc" --arg sec "$sec" \
        --arg encryption "$encryption" --arg insecure "$insecure" --argjson xhttp "$xhttp_opts" \
        --arg packet_encoding "$packet_encoding" --argjson http_upgrade "$http_upgrade" '
        { name:$name, type:"vless", server:$server, port:$port, uuid:$uuid, network:$net, udp:true,
          encryption:(if $encryption == "none" then "" else $encryption end) }
        + (if $flow != "" then { flow:$flow } else {} end)
        + (if $packet_encoding != "" then {"packet-encoding":$packet_encoding} else {} end)
        + (if $sec=="reality" or $sec=="tls" then { tls:true } else {} end)
        + (if $sni != "" then { servername:$sni } else {} end)
        + (if $fp  != "" then { "client-fingerprint":$fp } else {} end)
        + (if ($insecure|ascii_downcase) == "1" or ($insecure|ascii_downcase) == "true" then {"skip-cert-verify":true} else {} end)
        + (if $sec=="reality" then { "reality-opts": (
              {"public-key":$pbk} + (if $sid!="" then {"short-id":$sid} else {} end)
          ) } else {} end)
        + (if $alpn != "" then { alpn: ($alpn|split(",")) } else {} end)
        + (if $net=="ws"   then { "ws-opts": ({ path: (if $path!="" then $path else "/" end) }
                                   + (if $hh!="" then { headers: { Host:$hh } } else {} end)
                                   + (if $http_upgrade then {"v2ray-http-upgrade":true} else {} end)) } else {} end)
        + (if $net=="grpc" then { "grpc-opts": { "grpc-service-name":$svc } } else {} end)
        + (if $net=="h2" then {"h2-opts":{
              host:(if $hh!="" then ($hh|split(",")) else [] end),
              path:(if $path!="" then $path else "/" end)}} else {} end)
        + (if $net=="http" then {"http-opts":({method:"GET",path:[(if $path!="" then $path else "/" end)]}
              + (if $hh!="" then {headers:{Host:[$hh]}} else {} end))} else {} end)
        + (if $net=="xhttp" then { "xhttp-opts":$xhttp } else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{ tag:$tag, groups:[], proxy:$proxy }'
}

# ── vmess:// parser: v2rayN base64(JSON), with Shadowrocket fallback ─────────
_parse_vmess() {
    local uri="$1" encoded decoded proxy name
    [[ "$uri" == vmess://* ]] || return 1
    _split_uri "$uri" "vmess://" || return 1
    encoded="$REPLY_AUTHORITY"
    decoded="$(printf '%s' "$encoded" | _b64d)"
    if ! printf '%s' "$decoded" | jq -e 'type == "object" and (.add // "") != "" and (.id // "") != ""' >/dev/null 2>&1; then
        _parse_vmess_sr "$decoded" "$REPLY_QUERY" "$REPLY_NAME"
        return $?
    fi
    name="$(printf '%s' "$decoded" | jq -r '.ps // ("vmess-" + (.add // "node"))')"
    proxy=$(jq -n --argjson v "$decoded" '
        ($v.add // "") as $server
        | (($v.port | tonumber?) // 443) as $port
        | ($v.id // "") as $uuid
        | (($v.aid | tonumber?) // 0) as $aid
        | ($v.scy // "auto") as $cipher
        | ($v.host // "") as $host
        | ($v.path // "") as $path
        | ($v.sni // "") as $sni
        | ($v.fp // "") as $fp
        | ($v.alpn // "") as $alpn
        | ($v.tls // "") as $tls
        | ($v.net // "tcp") as $rawnet
        | (if $rawnet == "tcp" and ($v.type // "") == "http" then "http"
           elif $rawnet == "splithttp" or $rawnet == "xhttp" then "xhttp"
           elif $rawnet == "httpupgrade" then "httpupgrade"
           elif (["tcp","ws","http","h2","grpc"] | index($rawnet)) != null then $rawnet
           else "tcp" end) as $net
        | {name:($v.ps // ("vmess-"+$server)), type:"vmess", server:$server, port:$port,
           uuid:$uuid, alterId:$aid, cipher:$cipher, udp:true,
           network:(if $net == "httpupgrade" then "ws" else $net end)}
        + (if $tls == true or $tls == "tls" or $tls == "reality" then {tls:true} else {} end)
        + (if $sni != "" then {servername:$sni} else {} end)
        + (if $fp != "" then {"client-fingerprint":$fp} else {} end)
        + (if (($v.insecure // $v.allowInsecure // 0) | tostring | ascii_downcase) == "1" or
              (($v.insecure // $v.allowInsecure // 0) | tostring | ascii_downcase) == "true"
           then {"skip-cert-verify":true} else {} end)
        + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end)
        + (if $tls == "reality" then {"reality-opts":{
              "public-key":($v.pbk // ""), "short-id":($v.sid // "")}} else {} end)
        + (if $net == "ws" or $net == "httpupgrade" then {"ws-opts":({path:(if $path!="" then $path else "/" end)}
              + (if $host!="" then {headers:{Host:$host}} else {} end)
              + (if $net == "httpupgrade" then {"v2ray-http-upgrade":true} else {} end))} else {} end)
        + (if $net == "xhttp" then {"xhttp-opts":({path:(if $path!="" then $path else "/" end)}
              + (if $host!="" then {host:$host} else {} end))} else {} end)
        + (if $net == "grpc" then {"grpc-opts":{"grpc-service-name":$path}} else {} end)
        + (if $net == "h2" then {"h2-opts":{
              host:(if $host!="" then ($host|split(",")) else [] end),
              path:(if $path!="" then $path else "/" end)}} else {} end)
        + (if $net == "http" then {"http-opts":({method:"GET", path:[(if $path!="" then $path else "/" end)]}
              + (if $host!="" then {headers:{Host:[$host]}} else {} end))} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# Shadowrocket-style vmess: base64("method:uuid@host:port") with params in the
# outer query (remarks/obfs/obfsParam/path/peer/tls/alterId).
_parse_vmess_sr() {
    local decoded="$1" query="$2" name="$3" host port
    [[ "$decoded" == *:*@*:* ]] || return 1
    local userinfo="${decoded%@*}" cipher uuid
    cipher="${userinfo%%:*}"; uuid="${userinfo#*:}"
    [[ -n "$cipher" && -n "$uuid" ]] || return 1
    IFS=$'\t' read -r host port < <(_split_hostport "${decoded##*@}") || return 1
    local -A q=(); _qs_into q "$query"
    local net="${q[obfs]:-none}" path="${q[path]:-}" hh="${q[obfsParam]:-}" sni="${q[peer]:-}"
    local tls="${q[tls]:-0}" aid="${q[alterId]:-0}" insecure="${q[allowInsecure]:-0}"
    [[ -z "$name" ]] && name="${q[remarks]:-vmess-${host}}"
    case "$net" in websocket|ws) net="ws" ;; http) net="http" ;; *) net="tcp" ;; esac
    [[ "$aid" =~ ^[0-9]+$ ]] || aid=0
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg uuid "$uuid" \
        --arg cipher "$cipher" --argjson aid "$aid" --arg net "$net" --arg path "$path" \
        --arg hh "$hh" --arg sni "$sni" --arg tls "$tls" --arg insecure "$insecure" '
        {name:$n, type:"vmess", server:$s, port:$p, uuid:$uuid, alterId:$aid,
         cipher:(if $cipher != "" then $cipher else "auto" end), udp:true, network:$net}
        + (if ($tls|ascii_downcase)=="1" or ($tls|ascii_downcase)=="true" then {tls:true} else {} end)
        + (if $sni != "" then {servername:$sni} else {} end)
        + (if ($insecure|ascii_downcase)=="1" or ($insecure|ascii_downcase)=="true" then {"skip-cert-verify":true} else {} end)
        + (if $net == "ws" then {"ws-opts":({path:(if $path!="" then $path else "/" end)}
              + (if $hh!="" then {headers:{Host:$hh}} else {} end))} else {} end)
        + (if $net == "http" then {"http-opts":({method:"GET", path:[(if $path!="" then $path else "/" end)]}
              + (if $hh!="" then {headers:{Host:[$hh]}} else {} end))} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── trojan:// parser ─────────────────────────────────────────────────────────
_parse_trojan() {
    local uri="$1" name password query host port
    _split_uri "$uri" "trojan://" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    [[ "$REPLY_AUTHORITY" == *@* ]] || return 1
    password="$(urldecode "${REPLY_AUTHORITY%%@*}")"
    IFS=$'\t' read -r host port < <(_split_hostport "${REPLY_AUTHORITY#*@}" 443) || return 1
    local -A q=(); _qs_into q "$query"
    local net="${q[type]:-tcp}" sni="${q[sni]:-${q[peer]:-}}" fp="${q[fp]:-}" alpn="${q[alpn]:-}"
    local path="${q[path]:-}" hh="${q[host]:-}" svc="${q[serviceName]:-}" sec="${q[security]:-tls}"
    local insecure="${q[allowInsecure]:-${q[insecure]:-0}}" pbk="${q[pbk]:-}" sid="${q[sid]:-}"
    [[ "$net" == "ws" || "$net" == "grpc" ]] || net="tcp"
    [[ -z "$name" ]] && name="trojan-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg pw "$password" \
        --arg net "$net" --arg sni "$sni" --arg fp "$fp" --arg alpn "$alpn" \
        --arg path "$path" --arg hh "$hh" --arg svc "$svc" --arg insecure "$insecure" \
        --arg sec "$sec" --arg pbk "$pbk" --arg sid "$sid" '
        {name:$n,type:"trojan",server:$s,port:$p,password:$pw,udp:true,network:$net}
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $fp!="" then {"client-fingerprint":$fp} else {} end)
        + (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)
        + (if ($insecure|ascii_downcase)=="1" or ($insecure|ascii_downcase)=="true" then {"skip-cert-verify":true} else {} end)
        + (if $sec=="reality" then {"reality-opts":{"public-key":$pbk,"short-id":$sid}} else {} end)
        + (if $net=="ws" then {"ws-opts":({path:(if $path!="" then $path else "/" end)}
             + (if $hh!="" then {headers:{Host:$hh}} else {} end))} else {} end)
        + (if $net=="grpc" then {"grpc-opts":{"grpc-service-name":$svc}} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag,groups:[],proxy:$proxy}'
}

# ── hysteria2:// / hy2:// parser ─────────────────────────────────────────────
_parse_hysteria2() {
    local uri="$1" scheme name password query host port
    case "$uri" in hysteria2://*) scheme="hysteria2://" ;; hy2://*) scheme="hy2://" ;; *) return 1 ;; esac
    _split_uri "$uri" "$scheme" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    [[ "$REPLY_AUTHORITY" == *@* ]] || return 1
    password="$(urldecode "${REPLY_AUTHORITY%%@*}")"
    IFS=$'\t' read -r host port < <(_split_hostport "${REPLY_AUTHORITY#*@}" 443) || return 1
    local -A q=(); _qs_into q "$query"
    local sni="${q[sni]:-}" insecure="${q[insecure]:-${q[allowInsecure]:-0}}"
    local obfs="${q[obfs]:-}" obfs_pw="${q[obfs-password]:-${q[obfsPassword]:-}}"
    local obfs_min="${q[minPacketSize]:-${q[obfs-min-packet-size]:-}}" obfs_max="${q[maxPacketSize]:-${q[obfs-max-packet-size]:-}}"
    local ports="${q[mport]:-${q[ports]:-}}" hop="${q[hop-interval]:-${q[hopInterval]:-}}"
    local up="${q[up]:-}" down="${q[down]:-}" fingerprint="${q[pinSHA256]:-${q[fingerprint]:-}}" alpn="${q[alpn]:-}"
    [[ -z "$name" ]] && name="hysteria2-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg pw "$password" \
        --arg sni "$sni" --arg insecure "$insecure" --arg obfs "$obfs" --arg obfs_pw "$obfs_pw" \
        --arg obfs_min "$obfs_min" --arg obfs_max "$obfs_max" \
        --arg ports "$ports" --arg hop "$hop" --arg up "$up" --arg down "$down" \
        --arg fingerprint "$fingerprint" --arg alpn "$alpn" '
        {name:$n,type:"hysteria2",server:$s,port:$p,password:$pw}
        + (if $ports!="" then {ports:$ports} else {} end)
        + (if $hop!="" then {"hop-interval":($hop|tonumber? // $hop)} else {} end)
        + (if $up!="" then {up:$up} else {} end) + (if $down!="" then {down:$down} else {} end)
        + (if $obfs!="" then {obfs:$obfs} else {} end)
        + (if $obfs_pw!="" then {"obfs-password":$obfs_pw} else {} end)
        + (if $obfs_min!="" then {"obfs-min-packet-size":($obfs_min|tonumber? // $obfs_min)} else {} end)
        + (if $obfs_max!="" then {"obfs-max-packet-size":($obfs_max|tonumber? // $obfs_max)} else {} end)
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if ($insecure|ascii_downcase)=="1" or ($insecure|ascii_downcase)=="true" then {"skip-cert-verify":true} else {} end)
        + (if $fingerprint!="" then {fingerprint:$fingerprint} else {} end)
        + (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag,groups:[],proxy:$proxy}'
}

# ── snell:// parser (common share-link variants) ─────────────────────────────
_parse_snell() {
    local uri="$1" name query userinfo="" hostpart host port
    _split_uri "$uri" "snell://" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    if [[ "$REPLY_AUTHORITY" == *@* ]]; then
        userinfo="$(urldecode "${REPLY_AUTHORITY%%@*}")"; hostpart="${REPLY_AUTHORITY#*@}"
    else hostpart="$REPLY_AUTHORITY"
    fi
    IFS=$'\t' read -r host port < <(_split_hostport "$hostpart") || return 1
    local -A q=(); _qs_into q "$query"
    local psk="${q[psk]:-$userinfo}" version="${q[version]:-4}" obfs="${q[obfs]:-${q[obfs-mode]:-}}"
    local obfs_host="${q[obfs-host]:-${q[obfsHost]:-}}" obfs_pw="${q[obfs-password]:-${q[shadow-tls-password]:-}}"
    local shadow_ver="${q[shadow-tls-version]:-${q[obfs-version]:-}}" alpn="${q[alpn]:-}" fp="${q[fp]:-}"
    local reuse="${q[reuse]:-false}" udp="${q[udp]:-true}"
    version="${version#v}"; [[ "$version" =~ ^[1-5]$ && -n "$psk" ]] || return 1
    [[ -z "$name" ]] && name="snell-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg psk "$psk" \
        --argjson ver "$version" --arg obfs "$obfs" --arg oh "$obfs_host" --arg opw "$obfs_pw" \
        --arg over "$shadow_ver" --arg alpn "$alpn" --arg fp "$fp" --arg reuse "$reuse" --arg udp "$udp" '
        {name:$n,type:"snell",server:$s,port:$p,psk:$psk,version:$ver}
        + {udp:(if $ver >= 3 and (($udp|ascii_downcase)!="false" and $udp!="0") then true else false end)}
        + (if ($reuse|ascii_downcase)=="true" or $reuse=="1" then {reuse:true} else {} end)
        + (if $fp!="" then {"client-fingerprint":$fp} else {} end)
        + (if $obfs!="" then {"obfs-opts":(
              {mode:$obfs}
              + (if $oh!="" then {host:$oh} else {} end)
              + (if $opw!="" then {password:$opw} else {} end)
              + (if $over!="" then {version:($over|sub("^v";"")|tonumber? // $over)} else {} end)
              + (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)
          )} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag,groups:[],proxy:$proxy}'
}

# ── ss:// parser → node JSON (SIP002 incl. plugins, plus legacy base64) ──────
_parse_ss() {
    local uri="$1" name query rest
    _split_uri "$uri" "ss://" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"; rest="$REPLY_AUTHORITY"
    local method pass host port
    if [[ "$rest" == *@* ]]; then
        local ui="${rest%@*}" dec
        dec="$(printf '%s' "$ui" | _b64d)"
        # base64 userinfo decodes to "method:password"; SIP002-2022 keeps it
        # plain (percent-encoded), so only trust a clean-looking decode.
        if [[ "$dec" =~ ^[0-9A-Za-z+._-]+: ]]; then ui="$dec"
        else ui="$(urldecode "$ui")"
        fi
        [[ "$ui" == *:* ]] || return 1
        method="${ui%%:*}"; pass="${ui#*:}"
        IFS=$'\t' read -r host port < <(_split_hostport "${rest##*@}") || return 1
    else
        local dec ui
        dec="$(printf '%s' "$rest" | _b64d)"
        [[ "$dec" == *@* && "$dec" == *:* ]] || return 1
        ui="${dec%@*}"
        method="${ui%%:*}"; pass="${ui#*:}"
        IFS=$'\t' read -r host port < <(_split_hostport "${dec##*@}") || return 1
    fi
    [[ -z "$name" ]] && name="ss-${host}"

    # SIP002 plugin=<name>;k=v;flag;… → mihomo plugin / plugin-opts.
    local -A q=(); _qs_into q "$query"
    local plugin="${q[plugin]:-}" uot="${q[udp-over-tcp]:-${q[uot]:-}}"
    local pname="" popts="" item; local -A po=()
    if [[ -n "$plugin" ]]; then
        pname="${plugin%%;*}"
        [[ "$plugin" == *\;* ]] && popts="${plugin#*;}"
        while [[ -n "$popts" ]]; do
            item="${popts%%;*}"
            [[ "$item" == "$popts" ]] && popts="" || popts="${popts#*;}"
            [[ -z "$item" ]] && continue
            if [[ "$item" == *=* ]]; then po["${item%%=*}"]="${item#*=}"; else po["$item"]="true"; fi
        done
    fi
    local plugin_json='{}'
    case "$pname" in
        obfs-local|simple-obfs|obfs)
            plugin_json=$(jq -n --arg m "${po[obfs]:-http}" --arg h "${po[obfs-host]:-}" \
                '{plugin:"obfs", "plugin-opts":({mode:$m} + (if $h!="" then {host:$h} else {} end))}') ;;
        v2ray-plugin)
            plugin_json=$(jq -n --arg h "${po[host]:-}" --arg p "${po[path]:-}" \
                --arg tls "${po[tls]:-}" --arg mux "${po[mux]:-}" \
                '{plugin:"v2ray-plugin", "plugin-opts":({mode:"websocket"}
                    + (if $tls=="true" then {tls:true} else {} end)
                    + (if $h!="" then {host:$h} else {} end)
                    + (if $p!="" then {path:$p} else {} end)
                    + (if $mux!="" and $mux!="0" then {mux:true} else {} end))}') ;;
        shadow-tls)
            plugin_json=$(jq -n --arg h "${po[host]:-}" --arg pw "${po[password]:-}" --arg v "${po[version]:-3}" \
                '{plugin:"shadow-tls", "plugin-opts":{host:$h, password:$pw, version:($v|tonumber? // 3)}}') ;;
    esac
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg c "$method" --arg pw "$pass" \
        --arg uot "$uot" --argjson plugin "$plugin_json" \
        '{ name:$n, type:"ss", server:$s, port:$p, cipher:$c, password:$pw, udp:true }
         + (if ($uot|ascii_downcase)=="1" or ($uot|ascii_downcase)=="true" then {"udp-over-tcp":true} else {} end)
         + $plugin')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{ tag:$tag, groups:[], proxy:$proxy }'
}

# ── anytls:// parser ─────────────────────────────────────────────────────────
_parse_anytls() {
    local uri="$1" name query password host port
    _split_uri "$uri" "anytls://" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    [[ "$REPLY_AUTHORITY" == *@* ]] || return 1
    password="$(urldecode "${REPLY_AUTHORITY%%@*}")"
    IFS=$'\t' read -r host port < <(_split_hostport "${REPLY_AUTHORITY#*@}" 443) || return 1
    local -A q=(); _qs_into q "$query"
    local sni="${q[sni]:-${q[peer]:-}}" insecure="${q[insecure]:-${q[allowInsecure]:-0}}"
    local fp="${q[fp]:-}" alpn="${q[alpn]:-}" udp="${q[udp]:-true}"
    [[ -z "$name" ]] && name="anytls-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg pw "$password" \
        --arg sni "$sni" --arg insecure "$insecure" --arg fp "$fp" --arg alpn "$alpn" --arg udp "$udp" '
        {name:$n, type:"anytls", server:$s, port:$p, password:$pw,
         udp:(($udp|ascii_downcase) != "false" and $udp != "0")}
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $fp!="" then {"client-fingerprint":$fp} else {} end)
        + (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)
        + (if ($insecure|ascii_downcase)=="1" or ($insecure|ascii_downcase)=="true" then {"skip-cert-verify":true} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── tuic:// parser (v5 uuid:password@…; v4 token@…) ──────────────────────────
_parse_tuic() {
    local uri="$1" name query userinfo uuid="" password="" token="" host port
    _split_uri "$uri" "tuic://" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    [[ "$REPLY_AUTHORITY" == *@* ]] || return 1
    userinfo="${REPLY_AUTHORITY%%@*}"
    if [[ "$userinfo" == *:* ]]; then
        uuid="$(urldecode "${userinfo%%:*}")"; password="$(urldecode "${userinfo#*:}")"
    else
        token="$(urldecode "$userinfo")"
    fi
    IFS=$'\t' read -r host port < <(_split_hostport "${REPLY_AUTHORITY#*@}" 443) || return 1
    local -A q=(); _qs_into q "$query"
    local sni="${q[sni]:-${q[peer]:-}}" alpn="${q[alpn]:-}" cc="${q[congestion_control]:-${q[congestion-control]:-}}"
    local mode="${q[udp_relay_mode]:-${q[udp-relay-mode]:-}}" insecure="${q[allow_insecure]:-${q[allowInsecure]:-${q[insecure]:-0}}}"
    local disable_sni="${q[disable_sni]:-0}" reduce_rtt="${q[reduce_rtt]:-0}"
    [[ -z "$name" ]] && name="tuic-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" \
        --arg uuid "$uuid" --arg pw "$password" --arg token "$token" \
        --arg sni "$sni" --arg alpn "$alpn" --arg cc "$cc" --arg mode "$mode" \
        --arg insecure "$insecure" --arg dsni "$disable_sni" --arg rrtt "$reduce_rtt" '
        {name:$n, type:"tuic", server:$s, port:$p, udp:true}
        + (if $token != "" then {token:$token} else {uuid:$uuid, password:$pw} end)
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)
        + (if $cc!="" then {"congestion-controller":$cc} else {} end)
        + (if $mode!="" then {"udp-relay-mode":$mode} else {} end)
        + (if ($insecure|ascii_downcase)=="1" or ($insecure|ascii_downcase)=="true" then {"skip-cert-verify":true} else {} end)
        + (if ($dsni|ascii_downcase)=="1" or ($dsni|ascii_downcase)=="true" then {"disable-sni":true} else {} end)
        + (if ($rrtt|ascii_downcase)=="1" or ($rrtt|ascii_downcase)=="true" then {"reduce-rtt":true} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── hysteria:// (v1) parser ──────────────────────────────────────────────────
_parse_hysteria() {
    local uri="$1" scheme name query host port
    case "$uri" in hysteria://*) scheme="hysteria://" ;; hy://*) scheme="hy://" ;; *) return 1 ;; esac
    _split_uri "$uri" "$scheme" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    local authority="$REPLY_AUTHORITY"
    [[ "$authority" == *@* ]] && authority="${authority#*@}"   # rare auth@host form
    IFS=$'\t' read -r host port < <(_split_hostport "$authority" 443) || return 1
    local -A q=(); _qs_into q "$query"
    local auth="${q[auth]:-}" sni="${q[peer]:-${q[sni]:-}}" insecure="${q[insecure]:-0}"
    local up="${q[upmbps]:-${q[up]:-}}" down="${q[downmbps]:-${q[down]:-}}"
    local obfs="${q[obfs]:-}" obfs_param="${q[obfsParam]:-${q[obfs-param]:-}}"
    local protocol="${q[protocol]:-}" alpn="${q[alpn]:-}" ports="${q[mport]:-}"
    # v1 links carry obfs=xplus + obfsParam=<password>; mihomo wants the password.
    local obfs_pw="$obfs_param"
    [[ -z "$obfs_pw" && -n "$obfs" && "$obfs" != "xplus" && "$obfs" != "none" ]] && obfs_pw="$obfs"
    [[ -z "$name" ]] && name="hysteria-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg auth "$auth" \
        --arg sni "$sni" --arg insecure "$insecure" --arg up "$up" --arg down "$down" \
        --arg obfs "$obfs_pw" --arg protocol "$protocol" --arg alpn "$alpn" --arg ports "$ports" '
        {name:$n, type:"hysteria", server:$s, port:$p, udp:true}
        + (if $auth!="" then {"auth-str":$auth} else {} end)
        + (if $up!="" then {up:$up} else {} end) + (if $down!="" then {down:$down} else {} end)
        + (if $obfs!="" then {obfs:$obfs} else {} end)
        + (if $protocol!="" then {protocol:$protocol} else {} end)
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)
        + (if $ports!="" then {ports:$ports} else {} end)
        + (if ($insecure|ascii_downcase)=="1" or ($insecure|ascii_downcase)=="true" then {"skip-cert-verify":true} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── ssr:// parser: base64(host:port:proto:method:obfs:b64pass/?b64params) ────
_parse_ssr() {
    local uri="$1" decoded main params=""
    [[ "$uri" == ssr://* ]] || return 1
    decoded="$(printf '%s' "${uri#ssr://}" | _b64d)"
    [[ -n "$decoded" ]] || return 1
    main="${decoded%%/\?*}"
    [[ "$decoded" == */\?* ]] && params="${decoded#*/\?}"
    # Split the colon-form from the right: last 5 fields are fixed, the rest is host.
    local pass_b64 obfs method proto port host rest="$main"
    pass_b64="${rest##*:}"; rest="${rest%:*}"
    obfs="${rest##*:}";     rest="${rest%:*}"
    method="${rest##*:}";   rest="${rest%:*}"
    proto="${rest##*:}";    rest="${rest%:*}"
    port="${rest##*:}";     host="${rest%:*}"
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1
    local pass obfs_param="" proto_param="" name=""
    pass="$(printf '%s' "$pass_b64" | _b64d)"
    local -A q=(); _qs_into q "$params"
    [[ -n "${q[obfsparam]:-}" ]]  && obfs_param="$(printf '%s' "${q[obfsparam]}" | _b64d)"
    [[ -n "${q[protoparam]:-}" ]] && proto_param="$(printf '%s' "${q[protoparam]}" | _b64d)"
    [[ -n "${q[remarks]:-}" ]]    && name="$(printf '%s' "${q[remarks]}" | _b64d)"
    [[ -z "$name" ]] && name="ssr-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg c "$method" \
        --arg pw "$pass" --arg proto "$proto" --arg obfs "$obfs" \
        --arg op "$obfs_param" --arg pp "$proto_param" '
        {name:$n, type:"ssr", server:$s, port:$p, cipher:$c, password:$pw,
         protocol:$proto, obfs:$obfs, udp:true}
        + (if $op!="" then {"obfs-param":$op} else {} end)
        + (if $pp!="" then {"protocol-param":$pp} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── socks:// / socks5:// and http:// share links ─────────────────────────────
_parse_socks_http() {
    local uri="$1" scheme type tls=false defport
    case "$uri" in
        socks://*)  scheme="socks://";  type="socks5"; defport=1080 ;;
        socks5://*) scheme="socks5://"; type="socks5"; defport=1080 ;;
        http://*)   scheme="http://";   type="http";   defport=80 ;;
        https://*)  scheme="https://";  type="http";   defport=443; tls=true ;;
        *) return 1 ;;
    esac
    _split_uri "$uri" "$scheme" || return 1
    local name="$REPLY_NAME" rest="$REPLY_AUTHORITY" user="" pass="" host port
    if [[ "$rest" == *@* ]]; then
        local ui="${rest%@*}" dec
        # Shadowrocket emits socks://base64(user:pass)@host:port.
        dec="$(printf '%s' "$ui" | _b64d)"
        if [[ "$dec" =~ ^[[:print:]]+:[[:print:]]*$ ]]; then ui="$dec"; else ui="$(urldecode "$ui")"; fi
        user="${ui%%:*}"; [[ "$ui" == *:* ]] && pass="${ui#*:}"
        rest="${rest##*@}"
    fi
    IFS=$'\t' read -r host port < <(_split_hostport "$rest" "$defport") || return 1
    [[ -z "$name" ]] && name="${type}-${host}"
    local proxy
    proxy=$(jq -n --arg n "$name" --arg t "$type" --arg s "$host" --argjson p "$port" \
        --arg u "$user" --arg pw "$pass" --argjson tls "$tls" '
        {name:$n, type:$t, server:$s, port:$p, udp:true}
        + (if $u!="" then {username:$u} else {} end)
        + (if $pw!="" then {password:$pw} else {} end)
        + (if $tls then {tls:true} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── wireguard:// / wg:// parser ──────────────────────────────────────────────
_parse_wireguard() {
    local uri="$1" scheme name query pk host port
    case "$uri" in wireguard://*) scheme="wireguard://" ;; wg://*) scheme="wg://" ;; *) return 1 ;; esac
    _split_uri "$uri" "$scheme" || return 1
    name="$REPLY_NAME"; query="$REPLY_QUERY"
    [[ "$REPLY_AUTHORITY" == *@* ]] || return 1
    pk="$(urldecode "${REPLY_AUTHORITY%%@*}")"
    IFS=$'\t' read -r host port < <(_split_hostport "${REPLY_AUTHORITY#*@}") || return 1
    local -A q=(); _qs_into q "$query"
    local pub="${q[publickey]:-${q[public-key]:-}}" psk="${q[presharedkey]:-${q[pre-shared-key]:-}}"
    local address="${q[address]:-}" mtu="${q[mtu]:-}" reserved="${q[reserved]:-}"
    [[ -n "$pub" ]] || return 1
    [[ -z "$name" ]] && name="wg-${host}"
    local ip="" ip6="" a
    local IFS=','
    for a in $address; do
        a="${a%%/*}"; a="${a// /}"
        [[ -z "$a" ]] && continue
        if [[ "$a" == *:* ]]; then ip6="$a"; else ip="$a"; fi
    done
    unset IFS
    local proxy
    proxy=$(jq -n --arg n "$name" --arg s "$host" --argjson p "$port" --arg pk "$pk" \
        --arg pub "$pub" --arg psk "$psk" --arg ip "$ip" --arg ip6 "$ip6" \
        --arg mtu "$mtu" --arg reserved "$reserved" '
        {name:$n, type:"wireguard", server:$s, port:$p, "private-key":$pk, "public-key":$pub, udp:true}
        + (if $ip!="" then {ip:$ip} else {} end)
        + (if $ip6!="" then {ipv6:$ip6} else {} end)
        + (if $psk!="" then {"pre-shared-key":$psk} else {} end)
        + (if ($mtu|tonumber?) != null then {mtu:($mtu|tonumber)} else {} end)
        + (if $reserved!="" then {reserved:($reserved|split(",")|map(tonumber? // 0))} else {} end)
    ')
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# Dispatch one share link → node JSON (stdout) or return 1.
parse_uri() {
    local uri; uri="$(printf '%s' "$1" | tr -d '[:space:]')"
    case "$uri" in
        vless://*)                  _parse_vless "$uri" ;;
        vmess://*)                  _parse_vmess "$uri" ;;
        trojan://*)                 _parse_trojan "$uri" ;;
        hysteria2://*|hy2://*)      _parse_hysteria2 "$uri" ;;
        hysteria://*|hy://*)        _parse_hysteria "$uri" ;;
        tuic://*)                   _parse_tuic "$uri" ;;
        anytls://*)                 _parse_anytls "$uri" ;;
        snell://*)                  _parse_snell "$uri" ;;
        ssr://*)                    _parse_ssr "$uri" ;;
        ss://*)                     _parse_ss "$uri" ;;
        socks://*|socks5://*)       _parse_socks_http "$uri" ;;
        wireguard://*|wg://*)       _parse_wireguard "$uri" ;;
        # http(s) share links only when they carry credentials — a bare URL is
        # far more likely to be a subscription link than a proxy node.
        http://*@*|https://*@*)     _parse_socks_http "$uri" ;;
        *) return 1 ;;
    esac
}

_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ── Surge proxy line → node JSON ─────────────────────────────────────────────
# Protocols like snell have no official share-link scheme; their de-facto
# distribution format is a Surge [Proxy] line:
#   Name = snell, host, port, psk=…, version=4, obfs=http, obfs-host=…
_parse_surge_line() {
    local line="$1" name rhs
    [[ "$line" == *=* && "$line" == *,* ]] || return 1
    name="$(_trim "${line%%=*}")"; rhs="${line#*=}"
    local -a f=(); local IFS=','
    read -r -a f <<< "$rhs"
    unset IFS
    local type server port; local -A kv=(); local i field k v
    type="$(_trim "${f[0]:-}")"; server="$(_trim "${f[1]:-}")"; port="$(_trim "${f[2]:-}")"
    [[ -n "$server" && "$port" =~ ^[0-9]+$ ]] || return 1
    for ((i=3; i<${#f[@]}; i++)); do
        field="$(_trim "${f[i]}")"; [[ -z "$field" ]] && continue
        if [[ "$field" == *=* ]]; then
            k="$(_trim "${field%%=*}")"; v="$(_trim "${field#*=}")"
            v="${v#\"}"; v="${v%\"}"
            [[ -n "$k" ]] && kv["$k"]="$v"
        else
            kv["$field"]="true"
        fi
    done
    [[ -z "$name" ]] && name="${type}-${server}"

    local proxy=""
    case "$type" in
        snell)
            [[ -n "${kv[psk]:-}" ]] || return 1
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg psk "${kv[psk]}" --arg ver "${kv[version]:-4}" \
                --arg obfs "${kv[obfs]:-}" --arg oh "${kv[obfs-host]:-}" \
                --arg reuse "${kv[reuse]:-}" --arg udp "${kv[udp-relay]:-}" '
                {name:$n, type:"snell", server:$s, port:$p, psk:$psk,
                 version:($ver|tonumber? // 4), udp:($udp=="true" or $udp=="1")}
                + (if $reuse=="true" or $reuse=="1" then {reuse:true} else {} end)
                + (if $obfs!="" and $obfs!="none" then {"obfs-opts":({mode:$obfs}
                    + (if $oh!="" then {host:$oh} else {} end))} else {} end)') ;;
        ss)
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg c "${kv[encrypt-method]:-aes-256-gcm}" --arg pw "${kv[password]:-}" \
                --arg obfs "${kv[obfs]:-}" --arg oh "${kv[obfs-host]:-}" --arg udp "${kv[udp-relay]:-}" '
                {name:$n, type:"ss", server:$s, port:$p, cipher:$c, password:$pw,
                 udp:($udp=="true" or $udp=="1")}
                + (if $obfs!="" and $obfs!="none" then
                    {plugin:"obfs", "plugin-opts":({mode:$obfs}
                        + (if $oh!="" then {host:$oh} else {} end))} else {} end)') ;;
        trojan)
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg pw "${kv[password]:-}" --arg sni "${kv[sni]:-}" \
                --arg skip "${kv[skip-cert-verify]:-}" --arg alpn "${kv[alpn]:-}" \
                --arg ws "${kv[ws]:-}" --arg wsp "${kv[ws-path]:-}" --arg wsh "${kv[ws-headers]:-}" '
                {name:$n, type:"trojan", server:$s, port:$p, password:$pw, udp:true}
                + (if $sni!="" then {sni:$sni} else {} end)
                + (if $skip=="true" or $skip=="1" then {"skip-cert-verify":true} else {} end)
                + (if $alpn!="" then {alpn:($alpn|split("|"))} else {} end)
                + (if $ws=="true" or $ws=="1" then
                    {network:"ws", "ws-opts":({path:(if $wsp!="" then $wsp else "/" end)}
                     + (if ($wsh|test("(?i)^host:")) then
                         {headers:{Host:($wsh|sub("(?i)^host:";""))}} else {} end))}
                   else {} end)') ;;
        vmess)
            [[ -n "${kv[username]:-}" ]] || return 1
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg uuid "${kv[username]}" --arg c "${kv[encrypt-method]:-auto}" \
                --arg tls "${kv[tls]:-}" --arg sni "${kv[sni]:-}" --arg skip "${kv[skip-cert-verify]:-}" \
                --arg ws "${kv[ws]:-}" --arg wsp "${kv[ws-path]:-}" --arg wsh "${kv[ws-headers]:-}" '
                {name:$n, type:"vmess", server:$s, port:$p, uuid:$uuid, alterId:0,
                 cipher:$c, udp:true,
                 network:(if $ws=="true" or $ws=="1" then "ws" else "tcp" end)}
                + (if $tls=="true" or $tls=="1" then {tls:true} else {} end)
                + (if $sni!="" then {servername:$sni} else {} end)
                + (if $skip=="true" or $skip=="1" then {"skip-cert-verify":true} else {} end)
                + (if $ws=="true" or $ws=="1" then
                    {"ws-opts":({path:(if $wsp!="" then $wsp else "/" end)}
                     + (if ($wsh|test("(?i)^host:")) then
                         {headers:{Host:($wsh|sub("(?i)^host:";""))}} else {} end))}
                   else {} end)') ;;
        hysteria2)
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg pw "${kv[password]:-}" --arg sni "${kv[sni]:-}" \
                --arg skip "${kv[skip-cert-verify]:-}" --arg down "${kv[download-bandwidth]:-}" '
                {name:$n, type:"hysteria2", server:$s, port:$p, password:$pw}
                + (if $sni!="" then {sni:$sni} else {} end)
                + (if $skip=="true" or $skip=="1" then {"skip-cert-verify":true} else {} end)
                + (if $down!="" then {down:($down + " Mbps")} else {} end)') ;;
        tuic|tuic-v5)
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg token "${kv[token]:-}" --arg uuid "${kv[uuid]:-}" --arg pw "${kv[password]:-}" \
                --arg sni "${kv[sni]:-}" --arg alpn "${kv[alpn]:-}" --arg skip "${kv[skip-cert-verify]:-}" '
                {name:$n, type:"tuic", server:$s, port:$p, udp:true}
                + (if $uuid != "" then {uuid:$uuid, password:$pw}
                   elif $token != "" then {token:$token} else {} end)
                + (if $sni!="" then {sni:$sni} else {} end)
                + (if $alpn!="" then {alpn:($alpn|split("|"))} else {} end)
                + (if $skip=="true" or $skip=="1" then {"skip-cert-verify":true} else {} end)') ;;
        http|https)
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg u "${kv[username]:-}" --arg pw "${kv[password]:-}" \
                --argjson tls "$([[ "$type" == "https" ]] && echo true || echo false)" '
                {name:$n, type:"http", server:$s, port:$p}
                + (if $u!="" then {username:$u} else {} end)
                + (if $pw!="" then {password:$pw} else {} end)
                + (if $tls then {tls:true} else {} end)') ;;
        socks5|socks5-tls)
            proxy=$(jq -n --arg n "$name" --arg s "$server" --argjson p "$port" \
                --arg u "${kv[username]:-}" --arg pw "${kv[password]:-}" \
                --argjson tls "$([[ "$type" == "socks5-tls" ]] && echo true || echo false)" '
                {name:$n, type:"socks5", server:$s, port:$p, udp:true}
                + (if $u!="" then {username:$u} else {} end)
                + (if $pw!="" then {password:$pw} else {} end)
                + (if $tls then {tls:true} else {} end)') ;;
        *) return 1 ;;
    esac
    [[ -n "$proxy" ]] || return 1
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:$proxy}'
}

# ── mihomo JSON proxy dict → node JSON ───────────────────────────────────────
# The node store's .proxy already IS a mihomo proxy dict, so any protocol
# mihomo supports can be imported by pasting that dict as one JSON line.
_parse_json_proxy() {
    local line="$1" proxy name
    proxy="$(printf '%s' "$line" | jq -ce '
        select(type=="object" and (.type|type)=="string" and ((.server // "")|tostring) != "" and .port != null)
    ' 2>/dev/null)" || return 1
    name="$(printf '%s' "$proxy" | jq -r '.name // empty')"
    [[ -z "$name" ]] && name="$(printf '%s' "$proxy" | jq -r '.type + "-" + (.server|tostring)')"
    jq -n --arg tag "$name" --argjson proxy "$proxy" '{tag:$tag, groups:[], proxy:($proxy | .name = $tag)}'
}

# Parse one pasted line in any supported format → node JSON, or return 1.
parse_line() {
    local line="$1"
    if [[ "$line" == *"://"* ]]; then parse_uri "$line"
    elif [[ "$line" == \{* ]]; then _parse_json_proxy "$line"
    else _parse_surge_line "$line"
    fi
}

# Import many nodes (one per line): share links, Surge proxy lines, or mihomo
# JSON proxy dicts. Assigns unique tags; echoes count imported.
_import_lines() {
    local imported=0 line node tag
    while IFS= read -r line; do
        line="${line//$'\r'/}"; line="$(_trim "$line")"
        [[ -z "$line" ]] && continue
        node="$(parse_line "$line")" || { log_warn "$(t nodes.parse_fail "${line:0:24}…")"; continue; }
        tag="$(echo "$node" | jq -r '.tag')"; tag="$(_nodes_unique_tag "$tag")"
        node="$(echo "$node" | jq --arg t "$tag" '.tag=$t')"
        _nodes_upsert "$node"; ((imported+=1))
    done
    printf '%s' "$imported"
}

# ── Interactive: list ────────────────────────────────────────────────────────
nodes_list() {
    local n; n=$(_nodes_count)
    if [[ "$n" == "0" || -z "$n" ]]; then log_warn "$(t nodes.none)"; return; fi
    echo -e "\n${BOLD}$(t nodes.list_title)${NC}"
    printf "  %-22s %-8s %-22s %-6s %s\n" \
        "$(t nodes.col_tag)" "$(t nodes.col_type)" "$(t nodes.col_server)" "$(t nodes.col_port)" "$(t nodes.col_groups)"
    _nodes_load | jq -r '.[] | "\(.tag)\t\(.proxy.type)\t\(.proxy.server)\t\(.proxy.port)\t\((.groups // []) | join(","))"' \
        | while IFS=$'\t' read -r tag typ srv prt grp; do
            printf "  %-22s %-8s %-22s %-6s %s\n" "$tag" "$typ" "$srv" "$prt" "$grp"
        done
}

# ── Interactive: add a node by hand (multi-protocol wizard) ──────────────────
# Common tail: unique tag, groups, upsert, apply.
_wizard_finish() {
    local tag="$1" proxy="$2" groups
    ask groups "$(t nodes.ask_groups)" ""
    tag="$(_nodes_unique_tag "$tag")"
    local grp_json; grp_json=$(printf '%s' "$groups" | tr ',' '\n' | sed '/^\s*$/d' | jq -R . | jq -sc .)
    local node
    node=$(jq -n --arg tag "$tag" --argjson g "$grp_json" --argjson p "$proxy" \
        '{tag:$tag, groups:$g, proxy:($p | .name = $tag)}')
    _nodes_upsert "$node"
    log_ok "$(t nodes.added "$tag")"
    mc_apply || true
}

# Shared prompts: sets WIZ_TAG / WIZ_SERVER / WIZ_PORT (or returns 1).
_wizard_basics() {
    local prefix="$1" defport="$2"
    ask WIZ_TAG    "$(t nodes.ask_tag)" "${prefix}-$(( $(_nodes_count) + 1 ))"
    ask WIZ_SERVER "$(t nodes.ask_server)"
    [[ -z "$WIZ_SERVER" ]] && { log_error "$(t nodes.server_empty)"; return 1; }
    ask WIZ_PORT   "$(t nodes.ask_port)" "$defport"
    [[ "$WIZ_PORT" =~ ^[0-9]+$ ]] || WIZ_PORT="$defport"
}

_wizard_vless_reality() {
    local uuid sni pbk sid flow
    _wizard_basics "reality" 443 || return 1
    ask uuid "$(t nodes.ask_uuid)"
    ask sni  "$(t nodes.ask_sni)" "www.apple.com"
    ask pbk  "$(t nodes.ask_pbk)"
    ask sid  "$(t nodes.ask_sid)"
    ask flow "$(t nodes.ask_flow)" "xtls-rprx-vision"
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg uuid "$uuid" \
        --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" '
        { type:"vless", server:$s, port:$p, uuid:$uuid, network:"tcp", udp:true, tls:true,
          servername:$sni, "client-fingerprint":"chrome",
          "reality-opts": { "public-key":$pbk, "short-id":$sid } }
        + (if $flow != "" then { flow:$flow } else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_snell() {
    local psk ver obfs oh
    _wizard_basics "snell" 44046 || return 1
    ask psk "$(t nodes.ask_psk)"
    [[ -z "$psk" ]] && { log_error "$(t nodes.field_empty "psk")"; return 1; }
    ask ver  "$(t nodes.ask_snell_version)" "4"
    ask obfs "$(t nodes.ask_obfs)" "none"
    [[ "$obfs" != "none" && -n "$obfs" ]] && ask oh "$(t nodes.ask_obfs_host)" ""
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg psk "$psk" \
        --arg ver "$ver" --arg obfs "$obfs" --arg oh "${oh:-}" '
        {type:"snell", server:$s, port:$p, psk:$psk, version:($ver|tonumber? // 4), udp:true}
        + (if $obfs!="" and $obfs!="none" then {"obfs-opts":({mode:$obfs}
            + (if $oh!="" then {host:$oh} else {} end))} else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_ss() {
    local cipher pass
    _wizard_basics "ss" 8388 || return 1
    ask cipher "$(t nodes.ask_cipher)" "aes-256-gcm"
    ask pass   "$(t nodes.ask_password)"
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg c "$cipher" --arg pw "$pass" \
        '{type:"ss", server:$s, port:$p, cipher:$c, password:$pw, udp:true}')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_trojan() {
    local pass sni
    _wizard_basics "trojan" 443 || return 1
    ask pass "$(t nodes.ask_password)"
    ask sni  "$(t nodes.ask_sni)" "$WIZ_SERVER"
    local skip=false; ask_yn "$(t nodes.ask_insecure)" N && skip=true
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg pw "$pass" \
        --arg sni "$sni" --argjson skip "$skip" '
        {type:"trojan", server:$s, port:$p, password:$pw, udp:true}
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $skip then {"skip-cert-verify":true} else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_hysteria2() {
    local pass sni obfs opw
    _wizard_basics "hy2" 443 || return 1
    ask pass "$(t nodes.ask_password)"
    ask sni  "$(t nodes.ask_sni)" "$WIZ_SERVER"
    ask obfs "$(t nodes.ask_obfs_hy2)" "none"
    [[ "$obfs" != "none" && -n "$obfs" ]] && ask opw "$(t nodes.ask_obfs_password)" ""
    local skip=false; ask_yn "$(t nodes.ask_insecure)" N && skip=true
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg pw "$pass" \
        --arg sni "$sni" --arg obfs "$obfs" --arg opw "${opw:-}" --argjson skip "$skip" '
        {type:"hysteria2", server:$s, port:$p, password:$pw}
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $obfs!="" and $obfs!="none" then
            {obfs:$obfs} + (if $opw!="" then {"obfs-password":$opw} else {} end) else {} end)
        + (if $skip then {"skip-cert-verify":true} else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_anytls() {
    local pass sni
    _wizard_basics "anytls" 443 || return 1
    ask pass "$(t nodes.ask_password)"
    ask sni  "$(t nodes.ask_sni)" "$WIZ_SERVER"
    local skip=false; ask_yn "$(t nodes.ask_insecure)" N && skip=true
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg pw "$pass" \
        --arg sni "$sni" --argjson skip "$skip" '
        {type:"anytls", server:$s, port:$p, password:$pw, udp:true}
        + (if $sni!="" then {sni:$sni} else {} end)
        + (if $skip then {"skip-cert-verify":true} else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_tuic() {
    local uuid pass sni
    _wizard_basics "tuic" 443 || return 1
    ask uuid "$(t nodes.ask_uuid)"
    ask pass "$(t nodes.ask_password)"
    ask sni  "$(t nodes.ask_sni)" "$WIZ_SERVER"
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg uuid "$uuid" \
        --arg pw "$pass" --arg sni "$sni" '
        {type:"tuic", server:$s, port:$p, uuid:$uuid, password:$pw, udp:true,
         "congestion-controller":"bbr", alpn:["h3"]}
        + (if $sni!="" then {sni:$sni} else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

_wizard_socks5() {
    local user pass
    _wizard_basics "socks5" 1080 || return 1
    ask user "$(t nodes.ask_username)" ""
    [[ -n "$user" ]] && ask pass "$(t nodes.ask_password)"
    local proxy
    proxy=$(jq -n --arg s "$WIZ_SERVER" --argjson p "$WIZ_PORT" --arg u "$user" --arg pw "${pass:-}" '
        {type:"socks5", server:$s, port:$p, udp:true}
        + (if $u!="" then {username:$u} else {} end)
        + (if $pw!="" then {password:$pw} else {} end)')
    _wizard_finish "$WIZ_TAG" "$proxy"
}

nodes_add_manual() {
    show_menu "$(t nodes.wizard_type)" \
        "VLESS + Reality" "Snell" "Shadowsocks" "Trojan" "Hysteria2" "AnyTLS" "TUIC v5" "SOCKS5"
    case "$MENU_CHOICE" in
        1) _wizard_vless_reality ;;
        2) _wizard_snell ;;
        3) _wizard_ss ;;
        4) _wizard_trojan ;;
        5) _wizard_hysteria2 ;;
        6) _wizard_anytls ;;
        7) _wizard_tuic ;;
        8) _wizard_socks5 ;;
        *) return 0 ;;
    esac
}

# ── Interactive: import from pasted link(s) ──────────────────────────────────
nodes_import_uri() {
    log_info "$(t nodes.paste_hint)"
    local defer_apply="${1:-}" buf="" line normalized
    while IFS= read -r line; do
        # Some SSH/Web terminals leave a carriage return on an apparently empty
        # line. Treat every whitespace-only line as the end of pasted input.
        normalized="${line//$'\r'/}"
        [[ -z "${normalized//[[:space:]]/}" ]] && break
        buf+="${normalized}"$'\n'
    done
    [[ -z "$buf" ]] && { log_warn "$(t common.cancelled)"; return; }
    log_info "$(t nodes.importing)"
    local n; n=$(printf '%s' "$buf" | _import_lines)
    log_ok "$(t nodes.imported_n "$n")"
    if (( n > 0 )) && [[ "$defer_apply" != "--defer-apply" ]]; then
        mc_apply || true
    fi
}

# ── Interactive: import from a subscription URL (plain or base64 link list) ───
nodes_import_sub() {
    local url; ask url "$(t nodes.ask_sub_url)"
    [[ -z "$url" ]] && { log_warn "$(t common.cancelled)"; return; }
    have curl || { log_error "$(t common.dep_missing "curl")"; return 1; }
    local body; body="$(curl -fsSL --max-time 20 "$url" 2>/dev/null)" || { log_error "$(t nodes.sub_fail)"; return 1; }
    # A subscription body is often base64 of the whole link list; decode if it
    # doesn't already look like URIs.
    [[ "$body" == *://* ]] || body="$(printf '%s' "$body" | _b64d)"
    local n; n=$(printf '%s\n' "$body" | _import_lines)
    log_ok "$(t nodes.imported_n "$n")"
    (( n > 0 )) && { mc_apply || true; }
}

# ── Interactive: delete / modify / show ──────────────────────────────────────
nodes_delete() {
    nodes_list
    local tag; ask tag "$(t nodes.ask_del_tag)"
    [[ -z "$(_nodes_get "$tag")" ]] && { log_error "$(t nodes.not_found "$tag")"; return 1; }
    ask_yn "$(t nodes.confirm_del "$tag")" N || return 0
    _nodes_save "$(_nodes_load | jq --arg t "$tag" 'map(select(.tag != $t))')"
    log_ok "$(t nodes.deleted "$tag")"
    mc_apply || true
}

nodes_modify() {
    nodes_list
    local tag; ask tag "$(t nodes.ask_tag)"
    local node; node=$(_nodes_get "$tag")
    [[ -z "$node" ]] && { log_error "$(t nodes.not_found "$tag")"; return 1; }
    local server port groups
    ask server "$(t nodes.ask_server)" "$(echo "$node" | jq -r '.proxy.server')"
    ask port   "$(t nodes.ask_port)"   "$(echo "$node" | jq -r '.proxy.port')"
    ask groups "$(t nodes.ask_groups)" "$(echo "$node" | jq -r '(.groups // []) | join(",")')"
    local grp_json; grp_json=$(printf '%s' "$groups" | tr ',' '\n' | sed '/^\s*$/d' | jq -R . | jq -sc .)
    node=$(echo "$node" | jq --arg s "$server" --argjson p "${port:-443}" --argjson g "$grp_json" \
        '.proxy.server=$s | .proxy.port=$p | .groups=$g')
    _nodes_upsert "$node"
    log_ok "$(t nodes.updated "$tag")"
    mc_apply || true
}

nodes_show() {
    nodes_list
    local tag; ask tag "$(t nodes.ask_tag)"
    local node; node=$(_nodes_get "$tag")
    [[ -z "$node" ]] && { log_error "$(t nodes.not_found "$tag")"; return 1; }
    echo "$node" | jq .
}

# ── Interactive: pick the primary node (PROXY group's active exit) ───────────
_mihomo_select_proxy() {
    local group="$1" target="$2" ctrl secret endpoint body attempt
    ctrl="$(jq -r '.controller // "127.0.0.1:9090"' "$SETTINGS_JSON" 2>/dev/null)"
    secret="$(jq -r '.secret // ""' "$SETTINGS_JSON" 2>/dev/null)"
    endpoint="http://${ctrl}/proxies/$(printf '%s' "$group" | jq -sRr @uri)"
    body="$(jq -nc --arg n "$target" '{name:$n}')"
    local auth=(); [[ -n "$secret" ]] && auth=(-H "Authorization: Bearer ${secret}")

    # Applying the config restarts mihomo. systemd may report the unit active
    # slightly before the controller socket is ready, so retry briefly.
    for attempt in 1 2 3 4 5; do
        if curl -fsS -X PUT --connect-timeout 2 --max-time 4 \
                -H "Content-Type: application/json" "${auth[@]}" \
                --data-binary "$body" "$endpoint" >/dev/null 2>&1; then
            return 0
        fi
        (( attempt < 5 )) && sleep 1
    done
    return 1
}

nodes_set_primary() {
    nodes_list
    local current; current="$(jq -r '.primary_node // "AUTO"' "$SETTINGS_JSON" 2>/dev/null)"
    local tag; ask tag "$(t nodes.ask_primary)" "$current"
    [[ -z "$tag" ]] && { log_warn "$(t common.cancelled)"; return; }
    if [[ "$tag" != "AUTO" && "$tag" != "DIRECT" && -z "$(_nodes_get "$tag")" ]]; then
        log_error "$(t nodes.not_found "$tag")"; return 1
    fi
    local tmp; tmp=$(mktemp)
    if jq --arg t "$tag" '.primary_node = $t' "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SETTINGS_JSON"
    else
        rm -f "$tmp"; log_error "$(t config.gen_fail)"; return 1
    fi
    mc_apply || true
    # Live-switch the running core too; profile.store-selected persists it.
    if svc_is_active && have curl; then
        if _mihomo_select_proxy "PROXY" "$tag"; then
            log_ok "$(t nodes.primary_set "$tag")"
        else
            log_warn "$(t nodes.primary_api_warn)"
        fi
    else
        log_ok "$(t nodes.primary_set "$tag")"
    fi
}

# Latency test through the running mihomo external-controller. DIRECT is
# tested as a no-proxy baseline against its own (mainland by default) URL;
# nodes are measured against the proxy test URL.
_nodes_delay_one() {
    # _nodes_delay_one <tag> <encoded-url> <auth-args...>
    local tag="$1" enc="$2"; shift 2
    local ms; ms="$(curl -fsS --max-time 8 "$@" \
        "http://${_NODES_CTRL}/proxies/$(printf '%s' "$tag" | jq -sRr @uri)/delay?timeout=5000&url=${enc}" 2>/dev/null \
        | jq -r '.delay // "timeout"' 2>/dev/null)"
    printf "  %-24s %s\n" "$tag" "${ms:-timeout}${ms:+ms}"
}

# Edit the two latency-test URLs in place (proxy nodes vs DIRECT baseline).
# Standalone entry so changing a URL never drags users through TUN/QUIC prompts.
nodes_set_test_urls() {
    local url_proxy url_direct tmp
    url_proxy="$(jq -r '.test_url_proxy // "http://www.gstatic.com/generate_204"' "$SETTINGS_JSON" 2>/dev/null)"
    url_direct="$(jq -r '.test_url_direct // "http://connect.rom.miui.com/generate_204"' "$SETTINGS_JSON" 2>/dev/null)"
    ask url_proxy "$(t service.ask_test_url_proxy)" "$url_proxy"
    [[ "$url_proxy" =~ ^https?:// ]] || { log_warn "$(t service.bad_test_url)"; url_proxy="http://www.gstatic.com/generate_204"; }
    ask url_direct "$(t service.ask_test_url_direct)" "$url_direct"
    [[ "$url_direct" =~ ^https?:// ]] || { log_warn "$(t service.bad_test_url)"; url_direct="http://connect.rom.miui.com/generate_204"; }
    tmp="$(mktemp)"
    if jq --arg tup "$url_proxy" --arg tud "$url_direct" '
        .test_url_proxy = $tup | .test_url_direct = $tud
    ' "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SETTINGS_JSON"
        log_ok "$(t nodes.test_urls_saved)"
        # AUTO group embeds the proxy URL, so the config must be rebuilt.
        mc_apply || true
    else
        rm -f "$tmp"; log_error "$(t config.gen_fail)"
    fi
}

nodes_test() {
    local secret url_proxy url_direct
    _NODES_CTRL="$(jq -r '.controller // "127.0.0.1:9090"' "$SETTINGS_JSON" 2>/dev/null)"
    secret="$(jq -r '.secret // ""' "$SETTINGS_JSON" 2>/dev/null)"
    url_proxy="$(jq -r '.test_url_proxy // "http://www.gstatic.com/generate_204"' "$SETTINGS_JSON" 2>/dev/null)"
    url_direct="$(jq -r '.test_url_direct // "http://connect.rom.miui.com/generate_204"' "$SETTINGS_JSON" 2>/dev/null)"
    have curl || { log_error "$(t common.dep_missing "curl")"; return 1; }
    local auth=(); [[ -n "$secret" ]] && auth=(-H "Authorization: Bearer ${secret}")
    log_step "$(t nodes.test_running)"
    log_info "$(t nodes.test_url_direct "$url_direct")"
    _nodes_delay_one "DIRECT" "$(printf '%s' "$url_direct" | jq -sRr @uri)" "${auth[@]}"
    log_info "$(t nodes.test_url_proxy "$url_proxy")"
    local enc tag; enc="$(printf '%s' "$url_proxy" | jq -sRr @uri)"
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        _nodes_delay_one "$tag" "$enc" "${auth[@]}"
    done < <(_nodes_tags)
}

# ── Menu ─────────────────────────────────────────────────────────────────────
nodes_menu() {
    while true; do
        show_menu "$(t nodes.menu_title)" \
            "$(t nodes.import_uri)" \
            "$(t nodes.import_sub)" \
            "$(t nodes.add_manual)" \
            "$(t nodes.list)" \
            "$(t nodes.modify)" \
            "$(t nodes.delete)" \
            "$(t nodes.show)" \
            "$(t nodes.test)" \
            "$(t nodes.set_test_urls)" \
            "$(t nodes.set_primary)"
        case "$MENU_CHOICE" in
            1) nodes_import_uri ;;
            2) nodes_import_sub ;;
            3) nodes_add_manual ;;
            4) nodes_list ;;
            5) nodes_modify ;;
            6) nodes_delete ;;
            7) nodes_show ;;
            8) nodes_test ;;
            9) nodes_set_test_urls ;;
            10) nodes_set_primary ;;
            0) return ;;
        esac
        press_enter
    done
}
