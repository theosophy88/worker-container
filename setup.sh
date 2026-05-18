#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/theosophy88/worker-container.git"
DEFAULT_DIR="/opt/embedding-worker"
WORKER_DIR="${WORKER_DIR:-${DEFAULT_DIR}}"
SCRIPT_NAME="$(basename "$0")"

info() { printf "\033[1;34m→ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} <command>

Commands:
  install       Clone or update repo, then run install.sh
  update        Pull latest changes from GitHub
  remove        Remove the worker installation (runs uninstall.sh)
  help          Show this help

Environment:
  WORKER_DIR    Install path (default: ${DEFAULT_DIR})
  REPO_URL      GitHub repo URL (default: ${REPO_URL})
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Required command not found: $1"
  fi
}

clone_repo() {
  if [[ -d "$WORKER_DIR" && -n "$(ls -A "$WORKER_DIR")" ]]; then
    die "Directory '$WORKER_DIR' already exists and is not empty. Remove it or use update."
  fi

  info "Cloning repository into $WORKER_DIR..."
  mkdir -p "$WORKER_DIR"
  git clone --depth 1 "$REPO_URL" "$WORKER_DIR"
}

update_repo() {
  if [[ ! -d "$WORKER_DIR/.git" ]]; then
    die "No Git repository found at '$WORKER_DIR'. Run install first."
  fi

  info "Updating repository in $WORKER_DIR..."
  git -C "$WORKER_DIR" fetch --all --prune
  git -C "$WORKER_DIR" pull --ff-only
}

run_install() {
  if [[ ! -f "$WORKER_DIR/install.sh" ]]; then
    die "install.sh not found in '$WORKER_DIR'"
  fi

  info "Running installer..."
  cd "$WORKER_DIR"
  bash install.sh
}

run_uninstall() {
  if [[ ! -f "$WORKER_DIR/uninstall.sh" ]]; then
    die "uninstall.sh not found in '$WORKER_DIR'"
  fi

  info "Running uninstall script..."
  cd "$WORKER_DIR"
  bash uninstall.sh
}

command="${1:-help}"
case "$command" in
  install)
    require_command git
    require_command bash
    if [[ -d "$WORKER_DIR/.git" ]]; then
      update_repo
    else
      clone_repo
    fi
    run_install
    ;;
  update)
    require_command git
    update_repo
    info "Pull completed. To rebuild and restart, run:"
    info "  cd $WORKER_DIR && docker compose build && docker compose up -d"
    ;;
  remove)
    run_uninstall
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    err "Unknown command: $command"
    usage
    exit 1
    ;;
esac
