"""
Configuration and environment variable management.
"""

import os
import sys
import logging

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("worker")


# ── Environment variable helpers ──────────────────────────────────────────────

def require_env(key: str) -> str:
    """Load a required environment variable. Exits if not set."""
    val = os.getenv(key)
    if not val:
        log.error(f"ERROR: Environment variable '{key}' is required but not set.")
        sys.exit(1)
    return val


def optional_env(key: str, default: str = "") -> str:
    """Load an optional environment variable with a default."""
    return os.getenv(key, default).strip()


# ── n8n Configuration ────────────────────────────────────────────────────────

N8N_GET_URL = require_env("N8N_GET_URL")
N8N_SAVE_URL = require_env("N8N_SAVE_URL")
N8N_API_KEY = require_env("N8N_API_KEY")
N8N_STATUS_URL = optional_env("N8N_STATUS_URL", "")
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "30"))

# ── Worker Identity ──────────────────────────────────────────────────────────

NODE_NAME = require_env("NODE_NAME")

# ── Model Configuration ──────────────────────────────────────────────────────

HF_MODEL_NAME = optional_env("HF_MODEL_NAME", "Qwen/Qwen3-Embedding-8B")
HF_AUTH_TOKEN = optional_env("HF_AUTH_TOKEN", "")
HF_MODEL_URL = optional_env("HF_MODEL_URL", "")
HF_MODEL_LOCAL_PATH = optional_env("HF_MODEL_LOCAL_PATH", "")
PRECISION = optional_env("PRECISION", "float16").lower()

# ── Execution Parameters ────────────────────────────────────────────────────

BATCH_SIZE = int(os.getenv("BATCH_SIZE", "10"))
DELAY_SECONDS = float(os.getenv("DELAY_SECONDS", "5"))
STOP_AT = optional_env("STOP_AT", "")

# ── Status Reporting ────────────────────────────────────────────────────────

STATUS_INTERVAL = int(os.getenv("STATUS_INTERVAL", "10"))

# ── API Headers ────────────────────────────────────────────────────────────

HEADERS = {
    "X-API-Key": N8N_API_KEY,
    "Content-Type": "application/json",
}
