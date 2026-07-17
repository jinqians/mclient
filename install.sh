#!/usr/bin/env bash
# install.sh — bootstrap mclient on a Linux host: deps, mihomo binary, systemd
# unit, default config, and a first node. Interactive, so it does not use `set -e`.
set -uo pipefail
MC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MC_ROOT
source "$MC_ROOT/lib/common.sh"
source "$MC_ROOT/lib/i18n.sh"
source "$MC_ROOT/lib/config.sh"
source "$MC_ROOT/lib/core.sh"
source "$MC_ROOT/lib/nodes.sh"
source "$MC_ROOT/lib/service.sh"

i18n_init
[[ -f "$STATE_JSON" ]] || i18n_pick
require_root

log_step "$(t install.welcome)"
ensure_deps jq curl openssl tar || die "$(t install.deps_fail)"
region="$(network_region_detect)"
case "$region" in
    CN) log_info "$(t install.region_cn "$MC_GITHUB_MIRROR")" ;;
    GLOBAL) log_info "$(t install.region_global)" ;;
    *) log_warn "$(t install.region_unknown)" ;;
esac
config_init_defaults
config_route_default_github_urls || log_warn "$(t config.github_route_fail)"

if ! mihomo_installed; then
    if ask_yn "$(t install.get_mihomo)" Y; then
        mihomo_install || true
    else
        log_warn "$(t install.skip_mihomo)"
    fi
else
    log_info "$(t install.have_mihomo "$(mihomo_version)")"
fi

service_install_unit

# ── Shortcut launcher (psm-style) ────────────────────────────────────────────
# `mclient` (and `mc` when the name is free) pulls the latest code first when
# the checkout is a git clone, then opens the menu.
_launcher_write() {
    cat > "$1" <<LAUNCH
#!/usr/bin/env bash
# mclient launcher
MC_HOME="$MC_ROOT"
if [[ -d "\$MC_HOME/.git" ]] && command -v git >/dev/null 2>&1; then
    (cd "\$MC_HOME" && timeout 10 git pull --ff-only --quiet 2>/dev/null) || true
fi
exec "\$MC_HOME/mc.sh" "\$@"
LAUNCH
    chmod 0755 "$1"
}
install_launcher() {
    _launcher_write /usr/local/bin/mclient
    log_ok "$(t install.launcher_installed "mclient")"
    local existing
    existing="$(command -v mc 2>/dev/null || true)"
    if [[ -z "$existing" ]] || grep -q '^# mclient launcher' "$existing" 2>/dev/null; then
        _launcher_write /usr/local/bin/mc
        log_ok "$(t install.launcher_installed "mc")"
    else
        log_warn "$(t install.launcher_mc_taken "$existing")"
    fi
}
install_launcher

echo ""
log_step "$(t install.first_node)"
ask_yn "$(t install.add_first)" Y && nodes_import_uri --defer-apply

# Apply once after the optional import. nodes_import_uri normally applies its
# changes immediately, but installation defers it to avoid validating twice.
mc_apply || true
if [[ "$(_nodes_count)" == "0" ]]; then
    log_warn "$(t install.no_nodes)"
fi
if svc_start && svc_wait_active; then
    log_ok "$(t install.started)"
else
    log_warn "$(t install.start_fail)"
    service_logs
fi

echo ""
log_ok "$(t install.done)"
log_info "$(t install.run_hint)"
