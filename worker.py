"""
Embedding Worker
================
Loops forever (or until stop duration):
  1. Calls n8n GET webhook  → receives batch of {id, description}
  2. Embeds each description via local HuggingFace sentence-transformers model
  3. Calls n8n POST webhook → saves vectors back to DB
  4. Sleeps for DELAY_SECONDS
  5. Repeat

STOP_AT format examples:
  30m          → stop after 30 minutes
  5h           → stop after 5 hours
  1d           → stop after 1 day (24 hours)
  1d-5h        → stop after 29 hours
  1d-5h-30m    → stop after 29 hours 30 minutes
  (empty)      → run forever until manually stopped

All config via environment variables (see .env.example).
"""

import os
import sys
import re
import time
import json
import socket
import platform
import logging
import signal
from datetime import datetime, timedelta, timezone
from collections import deque

import requests

# ── Global statistics ─────────────────────────────────────────────────────────
total_embedded = 0
total_errors   = 0
total_fetched  = 0
_start_time    = time.time()
embed_history  = deque()
_shutdown      = False
_stopping_status_sent = False

# ── Config from environment ───────────────────────────────────────────────────

def require_env(key: str) -> str:
    val = os.getenv(key)
    if not val:
        print(f"ERROR: Environment variable '{key}' is required but not set.")
        sys.exit(1)
    return val

N8N_GET_URL     = require_env("N8N_GET_URL")
N8N_SAVE_URL    = require_env("N8N_SAVE_URL")
N8N_API_KEY     = require_env("N8N_API_KEY")
NODE_NAME       = require_env("NODE_NAME")

HF_MODEL_NAME   = os.getenv("HF_MODEL_NAME",   "Qwen/Qwen3-Embedding-8B")
PRECISION       = os.getenv("PRECISION",        "float16").strip().lower()
BATCH_SIZE      = int(os.getenv("BATCH_SIZE",      "10"))
DELAY_SECONDS   = float(os.getenv("DELAY_SECONDS",   "5"))
STOP_AT         = os.getenv("STOP_AT", "").strip()
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "30"))

N8N_STATUS_URL  = os.getenv("N8N_STATUS_URL",  "").strip()
STATUS_INTERVAL = int(os.getenv("STATUS_INTERVAL", "10"))
HF_AUTH_TOKEN   = os.getenv("HF_AUTH_TOKEN", "").strip()
HF_MODEL_URL    = os.getenv("HF_MODEL_URL", "").strip()
HF_MODEL_LOCAL_PATH = os.getenv("HF_MODEL_LOCAL_PATH", "").strip()

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("worker")

# ── Graceful shutdown ─────────────────────────────────────────────────────────

_shutdown = False

def handle_signal(sig, frame):
    global _shutdown
    log.info(f"Signal {sig} received — shutting down after current batch...")
    _shutdown = True

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT,  handle_signal)

# ── Duration parser ───────────────────────────────────────────────────────────

def parse_duration(raw: str) -> timedelta | None:
    """
    Parse a human duration string into a timedelta.

    Supported format: parts separated by '-'
      Nd   → N days
      Nh   → N hours
      Nm   → N minutes

    Examples:
      "30m"        → timedelta(minutes=30)
      "5h"         → timedelta(hours=5)
      "1d"         → timedelta(days=1)
      "1d-5h"      → timedelta(days=1, hours=5)
      "1d-5h-30m"  → timedelta(days=1, hours=5, minutes=30)
      "2h-45m"     → timedelta(hours=2, minutes=45)
      ""            → None  (run forever)
    """
    raw = raw.strip()
    if not raw:
        return None

    pattern = re.compile(r'^(\d+)(d|h|m)$', re.IGNORECASE)
    parts   = [p.strip() for p in raw.split('-')]

    days = hours = minutes = 0
    for part in parts:
        m = pattern.match(part)
        if not m:
            log.error(
                f"Invalid STOP_AT part: '{part}'\n"
                f"  Expected format: 30m | 5h | 1d | 1d-5h | 1d-5h-30m"
            )
            sys.exit(1)
        value = int(m.group(1))
        unit  = m.group(2).lower()
        if unit == 'd':
            days    += value
        elif unit == 'h':
            hours   += value
        elif unit == 'm':
            minutes += value

    total = timedelta(days=days, hours=hours, minutes=minutes)
    if total.total_seconds() <= 0:
        log.error("STOP_AT duration must be greater than zero.")
        sys.exit(1)

    return total

def calc_stop_time(raw: str) -> datetime | None:
    """
    Convert a duration string to an absolute UTC stop datetime
    anchored to right now (start time).
    Returns None if raw is empty (run forever).
    """
    duration = parse_duration(raw)
    if duration is None:
        return None
    return datetime.now(timezone.utc) + duration

def format_duration(td: timedelta) -> str:
    """Format a timedelta as a human-readable string."""
    total_seconds = int(td.total_seconds())
    days    = total_seconds // 86400
    hours   = (total_seconds % 86400) // 3600
    minutes = (total_seconds % 3600)  // 60
    parts = []
    if days:    parts.append(f"{days}d")
    if hours:   parts.append(f"{hours}h")
    if minutes: parts.append(f"{minutes}m")
    return "-".join(parts) if parts else "0m"

def should_stop(stop_at: datetime | None) -> bool:
    if _shutdown:
        return True
    if stop_at and datetime.now(timezone.utc) >= stop_at:
        log.info("Stop time reached. Shutting down.")
        return True
    return False

# ── Device detection ──────────────────────────────────────────────────────────

def detect_device() -> str:
    """Auto-detect best available device: CUDA/ROCm → MPS → CPU."""
    import torch
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        log.info(f"GPU detected: {name}")
        return "cuda"
    try:
        if torch.backends.mps.is_available():
            log.info("Apple MPS device detected")
            return "mps"
    except AttributeError:
        pass
    log.info("No GPU detected — using CPU")
    return "cpu"


def get_cpu_info() -> dict:
    """Return CPU and load statistics for the host and current process."""
    total_logical = os.cpu_count() or 1
    total_physical = None
    active = total_logical
    cpu_percent = None
    load_average = {"1m": None, "5m": None, "15m": None}

    try:
        import psutil
        total_logical = psutil.cpu_count(logical=True) or total_logical
        total_physical = psutil.cpu_count(logical=False) or total_logical
        process = psutil.Process(os.getpid())
        try:
            affinity = process.cpu_affinity()
            active = len(affinity)
        except Exception:
            active = total_logical
        cpu_percent = psutil.cpu_percent(interval=None)
    except Exception:
        total_physical = total_logical

    try:
        if hasattr(os, "getloadavg"):
            one, five, fifteen = os.getloadavg()
            load_average = {
                "1m": round(one, 2),
                "5m": round(five, 2),
                "15m": round(fifteen, 2),
            }
    except Exception:
        pass

    return {
        "cores_logical": total_logical,
        "cores_physical": total_physical,
        "cores_allowed": active,
        "cores_active": active,
        "cpu_percent": cpu_percent,
        "load_average_1m": load_average["1m"],
        "load_average_5m": load_average["5m"],
        "load_average_15m": load_average["15m"],
    }


def get_memory_info() -> dict:
    """Return system memory statistics if available."""
    memory = {
        "total_bytes": None,
        "available_bytes": None,
        "used_percent": None,
    }
    try:
        import psutil
        vm = psutil.virtual_memory()
        memory = {
            "total_bytes": vm.total,
            "available_bytes": vm.available,
            "used_percent": round(vm.percent, 2),
        }
    except Exception:
        pass
    return memory


def get_server_info() -> dict:
    """Return host name, LAN IP, and operating system information."""
    hostname = socket.gethostname()
    lan_ip = None

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            lan_ip = s.getsockname()[0]
    except Exception:
        pass

    if not lan_ip or lan_ip.startswith("127."):
        try:
            lan_ip = socket.gethostbyname(hostname)
        except Exception:
            pass

    return {
        "hostname": hostname,
        "lan_ip": lan_ip,
        "os": platform.system(),
        "platform": platform.platform(),
    }


def prune_embed_history(window: timedelta) -> int:
    """Keep only embedding events within `window` and return the count."""
    now = datetime.now(timezone.utc)
    cutoff = now - window
    while embed_history and embed_history[0][0] < cutoff:
        embed_history.popleft()
    return sum(count for _, count in embed_history)


def check_memory_requirements(device: str) -> None:
    """Ensure minimum memory for float16 mode (16 GB RAM/VRAM).

    Exits the process with an error if the requirement is not met when
    `PRECISION` is `float16`. For GPUs we inspect CUDA properties; for CPU
    we use `psutil` when available.
    """
    if PRECISION != "float16":
        return

    min_bytes = 16 * 1024 ** 3

    import torch

    if device == "cuda":
        try:
            props = torch.cuda.get_device_properties(0)
            total = getattr(props, 'total_memory', None)
            if total is not None and total < min_bytes:
                log.error(f"GPU memory {total // (1024**3)}GB < required 16GB for float16")
                sys.exit(1)
        except Exception as e:
            log.warning(f"Could not detect CUDA memory: {e} — ensure >=16GB VRAM for float16")
    elif device == "mps":
        log.warning("Unable to programmatically detect MPS device memory — ensure >=16GB for float16")
    else:  # cpu
        try:
            import psutil
            total = psutil.virtual_memory().total
            if total < min_bytes:
                log.error(f"System RAM {total // (1024**3)}GB < required 16GB for float16 on CPU")
                sys.exit(1)
        except Exception:
            log.error("psutil not installed; cannot verify system RAM. Install psutil or set PRECISION=float32")
            sys.exit(1)

# ── Model loading ─────────────────────────────────────────────────────────────

def load_model(device: str):
    """Load the sentence-transformers model with the configured precision."""
    import torch
    from sentence_transformers import SentenceTransformer

    model_kwargs: dict = {}

    if PRECISION == "float16":
        model_kwargs["torch_dtype"] = torch.float16
    elif PRECISION == "float32":
        model_kwargs["torch_dtype"] = torch.float32
    elif PRECISION == "8bit":
        model_kwargs["load_in_8bit"] = True
    elif PRECISION == "4bit":
        model_kwargs["load_in_4bit"] = True
    else:
        log.warning(f"Unknown PRECISION '{PRECISION}' — defaulting to float16")
        model_kwargs["torch_dtype"] = torch.float16

    if PRECISION in ("8bit", "4bit") and device == "cpu":
        log.warning(f"{PRECISION} quantization not supported on CPU — falling back to float32")
        model_kwargs = {"torch_dtype": torch.float32}

    log.info(f"Loading '{HF_MODEL_NAME}' (precision={PRECISION}, device={device})...")
    model = SentenceTransformer(
        HF_MODEL_NAME,
        device=device,
        model_kwargs=model_kwargs,
    )
    log.info("Model loaded.")
    return model


def download_and_prepare_remote_model(hf_home: str) -> str | None:
    """Download a model archive from `HF_MODEL_URL` and extract it under HF_HOME.

    Returns the local path to the extracted model directory, or None on failure.
    Supports .zip and .tar.gz archives.
    """
    if not HF_MODEL_URL:
        return None

    import os
    import requests
    import shutil
    import tempfile
    import tarfile
    import zipfile

    try:
        os.makedirs(hf_home, exist_ok=True)
        base = os.path.basename(HF_MODEL_URL).split('?')[0]
        name = os.path.splitext(base)[0]
        dest_dir = os.path.join(hf_home, 'custom_models', name)
        if os.path.isdir(dest_dir):
            log.info(f"Remote model already present at {dest_dir}")
            return dest_dir

        log.info(f"Downloading remote model from {HF_MODEL_URL}...")
        resp = requests.get(HF_MODEL_URL, stream=True, timeout=60)
        resp.raise_for_status()

        with tempfile.TemporaryDirectory() as td:
            tmp_path = os.path.join(td, base)
            with open(tmp_path, 'wb') as f:
                shutil.copyfileobj(resp.raw, f)

            # Extract
            if base.endswith('.zip'):
                with zipfile.ZipFile(tmp_path, 'r') as z:
                    z.extractall(dest_dir)
            elif base.endswith('.tar.gz') or base.endswith('.tgz'):
                with tarfile.open(tmp_path, 'r:gz') as t:
                    t.extractall(dest_dir)
            else:
                # not an archive — save as-is
                os.makedirs(dest_dir, exist_ok=True)
                shutil.move(tmp_path, os.path.join(dest_dir, base))

        log.info(f"Remote model prepared at {dest_dir}")
        return dest_dir
    except Exception as e:
        log.error(f"Failed to download/prepare remote model: {e}")
        return None

# ── Embedding ─────────────────────────────────────────────────────────────────

def embed_text(model, text: str) -> list[float] | None:
    try:
        vec = model.encode(str(text).strip(), normalize_embeddings=True)
        return vec.tolist()
    except Exception as e:
        log.error(f"Embed error: {e}")
        return None

def embed_batch(model, records: list[dict]) -> list[dict]:
    global total_embedded, total_errors
    results = []
    for i, record in enumerate(records):
        news_id     = record.get("id")
        description = record.get("description", "")

        if not description or not str(description).strip():
            log.warning(f"Record {news_id} has empty description — skipping")
            total_errors += 1
            continue

        log.info(f"Embedding record {news_id} ({i+1}/{len(records)}) ...")
        vector = embed_text(model, str(description).strip())

        if vector is None:
            log.warning(f"Failed to embed record {news_id} — AI-error")
            total_errors += 1
            results.append({
                "id":        news_id,
                "status":    "AI-error",
                "node_name": NODE_NAME,
            })
            continue

        total_embedded += 1
        embed_history.append((datetime.now(timezone.utc), 1))
        results.append({
            "id":        news_id,
            "vector":    vector,
            "status":    "done",
            "node_name": NODE_NAME,
        })
        log.info(f"Record {news_id} — embedded ({len(vector)} dims)")

    if total_embedded > 0 and total_embedded % 10 == 0:
        log.info(f"[STATS] Total: {total_embedded} embedded, {total_errors} errors")

    return results

# ── n8n API calls ─────────────────────────────────────────────────────────────

HEADERS = {
    "X-API-Key":    N8N_API_KEY,
    "Content-Type": "application/json",
}

def fetch_batch() -> list[dict]:
    global total_fetched
    payload = {
        "node_name":  NODE_NAME,
        "batch_size": BATCH_SIZE,
    }

    for attempt in range(1, 4):
        try:
            resp = requests.post(
                N8N_GET_URL, json=payload,
                headers=HEADERS, timeout=REQUEST_TIMEOUT,
            )
            resp.raise_for_status()
            records = resp.json().get("records", [])
            if records:
                total_fetched += len(records)
                log.info(f"Fetched {len(records)} records from n8n (total: {total_fetched})")
            else:
                log.info("No pending records — waiting before retry...")
            return records
        except requests.exceptions.HTTPError as e:
            log.error(f"n8n GET error (attempt {attempt}/3): {e.response.status_code} — {e.response.text[:200]}")
            if attempt < 3:
                log.info("Retrying in 1 minute...")
                time.sleep(60)
        except Exception as e:
            log.error(f"n8n GET error (attempt {attempt}/3): {e}")
            if attempt < 3:
                log.info("Retrying in 1 minute...")
                time.sleep(60)

    log.error("Failed to fetch batch after 3 attempts — will retry in next cycle")
    return []

def save_vectors(vectors: list[dict]) -> bool:
    payload = {"node_name": NODE_NAME, "vectors": vectors}

    for attempt in range(1, 4):
        try:
            resp = requests.post(
                N8N_SAVE_URL, json=payload,
                headers=HEADERS, timeout=REQUEST_TIMEOUT,
            )
            resp.raise_for_status()
            saved = resp.json().get("saved", len(vectors))
            log.info(f"Saved {saved}/{len(vectors)} vectors to DB via n8n")
            return True
        except requests.exceptions.HTTPError as e:
            log.error(f"n8n SAVE error (attempt {attempt}/3): {e.response.status_code} — {e.response.text[:200]}")
            if attempt < 3:
                log.info("Retrying in 1 minute...")
                time.sleep(60)
        except Exception as e:
            log.error(f"n8n SAVE error (attempt {attempt}/3): {e}")
            if attempt < 3:
                log.info("Retrying in 1 minute...")
                time.sleep(60)

    log.error("Failed to save vectors after 3 attempts")
    return False

def post_status(status: str, cycle: int, device: str, stop_at: datetime | None = None) -> None:
    """POST worker heartbeat/status to n8n. Non-fatal if it fails."""
    if not N8N_STATUS_URL:
        return

    uptime_seconds = int(time.time() - _start_time)
    since_start_hours = max(uptime_seconds / 3600, 1 / 3600)
    avg_hour = total_embedded / since_start_hours
    avg_min = avg_hour / 60
    recent_hour = prune_embed_history(timedelta(hours=1))
    next_status_in_seconds = None
    next_status_at = None
    if STATUS_INTERVAL > 0:
        remaining_cycles = STATUS_INTERVAL - (cycle % STATUS_INTERVAL)
        if remaining_cycles == STATUS_INTERVAL:
            remaining_cycles = STATUS_INTERVAL
        next_status_in_seconds = int(remaining_cycles * DELAY_SECONDS)
        next_status_at = (
            datetime.now(timezone.utc) + timedelta(seconds=next_status_in_seconds)
        ).isoformat()

    cpu_info = get_cpu_info()
    memory_info = get_memory_info()
    server_info = get_server_info()
    payload = {
        "node_name":                         NODE_NAME,
        "status":                            status,
        "cycles":                            cycle,
        "batch_size":                        BATCH_SIZE,
        "delay_seconds":                     DELAY_SECONDS,
        "articles_fetched":                  total_fetched,
        "articles_embedded":                 total_embedded,
        "articles_errors":                   total_errors,
        "device":                            device,
        "model_name":                        HF_MODEL_NAME,
        "server_host":                      server_info["hostname"],
        "server_lan_ip":                    server_info["lan_ip"],
        "server_os":                        server_info["os"],
        "server_platform":                  server_info["platform"],
        "session_started_at":               datetime.fromtimestamp(_start_time, timezone.utc).isoformat(),
        "session_uptime_seconds":            uptime_seconds,
        "stop_time":                         stop_at.isoformat() if stop_at else None,
        "status_interval":                   STATUS_INTERVAL,
        "next_status_in_seconds":            next_status_in_seconds,
        "next_status_at":                    next_status_at,
        "avg_embeddings_per_hour":           round(avg_hour, 2),
        "avg_embeddings_per_minute":         round(avg_min, 2),
        "embeddings_last_hour":              recent_hour,
        "embeddings_last_hour_per_minute":   round(recent_hour / 60, 2),
        "cores_logical":                     cpu_info["cores_logical"],
        "cores_physical":                    cpu_info["cores_physical"],
        "cores_allowed":                     cpu_info["cores_allowed"],
        "cores_active":                      cpu_info["cores_active"],
        "cpu_percent":                       cpu_info["cpu_percent"],
        "load_average_1m":                   cpu_info["load_average_1m"],
        "load_average_5m":                   cpu_info["load_average_5m"],
        "load_average_15m":                  cpu_info["load_average_15m"],
        "memory_total_bytes":                memory_info["total_bytes"],
        "memory_available_bytes":            memory_info["available_bytes"],
        "memory_used_percent":               memory_info["used_percent"],
    }
    try:
        resp = requests.post(
            N8N_STATUS_URL, json=payload,
            headers=HEADERS, timeout=REQUEST_TIMEOUT,
        )
        resp.raise_for_status()
        log.info(f"Status posted: {status} (cycle={cycle}, embedded={total_embedded})")
    except Exception as e:
        log.warning(f"Status POST failed (non-fatal): {e}")

# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    global _stopping_status_sent

    device = detect_device()
    check_memory_requirements(device)

    # If HF auth token provided in env, export it for huggingface_hub
    if HF_AUTH_TOKEN:
        os.environ["HUGGINGFACE_HUB_TOKEN"] = HF_AUTH_TOKEN

    # If user provided a local path, prefer that
    if HF_MODEL_LOCAL_PATH:
        if os.path.isdir(HF_MODEL_LOCAL_PATH):
            log.info(f"Using local model path: {HF_MODEL_LOCAL_PATH}")
            HF_MODEL_NAME_LOCAL = HF_MODEL_LOCAL_PATH
        else:
            log.error(f"Local model path not found: {HF_MODEL_LOCAL_PATH}")
            sys.exit(1)
    else:
        HF_MODEL_NAME_LOCAL = None

    # If a remote URL is provided, download & extract into HF_HOME
    hf_home = os.getenv("HF_HOME", "/root/.cache/huggingface")
    if HF_MODEL_URL and not HF_MODEL_NAME_LOCAL:
        downloaded = download_and_prepare_remote_model(hf_home)
        if downloaded:
            HF_MODEL_NAME_LOCAL = downloaded

    # If we have a local model directory, set HF_MODEL_NAME to that path
    if HF_MODEL_NAME_LOCAL:
        HF_MODEL_NAME = HF_MODEL_NAME_LOCAL

    model  = load_model(device)

    log.info("Running test embedding...")
    try:
        test_vec = model.encode("test", normalize_embeddings=True)
        log.info(f"Test embedding OK — {len(test_vec)} dimensions")
    except Exception as e:
        log.error(f"Test embedding failed: {e}")
        sys.exit(1)

    stop_at = calc_stop_time(STOP_AT)

    if stop_at:
        duration_str  = format_duration(parse_duration(STOP_AT))
        stop_at_local = stop_at.strftime("%Y-%m-%d %H:%M:%S UTC")
    else:
        duration_str  = "∞ forever"
        stop_at_local = "never"

    log.info("=" * 52)
    log.info("  Embedding Worker")
    log.info(f"  Node name   : {NODE_NAME}")
    log.info(f"  Model       : {HF_MODEL_NAME}")
    log.info(f"  Precision   : {PRECISION}")
    log.info(f"  Device      : {device}")
    log.info(f"  Batch size  : {BATCH_SIZE}")
    log.info(f"  Delay       : {DELAY_SECONDS}s between cycles")
    log.info(f"  Run for     : {duration_str}")
    log.info(f"  Stop at     : {stop_at_local}")
    if N8N_STATUS_URL:
        log.info(f"  Status URL  : {N8N_STATUS_URL}")
        log.info(f"  Status every: {STATUS_INTERVAL} cycles")
    log.info("=" * 52)

    cycle = 0

    try:
        while not should_stop(stop_at):
            cycle += 1

            if stop_at:
                remaining = stop_at - datetime.now(timezone.utc)
                remaining_str = format_duration(remaining) if remaining.total_seconds() > 0 else "0m"
                log.info(f"── Cycle {cycle}  (time remaining: {remaining_str}) ──")
            else:
                log.info(f"── Cycle {cycle} ──────────────────────────────────")

            records = fetch_batch()

            if not records:
                log.info("No pending records — waiting before retry...")
                time.sleep(DELAY_SECONDS)
                continue

            vectors = embed_batch(model, records)

            if not vectors:
                log.warning("No vectors produced this cycle — waiting...")
                time.sleep(DELAY_SECONDS)
                continue

            save_vectors(vectors)

            if _shutdown and not _stopping_status_sent:
                post_status("stopping", cycle, device, stop_at)
                _stopping_status_sent = True

            if N8N_STATUS_URL and STATUS_INTERVAL > 0 and cycle % STATUS_INTERVAL == 0:
                post_status("running", cycle, device, stop_at)

            if not should_stop(stop_at):
                log.info(f"Waiting {DELAY_SECONDS}s before next cycle...")
                time.sleep(DELAY_SECONDS)

        if _shutdown and not _stopping_status_sent:
            post_status("stopping", cycle, device, stop_at)

    finally:
        post_status("stopped", cycle, device, stop_at)
        log.info(f"Worker stopped. Session total: {total_embedded} embedded, {total_errors} errors.")

if __name__ == "__main__":
    main()
