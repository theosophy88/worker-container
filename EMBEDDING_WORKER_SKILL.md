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
│  entrypoint.sh  (pre-flight memory check)                    │
│    └─ python3 run_worker.py                                  │
│         ├─ detect_device()   CUDA → ROCm → MPS → CPU         │
│         ├─ load_model()      HuggingFace sentence-transformers│
│         │    padding_side=left, normalize_embeddings=True     │
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

## Embedding Standard

| Property | Value |
|---|---|
| Model | `Qwen/Qwen3-Embedding-8B` (HuggingFace, sentence-transformers) |
| Precision | `float16` everywhere |
| `normalize_embeddings` | `True` always |
| `padding_side` | `left` (required for Qwen3) |
| Device detection | CUDA → ROCm (MPS) → CPU |
| Quantization | None — bitsandbytes removed |

---

## Hardware Minimum Requirements

| Mode | Minimum |
|---|---|
| GPU (NVIDIA or AMD) | 16 GB VRAM |
| CPU | 18 GB RAM (16 GB model + OS overhead) |

The entrypoint performs a pre-flight check and warns if available memory is below
the threshold before loading the model.

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
| `HF_MODEL_NAME` | `Qwen/Qwen3-Embedding-8B` | sentence-transformers-compatible HuggingFace model |
| `HF_HOME` | `/root/.cache/huggingface` | Cache directory — map to a persistent volume |
| `PRECISION` | `float16` | `float16` (default) or `float32` (CPU fallback) |
| `HF_AUTH_TOKEN` | _(empty)_ | HuggingFace API token for gated models |
| `HF_MODEL_URL` | _(empty)_ | URL to a `.zip` or `.tar.gz` model archive |
| `HF_MODEL_LOCAL_PATH` | _(empty)_ | Path to a model directory already on disk |

### Compute

| Variable | Default | Description |
|---|---|---|
| `COMPUTE_MODE` | `cpu` | `cpu` / `nvidia` / `amd` — set by installer, do not change manually |
| `GPU_TYPE` | _(empty)_ | Mirror of COMPUTE_MODE for backward compat |
| `HSA_OVERRIDE_GFX_VERSION` | _(empty)_ | AMD ROCm GFX override (e.g. `11.0.0` for RDNA4) |

> **Warning:** Switching `COMPUTE_MODE` requires a full reinstall — the Docker
> image must be rebuilt from the matching Dockerfile. Run `install.sh` again.

### Batch & Timing

| Variable | Default | Description |
|---|---|---|
| `BATCH_SIZE` | `10` | Records per cycle (CPU: 2–5, GPU: 10–50) |
| `DELAY_SECONDS` | `5` | Sleep between cycles (seconds) |
| `STOP_AT` | _(empty)_ | Auto-stop duration: `30m`, `8h`, `1d`, `1d-5h-30m` |
| `REQUEST_TIMEOUT` | `30` | HTTP timeout for n8n calls (seconds) |

### Heartbeat / Status

| Variable | Default | Description |
|---|---|---|
| `N8N_STATUS_URL` | _(empty)_ | Optional webhook to receive status POSTs |
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
  "session_started_at": "2026-05-19T12:00:00+00:00",
  "session_uptime_seconds": 1234,
  "avg_embeddings_per_hour": 18.4,
  "memory_total_bytes": 17179869184,
  "memory_used_percent": 56.7
}
```
On clean exit (SIGTERM, SIGINT, or STOP_AT reached) a final POST is sent with
`"status": "stopped"`.

---

## Precision Modes

| PRECISION | Memory | Notes |
|---|---|---|
| `float16` | ~16 GB VRAM / ~18 GB RAM | **Default. Required for GPU.** |
| `float32` | ~32 GB RAM | CPU fallback only — use when float16 OOMs on CPU |

> **Removed:** `8bit` and `4bit` are no longer supported. `bitsandbytes` has been
> removed from this project entirely — it was unreliable on AMD ROCm and silently
> fell back to float32 on CPU, providing no benefit.

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
├── Dockerfile              CPU version (default for docker build .)
├── Dockerfile.cpu          CPU-only — plain torch from PyPI
├── Dockerfile.nvidia       NVIDIA — torch cu121 wheel
├── Dockerfile.amd          AMD    — torch rocm6.1 wheel
├── docker-compose.yml      Base / CPU compose
├── docker-compose.nvidia.yml  NVIDIA GPU overlay
├── docker-compose.amd.yml     AMD GPU overlay (numeric GIDs)
├── entrypoint.sh           Banner + pre-flight memory check + exec worker
├── run_worker.py           Modular entry point (preferred)
├── worker.py               Legacy monolithic entry point (fallback)
├── .env.example            Config template
├── install.sh              Linux guided installer
├── install.ps1             Windows guided installer
├── admin.sh                Interactive admin (logs, CPU pinning for CPU mode, stats)
└── src/worker/
    ├── config.py           All environment variable loading
    ├── worker_main.py      Main loop
    ├── embedding.py        Embedding operations
    ├── model.py            Model loading and memory check
    ├── n8n_api.py          n8n webhook calls
    ├── shutdown.py         Signal handling
    └── utils/
        ├── duration.py     Duration string parsing
        └── system.py       Device / memory / CPU detection
```

---

## docker-compose Usage

```bash
# CPU only (uses Dockerfile.cpu)
docker compose up -d

# NVIDIA GPU (uses Dockerfile.nvidia)
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d

# AMD GPU / ROCm (uses Dockerfile.amd)
docker compose -f docker-compose.yml -f docker-compose.amd.yml up -d
```

Model is cached at `/home/model` on the host (mapped to `HF_HOME` inside the
container). Subsequent restarts skip the download.

> **Note:** `docker-compose.amd.yml` uses numeric GIDs for `group_add` (the
> `render` and `video` groups don't exist inside `python:3.11-slim`). The
> installer detects and writes the correct GIDs at install time.

---

## AppArmor / LXC (Proxmox)

On Proxmox LXC containers, AppArmor blocks Docker builds. The installer
automatically writes `/etc/docker/daemon.json`:

```json
{
  "no-new-privileges": false,
  "seccomp-profile": "unconfined",
  "features": { "buildkit": false }
}
```

You must also configure the LXC container on the **Proxmox host**:
```
# /etc/pve/lxc/<CTID>.conf
lxc.apparmor.profile: unconfined
lxc.cap.drop:
```

All compose files include `security_opt: [apparmor:unconfined, seccomp:unconfined]`
which is harmless on non-LXC systems.

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
COMPUTE_MODE=nvidia
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
bash install.sh               # guided (asks CPU / NVIDIA / AMD)
bash install.sh --reconfigure # skip Docker install, re-run config only
bash install.sh --raw         # print manual Docker commands
```

### Windows (PowerShell as Administrator)
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

---

## Admin Commands (Linux)

```bash
bash admin.sh                  # interactive menu (CPU controls shown only in CPU mode)
bash admin.sh log              # live logs
bash admin.sh status           # show status panel and exit
bash admin.sh monitor          # live monitor with real-time stats

# CPU mode only:
bash admin.sh cpu 4            # pin to 4 cores permanently
bash admin.sh cpu 4 8h         # pin to 4 cores for 8 hours, then revert
bash admin.sh cpu max          # remove core limit
```

In CPU monitor view: `[+]` add 1 core · `[-]` remove 1 core · `[C]` full CPU menu.
CPU core controls are **hidden** in GPU mode (`COMPUTE_MODE=nvidia` or `amd`).

### Windows CPU limiting
```powershell
docker update --cpus=4 embedding-worker    # limit to 4 cores
docker update --cpu-quota=-1 embedding-worker  # remove limit
```

---

## Switching Compute Modes

Switching between CPU and GPU modes (or between NVIDIA and AMD) requires a full
reinstall — the Docker image must be rebuilt from scratch using the correct
Dockerfile and PyTorch wheel.

```bash
# Re-run the installer to switch modes:
bash install.sh
# Select the new compute type when prompted.
# The installer will rebuild the Docker image from scratch.
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

Mix CPU and GPU workers freely — each server selects the right Dockerfile at
install time.

---

## Error Handling

- Empty `description` → skipped, status set to `AI-error`
- Embed failure → status set to `AI-error`, logged, worker continues
- n8n GET/SAVE errors → 3 retries with 1-minute waits, then skip cycle
- Status POST errors → logged as warning, worker continues (non-fatal)
- SIGTERM / SIGINT → finishes current batch, posts `stopped` status, exits 0

---

## Changelog

### v3 — GPU-aware edition
- Three separate Dockerfiles: `Dockerfile.cpu` / `Dockerfile.nvidia` / `Dockerfile.amd`
- PyTorch installed BEFORE sentence-transformers in all Dockerfiles (prevents CPU wheel overwrite)
- `docker-compose.amd.yml` uses numeric GIDs for `group_add` (installer detects at install time)
- AppArmor/LXC fix: `/etc/docker/daemon.json` + `security_opt` in compose, Proxmox instructions
- Removed `bitsandbytes` entirely — only `float16` and `float32` supported
- Fixed `build:` syntax in all compose files (`context: .` + `dockerfile:` keys)
- `admin.sh`: CPU core pinning hidden/disabled when `COMPUTE_MODE != cpu`
- `entrypoint.sh`: pre-flight RAM/VRAM check before model load
- `install.sh`: three compute-type choices (cpu / nvidia / amd); AMD GID detection; mode-switch warning
- `.env.example` added

### v2 — HuggingFace edition
- Replaced Ollama + llama.cpp with HuggingFace `sentence-transformers`
- Auto-detect device: CUDA → ROCm → MPS → CPU
- Added `PRECISION` env var (`float16` / `float32`)
- Added `HF_MODEL_NAME` env var (default `Qwen/Qwen3-Embedding-8B`)
- Model cached in persistent volume via `HF_HOME`
- Added `N8N_STATUS_URL` + `STATUS_INTERVAL` heartbeat reporting
- Final `"status": "stopped"` POST on clean exit
- Dockerfile base changed to `python:3.11-slim`

### v1 — Ollama edition (removed)
- Legacy: Ollama + llama.cpp backend. No longer shipped.
