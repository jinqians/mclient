#!/usr/bin/env bash
# uninstall.sh — stop and remove the mclient service (optionally config + binary).
set -uo pipefail
MC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MC_ROOT
source "$MC_ROOT/lib/common.sh"
source "$MC_ROOT/lib/i18n.sh"
source "$MC_ROOT/lib/core.sh"
source "$MC_ROOT/lib/service.sh"

i18n_init
require_root

log_step "$(t uninstall.title)"
svc_stop 2>/dev/null || true
systemctl disable "$MIHOMO_SVC" --quiet 2>/dev/null || true
rm -f "$SERVICE_UNIT"
systemctl daemon-reload 2>/dev/null || true
log_ok "$(t uninstall.service_removed)"

# Remove shortcut launchers, but only ones we wrote (never an unrelated `mc`).
for l in /usr/local/bin/mclient /usr/local/bin/mc; do
    if [[ -f "$l" ]] && grep -q '^# mclient launcher' "$l" 2>/dev/null; then
        rm -f "$l"
    fi
done
log_ok "$(t uninstall.launcher_removed)"

if ask_yn "$(t uninstall.remove_config)" N; then
    rm -rf "$MC_CONF_DIR"
    log_ok "$(t uninstall.config_removed)"
fi

if [[ -x "$MIHOMO_BIN" ]] && ask_yn "$(t uninstall.remove_binary)" N; then
    rm -f "$MIHOMO_BIN"
    log_ok "$(t uninstall.binary_removed)"
fi

log_ok "$(t uninstall.done)"
