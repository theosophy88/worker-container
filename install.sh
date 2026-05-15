#!/usr/bin/env bash
# =============================================================================
#  EMBEDDING WORKER — Universal Linux Installer v3.0
#  Supported distros:
#    Debian/Ubuntu family: Ubuntu · Debian · Mint · Pop_OS · Kali · Raspbian
#    RHEL family:          CentOS 7/8 · RHEL 7/8/9 · Rocky · AlmaLinux
#    Others:               Fedora · Arch · Manjaro · openSUSE · Alpine
#
#  Usage:
#    bash install.sh               → interactive guided install
#    bash install.sh --raw         → print raw Docker install commands, then exit
#    bash install.sh --reconfigure → skip Docker install, re-run config only
# =============================================================================

set -uo pipefail

# ── TTY for prompts — defined first, used everywhere ─────────────────────────
TTY=/dev/tty

# ── Root / sudo check — MUST be before any file writes or prompts ─────────────
# If not root, re-exec the whole script under sudo.
# This runs before _setup_worker_dir so the install-path question is only
# asked once (as root), not twice.
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        printf "\033[0;31m  This script must be run as root (sudo not found).\033[0m\n" >&2
        exit 1
    fi
    printf "\033[0;36m  →  Re-running with sudo...\033[0m\n"
    exec sudo bash "$0" "$@"
fi
REAL_USER="${SUDO_USER:-${USER:-root}}"
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || echo "/root")

# ── Log file (safe now — we are root) ────────────────────────────────────────
LOG_FILE="/tmp/embedding_worker_install.log"
exec 3>>"$LOG_FILE"

CONTAINER_NAME="embedding-worker"

# ── Parse flags ───────────────────────────────────────────────────────────────
RAW_MODE=false; RECONFIG_MODE=false
for _arg in "$@"; do
    [[ "$_arg" == "--raw" ]]         && RAW_MODE=true
    [[ "$_arg" == "--reconfigure" ]] && RECONFIG_MODE=true
done

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
    C='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'
else
    R='' G='' Y='' B='' C='' BOLD='' DIM='' NC=''
fi

hdr()  { echo -e "\n${BOLD}${B}══════════════════════════════════════════════${NC}"
         echo -e "${BOLD}${B}  $*${NC}"
         echo -e "${BOLD}${B}══════════════════════════════════════════════${NC}"
         echo "=== $* ===" >&3 2>/dev/null || true; }
ok()   { echo -e "${G}  ✓  $*${NC}"; echo "  OK: $*"   >&3 2>/dev/null || true; }
warn() { echo -e "${Y}  ⚠  $*${NC}"; echo "  WARN: $*" >&3 2>/dev/null || true; }
err()  { echo -e "${R}  ✗  $*${NC}"; echo "  ERR: $*"  >&3 2>/dev/null || true; }
info() { echo -e "${C}  →  $*${NC}"; echo "  --> $*"   >&3 2>/dev/null || true; }
die()  { err "$*"; echo -e "  ${DIM}Check log: ${LOG_FILE}${NC}"; exit 1; }

ask() {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        printf "${BOLD}  ${prompt} [${default}]: ${NC}" > "$TTY"
    else
        printf "${BOLD}  ${prompt}: ${NC}" > "$TTY"
    fi
    read -r REPLY < "$TTY"
    [[ -z "$REPLY" && -n "$default" ]] && REPLY="$default"
    echo "  INPUT: ${prompt} = ${REPLY}" >&3 2>/dev/null || true
}

ask_yn() {
    local prompt="$1" default="${2:-y}"
    while true; do
        printf "${BOLD}  ${prompt} [y/n, default=${default}]: ${NC}" > "$TTY"
        read -r REPLY < "$TTY"; REPLY="${REPLY:-$default}"
        case "${REPLY,,}" in
            y|yes) echo "  INPUT: ${prompt} = yes" >&3 2>/dev/null || true; return 0 ;;
            n|no)  echo "  INPUT: ${prompt} = no"  >&3 2>/dev/null || true; return 1 ;;
            *) warn "Please enter y or n" ;;
        esac
    done
}

# ── Ask install location (now safe — we are root, log is open) ────────────────
_setup_worker_dir() {
    local _default="/opt/embedding-worker"
    printf "\n" > "$TTY"
    printf "\033[1m  Where should the worker be installed?\033[0m\n" > "$TTY"
    printf "  The installer will create this folder and write all required files.\n" > "$TTY"
    printf "\033[1m  Install path [%s]: \033[0m" "$_default" > "$TTY"
    read -r _dir < "$TTY"
    [[ -z "$_dir" ]] && _dir="$_default"
    mkdir -p "$_dir" || { err "Cannot create directory: $_dir"; exit 1; }
    echo "$_dir"
}

WORKER_DIR="$(_setup_worker_dir)"
SCRIPT_DIR="$WORKER_DIR"
info "Worker directory: ${WORKER_DIR}"


retry() {
    # retry <N> <cmd> [args...]
    local n="$1"; shift
    local attempt=1
    while [[ $attempt -le $n ]]; do
        "$@" && return 0
        warn "Attempt $attempt/$n failed — retrying in 3s..."
        sleep 3
        (( attempt++ ))
    done
    return 1
}

# (root check moved to top of script)

# ── OS detection ───────────────────────────────────────────────────────────────
OS="" DISTRO="" DISTRO_LIKE="" VERSION="" VERSION_CODENAME="" PKG_MGR=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO="${ID:-unknown}"; DISTRO="${DISTRO,,}"
        DISTRO_LIKE="${ID_LIKE:-}"
        VERSION="${VERSION_ID:-}"
        VERSION_CODENAME="${VERSION_CODENAME:-}"
    elif [[ -f /etc/alpine-release ]]; then
        DISTRO="alpine"; VERSION=$(cat /etc/alpine-release)
    fi

    case "$DISTRO" in
        ubuntu|debian)
            OS="debian"; PKG_MGR="apt" ;;
        linuxmint|pop|elementary|kali|raspbian|parrot|zorin)
            OS="debian"; PKG_MGR="apt"
            # Get upstream Ubuntu codename for Docker repo
            if [[ -f /etc/upstream-release/lsb-release ]]; then
                local _tmp; _tmp=$(grep CODENAME /etc/upstream-release/lsb-release | cut -d= -f2)
                [[ -n "$_tmp" ]] && VERSION_CODENAME="$_tmp"
            fi
            DISTRO="ubuntu"  # use ubuntu Docker repo for all Ubuntu derivatives ;;
            ;;
        centos|ol)
            OS="rhel"; PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf" ;;
        rhel|rocky|almalinux)
            OS="rhel"; PKG_MGR="dnf" ;;
        fedora)
            OS="fedora"; PKG_MGR="dnf" ;;
        arch|manjaro|endeavouros|garuda|artix)
            OS="arch"; PKG_MGR="pacman" ;;
        opensuse*|sles)
            OS="suse"; PKG_MGR="zypper" ;;
        alpine)
            OS="alpine"; PKG_MGR="apk" ;;
        *)
            # Fallback: detect from what's actually installed
            if   command -v apt-get &>/dev/null; then OS="debian"; PKG_MGR="apt";    DISTRO="${DISTRO:-debian}"
            elif command -v dnf     &>/dev/null; then OS="fedora"; PKG_MGR="dnf";    DISTRO="${DISTRO:-fedora}"
            elif command -v yum     &>/dev/null; then OS="rhel";   PKG_MGR="yum";    DISTRO="${DISTRO:-centos}"
            elif command -v pacman  &>/dev/null; then OS="arch";   PKG_MGR="pacman"; DISTRO="${DISTRO:-arch}"
            elif command -v zypper  &>/dev/null; then OS="suse";   PKG_MGR="zypper"; DISTRO="${DISTRO:-opensuse}"
            elif command -v apk     &>/dev/null; then OS="alpine"; PKG_MGR="apk";    DISTRO="${DISTRO:-alpine}"
            else
                err "Cannot auto-detect OS or package manager."
                echo ""
                echo "  Run:  bash install.sh --raw"
                echo "  to print the Docker install commands for your distro manually."
                exit 1
            fi ;;
    esac

    ok "OS: ${DISTRO} ${VERSION} (package manager: ${PKG_MGR})"
}

is_lxc() {
    # Returns 0 if running inside an LXC container
    grep -q "container=lxc" /proc/1/environ 2>/dev/null && return 0
    [[ -f /run/container_type ]] && grep -q lxc /run/container_type 2>/dev/null && return 0
    command -v systemd-detect-virt &>/dev/null && \
        systemd-detect-virt --container 2>/dev/null | grep -q lxc && return 0
    return 1
}

# ── Network detection & configuration ─────────────────────────────────────────
check_network() {
    hdr "Network Check"

    local reachable=false
    for _host in 8.8.8.8 1.1.1.1 9.9.9.9; do
        ping -c 1 -W 3 "$_host" &>/dev/null 2>&1 && reachable=true && break
    done

    if $reachable; then
        ok "Internet reachable"
        # Check DNS separately
        if ! (nslookup download.docker.com &>/dev/null 2>&1 || \
              host download.docker.com &>/dev/null 2>&1); then
            warn "DNS resolution failing — adding fallback nameservers"
            chattr -i /etc/resolv.conf 2>/dev/null || true
            {
                echo "nameserver 8.8.8.8"
                echo "nameserver 1.1.1.1"
            } >> /etc/resolv.conf
            ok "Added Google/Cloudflare DNS to /etc/resolv.conf"
        else
            ok "DNS resolution: OK"
        fi
        return 0
    fi

    warn "No internet connectivity detected"
    echo ""
    info "Scanning network interfaces..."
    echo ""

    # Build list of non-loopback interfaces
    local -a IFACES
    mapfile -t IFACES < <(
        ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | sed 's/@.*//' \
        | grep -v '^lo$' \
        | grep -v '^docker' \
        | grep -v '^veth'
    )

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        die "No network interfaces found. Check hardware/drivers."
    fi

    for i in "${!IFACES[@]}"; do
        local iface="${IFACES[$i]}"
        local state ip4 mac
        state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        ip4=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet )\S+' | head -1 || echo "none")
        mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "??:??:??")
        printf "    ${BOLD}[%d]${NC}  %-16s  state:%-8s  ip:%-20s  mac:%s\n" \
            "$((i+1))" "$iface" "$state" "$ip4" "$mac"
    done

    echo ""
    ask "Select interface number to configure" "1"
    local idx=$(( REPLY - 1 ))
    [[ $idx -lt 0 || $idx -ge ${#IFACES[@]} ]] && die "Invalid selection"
    local SELECTED_IFACE="${IFACES[$idx]}"

    echo ""
    echo "  Configure ${BOLD}${SELECTED_IFACE}${NC} as:"
    echo "    [1]  DHCP   — automatic IP (recommended)"
    echo "    [2]  Static — manual IP, gateway, DNS"
    ask "Choice" "1"
    case "$REPLY" in
        1) _configure_dhcp   "$SELECTED_IFACE" ;;
        2) _configure_static "$SELECTED_IFACE" ;;
        *) die "Invalid choice" ;;
    esac

    info "Waiting up to 20s for connectivity..."
    for i in $(seq 1 10); do
        sleep 2
        printf "\r  ${DIM}Checking... %d/10${NC}" "$i"
        ping -c 1 -W 2 8.8.8.8 &>/dev/null 2>&1 && { echo ""; ok "Network is up!"; return 0; }
    done
    echo ""
    warn "Network still not reachable after configuration."
    ask_yn "Continue anyway? (Docker image pull will fail without internet)" "n" || exit 1
}

_configure_dhcp() {
    local iface="$1"
    info "Setting ${iface} to DHCP..."
    ip link set "$iface" up 2>/dev/null || true

    # Try multiple DHCP clients (different distros ship different ones)
    if command -v dhclient &>/dev/null; then
        timeout 15 dhclient -v "$iface" 2>/dev/null || true
    elif command -v dhcpcd &>/dev/null; then
        timeout 15 dhcpcd "$iface" 2>/dev/null || true
    elif command -v udhcpc &>/dev/null; then
        timeout 15 udhcpc -i "$iface" -b 2>/dev/null || true
    fi

    # Persist via NetworkManager (most modern desktop/server distros)
    if command -v nmcli &>/dev/null 2>&1; then
        nmcli device set   "$iface" managed yes 2>/dev/null || true
        nmcli connection modify "$iface" ipv4.method auto 2>/dev/null || true
        nmcli connection up     "$iface" 2>/dev/null \
            || nmcli device connect "$iface" 2>/dev/null || true
    fi

    # Persist via systemd-networkd
    if systemctl is-active systemd-networkd &>/dev/null 2>&1; then
        mkdir -p /etc/systemd/network
        cat > "/etc/systemd/network/10-${iface}-dhcp.network" <<EOF
[Match]
Name=${iface}
[Network]
DHCP=yes
EOF
        systemctl reload systemd-networkd 2>/dev/null || true
    fi

    # Persist via /etc/network/interfaces (Debian legacy / Alpine)
    if [[ -f /etc/network/interfaces ]]; then
        # Remove existing block for this interface
        sed -i "/^auto ${iface}/,/^[[:space:]]*$/d" /etc/network/interfaces 2>/dev/null || true
        printf "\nauto %s\niface %s inet dhcp\n" "$iface" "$iface" >> /etc/network/interfaces
        ifdown "$iface" 2>/dev/null || true
        ifup   "$iface" 2>/dev/null || true
    fi

    ok "DHCP configured on ${iface}"
}

_configure_static() {
    local iface="$1"
    echo ""
    echo -e "  ${BOLD}Static IP configuration for ${iface}:${NC}"
    ask "  IP address    (e.g. 192.168.1.100)" ""
    local ip_addr="$REPLY"
    ask "  Prefix/mask   (e.g. 24 = /24 = 255.255.255.0)" "24"
    local prefix="$REPLY"
    ask "  Gateway       (e.g. 192.168.1.1)" ""
    local gw="$REPLY"
    ask "  Primary DNS" "8.8.8.8"
    local dns1="$REPLY"
    ask "  Secondary DNS" "8.8.4.4"
    local dns2="$REPLY"

    info "Applying ${ip_addr}/${prefix} → gateway ${gw}..."

    ip link set "$iface" up
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add "${ip_addr}/${prefix}" dev "$iface"
    ip route add default via "$gw" dev "$iface" 2>/dev/null \
        || ip route replace default via "$gw" dev "$iface" 2>/dev/null || true

    # DNS
    chattr -i /etc/resolv.conf 2>/dev/null || true
    printf "nameserver %s\nnameserver %s\n" "$dns1" "$dns2" > /etc/resolv.conf

    # Persist via nmcli
    if command -v nmcli &>/dev/null 2>&1; then
        nmcli connection modify "$iface" \
            ipv4.method   manual \
            ipv4.addresses "${ip_addr}/${prefix}" \
            ipv4.gateway   "$gw" \
            ipv4.dns       "${dns1} ${dns2}" 2>/dev/null || true
        nmcli connection up "$iface" 2>/dev/null || true
    fi

    # Persist via systemd-networkd
    if systemctl is-active systemd-networkd &>/dev/null 2>&1; then
        mkdir -p /etc/systemd/network
        cat > "/etc/systemd/network/10-${iface}-static.network" <<EOF
[Match]
Name=${iface}
[Network]
Address=${ip_addr}/${prefix}
Gateway=${gw}
DNS=${dns1}
DNS=${dns2}
EOF
        systemctl reload systemd-networkd 2>/dev/null || true
    fi

    # Persist via /etc/network/interfaces
    if [[ -f /etc/network/interfaces ]]; then
        sed -i "/^auto ${iface}/,/^[[:space:]]*$/d" /etc/network/interfaces 2>/dev/null || true
        cat >> /etc/network/interfaces <<EOF

auto ${iface}
iface ${iface} inet static
    address ${ip_addr}/${prefix}
    gateway ${gw}
    dns-nameservers ${dns1} ${dns2}
EOF
    fi

    ok "Static IP ${ip_addr}/${prefix} configured on ${iface}"
}

# ── Docker installation from official repositories ─────────────────────────────
install_docker() {
    hdr "Docker CE — Official Repository Install"

    # Check if already installed
    if command -v docker &>/dev/null; then
        local ver; ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
        ok "Docker already installed (v${ver})"
        if ! docker compose version &>/dev/null 2>&1; then
            warn "Compose plugin missing — installing..."
            _install_compose_standalone
        else
            ok "Docker Compose: $(docker compose version 2>/dev/null | grep -oP '[\d.]+' | head -1)"
        fi
        _start_docker; return 0
    fi

    # Apply LXC daemon fix before installing
    is_lxc && _apply_lxc_fix

    info "Installing from official Docker repositories..."
    case "$OS" in
        debian) _docker_install_debian ;;
        rhel)   _docker_install_rhel   ;;
        fedora) _docker_install_fedora ;;
        arch)   _docker_install_arch   ;;
        suse)   _docker_install_suse   ;;
        alpine) _docker_install_alpine ;;
        *) die "Unsupported OS: $OS — run: bash install.sh --raw" ;;
    esac

    _start_docker

    # Add real user to docker group
    [[ "$REAL_USER" != "root" ]] && usermod -aG docker "$REAL_USER" 2>/dev/null || true

    # Verify installation
    if docker run --rm hello-world &>/dev/null 2>&1; then
        ok "Docker verified ✓  (hello-world test passed)"
    else
        warn "Docker installed — hello-world test failed."
        warn "This is normal if you need to re-login for group changes."
        warn "Try: newgrp docker  (or log out and back in)"
    fi
}

_start_docker() {
    systemctl enable docker 2>/dev/null || rc-update add docker default 2>/dev/null || true
    systemctl start  docker 2>/dev/null || service docker start 2>/dev/null || true
    sleep 2
}

_apply_lxc_fix() {
    warn "LXC container detected — applying Docker AppArmor daemon fixes..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "no-new-privileges": false,
  "seccomp-profile": "unconfined",
  "features": { "buildkit": false }
}
EOF
    export DOCKER_BUILDKIT=0
    ok "LXC Docker fix applied (/etc/docker/daemon.json)"
}

_docker_install_debian() {
    # Official guide: https://docs.docker.com/engine/install/ubuntu/
    info "Removing old Docker packages..."
    for _pkg in docker docker-engine docker.io containerd runc docker-compose; do
        apt-get remove -y "$_pkg" 2>/dev/null || true
    done

    retry 3 apt-get update -y
    retry 3 apt-get install -y ca-certificates curl gnupg lsb-release

    # GPG key
    install -m 0755 -d /etc/apt/keyrings
    retry 3 curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    local arch; arch=$(dpkg --print-architecture)
    # Determine codename — for derivatives, use upstream Ubuntu codename
    local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo '')}"
    if [[ -z "$codename" ]]; then
        warn "Could not detect codename — defaulting to 'jammy'"
        codename="jammy"; DISTRO="ubuntu"
    fi

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DISTRO} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    retry 3 apt-get update -y
    retry 3 apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

_docker_install_rhel() {
    # Official guide: https://docs.docker.com/engine/install/centos/
    info "Removing old Docker packages..."
    for _pkg in docker docker-client docker-common docker-engine podman; do
        "$PKG_MGR" remove -y "$_pkg" 2>/dev/null || true
    done

    retry 3 "$PKG_MGR" install -y yum-utils

    local maj_ver; maj_ver=$(echo "$VERSION" | cut -d. -f1)
    if [[ "$DISTRO" == "rhel" ]]; then
        retry 3 yum-config-manager --add-repo \
            "https://download.docker.com/linux/rhel/docker-ce.repo"
    else
        retry 3 yum-config-manager --add-repo \
            "https://download.docker.com/linux/centos/${maj_ver}/docker-ce.repo" 2>/dev/null \
        || retry 3 yum-config-manager --add-repo \
            "https://download.docker.com/linux/centos/docker-ce.repo"
    fi

    retry 3 "$PKG_MGR" install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

_docker_install_fedora() {
    # Official guide: https://docs.docker.com/engine/install/fedora/
    for _pkg in docker docker-client docker-engine moby-engine; do
        dnf remove -y "$_pkg" 2>/dev/null || true
    done
    retry 3 dnf install -y dnf-plugins-core
    retry 3 dnf config-manager --add-repo \
        https://download.docker.com/linux/fedora/docker-ce.repo
    retry 3 dnf install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

_docker_install_arch() {
    # Docker is in the Arch extra repository
    retry 3 pacman -Sy --noconfirm docker docker-compose
}

_docker_install_suse() {
    # Official guide: https://docs.docker.com/engine/install/suse/
    retry 3 zypper --non-interactive refresh
    retry 3 zypper --non-interactive install -y curl ca-certificates
    retry 3 zypper --non-interactive addrepo \
        https://download.docker.com/linux/suse/docker-ce.repo 2>/dev/null || true
    retry 3 zypper --non-interactive --gpg-auto-import-keys refresh
    retry 3 zypper --non-interactive install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

_docker_install_alpine() {
    # Docker available in Alpine community repo
    retry 3 apk update
    retry 3 apk add --no-cache docker docker-compose curl bash
    rc-update add docker default 2>/dev/null || true
    service docker start 2>/dev/null || true
}

_install_compose_standalone() {
    local arch; arch=$(uname -m)
    local ver; ver=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
        2>/dev/null | grep '"tag_name"' | cut -d'"' -f4 || echo "v2.24.5")
    mkdir -p /usr/local/lib/docker/cli-plugins
    retry 3 curl -fsSL \
        "https://github.com/docker/compose/releases/download/${ver}/docker-compose-linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    ok "Docker Compose ${ver} installed"
}

# ── Generate all worker project files ─────────────────────────────────────────
create_worker_files() {
    hdr "Creating Worker Files in ${WORKER_DIR}"

    # ── Dockerfile ────────────────────────────────────────────────────────────
    cat > "${WORKER_DIR}/Dockerfile" <<'DOCKERFILE'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    torch sentence-transformers accelerate bitsandbytes requests
ENV HF_HOME=/root/.cache/huggingface
WORKDIR /app
COPY worker.py .
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
DOCKERFILE
    ok "Dockerfile"

    # ── entrypoint.sh ─────────────────────────────────────────────────────────
    cat > "${WORKER_DIR}/entrypoint.sh" <<'ENTRYPT'
#!/bin/bash
set -e
HF_MODEL="${HF_MODEL_NAME:-Qwen/Qwen3-Embedding-8B}"
PRECISION="${PRECISION:-float16}"
echo "========================================"
echo "  Embedding Worker Starting"
echo "  Node     : ${NODE_NAME:-worker}"
echo "  Model    : $HF_MODEL"
echo "  Precision: $PRECISION"
echo "========================================"
echo "[startup] Starting embedding worker..."
exec python3 /app/worker.py
ENTRYPT
    chmod +x "${WORKER_DIR}/entrypoint.sh"
    ok "entrypoint.sh"

    # ── worker.py ─────────────────────────────────────────────────────────────
    cat > "${WORKER_DIR}/worker.py" <<'WORKERPY'
import os, sys, re, time, json, logging, signal
from datetime import datetime, timedelta, timezone
import requests

total_embedded = 0; total_errors = 0; total_fetched = 0; _start_time = time.time()

def require_env(k):
    v = os.getenv(k)
    if not v: print(f"ERROR: {k} is required"); sys.exit(1)
    return v

N8N_GET_URL     = require_env("N8N_GET_URL")
N8N_SAVE_URL    = require_env("N8N_SAVE_URL")
N8N_API_KEY     = require_env("N8N_API_KEY")
NODE_NAME       = require_env("NODE_NAME")
HF_MODEL_NAME   = os.getenv("HF_MODEL_NAME",   "Qwen/Qwen3-Embedding-8B")
PRECISION       = os.getenv("PRECISION",        "float16").strip().lower()
BATCH_SIZE      = int(os.getenv("BATCH_SIZE",      "10"))
DELAY_SECONDS   = float(os.getenv("DELAY_SECONDS",   "5"))
STOP_AT         = os.getenv("STOP_AT",          "").strip()
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "30"))
N8N_STATUS_URL  = os.getenv("N8N_STATUS_URL",  "").strip()
STATUS_INTERVAL = int(os.getenv("STATUS_INTERVAL", "10"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout)])
log = logging.getLogger("worker")

_shutdown = False
def _sig(sig, frame):
    global _shutdown
    log.info(f"Signal {sig} received — shutting down after current batch...")
    _shutdown = True
signal.signal(signal.SIGTERM, _sig); signal.signal(signal.SIGINT, _sig)

def parse_duration(raw):
    raw = raw.strip()
    if not raw: return None
    pat = re.compile(r'^(\d+)(d|h|m)$', re.I)
    days = hours = minutes = 0
    for p in raw.split('-'):
        m = pat.match(p.strip())
        if not m: log.error(f"Invalid STOP_AT part: '{p}'"); sys.exit(1)
        v, u = int(m.group(1)), m.group(2).lower()
        if u == 'd': days += v
        elif u == 'h': hours += v
        elif u == 'm': minutes += v
    td = timedelta(days=days, hours=hours, minutes=minutes)
    if td.total_seconds() <= 0: log.error("STOP_AT must be > 0"); sys.exit(1)
    return td

def calc_stop_time(raw):
    td = parse_duration(raw)
    return datetime.now(timezone.utc) + td if td else None

def format_duration(td):
    s = int(td.total_seconds())
    d, h, m = s//86400, (s%86400)//3600, (s%3600)//60
    parts = ([f"{d}d"] if d else []) + ([f"{h}h"] if h else []) + ([f"{m}m"] if m else [])
    return "-".join(parts) if parts else "0m"

def should_stop(stop_at):
    if _shutdown: return True
    if stop_at and datetime.now(timezone.utc) >= stop_at:
        log.info("Stop time reached."); return True
    return False

def detect_device():
    import torch
    if torch.cuda.is_available():
        log.info(f"GPU: {torch.cuda.get_device_name(0)}"); return "cuda"
    try:
        if torch.backends.mps.is_available(): log.info("Apple MPS detected"); return "mps"
    except AttributeError: pass
    log.info("No GPU — using CPU"); return "cpu"

def load_model(device):
    import torch
    from sentence_transformers import SentenceTransformer
    kw = {}
    if PRECISION == "float16": kw["torch_dtype"] = torch.float16
    elif PRECISION == "float32": kw["torch_dtype"] = torch.float32
    elif PRECISION == "8bit": kw["load_in_8bit"] = True
    elif PRECISION == "4bit": kw["load_in_4bit"] = True
    else: log.warning(f"Unknown PRECISION '{PRECISION}' — using float16"); kw["torch_dtype"] = torch.float16
    if PRECISION in ("8bit","4bit") and device == "cpu":
        log.warning(f"{PRECISION} not supported on CPU — using float32"); kw = {"torch_dtype": torch.float32}
    log.info(f"Loading '{HF_MODEL_NAME}' (precision={PRECISION}, device={device})...")
    model = SentenceTransformer(HF_MODEL_NAME, device=device, model_kwargs=kw)
    log.info("Model loaded."); return model

HEADERS = {"X-API-Key": N8N_API_KEY, "Content-Type": "application/json"}

def fetch_batch():
    global total_fetched
    for attempt in range(1, 4):
        try:
            r = requests.post(N8N_GET_URL, json={"node_name": NODE_NAME, "batch_size": BATCH_SIZE},
                              headers=HEADERS, timeout=REQUEST_TIMEOUT)
            r.raise_for_status()
            recs = r.json().get("records", [])
            if recs: total_fetched += len(recs); log.info(f"Fetched {len(recs)} records (total: {total_fetched})")
            else: log.info("No pending records — waiting...")
            return recs
        except Exception as e:
            log.error(f"n8n GET error (attempt {attempt}/3): {e}")
            if attempt < 3: log.info("Retrying in 1 minute..."); time.sleep(60)
    log.error("Failed to fetch after 3 attempts"); return []

def save_vectors(vectors):
    for attempt in range(1, 4):
        try:
            r = requests.post(N8N_SAVE_URL, json={"node_name": NODE_NAME, "vectors": vectors},
                              headers=HEADERS, timeout=REQUEST_TIMEOUT)
            r.raise_for_status()
            log.info(f"Saved {r.json().get('saved', len(vectors))}/{len(vectors)} vectors"); return True
        except Exception as e:
            log.error(f"n8n SAVE error (attempt {attempt}/3): {e}")
            if attempt < 3: log.info("Retrying in 1 minute..."); time.sleep(60)
    log.error("Failed to save after 3 attempts"); return False

def post_status(status, cycle, device):
    if not N8N_STATUS_URL: return
    try:
        r = requests.post(N8N_STATUS_URL, headers=HEADERS, timeout=REQUEST_TIMEOUT,
                          json={"node_name": NODE_NAME, "status": status, "cycles": cycle,
                                "articles_embedded": total_embedded, "device": device,
                                "uptime_seconds": int(time.time()-_start_time), "model_name": HF_MODEL_NAME})
        r.raise_for_status()
        log.info(f"Status posted: {status} (cycle={cycle}, embedded={total_embedded})")
    except Exception as e:
        log.warning(f"Status POST failed (non-fatal): {e}")

def embed_batch(model, records):
    global total_embedded, total_errors
    results = []
    for i, rec in enumerate(records):
        nid = rec.get("id"); desc = rec.get("description", "")
        if not desc or not str(desc).strip():
            log.warning(f"Record {nid} empty — skipping"); total_errors += 1; continue
        log.info(f"Embedding record {nid} ({i+1}/{len(records)}) ...")
        try:
            vec = model.encode(str(desc).strip(), normalize_embeddings=True).tolist()
            total_embedded += 1
            results.append({"id": nid, "vector": vec, "status": "done", "node_name": NODE_NAME})
            log.info(f"Record {nid} — embedded ({len(vec)} dims)")
        except Exception as e:
            log.error(f"Embed error for {nid}: {e}"); total_errors += 1
            results.append({"id": nid, "status": "AI-error", "node_name": NODE_NAME})
    if total_embedded > 0 and total_embedded % 10 == 0:
        log.info(f"[STATS] Total: {total_embedded} embedded, {total_errors} errors")
    return results

def main():
    device = detect_device()
    model  = load_model(device)
    log.info("Running test embedding...")
    try:
        tv = model.encode("test", normalize_embeddings=True)
        log.info(f"Test embedding OK — {len(tv)} dimensions")
    except Exception as e:
        log.error(f"Test embedding failed: {e}"); sys.exit(1)
    stop_at = calc_stop_time(STOP_AT)
    dur_str = format_duration(parse_duration(STOP_AT)) if STOP_AT else "forever"
    log.info("="*52)
    log.info(f"  Node: {NODE_NAME}  Model: {HF_MODEL_NAME}  Precision: {PRECISION}  Device: {device}")
    log.info(f"  Batch: {BATCH_SIZE}  Delay: {DELAY_SECONDS}s  Run for: {dur_str}")
    if N8N_STATUS_URL: log.info(f"  Status every {STATUS_INTERVAL} cycles → {N8N_STATUS_URL}")
    log.info("="*52)
    cycle = 0
    try:
        while not should_stop(stop_at):
            cycle += 1
            if stop_at:
                rem = stop_at - datetime.now(timezone.utc)
                log.info(f"── Cycle {cycle}  (remaining: {format_duration(rem) if rem.total_seconds()>0 else '0m'}) ──")
            else:
                log.info(f"── Cycle {cycle} ──────────────────────────────────")
            records = fetch_batch()
            if not records: time.sleep(DELAY_SECONDS); continue
            vectors = embed_batch(model, records)
            if not vectors: time.sleep(DELAY_SECONDS); continue
            save_vectors(vectors)
            if N8N_STATUS_URL and STATUS_INTERVAL > 0 and cycle % STATUS_INTERVAL == 0:
                post_status("running", cycle, device)
            if not should_stop(stop_at): time.sleep(DELAY_SECONDS)
    finally:
        post_status("stopped", cycle, device)
        log.info(f"Worker stopped. Total: {total_embedded} embedded, {total_errors} errors.")

if __name__ == "__main__":
    main()
WORKERPY
    ok "worker.py"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    cat > "${WORKER_DIR}/docker-compose.yml" <<'DCOMPOSE'
services:
  embedding-worker:
    container_name: embedding-worker
    build: .
    restart: "${RESTART_POLICY:-on-failure}"
    volumes:
      - /home/model:/root/.cache/huggingface
    environment:
      - NODE_NAME=${NODE_NAME}
      - HF_MODEL_NAME=${HF_MODEL_NAME:-Qwen/Qwen3-Embedding-8B}
      - HF_HOME=/root/.cache/huggingface
      - PRECISION=${PRECISION:-float16}
      - N8N_GET_URL=${N8N_GET_URL}
      - N8N_SAVE_URL=${N8N_SAVE_URL}
      - N8N_API_KEY=${N8N_API_KEY}
      - N8N_STATUS_URL=${N8N_STATUS_URL:-}
      - STATUS_INTERVAL=${STATUS_INTERVAL:-10}
      - BATCH_SIZE=${BATCH_SIZE:-10}
      - DELAY_SECONDS=${DELAY_SECONDS:-5}
      - STOP_AT=${STOP_AT:-}
      - REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-30}
DCOMPOSE
    ok "docker-compose.yml"

    cat > "${WORKER_DIR}/docker-compose.nvidia.yml" <<'DCNV'
services:
  embedding-worker:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
DCNV
    ok "docker-compose.nvidia.yml"

    cat > "${WORKER_DIR}/docker-compose.amd.yml" <<'DCAMD'
services:
  embedding-worker:
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    group_add:
      - video
      - render
    environment:
      - HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-}
      - ROCR_VISIBLE_DEVICES=0
      - HIP_VISIBLE_DEVICES=0
DCAMD
    ok "docker-compose.amd.yml"

    ok "All files written to ${WORKER_DIR}"
    echo ""
    info "Install path: ${WORKER_DIR}"
}

# ── Compute/precision configuration ───────────────────────────────────────────
# HuggingFace sentence-transformers loads the full model in-process.
# Device is auto-detected at runtime: CUDA → ROCm → MPS → CPU.
# PRECISION controls memory vs. speed tradeoff for the 8B model:
#   float16 — half precision  (≥16 GB VRAM)
#   float32 — full precision  (CPU default; also works on GPU)
#   8bit    — quantised GPU   (≥8 GB VRAM; requires bitsandbytes)
#   4bit    — quantised GPU   (≥4 GB VRAM; requires bitsandbytes)
# ──────────────────────────────────────────────────────────────────────────────
COMPUTE_MODE="" GPU_TYPE="" PRECISION="float32" HSA_OVERRIDE=""

configure_compute() {
    hdr "Compute Mode — HuggingFace / sentence-transformers"
    echo ""
    echo -e "  ${BOLD}Device auto-detected at runtime (CUDA → ROCm → MPS → CPU).${NC}"
    echo -e "  ${BOLD}Choose the precision mode that fits your hardware:${NC}"
    echo ""
    echo "    [1]  CPU float32   — pure CPU inference; works everywhere; slowest"
    echo "                         Qwen3-Embedding-8B needs ≥32 GB RAM"
    echo "    [2]  GPU float16   — half precision; fastest GPU mode"
    echo "                         Needs ≥16 GB VRAM"
    echo "    [3]  GPU 8-bit     — quantised; balanced speed vs. memory"
    echo "                         Needs ≥8 GB VRAM; requires bitsandbytes"
    echo "    [4]  GPU 4-bit     — quantised; most memory-efficient"
    echo "                         Needs ≥4 GB VRAM; requires bitsandbytes"
    echo ""
    ask "Compute mode" "1"

    case "$REPLY" in
        1)
            COMPUTE_MODE="cpu"
            PRECISION="float32"
            ;;
        2)
            COMPUTE_MODE="gpu"
            PRECISION="float16"
            _ask_gpu_type
            ;;
        3)
            COMPUTE_MODE="gpu"
            PRECISION="8bit"
            _ask_gpu_type
            ;;
        4)
            COMPUTE_MODE="gpu"
            PRECISION="4bit"
            _ask_gpu_type
            ;;
        *)
            die "Invalid choice" ;;
    esac

    ok "Compute: ${COMPUTE_MODE} | Precision: ${PRECISION}"
}

_ask_gpu_type() {
    echo ""
    echo "    GPU type:"
    echo "      [1]  NVIDIA  (CUDA)"
    echo "      [2]  AMD     (ROCm / HIP)"
    ask "GPU type" "1"
    case "$REPLY" in
        1) GPU_TYPE="nvidia" ;;
        2)
            GPU_TYPE="amd"
            echo ""
            echo -e "  ${DIM}AMD RDNA3/RDNA4 (gfx1100/gfx1150) may need GFX version override${NC}"
            ask "HSA_OVERRIDE_GFX_VERSION (e.g. 11.0.0, blank to skip)" ""
            HSA_OVERRIDE="$REPLY"
            ;;
        *) die "Invalid GPU choice" ;;
    esac
}

# ── Worker Q&A ────────────────────────────────────────────────────────────────
NODE_NAME="" N8N_GET_URL="" N8N_SAVE_URL="" N8N_API_KEY="" N8N_STATUS_URL=""
HF_MODEL_NAME="" BATCH_SIZE=10 DELAY_SECONDS=5 STOP_AT="" STATUS_INTERVAL=10

configure_worker() {
    hdr "Worker Configuration"

    local default_node
    default_node="worker-$(hostname 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | head -c 20)"
    ask "Node name (unique per server)" "$default_node"
    NODE_NAME="$REPLY"

    echo ""
    echo -e "  ${BOLD}n8n Webhook URLs:${NC}"
    ask "  GET batch URL" \
        "https://n8n.3rfan.ir/webhook/4f1d52bf-25d5-4e0b-ab30-123f680d0265"
    N8N_GET_URL="$REPLY"

    ask "  SAVE vectors URL" \
        "https://n8n.3rfan.ir/webhook/4f1d52bf-25d5-4e0b-ab30-123f680d0255"
    N8N_SAVE_URL="$REPLY"

    ask "  API Key" "123"
    N8N_API_KEY="$REPLY"

    echo ""
    echo -e "  ${BOLD}Status reporting — optional heartbeat POST to n8n:${NC}"
    echo -e "  ${DIM}  Leave blank to disable${NC}"
    ask "  STATUS webhook URL" ""
    N8N_STATUS_URL="$REPLY"
    if [[ -n "$N8N_STATUS_URL" ]]; then
        ask "  Report status every N cycles" "10"
        STATUS_INTERVAL="$REPLY"
    fi

    echo ""
    ask "HuggingFace model name" "Qwen/Qwen3-Embedding-8B"
    HF_MODEL_NAME="$REPLY"

    # Suggest batch size based on compute mode
    local default_batch=10
    [[ "$COMPUTE_MODE" == "cpu" ]] && default_batch=2
    echo ""
    echo -e "  ${DIM}Recommended batch size: CPU=2–5  GPU=10–50${NC}"
    ask "Batch size" "$default_batch"
    BATCH_SIZE="$REPLY"

    ask "Delay between cycles (seconds)" "5"
    DELAY_SECONDS="$REPLY"

    echo ""
    echo -e "  ${BOLD}Auto-stop after duration (blank = run forever):${NC}"
    echo -e "  ${DIM}  Examples: 30m  |  8h  |  1d  |  1d-5h-30m${NC}"
    ask "  Stop after" ""
    STOP_AT="$REPLY"
}

# ── Write .env + patch compose file ───────────────────────────────────────────
write_config() {
    hdr "Writing Configuration"

    info "Worker directory: ${WORKER_DIR}"

    # Safety check — should never reach here without a valid worker dir,
    # but guard anyway so we don't write .env to a random folder.
    if [[ ! -f "${WORKER_DIR}/docker-compose.yml" ]]; then
        err "docker-compose.yml not found in ${WORKER_DIR}"
        err "Please make sure your embedding worker files are in that folder."
        err "Tip: copy docker-compose.yml, Dockerfile, worker.py, entrypoint.sh"
        err "     into ${WORKER_DIR}/ then re-run this installer."
        exit 1
    fi

    local restart_policy="on-failure"
    [[ -z "$STOP_AT" ]] && restart_policy="always"

    cat > "${WORKER_DIR}/.env" <<EOF
# Embedding Worker — generated by install.sh $(date '+%Y-%m-%d %H:%M:%S')

# ── Identity ──────────────────────────────────────────────────────────────────
NODE_NAME=${NODE_NAME}

# ── n8n Webhooks ──────────────────────────────────────────────────────────────
N8N_GET_URL=${N8N_GET_URL}
N8N_SAVE_URL=${N8N_SAVE_URL}
N8N_API_KEY=${N8N_API_KEY}
N8N_STATUS_URL=${N8N_STATUS_URL}
STATUS_INTERVAL=${STATUS_INTERVAL}

# ── Model (HuggingFace) ────────────────────────────────────────────────────────
HF_MODEL_NAME=${HF_MODEL_NAME}
HF_HOME=/root/.cache/huggingface

# ── Precision / compute ───────────────────────────────────────────────────────
# PRECISION: float16 | float32 | 8bit | 4bit
PRECISION=${PRECISION}
COMPUTE_MODE=${COMPUTE_MODE}
GPU_TYPE=${GPU_TYPE}
# AMD GPU compatibility override (leave blank for NVIDIA or pure CPU)
HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE}

# ── Batch / timing ────────────────────────────────────────────────────────────
BATCH_SIZE=${BATCH_SIZE}
DELAY_SECONDS=${DELAY_SECONDS}
STOP_AT=${STOP_AT}
REQUEST_TIMEOUT=30
RESTART_POLICY=${restart_policy}
EOF
    ok ".env written to ${WORKER_DIR}/.env"

    # Patch docker-compose.yml — add container_name so manage.sh can find it
    local compose_file="${WORKER_DIR}/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        if ! grep -q "container_name:" "$compose_file"; then
            # Insert container_name on the line after 'image:' or 'build:'
            sed -i '/^\s*\(image:\|build:\)/{
                /container_name/!{
                    i\    container_name: embedding-worker
                }
            }' "$compose_file" 2>/dev/null || true
            ok "docker-compose.yml: added container_name: embedding-worker"
        else
            ok "docker-compose.yml: container_name already set"
        fi
    else
        warn "docker-compose.yml not found in ${WORKER_DIR} — skipping patch"
    fi
}

# ── Build & start container ───────────────────────────────────────────────────
build_and_start() {
    hdr "Building & Starting Worker"
    cd "$WORKER_DIR"

    # Pick compose override for GPU
    local compose_args="-f docker-compose.yml"
    if [[ "$COMPUTE_MODE" != "cpu" ]]; then
        case "$GPU_TYPE" in
            nvidia) [[ -f docker-compose.nvidia.yml ]] && \
                    compose_args+=" -f docker-compose.nvidia.yml" ;;
            amd)    [[ -f docker-compose.amd.yml ]] && \
                    compose_args+=" -f docker-compose.amd.yml" ;;
        esac
    fi

    info "Building image (first run downloads model from HuggingFace — may take 10–30 min)..."
    if is_lxc || [[ "${DOCKER_BUILDKIT:-1}" == "0" ]]; then
        DOCKER_BUILDKIT=0 docker compose $compose_args build
    else
        docker compose $compose_args build
    fi

    info "Starting container..."
    docker compose $compose_args up -d

    sleep 4
    if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" \
            --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        ok "Container '${CONTAINER_NAME}' is running!"
        echo ""
        docker ps --filter "name=${CONTAINER_NAME}" \
            --format "  Name: {{.Names}}   Status: {{.Status}}"
    else
        warn "Container may still be starting up — check:"
        echo "    docker logs ${CONTAINER_NAME}"
    fi
}

# ── --raw mode: print manual install commands ─────────────────────────────────
print_raw_commands() {
    detect_os

    cat <<HEADER

==========================================================================
  RAW DOCKER INSTALL COMMANDS — ${DISTRO} ${VERSION}
  Run these manually if the automated installer fails.
  Source: https://docs.docker.com/engine/install/
==========================================================================

HEADER

    case "$OS" in
        debian) cat <<'CMDS'
# Step 1 — Remove old Docker packages
sudo apt-get remove -y docker docker-engine docker.io containerd runc

# Step 2 — Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Step 3 — Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Step 4 — Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Step 5 — Install Docker CE
sudo apt-get update
sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Step 6 — Start and enable
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker     # apply group without logout
CMDS
        ;;
        rhel) cat <<'CMDS'
# Step 1 — Remove old packages
sudo yum remove -y docker docker-client docker-common docker-engine

# Step 2 — Add repository
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

# Step 3 — Install Docker CE
sudo yum install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Step 4 — Start and enable
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
CMDS
        ;;
        fedora) cat <<'CMDS'
# Step 1 — Add repository
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo \
    https://download.docker.com/linux/fedora/docker-ce.repo

# Step 2 — Install Docker CE
sudo dnf install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Step 3 — Start and enable
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
CMDS
        ;;
        arch) cat <<'CMDS'
# Arch — Docker is in the official extra repository
sudo pacman -Sy --noconfirm docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
CMDS
        ;;
        suse) cat <<'CMDS'
# Step 1 — Add repository
sudo zypper addrepo \
    https://download.docker.com/linux/suse/docker-ce.repo
sudo zypper --gpg-auto-import-keys refresh

# Step 2 — Install Docker CE
sudo zypper install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Step 3 — Start and enable
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
CMDS
        ;;
        alpine) cat <<'CMDS'
# Alpine — Docker in official community repo
apk update
apk add --no-cache docker docker-compose curl bash
rc-update add docker default
service docker start
CMDS
        ;;
    esac

    cat <<'FOOTER'

==========================================================================
  After Docker is installed:
    cd /path/to/embedding_worker
    cp .env.example .env
    nano .env                          # fill in your settings
    docker compose build               # build image
    docker compose up -d               # start worker
    docker logs -f embedding-worker    # watch logs

  CPU management while running:
    bash manage.sh                     # interactive monitor
    bash manage.sh cpu 4 8h            # limit to 4 cores for 8h
==========================================================================
FOOTER
    exit 0
}

# ── Banner ─────────────────────────────────────────────────────────────────────
print_banner() {
    clear 2>/dev/null || true
    echo -e "${BOLD}${B}"
    cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║       EMBEDDING WORKER — Universal Linux Installer        ║
  ║       HuggingFace · sentence-transformers                 ║
  ║       Qwen/Qwen3-Embedding-8B  |  float16/8bit/4bit       ║
  ║                                                           ║
  ║  Supported: Ubuntu · Debian · CentOS · RHEL · Fedora      ║
  ║             Rocky · Alma · Arch · openSUSE · Alpine        ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "  ${DIM}Full install log: ${LOG_FILE}${NC}"
    echo -e "  ${DIM}Run with --raw to print manual Docker commands${NC}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    print_banner

    # --raw: just print commands and exit (detect OS first)
    $RAW_MODE && print_raw_commands

    detect_os
    check_network

    if ! $RECONFIG_MODE; then
        install_docker
    fi

    create_worker_files
    configure_compute
    configure_worker
    write_config
    build_and_start

    hdr "✓  Installation Complete"
    echo ""
    echo -e "  ${G}${BOLD}Worker '${CONTAINER_NAME}' is running!${NC}"
    echo ""
    echo -e "  ${BOLD}Quick commands:${NC}"
    echo "    docker logs -f ${CONTAINER_NAME}       ← live logs"
    echo "    docker ps                              ← container status"
    echo ""
    echo -e "  ${BOLD}CPU management (works while worker is running):${NC}"
    echo "    bash manage.sh                         ← interactive monitor & menu"
    echo "    bash manage.sh logs                    ← live log view + CPU controls"
    echo "    bash manage.sh cpu 4                   ← set 4 cores permanently"
    echo "    bash manage.sh cpu 4 8h                ← set 4 cores for 8 hours"
    echo "    bash manage.sh cpu max                 ← restore all cores"
    echo "    bash manage.sh cancel                  ← cancel scheduled revert"
    echo ""
    echo -e "  ${DIM}In log view: [+] add 1 core  [-] remove 1 core  [C] full CPU menu${NC}"
    echo ""
}

main "$@"
