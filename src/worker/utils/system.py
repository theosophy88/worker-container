"""System information gathering (CPU, memory, device, server details)."""

import os
import socket
import platform

from ..config import log


def detect_device() -> str:
    """Auto-detect best available device: CUDA/ROCm → MPS → CPU."""
    try:
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
    except ImportError:
        log.warning("PyTorch not available, defaulting to CPU")

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
    except ImportError:
        log.debug("psutil not available, using basic CPU info")
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
    except ImportError:
        log.debug("psutil not available, memory info unavailable")
    except Exception as e:
        log.warning(f"Could not gather memory info: {e}")

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
