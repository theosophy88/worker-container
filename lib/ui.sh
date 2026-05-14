#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — Status Display & UI Functions
# =============================================================================

# ── Status panel ───────────────────────────────────────────────────────────────

draw_status() {
    # W = exact inner width in visible characters (between ║ borders)
    local W=58

    local status_str uptime_str cpu_str pending_str cpu_sched
    if is_running; then status_str="● RUNNING"; else status_str="○ STOPPED"; fi
    uptime_str=$(get_uptime)
    cpu_str=$(get_cpu_info)
    pending_str=$(get_pending_summary)
    cpu_sched=$(get_cpu_schedule)

    local stats_raw; stats_raw=$(get_last_stats)
    local total_emb error_count status last_line
    total_emb=$(echo "$stats_raw" | grep -oP '(?<=total:)[^|]+')
    error_count=$(echo "$stats_raw" | grep -oP '(?<=errors:)[^|]+')
    status=$(echo "$stats_raw" | grep -oP '(?<=status:)[^|]+')
    last_line=$(echo "$stats_raw" | grep -oP '(?<=last:).+')

    local batch delay model node_name compute
    batch=$(env_get    "BATCH_SIZE"    "?")
    delay=$(env_get    "DELAY_SECONDS" "?")
    model=$(env_get    "MODEL_NAME"    "?")
    node_name=$(env_get "NODE_NAME"   "?")
    compute=$(env_get  "COMPUTE_MODE"  "cpu")

    # ── Box drawing helpers ───────────────────────────────────────────────────

    _pad() { printf "%-${2}s" "${1:0:$2}"; }

    _border() {
        local l="$1" m="$2" r="$3"
        printf "  ${BOLD}${B}%s" "$l"
        printf '%0.s═' $(seq 1 $W)
        echo -e "${r}${NC}"
    }

    _row() {
        local label="$1" value="$2" color="${3:-}" reset=""
        [[ -n "$color" ]] && reset="$NC"
        local inner; inner=$(printf "  %-18s %s" "$label" "$(_pad "$value" $((W-21)))")
        echo -e "  ${BOLD}${B}║${NC}${color}${inner}${reset}${BOLD}${B}║${NC}"
    }

    # ── Draw ─────────────────────────────────────────────────────────────────

    echo ""
    _border ╔ ═ ╗

    local title="  EMBEDDING WORKER — ADMIN CONSOLE"
    echo -e "  ${BOLD}${B}║${NC}${BOLD}$(_pad "$title" $W)${NC}${BOLD}${B}║${NC}"

    _border ╠ ═ ╣

    local sc="$G"; [[ "$status_str" == "○ STOPPED" ]] && sc="$R"
    _row "Status:"       "$status_str"     "$sc"
    _row "Node:"         "$node_name"
    _row "Uptime:"       "$uptime_str"
    _row "CPU:"          "$cpu_str"
    _row "Compute mode:" "$compute"

    _border ╠ ═ ╣

    local cfg="batch=${batch}  delay=${delay}s  model=${model}"
    _row "Config:" "$cfg"

    if is_running; then
        local stats="total=${total_emb:-0}  errors=${error_count:-0}  status=${status:-?}"
        _row "Last stats:" "$stats"
        if [[ -n "$last_line" ]]; then
            _row "Last log:" "$last_line" "$DIM"
        fi
    fi

    _border ╠ ═ ╣

    if [[ "$pending_str" != "none" ]]; then
        _row "Pending:" "⏳ $pending_str" "$Y"
    else
        _row "Pending changes:" "none"
    fi

    if [[ -n "$cpu_sched" ]]; then
        _row "CPU schedule:" "⏱ $cpu_sched" "$C"
    fi

    _border ╚ ═ ╝
    echo ""
}
