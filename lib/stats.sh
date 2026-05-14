#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — Statistics & Log Parsing
# =============================================================================

# ── Worker statistics from logs ────────────────────────────────────────────────

get_last_stats() {
    local cid; cid=$(get_container_id)
    [[ -z "$cid" ]] && echo "" && return

    # Parse last 200 log lines for meaningful stats
    local logs; logs=$($DOCKER logs --tail=200 "$cid" 2>&1)

    # Count successful embeddings: "Record X — embedded"
    local total_embedded; total_embedded=$(echo "$logs" | grep -c "— embedded" 2>/dev/null || echo 0)

    # Count errors: "Error|error|FAILED|failed"
    local error_count; error_count=$(echo "$logs" | grep -ic "error\|failed" 2>/dev/null || echo 0)

    # Check for [STATS] line (if worker.py provides it)
    local stats_line; stats_line=$(echo "$logs" | grep "\[STATS\]" | tail -1)
    if [[ -n "$stats_line" ]]; then
        # Extract if available: "[STATS] Total: X embedded, Y errors"
        local stat_embedded; stat_embedded=$(echo "$stats_line" | grep -oP 'Total:\s*\K\d+' | head -1)
        [[ -n "$stat_embedded" ]] && total_embedded="$stat_embedded"
    fi

    # Determine status based on recent logs
    local status="done"
    if echo "$logs" | tail -20 | grep -qi "error\|failed"; then
        status="AI-error"
    fi

    local last_line; last_line=$(echo "$logs" | grep -v '^$' | tail -1)

    printf "total:%s|errors:%s|status:%s|last:%s" \
        "${total_embedded:-0}" "${error_count}" "${status}" "${last_line}"
}

get_uptime() {
    local cid; cid=$(get_container_id)
    [[ -z "$cid" ]] && echo "—" && return

    local started; started=$($DOCKER inspect --format='{{.State.StartedAt}}' "$cid" 2>/dev/null)
    [[ -z "$started" ]] && echo "—" && return

    local s_epoch now diff
    s_epoch=$(date -d "$started" +%s 2>/dev/null) || { echo "—"; return; }
    now=$(date +%s); diff=$(( now - s_epoch ))

    local d=$(( diff/86400 )) h=$(( (diff%86400)/3600 )) m=$(( (diff%3600)/60 ))
    [[ $d -gt 0 ]] && echo "${d}d ${h}h ${m}m" || \
    [[ $h -gt 0 ]] && echo "${h}h ${m}m" || echo "${m}m $(( diff%60 ))s"
}

get_pending_summary() {
    [[ ! -f "$PENDING_FILE" ]] && echo "none" && return
    local lines; lines=$(grep -v '^#' "$PENDING_FILE" 2>/dev/null | grep -v '^$')
    [[ -z "$lines" ]] && { rm -f "$PENDING_FILE"; echo "none"; return; }
    echo "$lines" | while IFS='=' read -r k v; do printf "%s→%s  " "$k" "$v"; done
}

get_cpu_schedule() {
    [[ ! -f "$CPU_STATE_FILE" ]] && echo "" && return
    source "$CPU_STATE_FILE" 2>/dev/null || { rm -f "$CPU_STATE_FILE"; echo ""; return; }
    local now; now=$(date +%s)
    local remaining=$(( REVERT_AT - now ))
    [[ $remaining -le 0 ]] && { rm -f "$CPU_STATE_FILE"; echo ""; return; }
    local h=$(( remaining/3600 )) m=$(( (remaining%3600)/60 ))
    printf "revert to %s cores in %dh %dm" "$REVERT_TO" "$h" "$m"
}
