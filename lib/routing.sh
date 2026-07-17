#!/usr/bin/env bash
# routing.sh — traffic splitting: mode, rules, per-region exit groups, rule sets.
# Edits rules.json, then re-applies through the transactional core.
[[ -n "${_MC_ROUTING_LOADED:-}" ]] && return 0
_MC_ROUTING_LOADED=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nodes.sh"   # _nodes_tags for exit-group membership

_rules_load() { [[ -f "$RULES_JSON" ]] || config_default_rules > "$RULES_JSON"; cat "$RULES_JSON"; }
_rules_save() { echo "$1" > "$RULES_JSON"; }

routing_show() {
    local r; r=$(_rules_load)
    echo -e "\n${BOLD}$(t routing.current_title)${NC}"
    echo -e "  $(t routing.mode): ${GREEN}$(echo "$r" | jq -r '.mode // "rule"')${NC}   $(t routing.final): ${GREEN}$(echo "$r" | jq -r '.final // "PROXY"')${NC}"
    echo -e "\n  ${BOLD}$(t routing.rules_header)${NC}"
    echo "$r" | jq -r '(.rules // [])[] | "    \(.type),\(.payload // "")  →  \(.policy)\(if .no_resolve then ",no-resolve" else "" end)"'
    echo "    MATCH  →  $(echo "$r" | jq -r '.final // "PROXY"')"
    local ng; ng=$(echo "$r" | jq '(.groups // []) | length')
    if [[ "$ng" != "0" ]]; then
        echo -e "\n  ${BOLD}$(t routing.groups_header)${NC}"
        echo "$r" | jq -r '(.groups // [])[] | "    \(.name) [\(.type // "select")]: \((.proxies // []) | join(", "))"'
    fi
}

routing_add_rule() {
    log_info "$(t routing.rule_type_hint)"
    local typ payload policy
    ask typ     "$(t routing.ask_type)"    "DOMAIN-SUFFIX"
    ask payload "$(t routing.ask_payload)"
    ask policy  "$(t routing.ask_policy)"  "PROXY"
    [[ -z "$payload" && "$typ" != "MATCH" ]] && { log_error "$(t routing.payload_empty)"; return 1; }
    # Prepend so an explicit user rule wins over the default geo rules.
    local r; r=$(_rules_load)
    r=$(echo "$r" | jq --arg t "$typ" --arg p "$payload" --arg pol "$policy" \
        '.rules = ([{type:$t, payload:$p, policy:$pol}] + (.rules // []))')
    _rules_save "$r"
    log_ok "$(t routing.rule_added)"
    mc_apply || true
}

routing_del_rule() {
    routing_show
    local idx; ask idx "$(t routing.ask_del_index)"
    [[ "$idx" =~ ^[0-9]+$ ]] || { log_error "$(t routing.bad_index)"; return 1; }
    local r; r=$(_rules_load)
    local n; n=$(echo "$r" | jq '(.rules // []) | length')
    (( idx < 1 || idx > n )) && { log_error "$(t routing.bad_index)"; return 1; }
    r=$(echo "$r" | jq --argjson i "$((idx-1))" 'del(.rules[$i])')
    _rules_save "$r"
    log_ok "$(t routing.rule_deleted)"
    mc_apply || true
}

routing_set_mode() {
    echo -e "  1. rule\n  2. global\n  3. direct"
    local c; read -rp "$(echo -e "${CYAN}$(t routing.ask_mode) [1]: ${NC}")" c
    local mode; case "${c:-1}" in 2) mode=global ;; 3) mode=direct ;; *) mode=rule ;; esac
    _rules_save "$(_rules_load | jq --arg m "$mode" '.mode=$m')"
    log_ok "$(t routing.mode_set "$mode")"
    mc_apply || true
}

# Bind a rule-set (remote rule provider) to a specific exit — Surge-style
# "RULE-SET,url,NodeName". The policy may be a node tag, a group name, or
# PROXY/DIRECT/REJECT; node tags are valid policies because .proxy.name == tag.
routing_add_ruleset() {
    local name url behavior fmt policy
    ask name "$(t routing.ask_rs_name)"
    [[ -z "$name" ]] && { log_error "$(t routing.payload_empty)"; return 1; }
    ask url "$(t routing.ask_rs_url)"
    [[ -z "$url" ]] && { log_warn "$(t common.cancelled)"; return; }
    ask behavior "$(t routing.ask_rs_behavior)" "domain"
    case "$behavior" in domain|ipcidr|classical) ;; *) behavior="domain" ;; esac
    case "$url" in
        *.mrs) fmt="mrs" ;;
        *.yaml|*.yml) fmt="yaml" ;;
        *.list|*.txt|*.text) fmt="text" ;;
        *) fmt="yaml" ;;
    esac
    case "$url" in
        https://github.com/*|https://raw.githubusercontent.com/*|https://objects.githubusercontent.com/*)
            url="$(github_preferred_url "$url")" ;;
    esac
    log_info "$(t routing.policy_hint)"
    _nodes_tags 2>/dev/null | sed 's/^/    /'
    _rules_load | jq -r '(.groups // [])[].name' 2>/dev/null | sed 's/^/    /'
    local policy; ask policy "$(t routing.ask_rs_policy)" "PROXY"
    local r; r=$(_rules_load)
    r=$(echo "$r" | jq --arg n "$name" --arg u "$url" --arg b "$behavior" --arg f "$fmt" --arg pol "$policy" '
        .rule_providers[$n] = { type:"http", behavior:$b, format:$f, interval:86400,
                                url:$u, path:("./ruleset/" + $n + "." + $f) }
        | .rules = ([{type:"RULE-SET", payload:$n, policy:$pol}]
                    + ((.rules // []) | map(select(.payload != $n or .type != "RULE-SET"))))')
    _rules_save "$r"
    log_ok "$(t routing.rs_added "$name" "$policy")"
    mc_apply || true
}

# Add a per-region / per-purpose exit group bound to specific nodes, so e.g.
# streaming domains can be routed to a specific self-built node via a rule.
# Types: select (manual), url-test / fallback / load-balance (automatic), and
# smart — mihomo's Surge-like adaptive group with optional policy-priority.
routing_add_group() {
    local name members type prio=""
    ask name    "$(t routing.ask_group_name)"
    [[ -z "$name" ]] && { log_error "$(t routing.group_name_empty)"; return 1; }
    log_info "$(t routing.group_members_hint)"
    _nodes_tags 2>/dev/null | sed 's/^/    /'
    ask members "$(t routing.ask_group_members)"
    ask type    "$(t routing.ask_group_type)" "select"
    case "$type" in select|url-test|fallback|load-balance|smart) ;; *) type="select" ;; esac
    [[ "$type" == "smart" ]] && ask prio "$(t routing.ask_smart_priority)" ""
    local mem_json; mem_json=$(printf '%s' "$members" | tr ',' '\n' | sed '/^\s*$/d' | jq -R . | jq -sc .)
    local r; r=$(_rules_load)
    r=$(echo "$r" | jq --arg n "$name" --arg ty "$type" --arg prio "$prio" --argjson m "$mem_json" '
        .groups = ((.groups // []) | map(select(.name != $n)) + [
            {name:$n, type:$ty, proxies:$m}
            + (if $prio != "" then {"policy-priority":$prio} else {} end)
        ])')
    _rules_save "$r"
    log_ok "$(t routing.group_added "$name")"
    mc_apply || true
}

# Ask mihomo to refresh the remote rule-set providers (needs it running).
routing_update_providers() {
    local ctrl secret; ctrl="$(jq -r '.controller // "127.0.0.1:9090"' "$SETTINGS_JSON" 2>/dev/null)"
    secret="$(jq -r '.secret // ""' "$SETTINGS_JSON" 2>/dev/null)"
    have curl || { log_error "$(t common.dep_missing "curl")"; return 1; }
    local auth=(); [[ -n "$secret" ]] && auth=(-H "Authorization: Bearer ${secret}")
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        curl -fsS -X PUT --max-time 30 "${auth[@]}" "http://${ctrl}/providers/rules/${name}" >/dev/null 2>&1 \
            && log_ok "$(t routing.provider_updated "$name")" \
            || log_warn "$(t routing.provider_update_fail "$name")"
    done < <(_rules_load | jq -r '(.rule_providers // {}) | keys[]')
}

routing_menu() {
    while true; do
        routing_show
        show_menu "$(t routing.menu_title)" \
            "$(t routing.add_rule)" \
            "$(t routing.del_rule)" \
            "$(t routing.set_mode)" \
            "$(t routing.add_group)" \
            "$(t routing.add_ruleset)" \
            "$(t routing.update_providers)"
        case "$MENU_CHOICE" in
            1) routing_add_rule ;;
            2) routing_del_rule ;;
            3) routing_set_mode ;;
            4) routing_add_group ;;
            5) routing_add_ruleset ;;
            6) routing_update_providers ;;
            0) return ;;
        esac
        press_enter
    done
}
