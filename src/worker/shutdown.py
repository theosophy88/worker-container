"""Worker shutdown handling and signal management."""

import signal
import sys

from .config import log

_shutdown = False


def setup_signal_handlers(on_shutdown_callback=None):
    """Setup graceful shutdown signal handlers."""
    global _shutdown

    def handle_signal(sig, frame):
        global _shutdown
        log.info(f"Signal {sig} received — shutting down after current batch...")
        _shutdown = True
        if on_shutdown_callback:
            on_shutdown_callback()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)


def is_shutdown_requested() -> bool:
    """Check if shutdown has been requested."""
    global _shutdown
    return _shutdown


def reset_shutdown() -> None:
    """Reset shutdown flag (mainly for testing)."""
    global _shutdown
    _shutdown = False
