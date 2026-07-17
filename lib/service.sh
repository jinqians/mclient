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

service_set_mode() {
    echo -e "  1. TUN — $(t service.mode_tun)"
    echo -e "  2. system-proxy — $(t service.mode_system)"
    echo -e "  3. tproxy/gateway — $(t service.mode_tproxy)"
    local c; read -rp "$(echo -e "${CYAN}$(t service.ask_mode) [1]: ${NC}")" c
    local mode
    case "${c:-1}" in
        2) mode=system ;;
        3) log_warn "$(t service.tproxy_todo)"; return 0 ;;   # extension seam — not wired yet
        *) mode=tun ;;
    esac
    _settings_set intercept_mode "$mode"
    log_ok "$(t service.mode_set "$mode")"
    mc_apply || true
    [[ "$mode" == "system" ]] && log_info "$(t service.system_hint "$(jq -r '.mixed_port // 7890' "$SETTINGS_JSON")")"
}

service_logs() { journalctl -u "$MIHOMO_SVC" -n 60 --no-pager 2>/dev/null || log_warn "$(t service.no_logs)"; }

service_menu() {
    while true; do
        local st; svc_is_active && st="${GREEN}$(t service.active)${NC}" || st="${YELLOW}$(t service.inactive)${NC}"
        local mode; mode="$(jq -r '.intercept_mode // "tun"' "$SETTINGS_JSON" 2>/dev/null)"
        echo -e "\n  $(t service.status): ${st}   $(t service.mode): ${GREEN}${mode}${NC}"
        show_menu "$(t service.menu_title)" \
            "$(t service.start)" \
            "$(t service.stop)" \
            "$(t service.restart)" \
            "$(t service.status_cmd)" \
            "$(t service.logs)" \
            "$(t service.set_mode)" \
            "$(t service.install_unit)" \
            "$(t service.update_core)"
        case "$MENU_CHOICE" in
            1) svc_start   && log_ok "$(t service.started)"  || log_error "$(t service.op_fail)" ;;
            2) svc_stop    && log_ok "$(t service.stopped)"  || log_error "$(t service.op_fail)" ;;
            3) svc_restart && log_ok "$(t service.restarted)"|| log_error "$(t service.op_fail)" ;;
            4) svc_status ;;
            5) service_logs ;;
            6) service_set_mode ;;
            7) service_install_unit ;;
            8) mihomo_install && { svc_is_active && { svc_restart && log_ok "$(t service.restarted)" || log_error "$(t service.op_fail)"; } || true; } ;;
            0) return ;;
        esac
        press_enter
    done
}
