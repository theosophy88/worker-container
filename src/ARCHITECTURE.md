"""
Embedding Worker — Modular Architecture

src/worker/
├── __init__.py              Package initialization
├── config.py                Environment variables, constants, API headers
├── worker_main.py           Main event loop and orchestration
├── embedding.py             Embedding operations and batch processing
├── model.py                 Model loading and management
├── n8n_api.py               n8n webhook API calls (GET, SAVE, STATUS)
├── shutdown.py              Signal handling and graceful shutdown
└── utils/
    ├── __init__.py
    ├── duration.py          Duration parsing/formatting utilities
    └── system.py            System info gathering (CPU, memory, device, server)

Legacy:
├── worker.py                Original monolithic entry point (DEPRECATED)
└── legacy/                  Legacy code and deprecated versions

Entry points:
├── run_worker.py            Primary entry point (uses modular structure)
└── worker.py                Legacy entry point (kept for compatibility)

Docker:
├── entrypoint.sh            Startup script (auto-selects run_worker.py or worker.py)
└── Dockerfile               Updated to copy modular src/ directory
"""

# Module Dependency Graph:
# 
# worker_main.py
#   ├─> config.py
#   ├─> embedding.py
#   │    └─> config.py
#   ├─> model.py
#   │    ├─> config.py
#   │    └─> (torch, sentence-transformers, requests)
#   ├─> n8n_api.py
#   │    ├─> config.py
#   │    ├─> utils/duration.py
#   │    └─> utils/system.py
#   ├─> shutdown.py
#   │    └─> config.py
#   ├─> utils/duration.py
#   │    └─> config.py
#   └─> utils/system.py
#       ├─> config.py
#       └─> (socket, platform, psutil, torch)
