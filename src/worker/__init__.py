"""
Embedding Worker — Distributed text embedding system.

Processes news records from n8n webhooks, generates embeddings using
a local HuggingFace model, and persists results back to PostgreSQL via n8n.
"""

__version__ = "3.0.0"
__author__ = "Embedding Worker Team"
