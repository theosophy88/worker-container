#!/bin/bash
set -e

MODEL="${MODEL_NAME:-qwen3-embedding:8b}"

echo "========================================"
echo "  Embedding Worker Starting"
echo "  Node  : ${NODE_NAME:-worker}"
echo "  Model : $MODEL"
echo "========================================"

# Start Ollama server in background
ollama serve &
OLLAMA_PID=$!

# Wait for Ollama to be ready
echo "[startup] Waiting for Ollama to be ready..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "[startup] Ollama is ready"
        break
    fi
    sleep 2
done

# Pull model if not already present
echo "[startup] Pulling model: $MODEL"
ollama pull "$MODEL"
echo "[startup] Model ready"

# Start Python worker
echo "[startup] Starting embedding worker..."
exec python3 /app/worker.py

# Cleanup on exit
trap "kill $OLLAMA_PID 2>/dev/null" EXIT
