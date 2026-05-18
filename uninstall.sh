#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

echo
echo "============================================================"
echo "  EMBEDDING WORKER — Uninstaller"
echo "============================================================"
echo "This will stop the worker container, remove the image, and delete generated .env."
echo "It does not uninstall Docker Engine or remove this repository."
echo

read -r -p "Continue with uninstall? [y/N]: " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or not available in PATH."
    exit 1
fi

compose_args=("-f" "docker-compose.yml")
if [[ -f docker-compose.nvidia.yml ]]; then
    compose_args+=("-f" "docker-compose.nvidia.yml")
fi
if [[ -f docker-compose.amd.yml ]]; then
    compose_args+=("-f" "docker-compose.amd.yml")
fi

echo "Stopping Docker Compose stack..."
docker compose "${compose_args[@]}" down --rmi all --volumes || true

echo "Stopping any remaining embedding-worker containers..."
container_ids="$(docker ps -aq --filter "name=embedding-worker"; docker ps -aq --filter "ancestor=embedding-worker:latest" | sort -u)"
if [[ -n "${container_ids// }" ]]; then
    docker rm -f $container_ids || true
    echo "Stopped and removed remaining embedding-worker containers."
else
    echo "No remaining embedding-worker containers found."
fi

echo "Removing image embedding-worker:latest..."
docker image rm -f embedding-worker:latest || true

if [[ -f .env ]]; then
    rm -f .env
    echo ".env removed."
else
    echo ".env not found."
fi

echo
read -r -p "Also remove host-mounted model cache at /home/model if accessible? [y/N]: " remove_cache
if [[ "$remove_cache" =~ ^[Yy]$ ]]; then
    if [[ -d /home/model ]]; then
        rm -rf /home/model
        echo "Host model cache removed from /home/model."
    else
        echo "/home/model not found or not accessible from this shell."
    fi
fi

echo
read -r -p "Also remove the installation directory at $SCRIPT_DIR? [y/N]: " remove_install_dir
if [[ "$remove_install_dir" =~ ^[Yy]$ ]]; then
    cd "$(dirname "$SCRIPT_DIR")"
    rm -rf "$SCRIPT_DIR"
    echo "Installation directory removed: $SCRIPT_DIR"
fi

echo
echo "Uninstall complete."
echo "If you mounted a different host directory for HF_HOME, remove that directory manually."
