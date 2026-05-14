"""
Embedding Worker
================
Loops forever (or until stop duration):
  1. Calls n8n GET webhook  → receives batch of {id, description}
  2. Embeds each description via local Ollama
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
import logging
import signal
from datetime import datetime, timedelta, timezone

import requests

# ── Global statistics ────────────────────────────────────────────────────────
total_embedded = 0
total_errors = 0
total_fetched = 0

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

OLLAMA_URL      = os.getenv("OLLAMA_URL",      "http://localhost:11434")
MODEL_NAME      = os.getenv("MODEL_NAME",      "qwen3-embedding:8b")
BATCH_SIZE      = int(os.getenv("BATCH_SIZE",      "10"))
DELAY_SECONDS   = float(os.getenv("DELAY_SECONDS",   "5"))
STOP_AT         = os.getenv("STOP_AT", "").strip()
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "30"))
EMBED_TIMEOUT   = int(os.getenv("EMBED_TIMEOUT",  "120"))

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
    stop_at = datetime.now(timezone.utc) + duration
    return stop_at

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

# ── Ollama embedding ──────────────────────────────────────────────────────────

def embed_text(text: str) -> list[float] | None:
    try:
        resp = requests.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": MODEL_NAME, "input": text},
            timeout=EMBED_TIMEOUT,
        )
        resp.raise_for_status()
        embeddings = resp.json().get("embeddings")
        if embeddings and len(embeddings) > 0:
            return embeddings[0]
        log.warning("Ollama returned empty embeddings")
        return None
    except Exception as e:
        log.error(f"Ollama embed error: {e}")
        return None

def embed_batch(records: list[dict]) -> list[dict]:
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
        vector = embed_text(str(description).strip())

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
        results.append({
            "id":        news_id,
            "vector":    vector,
            "status":    "done",
            "node_name": NODE_NAME,
        })
        log.info(f"Record {news_id} — embedded ({len(vector)} dims)")

    # Log periodic stats
    if total_embedded > 0 and total_embedded % 10 == 0:
        log.info(f"[STATS] Total: {total_embedded} embedded, {total_errors} errors")

    return results

# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    stop_at = calc_stop_time(STOP_AT)

    # Human-readable stop time display
    if stop_at:
        duration_str   = format_duration(parse_duration(STOP_AT))
        stop_at_local  = stop_at.strftime("%Y-%m-%d %H:%M:%S UTC")
    else:
        duration_str  = "∞ forever"
        stop_at_local = "never"

    log.info("=" * 52)
    log.info("  Embedding Worker")
    log.info(f"  Node name   : {NODE_NAME}")
    log.info(f"  Model       : {MODEL_NAME}")
    log.info(f"  Ollama      : {OLLAMA_URL}")
    log.info(f"  Batch size  : {BATCH_SIZE}")
    log.info(f"  Delay       : {DELAY_SECONDS}s between cycles")
    log.info(f"  Run for     : {duration_str}")
    log.info(f"  Stop at     : {stop_at_local}")
    log.info("=" * 52)

    cycle = 0

    while not should_stop(stop_at):
        cycle += 1

        # Show remaining time every cycle
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

        vectors = embed_batch(records)

        if not vectors:
            log.warning("No vectors produced this cycle — waiting...")
            time.sleep(DELAY_SECONDS)
            continue

        save_vectors(vectors)

        if not should_stop(stop_at):
            log.info(f"Waiting {DELAY_SECONDS}s before next cycle...")
            time.sleep(DELAY_SECONDS)

    log.info("Worker stopped cleanly.")

if __name__ == "__main__":
    main()