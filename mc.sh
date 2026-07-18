#!/usr/bin/env bash
# mc.sh — mclient main menu entry point.
MC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MC_ROOT
source "$MC_ROOT/lib/common.sh"
source "$MC_ROOT/lib/i18n.sh"
source "$MC_ROOT/lib/config.sh"
source "$MC_ROOT/lib/core.sh"
source "$MC_ROOT/lib/nodes.sh"
source "$MC_ROOT/lib/routing.sh"
source "$MC_ROOT/lib/service.sh"
source "$MC_ROOT/lib/dashboard.sh"

if ! have jq; then
    echo "mclient requires jq. Install it first (e.g. apt install jq / dnf install jq)." >&2
    exit 1
fi

i18n_init
config_init_defaults
config_route_default_github_urls || log_warn "$(t config.github_route_fail)"

main_menu() {
    while true; do
        local ver n st
        ver="$(mihomo_version 2>/dev/null)"; [[ -z "$ver" ]] && ver="$(t main.not_installed)"
        n="$(_nodes_count 2>/dev/null || echo 0)"
        svc_is_active && st="${GREEN}$(t service.active)${NC}" || st="${YELLOW}$(t service.inactive)${NC}"
        echo -e "\n${BOLD}${BLUE}mclient${NC} — $(t main.subtitle)"
        echo -e "  mihomo: ${GREEN}${ver}${NC}   $(t main.nodes_count "$n")   ${st}"
        show_menu "$(t main.title)" \
            "$(t main.nodes)" \
            "$(t main.routing)" \
            "$(t main.service)" \
            "$(t main.dashboard)" \
            "$(t main.region)" \
            "$(t main.lang)"
        case "$MENU_CHOICE" in
            1) nodes_menu ;;
            2) routing_menu ;;
            3) service_menu ;;
            4) dashboard_menu ;;
            5) service_set_region; press_enter ;;
            6) i18n_pick ;;
            0) exit 0 ;;
            *) : ;;
        esac
    done
}

main_menu
