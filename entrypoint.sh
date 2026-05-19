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

# Use modularized version if available, otherwise fall back to legacy worker.py
if [[ -f "/app/run_worker.py" ]]; then
    exec python3 /app/run_worker.py
else
    exec python3 /app/worker.py
fi
