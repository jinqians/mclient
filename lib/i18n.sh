#!/usr/bin/env bash
# i18n.sh — minimal pure-bash i18n for mclient (zh base + selected-language overlay).
[[ -n "${_MC_I18N_LOADED:-}" ]] && return 0
_MC_I18N_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || echo "mclient needs bash 4+ (associative arrays)" >&2
declare -gA MSG

MC_LANG_DEFAULT="zh"
MC_LANG_SUPPORTED="zh en"

_i18n_resolve() {
    local l="${MC_LANG:-}"
    [[ -z "$l" ]] && l="$(state_get lang 2>/dev/null || true)"
    [[ -z "$l" ]] && l="$MC_LANG_DEFAULT"
    [[ " $MC_LANG_SUPPORTED " == *" $l "* ]] || l="$MC_LANG_DEFAULT"
    printf '%s' "$l"
}

# Load zh as the base (guarantees a fallback for any missing key), then overlay
# the selected language on top.
i18n_init() {
    MC_LANG="$(_i18n_resolve)"; MSG=()
    [[ -f "$MC_LANG_DIR/zh.sh" ]] && source "$MC_LANG_DIR/zh.sh"
    if [[ "$MC_LANG" != "zh" && -f "$MC_LANG_DIR/${MC_LANG}.sh" ]]; then
        source "$MC_LANG_DIR/${MC_LANG}.sh"
    fi
    return 0
}

# t <key> [printf args...] → localized text (missing key renders as ⟪key⟫).
t() {
    local key="$1"; shift
    [[ -z "${MSG[$key]+x}" ]] && { printf '⟪%s⟫' "$key"; return; }
    local tmpl="${MSG[$key]}"
    if (( $# )); then printf "$tmpl" "$@"; else printf '%s' "$tmpl"; fi
}

i18n_set_lang() { state_set lang "$1"; MC_LANG="$1"; i18n_init; }

i18n_pick() {
    echo -e "  1. 简体中文\n  2. English"
    local c; read -rp "$(echo -e "${CYAN}选择语言 / Select language [1]: ${NC}")" c
    case "${c:-1}" in 2) i18n_set_lang en ;; *) i18n_set_lang zh ;; esac
}
