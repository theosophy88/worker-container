#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — Docker Detection & Operations
# =============================================================================

# ── Docker command (with or without sudo) ────────────────────────────────────
# Use plain 'docker' if the current user can reach the socket,
# otherwise fall back to 'sudo docker'.
if docker info &>/dev/null 2>&1; then
    DOCKER="docker"
elif sudo docker info &>/dev/null 2>&1; then
    DOCKER="sudo docker"
else
    echo "Cannot reach Docker daemon (tried docker and sudo docker)" >&2
    echo "Add your user to the docker group:  sudo usermod -aG docker $USER" >&2
    echo "Then log out and back in, or run:   newgrp docker" >&2
    exit 1
fi

# ── Auto-detect the running worker container ──────────────────────────────────
# Tries in order: well-known names → image name → any embedding-related container
_detect_container() {
    local name
    # 1. Exact known names
    for c in "embedding-worker" "worker"; do
        name=$($DOCKER ps --format "{{.Names}}" 2>/dev/null | grep -i "^${c}" | head -1)
        [[ -n "$name" ]] && echo "$name" && return
    done
    # 2. Any running container whose image contains "embedding-worker"
    name=$($DOCKER ps --format "{{.Names}}	{{.Image}}" 2>/dev/null | grep -i "embedding.worker" | awk '{print $1}' | head -1)
    [[ -n "$name" ]] && echo "$name" && return
    # 3. Any running container with "embedding" or "worker" in image/name
    name=$($DOCKER ps --format "{{.Names}}	{{.Image}}" 2>/dev/null | grep -i "embedding\|worker" | awk '{print $1}' | head -1)
    [[ -n "$name" ]] && echo "$name" && return
    echo ""
}

# ── Container operations ────────────────────────────────────────────────────────

get_container_id() {
    local id
    id=$($DOCKER ps --quiet --filter "name=^${CONTAINER_NAME}$" 2>/dev/null | head -1)
    if [[ -z "$id" ]]; then
        # Fallback: first running container
        id=$($DOCKER ps --quiet 2>/dev/null | head -1)
    fi
    echo "$id"
}

is_running() {
    [[ -n "$(get_container_id)" ]]
}

require_container() {
    # Re-detect in case container started after script launched
    local _found; _found="$(_detect_container)"
    [[ -n "$_found" ]] && CONTAINER_NAME="$_found"

    if ! $DOCKER ps --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        err "No running worker container found."
        echo ""
        echo "  Running containers:"
        $DOCKER ps --format "    {{.Names}}  ({{.Image}})" 2>/dev/null || echo "    (none)"
        echo ""
        echo "  Start the worker:  cd $WORKER_DIR && $DOCKER compose up -d"
        exit 1
    fi
}
