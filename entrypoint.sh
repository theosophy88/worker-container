#!/bin/bash
set -e

HF_MODEL="${HF_MODEL_NAME:-Qwen/Qwen3-Embedding-8B}"
PRECISION="${PRECISION:-float16}"
COMPUTE_MODE="${COMPUTE_MODE:-cpu}"

echo "========================================"
echo "  Embedding Worker Starting"
echo "  Node     : ${NODE_NAME:-worker}"
echo "  Model    : $HF_MODEL"
echo "  Precision: $PRECISION"
echo "  Compute  : $COMPUTE_MODE"
echo "========================================"

# ── Pre-flight memory check ───────────────────────────────────────────────────
# GPU: warn if VRAM appears low (best-effort via nvidia-smi / rocm-smi)
# CPU: warn if RAM < 18 GB (16 GB model + OS overhead)
_MIN_GPU_MB=16000
_MIN_CPU_MB=18000

if [[ "$COMPUTE_MODE" == "nvidia" ]] && command -v nvidia-smi &>/dev/null; then
    _vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "")
    if [[ -n "$_vram_mb" ]] && [[ "$_vram_mb" =~ ^[0-9]+$ ]]; then
        if [[ "$_vram_mb" -lt "$_MIN_GPU_MB" ]]; then
            echo "WARNING: GPU VRAM ${_vram_mb}MB < ${_MIN_GPU_MB}MB minimum for float16"
            echo "WARNING: Model may OOM. Minimum 16GB VRAM required."
        else
            echo "[preflight] GPU VRAM: ${_vram_mb}MB  OK"
        fi
    fi
elif [[ "$COMPUTE_MODE" == "amd" ]] && command -v rocm-smi &>/dev/null; then
    echo "[preflight] AMD GPU detected — VRAM check skipped (use rocm-smi manually to verify >=16GB)"
elif [[ "$COMPUTE_MODE" == "cpu" ]]; then
    _ram_mb=$(awk '/MemTotal/ { printf "%.0f", $2/1024 }' /proc/meminfo 2>/dev/null || echo "")
    if [[ -n "$_ram_mb" ]] && [[ "$_ram_mb" =~ ^[0-9]+$ ]]; then
        if [[ "$_ram_mb" -lt "$_MIN_CPU_MB" ]]; then
            echo "WARNING: System RAM ${_ram_mb}MB < ${_MIN_CPU_MB}MB minimum for CPU float16"
            echo "WARNING: Requires ~16GB for the model plus OS overhead."
            echo "WARNING: Worker may OOM. Consider a machine with >=18GB RAM."
        else
            echo "[preflight] System RAM: ${_ram_mb}MB  OK"
        fi
    fi
fi

echo "[startup] Starting embedding worker..."

# Use modularized version if available, otherwise fall back to legacy worker.py
if [[ -f "/app/run_worker.py" ]]; then
    exec python3 /app/run_worker.py
else
    exec python3 /app/worker.py
fi
