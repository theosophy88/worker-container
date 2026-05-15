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
