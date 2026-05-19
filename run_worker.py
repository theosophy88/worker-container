#!/usr/bin/env python3
"""
Embedding Worker Entry Point

Starts the distributed embedding worker process.
Configuration via environment variables (see .env).
"""

if __name__ == "__main__":
    from src.worker.worker_main import main
    main()
