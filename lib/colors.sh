#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — Color & Output Functions
# =============================================================================

# ── Color definitions (auto-detect if terminal) ────────────────────────────────
if [[ -t 1 ]]; then
    R='\033[0;31m'      # Red
    G='\033[0;32m'      # Green
    Y='\033[1;33m'      # Yellow (bright)
    B='\033[0;34m'      # Blue
    C='\033[0;36m'      # Cyan
    BOLD='\033[1m'      # Bold
    DIM='\033[2m'       # Dim
    UP='\033[1A'        # Cursor up
    CLRLINE='\033[2K'   # Clear line
    NC='\033[0m'        # No color (reset)
else
    # No terminal — disable colors
    R='' G='' Y='' B='' C='' BOLD='' DIM='' UP='' CLRLINE='' NC=''
fi

# ── Output functions (indent + icon + color) ──────────────────────────────────

ok()   { echo -e "${G}  ✓  $*${NC}"; }
warn() { echo -e "${Y}  ⚠  $*${NC}"; }
err()  { echo -e "${R}  ✗  $*${NC}"; }
info() { echo -e "${C}  →  $*${NC}"; }
hdr()  { echo -e "\n${BOLD}${B}  $*${NC}"; }
