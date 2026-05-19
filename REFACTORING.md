## Project Structure Refactoring

The embedding worker has been refactored from a monolithic `worker.py` into a modular package structure for improved maintainability, testability, and clarity.

### New Directory Structure

```
embedding-worker/
├── src/
│   └── worker/
│       ├── __init__.py              # Package initialization
│       ├── config.py                # Configuration & environment management
│       ├── worker_main.py           # Main event loop and orchestration
│       ├── embedding.py             # Text embedding operations
│       ├── model.py                 # Model loading and management
│       ├── n8n_api.py               # n8n webhook integration
│       ├── shutdown.py              # Signal handling and graceful shutdown
│       ├── utils/
│       │   ├── __init__.py
│       │   ├── duration.py          # Time/duration utilities
│       │   └── system.py            # System info gathering
│       └── ARCHITECTURE.md          # Detailed architecture docs
├── run_worker.py                    # Primary entry point
├── worker.py                        # Legacy entry point (deprecated)
├── entrypoint.sh                    # Docker startup script
├── Dockerfile                       # Updated Docker config
└── ... (other files)
```

### Module Breakdown

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| **config.py** | Environment variables and constants | `require_env()`, `optional_env()`, `HEADERS`, `BATCH_SIZE`, etc. |
| **worker_main.py** | Main event loop | `main()` - orchestrates fetch → embed → save cycles |
| **embedding.py** | Text embedding operations | `embed_text()`, `embed_batch()`, `EmbeddingStats` class |
| **model.py** | Model loading and preparation | `load_model()`, `prepare_model_path()`, `check_memory_requirements()` |
| **n8n_api.py** | n8n webhook API integration | `fetch_batch()`, `save_vectors()`, `post_status()` |
| **shutdown.py** | Signal handling | `setup_signal_handlers()`, `is_shutdown_requested()` |
| **utils/duration.py** | Duration parsing/formatting | `parse_duration()`, `calc_stop_time()`, `format_duration()` |
| **utils/system.py** | System information | `get_cpu_info()`, `get_memory_info()`, `get_server_info()`, `detect_device()` |

### Key Improvements

1. **Modularity** - Each functional area is now in its own file
2. **Testability** - Easier to write unit tests for individual modules
3. **Maintainability** - Clear separation of concerns
4. **Extensibility** - Easy to add new features without touching existing code
5. **Reusability** - Modules can be imported and used independently
6. **Documentation** - Each module has docstrings and type hints

### Running the Worker

```bash
# New modular structure
python3 run_worker.py

# Docker (automatic selection)
docker-compose up

# Legacy (still supported for compatibility)
python3 worker.py
```

### Backwards Compatibility

- The original `worker.py` is kept for backwards compatibility
- The Docker `entrypoint.sh` automatically prefers `run_worker.py`
- Falls back to `worker.py` if new structure is not available

### For Developers

When adding new features:
1. Keep configuration in `config.py`
2. Implement functionality in appropriate module (or create new utility module)
3. Update `worker_main.py` to use the new functionality
4. Add tests in `tests/` directory
5. Update `ARCHITECTURE.md` and relevant module docstrings

### Dependencies

All Python packages remain the same:
- torch
- sentence-transformers
- requests
- psutil
- accelerate
- bitsandbytes

See `requirements.txt` or `Dockerfile` for complete list.
