#!/usr/bin/env bash
# service.sh — systemd unit + interception-mode switch + service control.
#
# Interception mode is the deliberate extension seam. Today: "tun" (whole-host
# transparent, the default) and "system" (mixed-port HTTP/SOCKS). "tproxy"
# (LAN gateway / 旁路由) is reserved — the config generator already emits a
# tproxy-port for it; only the firewall/nftables wiring below is left to add.
[[ -n "${_MC_SERVICE_LOADED:-}" ]] && return 0
_MC_SERVICE_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SERVICE_UNIT="/etc/systemd/system/${MIHOMO_SVC}.service"

service_install_unit() {
    require_root
    cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=mclient (mihomo proxy client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${MC_CONF_DIR}
Restart=on-failure
RestartSec=3
# TUN needs NET_ADMIN/NET_RAW; these caps let mihomo run without full root.
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    svc_enable
    log_ok "$(t service.unit_installed)"
}

_settings_set() {
    local key="$1" val="$2" tmp; tmp=$(mktemp)
    if jq --arg v "$val" ".${key} = \$v" "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$SETTINGS_JSON"; else rm -f "$tmp"; fi
}

# ── Network region (CN / GLOBAL) ─────────────────────────────────────────────
# Detected once at install and cached; a relocated box switches here. All
# region-derived stock settings (DNS layout, DIRECT test URL, mirror
# preference) follow automatically via config_migrate_settings.
service_set_region() {
    local cur; cur="$(network_region_effective)"
    echo -e "  $(t service.region_current "$cur")"
    echo -e "  1. CN — $(t service.region_cn)"
    echo -e "  2. GLOBAL — $(t service.region_global)"
    echo -e "  3. $(t service.region_auto)"
    local c; read -rp "$(echo -e "${CYAN}$(t common.select): ${NC}")" c
    local region=""
    case "${c:-}" in
        1) region="CN" ;;
        2) region="GLOBAL" ;;
        3)
            svc_is_active && log_warn "$(t service.region_proxy_warn)"
            log_info "$(t service.region_detecting)"
            region="$(MC_REGION=AUTO network_region_detect)" ;;
        *) return 0 ;;
    esac
    [[ -z "$region" ]] && return 0
    MC_NETWORK_REGION="$region"; export MC_NETWORK_REGION
    state_set network_region "$region"
    log_ok "$(t service.region_set "$region")"
    config_migrate_settings || true
    mc_apply || true
}

# ── IPv6 leak guard ──────────────────────────────────────────────────────────
# mihomo runs with ipv6:false, so it only captures IPv4; native IPv6 would
# bypass the TUN and expose the real address (the classic WebRTC leak, and it
# affects all v6 traffic, not just WebRTC). While proxying is v4-only the
# guard disables system IPv6; it re-enables when ipv6 proxying is turned on
# or the guard is switched off. Kept idempotent: mc_apply calls it on every
# apply so any settings path stays in sync.
IPV6_GUARD_SYSCTL="/etc/sysctl.d/98-mclient-ipv6.conf"

service_ipv6_guard_sync() {
    [[ -d /etc/sysctl.d ]] || return 0   # not a Linux target (e.g. dev box)
    local want
    want="$(jq -r 'if (.ipv6 // false) == false and (.block_ipv6_leak // false) == true
                   then "1" else "0" end' "$SETTINGS_JSON" 2>/dev/null)"
    if [[ "$want" == "1" ]]; then
        [[ -f "$IPV6_GUARD_SYSCTL" ]] && return 0
        printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' \
            > "$IPV6_GUARD_SYSCTL" 2>/dev/null || return 0
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
        log_info "$(t service.ipv6_guard_on)"
    else
        [[ -f "$IPV6_GUARD_SYSCTL" ]] || return 0
        rm -f "$IPV6_GUARD_SYSCTL"
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        log_info "$(t service.ipv6_guard_off)"
    fi
}

# ── Gateway (旁路由) mode: TUN + IPv4 forwarding for the whole LAN ───────────
GATEWAY_SYSCTL="/etc/sysctl.d/99-mclient-gateway.conf"

_lan_ip() {
    have ip || return 1
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1
}

# Forwarded LAN traffic only reaches the TUN device with ip_forward on; the
# sysctl.d drop-in keeps it enabled across reboots.
_gateway_forwarding_on() {
    printf 'net.ipv4.ip_forward = 1\n' > "$GATEWAY_SYSCTL" 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    log_ok "$(t service.gateway_forward_on)"
}

_gateway_forwarding_off() {
    [[ -f "$GATEWAY_SYSCTL" ]] || return 0
    rm -f "$GATEWAY_SYSCTL"
    log_info "$(t service.gateway_forward_off)"
}

_settings_set_bool() {
    local key="$1" val="$2" tmp; tmp=$(mktemp)
    if jq --argjson v "$val" ".${key} = \$v" "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$SETTINGS_JSON"; else rm -f "$tmp"; fi
}

_gateway_enabled() {
    [[ "$(jq -r '.lan_gateway // false' "$SETTINGS_JSON" 2>/dev/null)" == "true" ]]
}

service_set_mode() {
    echo -e "  1. TUN — $(t service.mode_tun)"
    echo -e "  2. system-proxy — $(t service.mode_system)"
    local c; read -rp "$(echo -e "${CYAN}$(t service.ask_mode) [1]: ${NC}")" c
    local mode
    case "${c:-1}" in
        2) mode=system ;;
        *) mode=tun ;;
    esac
    _settings_set intercept_mode "$mode"
    # The gateway add-on rides on TUN; leaving TUN switches it off too.
    if [[ "$mode" != "tun" ]] && _gateway_enabled; then
        _settings_set_bool lan_gateway false
        _gateway_forwarding_off
        log_warn "$(t service.gateway_off_by_mode)"
    fi
    log_ok "$(t service.mode_set "$mode")"
    mc_apply || true
    [[ "$mode" == "system" ]] && log_info "$(t service.system_hint "$(jq -r '.mixed_port // 7890' "$SETTINGS_JSON")")"
}

# Standalone on/off toggle for the LAN gateway (旁路由) add-on. Optional:
# nothing in install or normal single-host use ever requires it.
service_toggle_gateway() {
    if _gateway_enabled; then
        _settings_set_bool lan_gateway false
        _gateway_forwarding_off
        log_ok "$(t service.gateway_disabled)"
        mc_apply || true
    else
        local mode; mode="$(jq -r '.intercept_mode // "tun"' "$SETTINGS_JSON" 2>/dev/null)"
        if [[ "$mode" != "tun" ]]; then
            _settings_set intercept_mode tun
            log_info "$(t service.gateway_needs_tun)"
        fi
        _settings_set_bool lan_gateway true
        _gateway_forwarding_on
        log_info "$(t service.gateway_port53)"
        mc_apply || true
        local lan_ip; lan_ip="$(_lan_ip || true)"
        log_info "$(t service.gateway_hint "${lan_ip:-<LAN-IP>}")"
        # LAN clients' native IPv6 bypasses a side-gateway entirely; only the
        # main router can cut it off.
        log_info "$(t service.gateway_ipv6_note)"
    fi
}

service_set_network() {
    local stack mtu current_quic quic tmp
    stack="$(jq -r '.tun.stack // "mixed"' "$SETTINGS_JSON" 2>/dev/null)"
    mtu="$(jq -r '.tun.mtu // 1500' "$SETTINGS_JSON" 2>/dev/null)"
    current_quic="$(jq -r '.quic_policy // "block"' "$SETTINGS_JSON" 2>/dev/null)"

    ask stack "$(t service.ask_tun_stack)" "$stack"
    case "$stack" in system|gvisor|mixed) ;; *) stack=mixed ;; esac
    ask mtu "$(t service.ask_tun_mtu)" "$mtu"
    if [[ ! "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 1280 || mtu > 9000 )); then
        log_warn "$(t service.bad_tun_mtu)"; mtu=1500
    fi
    if [[ "$current_quic" == "block" ]]; then
        ask_yn "$(t service.ask_block_quic)" Y && quic=block || quic=allow
    else
        ask_yn "$(t service.ask_block_quic)" N && quic=block || quic=allow
    fi
    local cur_guard guard
    cur_guard="$(jq -r '.block_ipv6_leak // false' "$SETTINGS_JSON" 2>/dev/null)"
    if [[ "$cur_guard" == "true" ]]; then
        ask_yn "$(t service.ask_ipv6_guard)" Y && guard=true || guard=false
    else
        ask_yn "$(t service.ask_ipv6_guard)" N && guard=true || guard=false
    fi
    tmp="$(mktemp)"
    if jq --arg stack "$stack" --argjson mtu "$mtu" --arg quic "$quic" --argjson guard "$guard" '
        .tun = ((.tun // {}) + {stack:$stack, mtu:$mtu})
        | .quic_policy = $quic
        | .block_ipv6_leak = $guard
    ' "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SETTINGS_JSON"
        log_ok "$(t service.network_set "$stack" "$mtu" "$quic")"
        mc_apply || true
    else
        rm -f "$tmp"
        log_error "$(t config.gen_fail)"
        return 1
    fi
}

service_logs() { journalctl -u "$MIHOMO_SVC" -n 60 --no-pager 2>/dev/null || log_warn "$(t service.no_logs)"; }

service_menu() {
    while true; do
        local st; svc_is_active && st="${GREEN}$(t service.active)${NC}" || st="${YELLOW}$(t service.inactive)${NC}"
        local mode stack mtu quic gw_st
        mode="$(jq -r '.intercept_mode // "tun"' "$SETTINGS_JSON" 2>/dev/null)"
        stack="$(jq -r '.tun.stack // "mixed"' "$SETTINGS_JSON" 2>/dev/null)"
        mtu="$(jq -r '.tun.mtu // 1500' "$SETTINGS_JSON" 2>/dev/null)"
        quic="$(jq -r '.quic_policy // "block"' "$SETTINGS_JSON" 2>/dev/null)"
        _gateway_enabled && gw_st="$(t service.gw_on)" || gw_st="$(t service.gw_off)"
        echo -e "\n  $(t service.status): ${st}   $(t service.mode): ${GREEN}${mode}${NC}   $(t service.gateway_state "$gw_st")"
        echo -e "  $(t service.network_status "$stack" "$mtu" "$quic")"
        show_menu "$(t service.menu_title)" \
            "$(t service.start)" \
            "$(t service.stop)" \
            "$(t service.restart)" \
            "$(t service.apply)" \
            "$(t service.status_cmd)" \
            "$(t service.logs)" \
            "$(t service.set_mode)" \
            "$(t service.set_network)" \
            "$(t service.gateway_toggle "$gw_st")" \
            "$(t service.install_unit)" \
            "$(t service.update_core)"
        case "$MENU_CHOICE" in
            1) svc_start   && log_ok "$(t service.started)"  || log_error "$(t service.op_fail)" ;;
            2) svc_stop    && log_ok "$(t service.stopped)"  || log_error "$(t service.op_fail)" ;;
            3) svc_restart && log_ok "$(t service.restarted)"|| log_error "$(t service.op_fail)" ;;
            4) mc_apply || true ;;
            5) svc_status ;;
            6) service_logs ;;
            7) service_set_mode ;;
            8) service_set_network ;;
            9) service_toggle_gateway ;;
            10) service_install_unit ;;
            11) mihomo_install && { svc_is_active && { svc_restart && log_ok "$(t service.restarted)" || log_error "$(t service.op_fail)"; } || true; } ;;
            0) return ;;
        esac
        press_enter
    done
}
