#!/usr/bin/env bash
# =============================================================================
#  EMBEDDING WORKER — Admin Controller (All-in-One)
#
#  Usage:
#    ./admin.sh                              Run interactive menu (recommended)
#    ./admin.sh monitor                      Live monitor with CPU controls
#    ./admin.sh start                        Start the worker
#    ./admin.sh stop                         Graceful stop (waits for current batch)
#    ./admin.sh kill                         Force stop immediately
#    ./admin.sh log                          Follow live logs
#    ./admin.sh status                       Show status panel and exit
#    ./admin.sh cpu [N] [duration]           Set CPU cores (e.g. "cpu 4" or "cpu 4 8h")
#    ./admin.sh batch [N]                    Set batch size
#    ./admin.sh delay [N]                    Set delay seconds between cycles
#    ./admin.sh reinstall                    Wipe Docker cache and rebuild
#    ./admin.sh help                         Show this help
# =============================================================================

# ── Source all lib modules ────────────────────────────────────────────────────

_SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ -L "${_SCRIPT_PATH}" ]]; then
    if command -v readlink &>/dev/null; then
        _SCRIPT_PATH="$(readlink -f "${_SCRIPT_PATH}" 2>/dev/null || echo "${_SCRIPT_PATH}")"
    elif command -v realpath &>/dev/null; then
        _SCRIPT_PATH="$(realpath "${_SCRIPT_PATH}" 2>/dev/null || echo "${_SCRIPT_PATH}")"
    fi
fi
_SCRIPT_DIR="$(cd "$(dirname "${_SCRIPT_PATH}")" && pwd)"
LIB_DIR="${_SCRIPT_DIR}/lib"

for lib_file in "$LIB_DIR"/{colors,docker,env,state,cpu,stats,ui}.sh; do
    if [[ -f "$lib_file" ]]; then
        source "$lib_file"
    else
        echo "ERROR: Missing library file: $lib_file" >&2
        exit 1
    fi
done

# ── Worker directory detection ────────────────────────────────────────────────

_find_worker_dir() {
    for _candidate in "$_SCRIPT_DIR" "$PWD" "/opt/embedding-worker"; do
        if [[ -f "${_candidate}/Dockerfile" ]]; then
            echo "$_candidate"; return
        fi
    done
    echo ""
    echo -e "\033[1;33m  ⚠  Could not find a folder containing a Dockerfile.\033[0m"
    echo -e "\033[1m  Enter the full path to your embedding-worker folder: \033[0m"
    read -r _user_path
    if [[ -f "${_user_path}/Dockerfile" ]]; then
        echo "$_user_path"
    else
        err "Still no Dockerfile found at '${_user_path}' — exiting."
        exit 1
    fi
}

WORKER_DIR="$(_find_worker_dir)"
ENV_FILE="${WORKER_DIR}/.env"
CONTAINER_NAME="$(_detect_container)"
CONTAINER_NAME="${CONTAINER_NAME:-embedding-worker}"

require_worker_dir() {
    if [[ ! -f "${WORKER_DIR}/Dockerfile" ]]; then
        err "\"${WORKER_DIR}\" is not a valid worker folder (no Dockerfile found)"
        exit 1
    fi
}

# ── Helper to add pending changes ──────────────────────────────────────────────

_add_pending() {
    local key="$1" val="$2"
    [[ -f "$PENDING_FILE" ]] && sed -i "/^${key}=/d" "$PENDING_FILE"
    echo "${key}=${val}" >> "$PENDING_FILE"
}

# ── Start worker ──────────────────────────────────────────────────────────────

func_start() {
    require_worker_dir
    if is_running; then
        warn "Worker is already running (container: $(get_container_id))"
        return 0
    fi

    if [[ -f "$PENDING_FILE" ]]; then
        info "Applying pending changes from last graceful stop..."
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^# || -z "$key" ]] && continue
            env_set "$key" "$val"
            ok "Applied: ${key}=${val}"
            printf "[%s] Applied pending: %s=%s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$key" "$val" >> "$CHANGE_LOG"
        done < "$PENDING_FILE"
        rm -f "$PENDING_FILE"
    fi

    info "Starting worker..."
    cd "$WORKER_DIR"
    $DOCKER compose up -d

    sleep 3
    if is_running; then
        ok "Worker started ($(get_container_id))"
    else
        err "Worker did not start — check: $DOCKER logs ${CONTAINER_NAME}"
    fi
}

# ── Graceful stop (SIGTERM) ───────────────────────────────────────────────────

func_stop() {
    local cid; cid=$(get_container_id)
    if [[ -z "$cid" ]]; then
        warn "No container is running"
        return 1
    fi

    info "Sending graceful stop signal (SIGTERM)..."
    info "The worker will finish its current batch, then stop."
    $DOCKER kill --signal='SIGTERM' "$cid"

    echo ""
    local waited=0 spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
    while is_running; do
        printf "\r  ${Y}%s Waiting for current batch to finish... %ds${NC}" \
            "${spinner[$i]}" "$waited"
        sleep 1
        (( waited++ )); (( i = (i+1) % ${#spinner[@]} ))
        [[ $waited -ge 600 ]] && { echo ""; warn "Waited 10 minutes — forcing stop now"; $DOCKER kill "$cid" &>/dev/null || true; break; }
    done
    echo ""

    if ! is_running; then
        ok "Worker stopped gracefully after ${waited}s"
    fi

    _apply_pending_if_any
}

_apply_pending_if_any() {
    [[ ! -f "$PENDING_FILE" ]] && return
    local has_pending=false

    while IFS='=' read -r key val; do
        [[ "$key" =~ ^# || -z "$key" ]] && continue
        has_pending=true
        env_set "$key" "$val"
        ok "Pending change applied: ${key}=${val}"
        printf "[%s] Applied: %s=%s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$key" "$val" >> "$CHANGE_LOG"
    done < "$PENDING_FILE"
    rm -f "$PENDING_FILE"

    if $has_pending; then
        echo ""
        info "All pending changes applied to .env"
        echo -ne "  ${BOLD}Restart worker now to use new settings? [y/N]: ${NC}"
        read -r ans
        [[ "${ans,,}" == "y" ]] && func_start
    fi
}

# ── Force kill ────────────────────────────────────────────────────────────────

func_kill() {
    require_worker_dir
    if ! is_running; then
        warn "No container is running"
    fi
    info "Force stopping container..."
    cd "$WORKER_DIR"
    $DOCKER compose down
    ok "Container stopped"
}

# ── Live logs ─────────────────────────────────────────────────────────────────

func_log() {
    local cid; cid=$(get_container_id)
    if [[ -z "$cid" ]]; then
        warn "No container is running — showing last logs from stopped container"
        cid=$($DOCKER ps -a --quiet --filter "name=${CONTAINER_NAME}" | head -1)
        [[ -z "$cid" ]] && { err "No container found"; return 1; }
    fi
    info "Following logs (Ctrl+C to exit)..."
    echo ""
    $DOCKER logs -f "$cid"
}

# ── CPU management ───────────────────────────────────────────────────────────

func_cpu() {
    require_container
    local cores="${1:-}"
    local duration="${2:-}"

    if [[ -z "$cores" ]]; then
        # Interactive menu
        cpu_menu_interactive
    else
        # CLI: set cores directly
        apply_cpu_limit "$cores" "$duration"
    fi
}

cpu_menu_interactive() {
    local total; total=$(get_total_cpus)
    local current; current=$(get_current_cpus)
    local sched; sched=$(get_cpu_schedule)

    echo ""
    echo -e "  ${BOLD}Current CPU: ${current}/${total} cores${NC}"
    [[ -n "$sched" ]] && echo -e "  ${C}  Scheduled: ${sched}${NC}"
    echo ""
    echo "  Set new CPU limit:"
    echo -e "  ${DIM}  Enter 1–${total}, 'max' for unlimited, or Enter to cancel${NC}"
    echo ""
    echo -ne "  ${BOLD}Cores > ${NC}"
    read -r new_cores
    [[ -z "$new_cores" ]] && return

    if [[ "${new_cores,,}" == "max" ]]; then new_cores="$total"; fi
    if ! [[ "$new_cores" =~ ^[0-9]+$ ]] || [[ "$new_cores" -lt 1 ]] || [[ "$new_cores" -gt "$total" ]]; then
        err "Invalid: must be 1–${total} or 'max'"; sleep 1; return
    fi

    echo ""
    echo -e "  ${BOLD}Apply this CPU limit:${NC}"
    echo "    [1] Immediately (no restart needed)"
    echo "    [2] After current batch finishes (graceful stop + restart)"
    echo "    [3] Immediately, and revert after N time"
    echo ""
    echo -ne "  ${BOLD}How > ${NC}"
    read -r how

    case "$how" in
        1)
            if is_running; then
                apply_cpu_limit "$new_cores"
            else
                warn "Worker not running — change will apply on next start"
                env_set "CPU_THREADS" "$new_cores"
            fi ;;
        2)
            _add_pending "CPU_THREADS" "$new_cores"
            ok "CPU change queued — will apply after graceful stop + restart"
            echo -ne "  ${BOLD}Trigger graceful stop now? [y/N]: ${NC}"
            read -r go
            [[ "${go,,}" == "y" ]] && func_stop ;;
        3)
            if is_running; then
                echo -ne "  ${BOLD}Revert after (e.g. 8h, 1d-5h-30m): ${NC}"
                read -r dur
                apply_cpu_limit "$new_cores" "$dur"
            else
                warn "Worker not running — start it first"
            fi ;;
        *) warn "Cancelled" ;;
    esac
}

# ── Batch size change ────────────────────────────────────────────────────────

func_batch() {
    local new_batch="${1:-}"

    local current; current=$(env_get "BATCH_SIZE" "2")

    if [[ -z "$new_batch" ]]; then
        # Interactive menu
        echo ""
        echo -e "  ${BOLD}Current batch size: ${current}${NC}"
        echo -e "  ${DIM}  Recommended: CPU=2–5  Mixed=5–15  GPU=10–50${NC}"
        echo ""
        echo -ne "  ${BOLD}New batch size > ${NC}"
        read -r new_batch
        [[ -z "$new_batch" || ! "$new_batch" =~ ^[0-9]+$ ]] && { warn "Cancelled"; return; }
    fi

    if ! [[ "$new_batch" =~ ^[0-9]+$ ]]; then
        err "Invalid batch size: must be a number"; return 1
    fi

    echo ""
    echo "  Apply when?"
    echo "    [1] After current batch finishes (graceful stop + restart)"
    echo "    [2] Immediately (force restart — current batch will be abandoned)"
    echo ""
    echo -ne "  ${BOLD}How > ${NC}"
    read -r how

    case "$how" in
        1)
            _add_pending "BATCH_SIZE" "$new_batch"
            ok "batch_size=${new_batch} queued"
            echo -ne "  ${BOLD}Trigger graceful stop now? [y/N]: ${NC}"
            read -r go
            [[ "${go,,}" == "y" ]] && func_stop ;;
        2)
            env_set "BATCH_SIZE" "$new_batch"
            ok "batch_size=${new_batch} written to .env"
            warn "Restarting container..."
            func_kill; sleep 2; func_start ;;
        *) warn "Cancelled" ;;
    esac
}

# ── Delay change ─────────────────────────────────────────────────────────────

func_delay() {
    local new_delay="${1:-}"

    local current; current=$(env_get "DELAY_SECONDS" "5")

    if [[ -z "$new_delay" ]]; then
        # Interactive menu
        echo ""
        echo -e "  ${BOLD}Current delay between cycles: ${current}s${NC}"
        echo ""
        echo -ne "  ${BOLD}New delay (seconds) > ${NC}"
        read -r new_delay
        [[ -z "$new_delay" || ! "$new_delay" =~ ^[0-9]+$ ]] && { warn "Cancelled"; return; }
    fi

    if ! [[ "$new_delay" =~ ^[0-9]+$ ]]; then
        err "Invalid delay: must be a number"; return 1
    fi

    echo ""
    echo "  Apply when?"
    echo "    [1] After current batch finishes (graceful stop + restart)"
    echo "    [2] Immediately (force restart)"
    echo ""
    echo -ne "  ${BOLD}How > ${NC}"
    read -r how

    case "$how" in
        1)
            _add_pending "DELAY_SECONDS" "$new_delay"
            ok "delay=${new_delay}s queued"
            echo -ne "  ${BOLD}Trigger graceful stop now? [y/N]: ${NC}"
            read -r go
            [[ "${go,,}" == "y" ]] && func_stop ;;
        2)
            env_set "DELAY_SECONDS" "$new_delay"
            ok "delay=${new_delay}s written to .env"
            warn "Restarting container..."
            func_kill; sleep 2; func_start ;;
        *) warn "Cancelled" ;;
    esac
}

# ── Reinstall ────────────────────────────────────────────────────────────────

func_reinstall() {
    echo ""
    echo -e "  ${R}${BOLD}⚠  REINSTALL — THIS WILL:${NC}"
    echo "    • Stop the running container"
    echo "    • Remove ALL Docker images, containers, build cache"
    echo "    • Optionally remove the downloaded model (~5 GB)"
    echo "    • Rebuild the image from scratch"
    echo "    • Restart the worker"
    echo ""
    echo -ne "  ${BOLD}Are you sure? Type YES to confirm: ${NC}"
    read -r confirm
    [[ "$confirm" != "YES" ]] && { warn "Reinstall cancelled"; return; }

    echo ""
    info "Step 1/5 — Stopping container..."
    cd "$WORKER_DIR"
    $DOCKER compose down 2>/dev/null || true
    sleep 2

    info "Step 2/5 — Removing all Docker images and containers..."
    $DOCKER system prune -a -f 2>/dev/null || true

    info "Step 3/5 — Removing Docker build cache..."
    $DOCKER builder prune -a -f 2>/dev/null || true

    echo ""
    echo -ne "  ${BOLD}Also remove downloaded model cache (frees ~5 GB, will re-download)? [y/N]: ${NC}"
    read -r rm_model
    if [[ "${rm_model,,}" == "y" ]]; then
        info "Removing model cache (/home/model)..."
        rm -rf /home/model 2>/dev/null || sudo rm -rf /home/model 2>/dev/null || \
            warn "Could not remove /home/model — may need root"
    fi

    $DOCKER volume prune -f 2>/dev/null || true
    ok "Docker cache cleared"

    info "Step 4/5 — Rebuilding image (no cache)..."
    cd "$WORKER_DIR"

    local compose_args="-f docker-compose.yml"
    local compute; compute=$(env_get "COMPUTE_MODE" "cpu")
    local gpu_type; gpu_type=$(env_get "GPU_TYPE" "")
    if [[ "$compute" != "cpu" ]]; then
        [[ "$gpu_type" == "nvidia" && -f docker-compose.nvidia.yml ]] && \
            compose_args+=" -f docker-compose.nvidia.yml"
        [[ "$gpu_type" == "amd" && -f docker-compose.amd.yml ]] && \
            compose_args+=" -f docker-compose.amd.yml"
    fi

    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        DOCKER_BUILDKIT=0 $DOCKER compose $compose_args build --no-cache
    else
        $DOCKER compose $compose_args build --no-cache
    fi

    info "Step 5/5 — Starting worker..."
    $DOCKER compose $compose_args up -d
    sleep 3

    echo ""
    if is_running; then
        ok "Reinstall complete — worker is running!"
    else
        warn "Reinstall done but worker did not start — check: $DOCKER logs ${CONTAINER_NAME}"
    fi
}

# ── Discard pending changes ───────────────────────────────────────────────────

func_discard_pending() {
    if [[ -f "$PENDING_FILE" ]]; then
        echo ""
        echo "  Pending changes:"
        grep -v '^#' "$PENDING_FILE" | sed 's/^/    /'
        echo ""
        echo -ne "  ${BOLD}Discard all pending changes? [y/N]: ${NC}"
        read -r ans
        if [[ "${ans,,}" == "y" ]]; then
            rm -f "$PENDING_FILE"
            ok "Pending changes discarded"
        fi
    else
        warn "No pending changes"
    fi
}

# ── Show change log ───────────────────────────────────────────────────────────

func_show_log() {
    if [[ -f "$CHANGE_LOG" ]]; then
        echo ""
        echo -e "  ${BOLD}Change history:${NC}"
        cat "$CHANGE_LOG" | sed 's/^/    /'
    else
        warn "No change history yet"
    fi
    echo ""
    echo -ne "  Press Enter to continue..."; read -r
}

# ── Live monitor with CPU controls ────────────────────────────────────────────

W=65  # box width

draw_header() {
    local total; total=$(get_total_cpus)
    local current; current=$(get_current_cpus)
    local cpuset; cpuset=$($DOCKER inspect --format='{{.HostConfig.CpusetCpus}}' "$CONTAINER_NAME" 2>/dev/null)
    local limited_flag; [[ -n "$cpuset" ]] && limited_flag=true || limited_flag=false

    local pct=$(( current * 100 / total ))
    local bar_len=28 filled=$(( current * bar_len / total )) bar="" i
    for (( i=0; i<bar_len; i++ )); do
        [[ $i -lt $filled ]] && bar+="█" || bar+="░"
    done

    local uptime; uptime=$(get_uptime)
    local schedule; schedule=$(get_cpu_schedule)

    local cpu_color="$G"
    $limited_flag && cpu_color="$Y"

    echo -e "${BOLD}${B}┌$(printf '─%.0s' $(seq 1 $((W-2))))┐${NC}"
    echo -e "${BOLD}${B}│${NC}  ${BOLD}EMBEDDING WORKER — LIVE MONITOR${NC}$(printf ' %.0s' $(seq 1 $((W-35))))${BOLD}${B}│${NC}"
    echo -e "${BOLD}${B}├$(printf '─%.0s' $(seq 1 $((W-2))))┤${NC}"

    local _found; _found="$(_detect_container)"
    [[ -n "$_found" ]] && CONTAINER_NAME="$_found"

    printf "${BOLD}${B}│${NC}  %-18s ${G}●${NC} %-$(( W-24 ))s${BOLD}${B}│${NC}\n" \
        "Container:" "${CONTAINER_NAME}"
    printf "${BOLD}${B}│${NC}  %-18s %-$(( W-21 ))s${BOLD}${B}│${NC}\n" \
        "Uptime:" "$uptime"

    local cpu_str="${current}/${total} cores  [${bar}]  ${pct}%%"
    printf "${BOLD}${B}│${NC}  %-18s ${cpu_color}%-$(( W-21 ))s${NC}${BOLD}${B}│${NC}\n" \
        "CPU:" "$cpu_str"

    if [[ -n "$schedule" ]]; then
        printf "${BOLD}${B}│${NC}  ${Y}⏱ %-$(( W-5 ))s${NC}${BOLD}${B}│${NC}\n" \
            "Temporary: ${schedule}"
    fi

    echo -e "${BOLD}${B}└$(printf '─%.0s' $(seq 1 $((W-2))))┘${NC}"
}

draw_controls() {
    local _cm; _cm=$(env_get "COMPUTE_MODE" "cpu")
    echo ""
    if [[ "$_cm" == "cpu" ]]; then
        echo -e "  ${BOLD}[+]${NC} +1 core  ${BOLD}[-]${NC} -1 core  ${BOLD}[C]${NC} CPU menu  \
${BOLD}[X]${NC} cancel schedule  ${BOLD}[Q]${NC} quit"
    else
        echo -e "  ${BOLD}[Q]${NC} quit  ${BOLD}[R]${NC} refresh"
        echo -e "  ${DIM}CPU core pinning disabled — worker is GPU-bound (COMPUTE_MODE=${_cm})${NC}"
    fi
    echo -e "  ${DIM}Auto-refreshes every 5s — press a key at any time${NC}"
}

func_monitor() {
    require_container
    local LOG_LINES=18 REFRESH_SECS=5

    stty -echo 2>/dev/null || true
    trap 'stty echo 2>/dev/null; echo ""; exit 0' INT TERM

    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        draw_header
        echo ""
        echo -e "  ${BOLD}── Recent Logs ──────────────────────────────────────────────${NC}"

        $DOCKER logs --tail="$LOG_LINES" "$CONTAINER_NAME" 2>&1 \
        | awk '
            /[Ee]rror|FAILED|failed|Error/ { print "\033[0;31m  " $0 "\033[0m"; next }
            /embedded|done|saved|✓/        { print "\033[0;32m  " $0 "\033[0m"; next }
            /[Bb]atch|[Cc]ycle|records/    { print "\033[0;36m  " $0 "\033[0m"; next }
            /[Ww]arn|warning/              { print "\033[1;33m  " $0 "\033[0m"; next }
                                           { print "  " $0 }
        '

        draw_controls

        local key=""
        local _cm; _cm=$(env_get "COMPUTE_MODE" "cpu")
        if read -t "$REFRESH_SECS" -n 1 -r key 2>/dev/null; then
            case "$key" in
                +|=)  [[ "$_cm" == "cpu" ]] && quick_cpu_adjust +1 ;;
                -)    [[ "$_cm" == "cpu" ]] && quick_cpu_adjust -1 ;;
                c|C)  [[ "$_cm" == "cpu" ]] && { stty echo 2>/dev/null; cpu_menu_interactive; stty -echo 2>/dev/null || true; } ;;
                x|X)  [[ "$_cm" == "cpu" ]] && cancel_schedule ;;
                q|Q)  break ;;
                r|R)  ;; # refresh
            esac
        fi
    done

    stty echo 2>/dev/null || true
    echo -e "\n  ${DIM}Exited monitor. Worker is still running.${NC}"
}

# ── Interactive menu ──────────────────────────────────────────────────────────

func_menu() {
    while true; do
        clear 2>/dev/null || true
        draw_status

        local _compute_mode; _compute_mode=$(env_get "COMPUTE_MODE" "cpu")

        echo -e "  ${BOLD}Actions:${NC}"
        echo ""

        if is_running; then
            echo -e "  ${BOLD}Worker control:${NC}"
            echo "    [1]  Graceful stop   (finish current batch, then stop)"
            echo "    [2]  Force kill      (stop immediately)"
            echo "    [3]  View live logs"
            echo "    [4]  Restart         (graceful stop → start)"
            echo "    [M]  Live monitor    (with real-time stats)"
        else
            echo -e "  ${BOLD}Worker control:${NC}"
            echo "    [1]  Start worker"
            echo -e "    ${DIM}[2]  Force kill      (not running)${NC}"
            echo "    [3]  View last logs"
            echo -e "    ${DIM}[4]  Restart         (not running — use Start)${NC}"
            echo -e "    ${DIM}[M]  Live monitor    (requires worker running)${NC}"
        fi

        echo ""
        echo -e "  ${BOLD}Configuration (some changes apply after-cycle):${NC}"
        if [[ "$_compute_mode" == "cpu" ]]; then
            echo "    [5]  Change CPU cores"
        else
            echo -e "    ${DIM}[5]  CPU core pinning N/A — GPU mode (COMPUTE_MODE=${_compute_mode})${NC}"
        fi
        echo "    [6]  Change batch size   (current: $(env_get BATCH_SIZE 2))"
        echo "    [7]  Change cycle delay  (current: $(env_get DELAY_SECONDS 5)s)"

        echo ""
        echo -e "  ${BOLD}Pending & history:${NC}"
        echo "    [8]  Discard pending changes"
        echo "    [9]  View change history"

        echo ""
        echo -e "  ${BOLD}Maintenance:${NC}"
        echo "    [R]  Reinstall  (wipe Docker cache + rebuild from scratch)"
        echo "    [Q]  Exit"
        echo ""
        echo -ne "  ${BOLD}> ${NC}"
        read -r choice

        case "${choice,,}" in
            1)
                echo ""
                if is_running; then func_stop; else func_start; fi
                echo -ne "  Press Enter to continue..."; read -r ;;
            2) echo ""; func_kill; echo -ne "  Press Enter to continue..."; read -r ;;
            3) func_log ;;
            4)
                if is_running; then
                    echo ""
                    info "Graceful stop then restart..."
                    func_stop; sleep 1; func_start
                    echo -ne "  Press Enter to continue..."; read -r
                fi ;;
            m) if is_running; then func_monitor; else err "Worker not running"; sleep 2; fi ;;
            5)
                if [[ "$_compute_mode" == "cpu" ]]; then
                    func_cpu; echo -ne "  Press Enter to continue..."; read -r
                else
                    warn "CPU core pinning is only available in CPU mode (COMPUTE_MODE=${_compute_mode})"
                    echo -ne "  Press Enter to continue..."; read -r
                fi ;;
            6) func_batch; echo -ne "  Press Enter to continue..."; read -r ;;
            7) func_delay; echo -ne "  Press Enter to continue..."; read -r ;;
            8) func_discard_pending; sleep 1 ;;
            9) func_show_log ;;
            r) func_reinstall; echo -ne "  Press Enter to continue..."; read -r ;;
            q) echo ""; break ;;
        esac
    done
    echo -e "  ${DIM}Exited admin console. Worker is still running if it was started.${NC}"
    echo ""
}

# ── CLI help ──────────────────────────────────────────────────────────────────

func_help() {
    cat <<'HELP'

  EMBEDDING WORKER — Admin Controller (All-in-One)

  Usage:
    ./admin.sh                              Run interactive menu (recommended)
    ./admin.sh monitor                      Live monitor with CPU controls
    ./admin.sh start                        Start the worker
    ./admin.sh stop                         Graceful stop (waits for current batch)
    ./admin.sh kill                         Force stop immediately
    ./admin.sh log                          Follow live logs
    ./admin.sh status                       Show status panel and exit
    ./admin.sh cpu [N] [duration]           Set CPU cores (N=1..max, duration=8h/1d-5h/etc)
    ./admin.sh batch [N]                    Set batch size
    ./admin.sh delay [N]                    Set delay (seconds)
    ./admin.sh reinstall                    Wipe Docker cache and rebuild
    ./admin.sh help                         Show this help

  Examples:
    ./admin.sh monitor              # Live monitoring (watch logs + control CPU)
    ./admin.sh cpu 4                # Set to 4 cores permanently
    ./admin.sh cpu 4 8h             # Set to 4 cores for 8 hours, then revert
    ./admin.sh batch 15             # Set batch size to 15
    ./admin.sh delay 10             # Set delay to 10 seconds
    ./admin.sh status && ./admin.sh cpu 4 && ./admin.sh batch 20  # Chain commands

HELP
}

# ── Entry point ───────────────────────────────────────────────────────────────

case "${1:-}" in
    start)       func_start              ;;
    stop)        func_stop               ;;
    kill)        func_kill               ;;
    log)         func_log                ;;
    monitor)     func_monitor            ;;
    status)      draw_status             ;;
    cpu)         func_cpu "$2" "$3"      ;;
    batch)       func_batch "$2"         ;;
    delay)       func_delay "$2"         ;;
    reinstall)   func_reinstall          ;;
    help|--help|-h) func_help            ;;
    "")          func_menu               ;;
    *)
        err "Unknown command: ${1}"
        func_help
        exit 1 ;;
esac
