"""n8n webhook API integration for batch fetching, saving, and status reporting."""

import time
from datetime import datetime, timedelta, timezone

import requests

from .config import log, NODE_NAME, N8N_GET_URL, N8N_SAVE_URL, N8N_STATUS_URL, HEADERS, REQUEST_TIMEOUT
from .config import BATCH_SIZE, DELAY_SECONDS, STATUS_INTERVAL, HF_MODEL_NAME
from .utils.duration import format_duration
from .utils.system import get_cpu_info, get_memory_info, get_server_info


def fetch_batch(batch_size: int = BATCH_SIZE) -> list[dict]:
    """Fetch a batch of records from n8n GET webhook."""
    payload = {
        "node_name": NODE_NAME,
        "batch_size": batch_size,
    }

    for attempt in range(1, 4):
        try:
            resp = requests.post(
                N8N_GET_URL,
                json=payload,
                headers=HEADERS,
                timeout=REQUEST_TIMEOUT,
            )
            resp.raise_for_status()
            records = resp.json().get("records", [])
            if records:
                log.info(f"Fetched {len(records)} records from n8n (total batch)")
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
    """Save embedded vectors to n8n SAVE webhook."""
    payload = {"node_name": NODE_NAME, "vectors": vectors}

    for attempt in range(1, 4):
        try:
            resp = requests.post(
                N8N_SAVE_URL,
                json=payload,
                headers=HEADERS,
                timeout=REQUEST_TIMEOUT,
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


def post_status(
    status: str,
    cycle: int,
    device: str,
    stats,
    stop_at: datetime | None = None,
    embed_history=None,
    start_time: float = None,
) -> None:
    """POST worker heartbeat/status to n8n. Non-fatal if it fails."""
    if not N8N_STATUS_URL:
        return

    if start_time is None:
        import time
        start_time = time.time()

    uptime_seconds = int(time.time() - start_time)
    since_start_hours = max(uptime_seconds / 3600, 1 / 3600)
    avg_hour = stats.total_embedded / since_start_hours
    avg_min = avg_hour / 60

    # Calculate recent hour embeddings
    recent_hour = 0
    if embed_history:
        now = datetime.now(timezone.utc)
        cutoff = now - timedelta(hours=1)
        # Prune old entries
        while embed_history and embed_history[0][0] < cutoff:
            embed_history.popleft()
        # Count remaining
        for timestamp, count in embed_history:
            if timestamp >= cutoff:
                recent_hour += count

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
        "node_name": NODE_NAME,
        "status": status,
        "cycles": cycle,
        "batch_size": BATCH_SIZE,
        "delay_seconds": DELAY_SECONDS,
        "articles_fetched": stats.total_fetched,
        "articles_embedded": stats.total_embedded,
        "articles_errors": stats.total_errors,
        "device": device,
        "model_name": HF_MODEL_NAME,
        "server_host": server_info["hostname"],
        "server_lan_ip": server_info["lan_ip"],
        "server_os": server_info["os"],
        "server_platform": server_info["platform"],
        "session_started_at": datetime.fromtimestamp(start_time, timezone.utc).isoformat(),
        "session_uptime_seconds": uptime_seconds,
        "stop_time": stop_at.isoformat() if stop_at else None,
        "status_interval": STATUS_INTERVAL,
        "next_status_in_seconds": next_status_in_seconds,
        "next_status_at": next_status_at,
        "avg_embeddings_per_hour": round(avg_hour, 2),
        "avg_embeddings_per_minute": round(avg_min, 2),
        "embeddings_last_hour": recent_hour,
        "embeddings_last_hour_per_minute": round(recent_hour / 60, 2) if recent_hour > 0 else 0,
        "cores_logical": cpu_info["cores_logical"],
        "cores_physical": cpu_info["cores_physical"],
        "cores_allowed": cpu_info["cores_allowed"],
        "cores_active": cpu_info["cores_active"],
        "cpu_percent": cpu_info["cpu_percent"],
        "load_average_1m": cpu_info["load_average_1m"],
        "load_average_5m": cpu_info["load_average_5m"],
        "load_average_15m": cpu_info["load_average_15m"],
        "memory_total_bytes": memory_info["total_bytes"],
        "memory_available_bytes": memory_info["available_bytes"],
        "memory_used_percent": memory_info["used_percent"],
    }
    try:
        resp = requests.post(
            N8N_STATUS_URL,
            json=payload,
            headers=HEADERS,
            timeout=REQUEST_TIMEOUT,
        )
        resp.raise_for_status()
        log.info(f"Status posted: {status} (cycle={cycle}, embedded={stats.total_embedded})")
    except Exception as e:
        log.warning(f"Status POST failed (non-fatal): {e}")
