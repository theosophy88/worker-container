"""Main worker event loop and orchestration."""

import os
import sys
import time
from collections import deque
from datetime import datetime, timedelta, timezone

from . import config
from .config import log
from .embedding import EmbeddingStats, embed_batch
from .model import check_memory_requirements, load_model, prepare_model_path
from .n8n_api import fetch_batch, save_vectors, post_status
from .shutdown import setup_signal_handlers, is_shutdown_requested
from .utils.duration import calc_stop_time, format_duration, parse_duration
from .utils.system import detect_device


def main():
    """Run the main embedding worker loop."""
    # Setup graceful shutdown
    setup_signal_handlers()

    # Detect device and check resources
    device = detect_device()
    check_memory_requirements(device)

    # Setup HuggingFace auth if provided
    if config.HF_AUTH_TOKEN:
        os.environ["HUGGINGFACE_HUB_TOKEN"] = config.HF_AUTH_TOKEN

    # Prepare model path (local, remote, or default)
    model_name = prepare_model_path(config.HF_MODEL_LOCAL_PATH, config.HF_MODEL_URL)

    # Load model
    model = load_model(device, model_name, config.PRECISION)

    # Test embedding
    log.info("Running test embedding...")
    try:
        test_vec = model.encode("test", normalize_embeddings=True)
        log.info(f"Test embedding OK — {len(test_vec)} dimensions")
    except Exception as e:
        log.error(f"Test embedding failed: {e}")
        sys.exit(1)

    # Calculate stop time
    stop_at = calc_stop_time(config.STOP_AT)
    if stop_at:
        duration_str = format_duration(parse_duration(config.STOP_AT))
        stop_at_local = stop_at.strftime("%Y-%m-%d %H:%M:%S UTC")
    else:
        duration_str = "∞ forever"
        stop_at_local = "never"

    # Initialize stats and tracking
    stats = EmbeddingStats()
    embed_history = deque()
    start_time = time.time()
    _stopping_status_sent = False

    # Log startup info
    log.info("=" * 52)
    log.info("  Embedding Worker")
    log.info(f"  Node name   : {config.NODE_NAME}")
    log.info(f"  Model       : {model_name}")
    log.info(f"  Precision   : {config.PRECISION}")
    log.info(f"  Device      : {device}")
    log.info(f"  Batch size  : {config.BATCH_SIZE}")
    log.info(f"  Delay       : {config.DELAY_SECONDS}s between cycles")
    log.info(f"  Run for     : {duration_str}")
    log.info(f"  Stop at     : {stop_at_local}")
    if config.N8N_STATUS_URL:
        log.info(f"  Status URL  : {config.N8N_STATUS_URL}")
        log.info(f"  Status every: {config.STATUS_INTERVAL} cycles")
    log.info("=" * 52)

    # Main event loop
    cycle = 0
    try:
        while True:
            cycle += 1

            # Check stop conditions
            if is_shutdown_requested():
                log.info("Shutdown requested")
                break
            if stop_at and datetime.now(timezone.utc) >= stop_at:
                log.info("Stop time reached. Shutting down.")
                break

            # Log cycle info
            if stop_at:
                remaining = stop_at - datetime.now(timezone.utc)
                remaining_str = format_duration(remaining) if remaining.total_seconds() > 0 else "0m"
                log.info(f"── Cycle {cycle}  (time remaining: {remaining_str}) ──")
            else:
                log.info(f"── Cycle {cycle} ──────────────────────────────────")

            # Fetch batch
            records = fetch_batch(config.BATCH_SIZE)
            if records:
                stats.record_fetched(len(records))
            else:
                log.info("No pending records — waiting before retry...")
                time.sleep(config.DELAY_SECONDS)
                continue

            # Embed batch
            vectors = embed_batch(model, records, stats)
            if not vectors:
                log.warning("No vectors produced this cycle — waiting...")
                time.sleep(config.DELAY_SECONDS)
                continue

            # Record embed history for rate calculations
            now = datetime.now(timezone.utc)
            for vector_result in vectors:
                if vector_result.get("status") == "done":
                    embed_history.append((now, 1))

            # Save vectors
            save_vectors(vectors)

            # Send status if shutdown is requested
            if is_shutdown_requested() and not _stopping_status_sent:
                post_status("stopping", cycle, device, stats, stop_at, embed_history, start_time)
                _stopping_status_sent = True

            # Send periodic status
            if config.N8N_STATUS_URL and config.STATUS_INTERVAL > 0 and cycle % config.STATUS_INTERVAL == 0:
                post_status("running", cycle, device, stats, stop_at, embed_history, start_time)

            # Wait before next cycle
            if not (is_shutdown_requested() or (stop_at and datetime.now(timezone.utc) >= stop_at)):
                log.info(f"Waiting {config.DELAY_SECONDS}s before next cycle...")
                time.sleep(config.DELAY_SECONDS)

        # Final stopping status if needed
        if not _stopping_status_sent:
            post_status("stopping", cycle, device, stats, stop_at, embed_history, start_time)

    finally:
        # Send final stopped status
        post_status("stopped", cycle, device, stats, stop_at, embed_history, start_time)
        log.info(f"Worker stopped. Session total: {stats.total_embedded} embedded, {stats.total_errors} errors.")


if __name__ == "__main__":
    main()
