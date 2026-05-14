#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — CPU Control (cpuset-based core pinning)
# =============================================================================

# ── CPU information ───────────────────────────────────────────────────────────

get_total_cpus() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
}

# Returns current CPU pinning (cpuset) or total CPUs if unlimited
get_current_cpus() {
    local cid; cid=$(get_container_id)
    if [[ -z "$cid" ]]; then
        echo "$(get_total_cpus)"
        return
    fi

    # Read cpuset from container
    local cpuset; cpuset=$($DOCKER inspect --format='{{.HostConfig.CpusetCpus}}' "$cid" 2>/dev/null)
    if [[ -z "$cpuset" ]]; then
        echo "$(get_total_cpus)"
        return
    fi

    # Parse cpuset string like "0-3" to count cores
    if [[ "$cpuset" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start=${BASH_REMATCH[1]} end=${BASH_REMATCH[2]}
        echo $(( end - start + 1 ))
    else
        # Fallback
        echo "$(get_total_cpus)"
    fi
}

get_cpu_info() {
    local cid; cid=$(get_container_id)
    local total; total=$(get_total_cpus)
    [[ -z "$cid" ]] && echo "${total} cores (worker stopped)" && return

    local cpuset; cpuset=$($DOCKER inspect --format='{{.HostConfig.CpusetCpus}}' "$cid" 2>/dev/null)
    if [[ -z "$cpuset" ]]; then
        echo "${total}/${total} cores (unlimited)"
    else
        local current; current=$(get_current_cpus)
        echo "${current}/${total} cores (pinned)"
    fi
}

is_limited() {
    local cid; cid=$(get_container_id)
    [[ -z "$cid" ]] && return 1
    local cpuset; cpuset=$($DOCKER inspect --format='{{.HostConfig.CpusetCpus}}' "$cid" 2>/dev/null)
    [[ -n "$cpuset" ]]
}

# ── Duration parsing ───────────────────────────────────────────────────────────
# Accepts: 30m | 8h | 1d | 1d-5h | 1d-5h-30m

parse_duration_secs() {
    local input="${1,,}" total=0
    local IFS='-' parts
    read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part="${part// /}"
        if   [[ "$part" =~ ^([0-9]+)d$ ]]; then total=$(( total + BASH_REMATCH[1] * 86400 ))
        elif [[ "$part" =~ ^([0-9]+)h$ ]]; then total=$(( total + BASH_REMATCH[1] * 3600  ))
        elif [[ "$part" =~ ^([0-9]+)m$ ]]; then total=$(( total + BASH_REMATCH[1] * 60    ))
        fi
    done
    echo "$total"
}

format_secs() {
    local secs=$1 d=$(( secs / 86400 )) h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    [[ $d -gt 0 ]] && echo "${d}d ${h}h ${m}m" || \
    [[ $h -gt 0 ]] && echo "${h}h ${m}m" || echo "${m}m"
}

# ── CPU schedule (temporary limits) ────────────────────────────────────────────

get_cpu_schedule() {
    [[ ! -f "$CPU_STATE_FILE" ]] && echo "" && return
    source "$CPU_STATE_FILE" 2>/dev/null || { rm -f "$CPU_STATE_FILE"; echo ""; return; }
    local now; now=$(date +%s)
    local remaining=$(( REVERT_AT - now ))
    [[ $remaining -le 0 ]] && { rm -f "$CPU_STATE_FILE"; echo ""; return; }
    local h=$(( remaining/3600 )) m=$(( (remaining%3600)/60 ))
    printf "revert to %s cores in %dh %dm" "$REVERT_TO" "$h" "$m"
}

# ── Retry logic for Docker API calls ───────────────────────────────────────────

retry_docker_update() {
    local cmd="$1" max_retries=3 attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        if eval "$cmd" &>/dev/null; then
            return 0
        fi
        (( attempt++ ))
        if [[ $attempt -lt $max_retries ]]; then
            warn "Docker API error on attempt $attempt/$max_retries — retrying in 1 minute..."
            sleep 60
        fi
    done

    err "Docker API call failed after $max_retries attempts"
    return 1
}

# ── Apply CPU limit (cpuset-based core pinning) ──────────────────────────────

apply_cpu_limit() {
    local new_cores="$1"
    local duration="${2:-}"
    local total; total=$(get_total_cpus)

    # Validate and resolve input
    if [[ "${new_cores,,}" == "max" || "${new_cores,,}" == "all" || "$new_cores" -ge "$total" ]]; then
        new_cores="$total"
    fi

    if ! [[ "$new_cores" =~ ^[0-9]+$ ]] || [[ "$new_cores" -lt 1 ]]; then
        err "Invalid core count: '$new_cores' (must be 1–${total} or 'max')"
        return 1
    fi

    # Cancel any existing schedule first
    cancel_schedule silent

    local cid; cid=$(get_container_id)
    [[ -z "$cid" ]] && { err "No running container"; return 1; }

    # Apply using cpuset (core pinning)
    if [[ "$new_cores" -ge "$total" ]]; then
        # Remove pinning — allow all cores
        local cmd="$DOCKER update --cpuset-cpus=\"\" \"$cid\""
        if retry_docker_update "$cmd"; then
            ok "CPU limit removed — using all ${total} cores (unlimited)"
        else
            return 1
        fi
    else
        # Pin to cores 0 through (N-1)
        local last_core=$(( new_cores - 1 ))
        local cpuset="0-${last_core}"
        local cmd="$DOCKER update --cpuset-cpus=\"${cpuset}\" \"$cid\""
        if retry_docker_update "$cmd"; then
            ok "CPU pinned to ${new_cores}/${total} cores (cores ${cpuset})"
        else
            return 1
        fi
    fi

    printf "[%s] CPU changed to %s/%s cores\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$new_cores" "$total" >> "$CPU_LOG_FILE"

    # Schedule a revert if duration given
    if [[ -n "$duration" ]]; then
        local secs; secs=$(parse_duration_secs "$duration")
        if [[ "$secs" -le 0 ]]; then
            warn "Could not parse duration '${duration}' — change applied permanently"
            return 0
        fi

        local revert_at; revert_at=$(( $(date +%s) + secs ))
        cat > "$CPU_STATE_FILE" <<EOF
REVERT_AT=${revert_at}
REVERT_TO=${total}
SET_CORES=${new_cores}
DURATION=${duration}
EOF

        # Background revert process with retry logic
        (
            sleep "$secs"
            local rcid; rcid=$($DOCKER ps --quiet --filter "name=^${CONTAINER_NAME}$" | head -1 || $DOCKER ps --quiet | head -1)
            [[ -n "$rcid" ]] && {
                local revert_cmd="$DOCKER update --cpuset-cpus=\"\" \"$rcid\""
                if retry_docker_update "$revert_cmd"; then
                    printf "[%s] CPU auto-reverted to %s cores after %s\n" \
                        "$(date '+%Y-%m-%d %H:%M:%S')" "$total" "$duration" >> "$CPU_LOG_FILE"
                fi
            }
            rm -f "$CPU_STATE_FILE"
        ) &>/dev/null &
        disown $!
        echo $! > "$CPU_REVERT_PID"

        printf "[%s] Scheduled revert to %s cores in %s\n" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$total" "$duration" >> "$CPU_LOG_FILE"
        echo -e "  ${C}⏱ Will revert to ${total} cores in ${duration}${NC}"
    else
        printf " (permanent)\n" >> "$CPU_LOG_FILE"
    fi
}

cancel_schedule() {
    local silent="${1:-}"
    if [[ -f "$CPU_REVERT_PID" ]]; then
        local pid; pid=$(cat "$CPU_REVERT_PID" 2>/dev/null)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$CPU_REVERT_PID" "$CPU_STATE_FILE"
        [[ "$silent" != "silent" ]] && ok "Scheduled CPU revert cancelled"
    else
        [[ "$silent" != "silent" ]] && warn "No active CPU schedule found"
    fi
}

# ── Quick CPU adjustment (±1 core) ─────────────────────────────────────────────

quick_cpu_adjust() {
    local delta="$1" total; total=$(get_total_cpus)
    local current; current=$(get_current_cpus)
    local new=$(( current + delta ))

    if   [[ $new -lt 1     ]]; then err "Already at minimum (1 core)"; return 1
    elif [[ $new -gt $total ]]; then err "Already at maximum ($total cores)"; return 1
    fi

    local cid; cid=$(get_container_id)
    [[ -z "$cid" ]] && { err "No running container"; return 1; }

    if [[ "$new" -ge "$total" ]]; then
        $DOCKER update --cpuset-cpus="" "$cid" &>/dev/null || true
    else
        local last_core=$(( new - 1 ))
        $DOCKER update --cpuset-cpus="0-${last_core}" "$cid" &>/dev/null || true
    fi

    local arrow; [[ $delta -gt 0 ]] && arrow="▲" || arrow="▼"
    echo -e "  ${Y}${arrow} CPU: ${new}/${total} cores${NC}"
}
