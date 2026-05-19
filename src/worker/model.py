"""Model loading, validation, and remote model preparation."""

import os
import sys
import shutil
import tempfile
import tarfile
import zipfile

import requests

from . import config
from .config import log, HF_MODEL_NAME, PRECISION, HF_AUTH_TOKEN, HF_MODEL_URL


def check_memory_requirements(device: str, precision: str = PRECISION) -> None:
    """Ensure minimum memory for float16 mode (16 GB RAM/VRAM).

    Exits the process with an error if the requirement is not met when
    `PRECISION` is `float16`. For GPUs we inspect CUDA properties; for CPU
    we use `psutil` when available.
    """
    if precision != "float16":
        return

    min_bytes = 16 * 1024**3

    try:
        import torch

        if device == "cuda":
            try:
                props = torch.cuda.get_device_properties(0)
                total = getattr(props, "total_memory", None)
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
            except ImportError:
                log.error("psutil not installed; cannot verify system RAM. Install psutil or set PRECISION=float32")
                sys.exit(1)
    except ImportError:
        log.warning("PyTorch not available, skipping memory check")


def load_model(device: str, model_name: str = HF_MODEL_NAME, precision: str = PRECISION):
    """Load the sentence-transformers model with the configured precision."""
    try:
        import torch
        from sentence_transformers import SentenceTransformer
    except ImportError:
        log.error("Required packages not found. Install: pip install torch sentence-transformers")
        sys.exit(1)

    model_kwargs: dict = {}

    if precision == "float16":
        model_kwargs["torch_dtype"] = torch.float16
    elif precision == "float32":
        model_kwargs["torch_dtype"] = torch.float32
    elif precision == "8bit":
        model_kwargs["load_in_8bit"] = True
    elif precision == "4bit":
        model_kwargs["load_in_4bit"] = True
    else:
        log.warning(f"Unknown PRECISION '{precision}' — defaulting to float16")
        model_kwargs["torch_dtype"] = torch.float16

    if precision in ("8bit", "4bit") and device == "cpu":
        log.warning(f"{precision} quantization not supported on CPU — falling back to float32")
        model_kwargs = {"torch_dtype": torch.float32}

    log.info(f"Loading '{model_name}' (precision={precision}, device={device})...")
    model = SentenceTransformer(
        model_name,
        device=device,
        model_kwargs=model_kwargs,
    )
    log.info("Model loaded.")
    return model


def download_and_prepare_remote_model(model_url: str, hf_home: str) -> str | None:
    """Download a model archive from URL and extract it under HF_HOME.

    Returns the local path to the extracted model directory, or None on failure.
    Supports .zip and .tar.gz archives.
    """
    if not model_url:
        return None

    try:
        os.makedirs(hf_home, exist_ok=True)
        base = os.path.basename(model_url).split('?')[0]
        name = os.path.splitext(base)[0]
        dest_dir = os.path.join(hf_home, 'custom_models', name)
        if os.path.isdir(dest_dir):
            log.info(f"Remote model already present at {dest_dir}")
            return dest_dir

        log.info(f"Downloading remote model from {model_url}...")
        resp = requests.get(model_url, stream=True, timeout=60)
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


def prepare_model_path(model_local_path: str = "", model_url: str = "") -> str:
    """Determine the model path to use, considering local path, remote URL, or default."""
    if model_local_path:
        if os.path.isdir(model_local_path):
            log.info(f"Using local model path: {model_local_path}")
            return model_local_path
        else:
            log.error(f"Local model path not found: {model_local_path}")
            sys.exit(1)

    hf_home = os.getenv("HF_HOME", "/root/.cache/huggingface")
    if model_url:
        downloaded = download_and_prepare_remote_model(model_url, hf_home)
        if downloaded:
            return downloaded

    # Return the default model name
    return HF_MODEL_NAME
