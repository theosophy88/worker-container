# Embedding Worker — Skill Reference

Distributed Docker embedding worker. Fetches news records from n8n, generates
vector embeddings with a local HuggingFace model, and writes vectors back to
PostgreSQL via n8n — all without exposing the DB directly.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Docker container (any server)                               │
│                                                              │
│  entrypoint.sh                                               │
│    └─ python3 worker.py                                      │
│         ├─ detect_device()   CUDA → ROCm → MPS → CPU         │
│         ├─ load_model()      HuggingFace sentence-transformers│
│         └─ main loop                                         │
│              ├─ POST  N8N_GET_URL   → fetch batch            │
│              ├─ model.encode()      → embed locally          │
│              ├─ POST  N8N_SAVE_URL  → save vectors           │
│              └─ POST  N8N_STATUS_URL (every N cycles)        │
└──────────────────────────────────────────────────────────────┘
         ↕  X-API-Key header on all calls
┌─────────────────┐        ┌──────────────────────────┐
│   n8n webhooks  │ ──────▶│  PostgreSQL               │
│  GET  / SAVE    │        │  news.status:             │
│  STATUS         │        │   pending → node_name     │
└─────────────────┘        │            → done/AI-error│
                           └──────────────────────────┘
```

Concurrent safety: the GET webhook uses `FOR UPDATE SKIP LOCKED` so multiple
workers on different servers never claim the same record.

---

## Environment Variables

### Required

| Variable | Description |
|---|---|
| `NODE_NAME` | Unique label for this worker (written to each DB row) |
| `N8N_GET_URL` | Webhook that returns `{"records": [{id, description}]}` |
| `N8N_SAVE_URL` | Webhook that accepts `{"vectors": [{id, vector, status, node_name}]}` |
| `N8N_API_KEY` | Sent as `X-API-Key` on every request |

### Model

| Variable | Default | Description |
|---|---|---|
| `HF_MODEL_NAME` | `Qwen/Qwen3-Embedding-8B` | Any sentence-transformers-compatible HuggingFace model |
| `HF_HOME` | `/root/.cache/huggingface` | Cache directory — map to a persistent volume |
| `PRECISION` | `float16` | `float16` / `float32` / `8bit` / `4bit` |

### Batch & Timing

| Variable | Default | Description |
|---|---|---|
| `BATCH_SIZE` | `10` | Records per cycle |
| `DELAY_SECONDS` | `5` | Sleep between cycles (seconds) |
| `STOP_AT` | _(empty)_ | Auto-stop duration: `30m`, `8h`, `1d`, `1d-5h-30m` |
| `REQUEST_TIMEOUT` | `30` | HTTP timeout for n8n calls (seconds) |

### Heartbeat / Status

| Variable | Default | Description |
|---|---|---|
| `N8N_STATUS_URL` | `https://n8n.example.com/webhook/worker-status` | Optional webhook to receive status POSTs. A default placeholder is shown in setup; type `none` to disable. |
| `STATUS_INTERVAL` | `10` | POST status every N cycles |

Status POST body:
```json
{
  "node_name": "worker-gpu-1",
  "status": "running",
  "cycles": 40,
  "batch_size": 10,
  "delay_seconds": 5,
  "articles_fetched": 420,
  "articles_embedded": 380,
  "articles_errors": 5,
  "device": "cuda",
  "model_name": "Qwen/Qwen3-Embedding-8B",
  "server_host": "worker-01",
  "server_lan_ip": "192.168.1.20",
  "server_os": "Linux",
  "server_platform": "Linux-5.15.0-xyz-x86_64-with-glibc2.31",
  "session_started_at": "2026-05-19T12:00:00+00:00",
  "session_uptime_seconds": 1234,
  "stop_time": null,
  "status_interval": 10,
  "next_status_in_seconds": 50,
  "next_status_at": "2026-05-19T12:03:00+00:00",
  "avg_embeddings_per_hour": 18.4,
  "avg_embeddings_per_minute": 0.31,
  "embeddings_last_hour": 14,
  "embeddings_last_hour_per_minute": 0.23,
  "cores_logical": 16,
  "cores_physical": 8,
  "cores_allowed": 8,
  "cores_active": 8,
  "cpu_percent": 12.5,
  "load_average_1m": 0.40,
  "load_average_5m": 0.60,
  "load_average_15m": 0.50,
  "memory_total_bytes": 17179869184,
  "memory_available_bytes": 7450000000,
  "memory_used_percent": 56.7
}
```
On clean exit (SIGTERM, SIGINT, or STOP_AT reached) a final POST is sent with
`"status": "stopped"`.

---

## Precision Modes

| PRECISION | Memory | Speed | Notes |
|---|---|---|---|
| `float32` | ~32 GB RAM or VRAM | slowest | Safe default for CPU |
| `float16` | ~16 GB VRAM | fast | Recommended for GPU |
| `8bit` | ~8 GB VRAM | moderate | Requires `bitsandbytes` |
| `4bit` | ~4 GB VRAM | moderate | Requires `bitsandbytes` |

8-bit and 4-bit are silently downgraded to `float32` if no GPU is detected.

---

## Device Detection Order

`detect_device()` runs at startup and picks:
1. **CUDA** — NVIDIA GPU (also covers AMD ROCm when using ROCm-enabled PyTorch)
2. **MPS** — Apple Silicon
3. **CPU** — fallback

The selected device is logged at startup and included in every status POST.

---

## File Structure

```
Worker/
├── Dockerfile                  python:3.11-slim + torch + sentence-transformers
├── entrypoint.sh               prints banner, execs worker.py
├── worker.py                   main loop
├── docker-compose.yml          base compose (CPU or CUDA)
├── docker-compose.nvidia.yml   overlay — adds NVIDIA GPU reservation
├── docker-compose.amd.yml      overlay — adds ROCm /dev mounts + HSA env
├── install.sh                  Linux guided installer
├── install.ps1                 Windows guided installer
├── admin.sh                    interactive admin (logs, CPU pinning, stats)
└── lib/
    ├── colors.sh   ui helpers
    ├── cpu.sh      cpuset core pinning with auto-revert
    ├── docker.sh   container detection
    ├── env.sh      .env read/write helpers
    ├── state.sh    temp file paths
    ├── stats.sh    log parsing for embedded/error counts
    └── ui.sh       status panel renderer
```

---

## docker-compose Usage

```bash
# CPU only
docker compose up -d

# NVIDIA GPU
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d

# AMD GPU (ROCm)
docker compose -f docker-compose.yml -f docker-compose.amd.yml up -d
```

Model is cached at `/home/model` on the host (mapped to `HF_HOME` inside the
container). Subsequent restarts skip the download.

---

## .env Reference

Generated by `install.sh` / `install.ps1`. Minimal example:

```env
NODE_NAME=worker-gpu-1

N8N_GET_URL=https://n8n.example.com/webhook/get-batch
N8N_SAVE_URL=https://n8n.example.com/webhook/save-vectors
N8N_API_KEY=secret
N8N_STATUS_URL=https://n8n.example.com/webhook/worker-status
STATUS_INTERVAL=10

HF_MODEL_NAME=Qwen/Qwen3-Embedding-8B
HF_HOME=/root/.cache/huggingface
PRECISION=float16
COMPUTE_MODE=gpu
GPU_TYPE=nvidia

BATCH_SIZE=10
DELAY_SECONDS=5
STOP_AT=
REQUEST_TIMEOUT=30
RESTART_POLICY=always
```

---

## Installation

### Linux (all distros)
```bash
curl -fsSL https://raw.githubusercontent.com/your-org/worker/main/install.sh | bash
# or
bash install.sh               # guided
bash install.sh --reconfigure # skip Docker install, re-run config only
bash install.sh --raw         # print manual Docker commands
```

### Windows (PowerShell as Administrator)
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
# or
.\install.ps1 -Reconfigure
.\install.ps1 -Raw
```

---

## Admin Commands (Linux)

```bash
bash admin.sh                  # interactive monitor
bash admin.sh logs             # live logs + CPU controls
bash admin.sh cpu 4            # pin to 4 cores permanently
bash admin.sh cpu 4 8h         # pin to 4 cores for 8 hours, then revert
bash admin.sh cpu max          # remove core limit
bash admin.sh cancel           # cancel scheduled revert
```

In log view: `[+]` add 1 core · `[-]` remove 1 core · `[C]` full CPU menu.

### Windows CPU limiting
```powershell
docker update --cpus=4 embedding-worker    # limit to 4 cores
docker update --cpu-quota=-1 embedding-worker  # remove limit
```

---

## Restart Policy

| Condition | `RESTART_POLICY` |
|---|---|
| `STOP_AT` is empty (run forever) | `always` |
| `STOP_AT` is set | `on-failure` (exits 0 on clean stop, no restart) |

---

## Multi-Server Deployment

Deploy the same compose stack on as many servers as needed. Give each a unique
`NODE_NAME`. The GET webhook's `FOR UPDATE SKIP LOCKED` guarantees no two
workers process the same record simultaneously.

---

## Error Handling

- Empty `description` → skipped, status set to `AI-error`
- Embed failure → status set to `AI-error`, logged, worker continues
- n8n GET/SAVE errors → 3 retries with 1-minute waits, then skip cycle
- Status POST errors → logged as warning, worker continues (non-fatal)
- SIGTERM / SIGINT → finishes current batch, posts `stopped` status, exits 0

---

## Changelog

### v2 — HuggingFace edition
- Replaced Ollama + llama.cpp with HuggingFace `sentence-transformers`
- Auto-detect device: CUDA → ROCm → MPS → CPU
- Added `PRECISION` env var (`float16` / `float32` / `8bit` / `4bit`)
- Added `HF_MODEL_NAME` env var (default `Qwen/Qwen3-Embedding-8B`)
- Model cached in persistent volume via `HF_HOME`
- Added `N8N_STATUS_URL` + `STATUS_INTERVAL` heartbeat reporting
- Final `"status": "stopped"` POST on clean exit
- Dockerfile base changed to `python:3.11-slim`

### v1 — Ollama edition (removed)
- Legacy: Ollama + llama.cpp backend. This project no longer ships or
  configures Ollama; the current codebase uses HuggingFace `sentence-transformers`.
