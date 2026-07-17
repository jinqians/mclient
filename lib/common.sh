#!/usr/bin/env bash
# common.sh — shared helpers for mclient (a mihomo-based proxy client manager).
# Kept deliberately close to proxy-stack's conventions so patterns/knowledge carry over.
[[ -n "${_MC_COMMON_LOADED:-}" ]] && return 0
_MC_COMMON_LOADED=1

# ── Paths (config/ is runtime state; overridable so an install can relocate it) ──
MC_ROOT="${MC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MC_LIB_DIR="$MC_ROOT/lib"
MC_LANG_DIR="$MC_ROOT/lang"
MC_CONF_DIR="${MC_CONF_DIR:-$MC_ROOT/config}"
NODES_JSON="$MC_CONF_DIR/nodes.json"
RULES_JSON="$MC_CONF_DIR/rules.json"
SETTINGS_JSON="$MC_CONF_DIR/settings.json"
STATE_JSON="$MC_CONF_DIR/state.json"
MIHOMO_CFG="$MC_CONF_DIR/config.yaml"          # generated; JSON content (valid YAML) mihomo reads
MC_GITHUB_MIRROR="${MC_GITHUB_MIRROR:-https://cf.jinqians.com}"
# Ordered fallback list; the primary mirror always comes first. Every entry is a
# prefix-style proxy that accepts <mirror>/https://github.com/… URLs.
MC_GITHUB_MIRRORS="${MC_GITHUB_MIRRORS:-$MC_GITHUB_MIRROR https://ghfast.top https://gh-proxy.com https://ghproxy.net}"

# ── Colors (disabled when stdout is not a TTY) ───────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ── Logging ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "  ${CYAN}i${NC} $*"; }
log_ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "  ${YELLOW}!${NC} $*" >&2; }
log_error() { echo -e "  ${RED}✗${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${BLUE}▶${NC} ${BOLD}$*${NC}"; }
die()       { log_error "$*"; exit 1; }

# ── Prompts ──────────────────────────────────────────────────────────────────
ask() {
    # ask <var> <prompt> [default]
    local var="$1" prompt="$2" default="${3:-}" hint="" val
    [[ -n "$default" ]] && hint=" [${default}]"
    read -rp "$(echo -e "${CYAN}${prompt}${hint}: ${NC}")" val
    [[ -z "$val" && -n "$default" ]] && val="$default"
    printf -v "$var" '%s' "$val"
}
ask_yn() {
    # ask_yn <prompt> [Y|N] → 0=yes 1=no
    local prompt="$1" default="${2:-Y}" hint ans
    [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$(echo -e "${CYAN}${prompt} ${hint}: ${NC}")" ans
    [[ -z "$ans" ]] && ans="$default"
    [[ "$ans" =~ ^[Yy]$ ]]
}
press_enter() { read -rp "$(echo -e "${YELLOW}$(t common.press_enter)${NC}")" _; }

# ── Menu builder (sets global MENU_CHOICE) ───────────────────────────────────
show_menu() {
    local title="$1"; shift
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  $title${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    local i=1 opt
    for opt in "$@"; do printf "  ${CYAN}%2d.${NC} %s\n" "$i" "$opt"; ((i++)); done
    echo -e "  ${CYAN} 0.${NC} $(t common.back)"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t common.select): ${NC}")" MENU_CHOICE
}

# ── Tiny key/value state store ───────────────────────────────────────────────
_state_init() { mkdir -p "$MC_CONF_DIR"; [[ -f "$STATE_JSON" ]] || echo '{}' > "$STATE_JSON"; }
state_get() { _state_init; jq -r --arg k "$1" '.[$k] // empty' "$STATE_JSON" 2>/dev/null; }
state_set() {
    _state_init; local tmp; tmp=$(mktemp)
    if jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$STATE_JSON" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$STATE_JSON"
    else
        rm -f "$tmp"
    fi
}

# ── Dependencies ─────────────────────────────────────────────────────────────
have() { command -v "$1" &>/dev/null; }
ensure_deps() {
    local miss=() c
    for c in "$@"; do have "$c" || miss+=("$c"); done
    (( ${#miss[@]} == 0 )) && return 0
    log_warn "$(t common.dep_missing "${miss[*]}")"
    if   have apt-get; then sudo apt-get update -qq && sudo apt-get install -y "${miss[@]}"
    elif have dnf;     then sudo dnf install -y "${miss[@]}"
    elif have yum;     then sudo yum install -y "${miss[@]}"
    elif have pacman;  then sudo pacman -Sy --noconfirm "${miss[@]}"
    elif have apk;     then sudo apk add "${miss[@]}"
    else log_error "$(t common.dep_manual "${miss[*]}")"; return 1; fi
}
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "$(t common.need_root)"; }
rand_hex() { openssl rand -hex "${1:-8}" 2>/dev/null || head -c "${1:-8}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ── Network region + GitHub routing ─────────────────────────────────────────
# MC_REGION=CN|GLOBAL bypasses detection. Detection is advisory only: every
# download path still falls back to the other route when the preferred one
# fails, so a geolocation outage can never block installation by itself.
network_region_detect() {
    local forced="${MC_REGION:-AUTO}" country="" region
    forced="${forced^^}"
    case "$forced" in
        CN|CHINA) region="CN" ;;
        GLOBAL|INTL|INTERNATIONAL|OVERSEA|OVERSEAS) region="GLOBAL" ;;
        *)
            if have curl; then
                country="$(curl -fsSL --connect-timeout 3 --max-time 6 \
                    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
                    | sed -n 's/^loc=\([A-Za-z][A-Za-z]\)$/\1/p' | head -1)"
                if [[ ! "$country" =~ ^[A-Za-z]{2}$ ]]; then
                    country="$(curl -fsSL --connect-timeout 3 --max-time 6 \
                        https://ipinfo.io/country 2>/dev/null | tr -dc 'A-Za-z' | head -c 2)"
                fi
                if [[ ! "$country" =~ ^[A-Za-z]{2}$ ]]; then
                    country="$(curl -fsSL --connect-timeout 3 --max-time 6 \
                        https://ifconfig.co/country-iso 2>/dev/null | tr -dc 'A-Za-z' | head -c 2)"
                fi
            fi
            country="${country^^}"
            if [[ "$country" == "CN" ]]; then region="CN"
            elif [[ "$country" =~ ^[A-Z]{2}$ ]]; then region="GLOBAL"
            else region="UNKNOWN"
            fi
            ;;
    esac
    MC_NETWORK_REGION="$region"; export MC_NETWORK_REGION
    state_set network_region "$region" 2>/dev/null || true
    printf '%s' "$region"
}

network_region_effective() {
    local region="${MC_NETWORK_REGION:-}"
    [[ -z "$region" ]] && region="$(state_get network_region 2>/dev/null || true)"
    case "$region" in CN|GLOBAL|UNKNOWN) printf '%s' "$region" ;; *) printf 'UNKNOWN' ;; esac
}

github_mirror_url() {
    local mirror="${2:-$MC_GITHUB_MIRROR}" url="$1"
    mirror="${mirror%/}"
    url="${url#"$mirror"/}"
    printf '%s/%s' "$mirror" "$url"
}

# Deduplicated mirror list, primary first, one per line.
github_mirror_list() {
    local m seen=" "
    for m in $MC_GITHUB_MIRRORS; do
        m="${m%/}"
        [[ "$seen" == *" $m "* ]] && continue
        seen+="$m "
        printf '%s\n' "$m"
    done
}

# Print direct and mirrored candidates in the preferred order, one per line.
# CN: every mirror first (primary → fallbacks), then direct; elsewhere reversed.
github_url_candidates() {
    local direct="$1" region m
    region="$(network_region_effective)"
    if [[ "$region" == "CN" ]]; then
        while IFS= read -r m; do github_mirror_url "$direct" "$m"; echo; done < <(github_mirror_list)
        printf '%s\n' "$direct"
    else
        printf '%s\n' "$direct"
        while IFS= read -r m; do github_mirror_url "$direct" "$m"; echo; done < <(github_mirror_list)
    fi
}

# Runtime configs can contain only one provider URL. Mainland China uses the
# mirror; other/unknown regions keep the official URL.
github_preferred_url() {
    local direct="$1"
    if [[ "$(network_region_effective)" == "CN" ]]; then github_mirror_url "$direct"; else printf '%s' "$direct"; fi
}

# ── Mirror speed probe ───────────────────────────────────────────────────────
# Region preference only orders candidates; a "preferred" mirror can still be
# slow. Probe all candidates in parallel (first 256 KB each, ≤8 s) and emit
# them fastest-first; unreachable ones sort last but stay as fallbacks.
mc_rank_urls() {
    local tmpdir url i=0; local -a urls=()
    tmpdir="$(mktemp -d)"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        urls+=("$url")
        (
            s="$(curl -fsSL -o /dev/null -r 0-262143 --connect-timeout 5 --max-time 8 \
                -w '%{speed_download}' "$url" 2>/dev/null)" || s=0
            printf '%s' "${s%%[.,]*}" > "$tmpdir/$i"
        ) &
        i=$((i + 1))
    done
    wait
    if (( ${#urls[@]} <= 1 )); then
        (( ${#urls[@]} == 1 )) && printf '%s\n' "${urls[0]}"
        rm -rf "$tmpdir"; return 0
    fi
    local speed
    for ((i=0; i<${#urls[@]}; i++)); do
        speed="$(cat "$tmpdir/$i" 2>/dev/null)"
        [[ "$speed" =~ ^[0-9]+$ ]] || speed=0
        printf '%s\t%s\t%s\n' "$speed" "$i" "${urls[$i]}"
    done | sort -t$'\t' -k1,1rn -k2,2n | cut -f3-
    rm -rf "$tmpdir"
}

# ── Large-file download ──────────────────────────────────────────────────────
# Slow links (e.g. mainland → mirror) must never be killed mid-transfer by a
# hard total timeout; abort only on a genuine stall (< 8 KB/s for 30 s) or a
# generous 15-minute ceiling. Shows a progress bar on interactive terminals.
mc_download() {
    local url="$1" out="$2" progress=(-sS)
    [[ -t 2 ]] && progress=(--progress-bar)
    curl -fL --retry 2 --retry-delay 1 --connect-timeout 10 \
        --speed-limit 8192 --speed-time 30 --max-time 900 \
        "${progress[@]}" "$url" -o "$out"
}

# ── URL-decode a single component ────────────────────────────────────────────
# Only valid %XX sequences decode; stray '%' and backslashes pass through
# literally, and '+' stays '+' (share links encode spaces as %20, and '+' is
# common in base64 passwords/keys).
urldecode() {
    local s="$1" out="" chunk hex
    while [[ "$s" == *%* ]]; do
        chunk="${s%%\%*}"; out+="$chunk"; s="${s#*%}"
        hex="${s:0:2}"
        if [[ "$hex" =~ ^[0-9a-fA-F]{2}$ ]]; then
            printf -v chunk '%b' "\\x$hex"; out+="$chunk"; s="${s:2}"
        else
            out+="%"
        fi
    done
    printf '%s' "$out$s"
}

# Fallback t() so libraries can be sourced (e.g. in tests) without i18n.sh; the
# real t() in i18n.sh overrides this when loaded.
declare -f t >/dev/null 2>&1 || t() { local k="$1"; shift; printf '%s' "$k"; }
