# Embedding Worker

Distributed embedding system. Run this container on any server (CPU or GPU)
to embed news from your PostgreSQL database using Qwen3-Embedding:8b.

## Quick Download

**Download the complete project as ZIP:**
```
https://3rfan.com/files/worker.zip
```

Or clone with git:
```bash
git clone <your-repo-url>
cd embedding-worker
```

## Bootstrap install from GitHub

Run a single bootstrap script from GitHub to clone, install, and configure the worker:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theosophy88/worker-container/main/setup.sh)"
```

Or if you already have the repo locally:

```bash
./setup.sh install
./setup.sh update
./setup.sh remove
```

You can also override the install path:

```bash
WORKER_DIR=/opt/embedding-worker bash setup.sh install
```

## Architecture

```
[Server 1]              [Your server]           [PostgreSQL]
Docker container   →    n8n GET webhook   →    Claim batch (status = node_name)
  HuggingFace (model)   n8n SAVE webhook  →    Save vector + status = 'done'
  worker.py loop   ←────────────────────────── Return {id, description}
```

Multiple containers on different servers work in parallel safely —
`FOR UPDATE SKIP LOCKED` in PostgreSQL prevents duplicate processing.

## Status flow in news table

```
'pending'  →  '<node_name>'  →  'done' or 'AI-error'
   │               │                    │
   │          Worker claimed      Worker finished
   │          (in progress)       (vector saved)
   │
'pending' rows = what workers look for
'done' = successfully embedded
'AI-error' = embedding failed (needs retry)
```

**Per-record status** — Each record saved to n8n includes:
```json
{
  "id": 123,
  "vector": [...],
  "status": "done",         # or "AI-error" if embedding failed
  "node_name": "worker-1"
}
```

**Worker resilience**:
- Automatically retries n8n API calls (fetch & save) up to 3 times with 1-minute waits
- Tracks total embeddings in logs: `[STATS] Total: 100 embedded, 5 errors`
- Admin script parses stats to show actual totals (not "?")

## Setup

### Step 1 — Database migration

```bash
psql -U myuser -d mydb -f add_node_name.sql
```

### Step 2 — n8n workflows

1. Open n8n → **Workflows** → **Import from file**
2. Import `n8n_get_batch_workflow.json`
3. Import `n8n_save_vectors_workflow.json`
4. In each workflow:
   - Click the **Postgres** node → select your PostgreSQL credential
   - Replace `YOUR_POSTGRES_CREDENTIAL_ID` or just reconnect via UI
5. Add environment variable in n8n:
   - **Settings** → **Environment Variables** → add `EMBED_API_KEY` = a long random secret
6. **Activate** both workflows
7. Copy both webhook URLs

### Step 3 — Configure the worker

```bash
cp .env.example .env
nano .env   # fill in your values
```

Key variables:
```
NODE_NAME=worker-gpu-berlin-1       # unique per server
N8N_GET_URL=https://...             # from n8n webhook
N8N_SAVE_URL=https://...            # from n8n webhook
N8N_API_KEY=your-secret-key        # must match EMBED_API_KEY in n8n
BATCH_SIZE=10                       # records per cycle
DELAY_SECONDS=5                     # wait between cycles
STOP_AT=                            # empty = run forever
                                    # or: 2026-12-31 23:59:59
```

### Step 4 — Build and run

**CPU:**
```bash
docker compose build
docker compose up -d
```

**NVIDIA GPU:**
```bash
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d
```

**AMD GPU (ROCm):**
```bash
# Set HSA_OVERRIDE_GFX_VERSION in .env if needed (e.g. 11.0.0 for gfx1150)
docker compose -f docker-compose.yml -f docker-compose.amd.yml up -d
```

### Step 5 — Monitor

```bash
# Live logs
docker logs -f embedding-worker

# Check progress in DB
psql -U myuser -d mydb -c "
  SELECT
    node_name,
    status,
    COUNT(*) AS count
  FROM news
  GROUP BY node_name, status
  ORDER BY node_name, status;
"
```

## Uninstall

**Windows:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\uninstall.ps1
```

**Linux:**
```bash
bash uninstall.sh
```

Running either script will:
- stop and remove the Docker Compose stack
- force-stop and remove any remaining `embedding-worker` containers
- remove the `embedding-worker:latest` image
- delete generated `.env`
- optionally remove the host model cache at `/home/model`
- optionally remove the installed worker directory itself (the current repository/install path)

Manual removal steps (if you do not use the uninstall script):

**Windows:**
```powershell
cd C:\path\to\Worker
docker compose down --rmi all --volumes
docker image rm -f embedding-worker:latest
Remove-Item .env -Force
# optionally remove model cache if mounted on host
Remove-Item -Recurse -Force C:\path\to\host\model\cache
```

**Linux:**
```bash
cd /path/to/Worker
docker compose down --rmi all --volumes
docker image rm -f embedding-worker:latest
rm -f .env
# optionally remove model cache if mounted on host
rm -rf /home/model
```

## Admin Control — `admin.sh`

Unified script for all worker management. Use **interactively** or with **command-line arguments**.

### Interactive Menu (Recommended)
```bash
./admin.sh          # Opens interactive menu
```

Press keys to control:
- **[1]** Start/stop worker
- **[2]** Force kill
- **[3]** View logs
- **[4]** Restart
- **[M]** Live monitor (real-time logs + CPU controls)
- **[5]** Change CPU cores
- **[6]** Change batch size
- **[7]** Change cycle delay
- **[8]** Discard pending changes
- **[9]** View change history
- **[R]** Reinstall (full rebuild)
- **[Q]** Exit

### Live Monitor (Best for Watching Work)
```bash
./admin.sh monitor
```
Shows:
- Real-time logs (auto-refreshes every 5 seconds)
- Live CPU status bar + percentage
- Total embedded count + error count
- Uptime & scheduled tasks

**In monitor, press:**
- `[+]` / `[-]` → Adjust CPU by ±1 core instantly (no restart)
- `[C]` → Open full CPU menu
- `[X]` → Cancel scheduled CPU revert
- `[Q]` → Exit monitor

### Command-Line Usage (Scripting)
```bash
./admin.sh start                        # Start worker
./admin.sh stop                         # Graceful stop (finish current batch)
./admin.sh kill                         # Force stop immediately
./admin.sh log                          # Follow live logs
./admin.sh status                       # Show status panel and exit

# CPU control (uses cpuset-based core pinning)
./admin.sh cpu 4                        # Set to 4 cores permanently
./admin.sh cpu 4 8h                     # Set 4 cores, revert after 8 hours
./admin.sh cpu 4 1d-5h-30m              # Set 4 cores for 1 day 5 hours 30 min
./admin.sh cpu max                      # Remove all limits (use all cores)

# Configuration changes
./admin.sh batch 15                     # Set batch size to 15
./admin.sh batch 15                     # Set batch size to 15
./admin.sh delay 10                     # Set delay between cycles to 10 seconds

./admin.sh reinstall                    # Wipe Docker cache and rebuild

# Chain commands
./admin.sh start && ./admin.sh cpu 4 && ./admin.sh batch 20
```

### CPU Control Details

**Core Pinning (cpuset)** — New approach:
- `./admin.sh cpu 4` pins container to cores 0-3
- Much cleaner than CPU quota (uses actual cores)
- Removes limit with empty cpuset: `--cpuset-cpus=""`

**Reliability** — Auto-retry on API failure:
- If Docker API fails when reverting CPU, retries every 1 minute
- Ensures CPU revert completes even if Docker briefly unavailable
- Logs all attempts

**Temporary Limits** — Auto-revert after duration:
```bash
./admin.sh cpu 2 30m                    # 2 cores for 30 minutes
./admin.sh cpu 4 8h                     # 4 cores for 8 hours
./admin.sh cpu 6 1d-2h                  # 6 cores for 1 day 2 hours
```

### Status Display

`./admin.sh status` shows:
- **Total embedded** — cumulative count from startup (not "?")
- **Error count** — number of embedding failures
- **Status** — "done" or "AI-error" based on recent logs
- **CPU** — current cores / total cores (pinned or unlimited)
- **Uptime** — container runtime
- **Config** — batch size, delay, model
- **Pending changes** — queued settings to apply

---

## Running on multiple servers

On each server:
1. Copy this folder
2. Edit `.env` — set a **unique `NODE_NAME`** per server
3. Same `N8N_API_KEY` and webhook URLs on all servers
4. `docker compose up -d`
5. Use `./admin.sh` to monitor and control each worker

## Recovery — if a worker crashes mid-batch

Records claimed by a crashed worker stay with status = node_name.
Reset them back to pending:

```sql
-- Reset all in-progress records (not done, not pending, not AI-error)
UPDATE news
SET status = 'pending', node_name = NULL
WHERE status NOT IN ('pending', 'done', 'AI-error');

-- Or reset a specific dead node
UPDATE news
SET status = 'pending', node_name = NULL
WHERE status = 'worker-gpu-berlin-1';
```

## Project Structure

```
embedding-worker/
├── admin.sh                 # Main control script (all-in-one)
├── worker.py                # Python worker (embeds records, retries API)
├── entrypoint.sh            # Docker startup script
├── install.sh               # Linux installer
├── install.ps1              # Windows installer
├── Dockerfile               # Container definition
├── docker-compose.yml       # CPU/base configuration
├── docker-compose.nvidia.yml # GPU override
├── docker-compose.amd.yml   # AMD GPU override
├── .env.example             # Configuration template
├── README.md                # This file
└── lib/                     # Modular admin.sh libraries
    ├── colors.sh            # Color constants & output functions
    ├── docker.sh            # Docker detection & operations
    ├── env.sh               # Environment file management
    ├── state.sh             # State file definitions
    ├── cpu.sh               # CPU control (cpuset pinning + retry)
    ├── stats.sh             # Log parsing & statistics
    └── ui.sh                # Status display & UI functions
```

**Why modular?** Each `lib/*.sh` file has one responsibility, making it easier to:
- Debug specific functionality
- Reuse functions in other scripts
- Test individual components
- Maintain and extend features
