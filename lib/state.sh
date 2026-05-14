#!/usr/bin/env bash
# =============================================================================
#  Embedding Worker — State Files Management
# =============================================================================

# State files for pending/scheduled changes
PENDING_FILE="/tmp/.emb_pending"           # changes to apply after graceful stop
CPU_STATE_FILE="/tmp/.emb_cpu_state"       # active temporary CPU schedule
CPU_REVERT_PID="/tmp/.emb_cpu_revert.pid"  # background revert process PID
CHANGE_LOG="/tmp/.emb_changes.log"         # change history
CPU_LOG_FILE="/tmp/.emb_cpu_history.log"   # CPU change history
