#!/usr/bin/env bash
# core.sh — mihomo binary lifecycle + transactional "apply" + low-level service ops.
[[ -n "${_MC_CORE_LOADED:-}" ]] && return 0
_MC_CORE_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
MIHOMO_SVC="${MIHOMO_SVC:-mclient}"           # systemd unit name

# ── Binary ───────────────────────────────────────────────────────────────────
mihomo_installed() { [[ -x "$MIHOMO_BIN" ]] || have mihomo; }
_mihomo() { if [[ -x "$MIHOMO_BIN" ]]; then "$MIHOMO_BIN" "$@"; else mihomo "$@"; fi; }
mihomo_version() { mihomo_installed && _mihomo -v 2>/dev/null | head -1; }
# -t validates the config; -f points at the candidate file, -d supplies the data dir (geo/cache).
mihomo_test_file() {
    local file="$1" output="$2" limit="${MIHOMO_TEST_TIMEOUT:-45}" bin
    if [[ -x "$MIHOMO_BIN" ]]; then bin="$MIHOMO_BIN"; else bin="$(command -v mihomo)" || return 127; fi

    # Loading a fresh config can fetch remote rule providers. Bound the test so
    # an unreachable provider cannot make the installer appear frozen forever.
    if have timeout; then
        timeout -k 5 "$limit" "$bin" -t -d "$MC_CONF_DIR" -f "$file" >"$output" 2>&1
        return $?
    fi

    # Minimal fallback for systems without coreutils/busybox timeout.
    local pid watcher rc marker="${output}.timeout"
    rm -f "$marker"
    "$bin" -t -d "$MC_CONF_DIR" -f "$file" >"$output" 2>&1 &
    pid=$!
    (
        sleep "$limit"
        if kill -0 "$pid" 2>/dev/null; then
            : > "$marker"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    watcher=$!
    if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    if [[ -f "$marker" ]]; then rm -f "$marker"; return 124; fi
    return "$rc"
}

# Pre-fetch the GeoIP MMDB through our mirror-ranked download path so mihomo's
# own (mirror-unaware) downloader never has to run: without this, validating a
# config on a host that can't reach GitHub hangs at "Can't find MMDB".
MIHOMO_MMDB_URL="${MIHOMO_MMDB_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb}"
mihomo_ensure_geo() {
    local mmdb="$MC_CONF_DIR/country.mmdb" url tmp
    [[ -s "$mmdb" ]] && return 0
    have curl || return 1
    log_info "$(t core.geo_fetch)"
    tmp="$(mktemp)"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        if mc_download "$url" "$tmp" && [[ -s "$tmp" ]]; then
            mkdir -p "$MC_CONF_DIR"
            mv -f "$tmp" "$mmdb"
            return 0
        fi
    done < <(mc_rank_urls < <(github_url_candidates "$MIHOMO_MMDB_URL"))
    rm -f "$tmp"
    log_warn "$(t core.geo_fetch_fail)"
    return 1
}

_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l) printf 'armv7' ;;
        *) printf 'amd64' ;;
    esac
}

_mihomo_latest_tag_direct() {
    curl -fsSL --connect-timeout 5 --max-time 15 \
        https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null
}

_mihomo_latest_tag_mirror() {
    local m latest tag
    while IFS= read -r m; do
        latest="$(github_mirror_url 'https://github.com/MetaCubeX/mihomo/releases/latest' "$m")"
        tag="$(curl -fsSI --connect-timeout 5 --max-time 15 "$latest" 2>/dev/null \
            | tr -d '\r' \
            | awk 'tolower($1)=="location:" && $2 ~ /\/releases\/tag\// {
                       sub(/^.*\/releases\/tag\//, "", $2); print $2; exit
                   }')"
        [[ "$tag" == v* ]] && { printf '%s' "$tag"; return 0; }
    done < <(github_mirror_list)
    return 1
}

_mihomo_latest_tag() {
    local region route tag
    region="$(network_region_effective)"
    if [[ "$region" == "CN" ]]; then route="mirror direct"; else route="direct mirror"; fi
    for route in $route; do
        if [[ "$route" == "mirror" ]]; then tag="$(_mihomo_latest_tag_mirror)"
        else tag="$(_mihomo_latest_tag_direct)"
        fi
        [[ "$tag" == v* ]] && { printf '%s' "$tag"; return 0; }
    done
    return 1
}

# Download the latest mihomo release for this arch into $MIHOMO_BIN.
mihomo_install() {
    require_root
    ensure_deps curl jq || return 1
    local arch tag direct_url url tmp downloaded=0 source
    arch="$(_arch)"
    log_step "$(t core.installing)"
    tag="$(_mihomo_latest_tag)"
    [[ -z "$tag" || "$tag" == "null" ]] && { log_error "$(t core.download_fail)"; return 1; }
    direct_url="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/mihomo-linux-${arch}-${tag}.gz"
    tmp="$(mktemp)"
    log_info "$(t core.probing)"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        if [[ "$url" == "$direct_url" ]]; then source="GitHub"; else source="${url%%/https://*}"; fi
        log_info "$(t core.download_route "$source")"
        rm -f "${tmp}.gz"
        if mc_download "$url" "${tmp}.gz" \
                && gzip -t "${tmp}.gz" 2>/dev/null \
                && gzip -dc "${tmp}.gz" > "$tmp"; then
            downloaded=1
            break
        fi
        log_warn "$(t core.download_route_fail "$source")"
    done < <(mc_rank_urls < <(github_url_candidates "$direct_url"))
    if (( ! downloaded )); then
        rm -f "$tmp" "${tmp}.gz"; log_error "$(t core.download_fail)"; return 1
    fi
    install -m 0755 "$tmp" "$MIHOMO_BIN"
    rm -f "$tmp" "${tmp}.gz"
    log_ok "$(t core.installed "$(mihomo_version)")"
}

# ── Low-level systemd wrappers ───────────────────────────────────────────────
svc_is_active() { systemctl is-active --quiet "$MIHOMO_SVC" 2>/dev/null; }
svc_start()     { systemctl start   "$MIHOMO_SVC" 2>/dev/null; }
svc_stop()      { systemctl stop    "$MIHOMO_SVC" 2>/dev/null; }
svc_restart()   { systemctl restart "$MIHOMO_SVC" 2>/dev/null; }
svc_status()    { systemctl status  "$MIHOMO_SVC" --no-pager -l 2>/dev/null; }
svc_enable()    { systemctl enable  "$MIHOMO_SVC" --quiet 2>/dev/null; }
svc_wait_active() {
    local _
    for _ in 1 2 3 4 5; do
        svc_is_active && return 0
        sleep 1
    done
    return 1
}

# ── Transactional apply: regenerate → validate → test → swap → restart ───────
# On any failure the live config.yaml is untouched (or rolled back), so a bad
# edit can never take the client offline. Store mutations call this.
mc_apply() {
    local tmp="${MIHOMO_CFG}.tmp" test_log="${MIHOMO_CFG}.test.log" rc
    if ! config_build > "$tmp" 2>/dev/null || ! jq -e . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; log_error "$(t config.gen_fail)"; return 1
    fi
    if mihomo_installed; then
        mihomo_ensure_geo || true
        log_info "$(t core.testing "${MIHOMO_TEST_TIMEOUT:-45}")"
        if mihomo_test_file "$tmp" "$test_log"; then
            rm -f "$test_log"
        else
            rc=$?
            rm -f "$tmp"
            if (( rc == 124 || rc == 137 || rc == 143 )); then
                log_error "$(t core.test_timeout "${MIHOMO_TEST_TIMEOUT:-45}")"
            else
                log_error "$(t core.test_fail)"
            fi
            if [[ -s "$test_log" ]]; then
                log_error "$(t core.test_output)"
                tail -n 20 "$test_log" >&2
            fi
            rm -f "$test_log"
            return 1
        fi
    else
        log_warn "$(t service.not_installed)"
    fi
    [[ -f "$MIHOMO_CFG" ]] && cp -f "$MIHOMO_CFG" "${MIHOMO_CFG}.bak"
    mv -f "$tmp" "$MIHOMO_CFG"
    log_ok "$(t config.generated)"

    if mihomo_installed && svc_is_active; then
        if ! svc_restart; then
            log_error "$(t core.restart_fail)"
            if [[ -f "${MIHOMO_CFG}.bak" ]]; then
                cp -f "${MIHOMO_CFG}.bak" "$MIHOMO_CFG"; svc_restart || true
                log_warn "$(t core.rolled_back)"
            fi
            return 1
        fi
    fi
    return 0
}
