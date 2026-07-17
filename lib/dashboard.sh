#!/usr/bin/env bash
# dashboard.sh — external-controller info + optional local Web UI (metacubexd).
[[ -n "${_MC_DASHBOARD_LOADED:-}" ]] && return 0
_MC_DASHBOARD_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

dashboard_info() {
    local ctrl secret ui
    ctrl="$(jq -r '.controller // "127.0.0.1:9090"' "$SETTINGS_JSON" 2>/dev/null)"
    secret="$(jq -r '.secret // ""' "$SETTINGS_JSON" 2>/dev/null)"
    ui="$(jq -r '.external_ui // ""' "$SETTINGS_JSON" 2>/dev/null)"
    echo -e "\n${BOLD}$(t dashboard.title)${NC}"
    printf "  %-16s http://%s\n" "API:" "$ctrl"
    printf "  %-16s %s\n" "Secret:" "${secret:-<none>}"
    if [[ -n "$ui" ]]; then
        printf "  %-16s http://%s/ui/\n" "Local UI:" "$ctrl"
    elif [[ -d "$MC_CONF_DIR/ui" ]]; then
        echo -e "  ${YELLOW}$(t dashboard.ui_off)${NC}"
    fi
    echo -e "  ${CYAN}$(t dashboard.hint)${NC}"
    # Controller binds 127.0.0.1 — never exposed publicly; remote access is an
    # SSH tunnel away.
    local port="${ctrl##*:}"
    echo -e "  ${CYAN}$(t dashboard.tunnel_hint "$port" "$port" "$port")${NC}"
}

# Fetch metacubexd's prebuilt dist into $MC_CONF_DIR/ui and point mihomo at it
# via external-ui, so the panel is served at http://<controller>/ui/.
dashboard_install_ui() {
    ensure_deps curl tar || return 1
    local dir="$MC_CONF_DIR/ui" tmp direct_url url source downloaded=0
    tmp="$(mktemp)"
    direct_url="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
    log_step "$(t dashboard.installing_ui)"
    log_info "$(t core.probing)"
    while IFS= read -r url; do
        if [[ "$url" == "$direct_url" ]]; then source="GitHub"; else source="${url%%/https://*}"; fi
        log_info "$(t core.download_route "$source")"
        if mc_download "$url" "$tmp" \
                && tar -tzf "$tmp" >/dev/null 2>&1; then
            downloaded=1
            break
        fi
        log_warn "$(t core.download_route_fail "$source")"
    done < <(mc_rank_urls < <(github_url_candidates "$direct_url"))
    if (( ! downloaded )); then
        rm -f "$tmp"; log_error "$(t dashboard.ui_fail)"; return 1
    fi
    mkdir -p "$dir"
    tar -xzf "$tmp" -C "$dir" 2>/dev/null || { rm -f "$tmp"; log_error "$(t dashboard.ui_fail)"; return 1; }
    rm -f "$tmp"
    _settings_set_dash external_ui "ui"
    log_ok "$(t dashboard.ui_ready)"
    mc_apply || true
}

_settings_set_dash() {
    local key="$1" val="$2" tmp; tmp=$(mktemp)
    if jq --arg v "$val" ".${key} = \$v" "$SETTINGS_JSON" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$SETTINGS_JSON"; else rm -f "$tmp"; fi
}

# Enable the already-downloaded panel (external-ui → ui) without re-fetching.
dashboard_enable_ui() {
    [[ -d "$MC_CONF_DIR/ui" ]] || { log_warn "$(t dashboard.ui_missing)"; return 1; }
    _settings_set_dash external_ui "ui"
    mc_apply || true
    log_ok "$(t dashboard.ui_enabled)"
}

# Disable serving the panel; the downloaded files stay for quick re-enable.
dashboard_disable_ui() {
    _settings_set_dash external_ui ""
    mc_apply || true
    log_ok "$(t dashboard.ui_disabled)"
}

# Remove the panel files entirely and stop serving them.
dashboard_uninstall_ui() {
    ask_yn "$(t dashboard.confirm_uninstall)" N || return 0
    _settings_set_dash external_ui ""
    rm -rf "$MC_CONF_DIR/ui"
    mc_apply || true
    log_ok "$(t dashboard.ui_uninstalled)"
}

dashboard_menu() {
    while true; do
        dashboard_info
        show_menu "$(t dashboard.menu_title)" \
            "$(t dashboard.install_ui)" \
            "$(t dashboard.enable_ui)" \
            "$(t dashboard.disable_ui)" \
            "$(t dashboard.uninstall_ui)"
        case "$MENU_CHOICE" in
            1) dashboard_install_ui ;;
            2) dashboard_enable_ui ;;
            3) dashboard_disable_ui ;;
            4) dashboard_uninstall_ui ;;
            0) return ;;
        esac
        press_enter
    done
}
