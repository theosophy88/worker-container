#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — Environment & Config Management
# =============================================================================

# ── .env file operations ──────────────────────────────────────────────────────

env_get() {
    local key="$1" default="${2:-}"
    if [[ -f "$ENV_FILE" ]]; then
        local val; val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

env_set() {
    local key="$1" value="$2"
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
        else
            echo "${key}=${value}" >> "$ENV_FILE"
        fi
    fi
}
