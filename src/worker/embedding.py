"""Embedding operations and batch processing."""

from datetime import datetime, timezone

from .config import log, NODE_NAME


class EmbeddingStats:
    """Track embedding statistics during session."""

    def __init__(self):
        self.total_embedded = 0
        self.total_errors = 0
        self.total_fetched = 0

    def record_embedded(self):
        """Record a successful embedding."""
        self.total_embedded += 1

    def record_error(self):
        """Record an embedding error."""
        self.total_errors += 1

    def record_fetched(self, count: int):
        """Record fetched articles."""
        self.total_fetched += count


def embed_text(model, text: str) -> list[float] | None:
    """Embed a single text using the model."""
    try:
        vec = model.encode(str(text).strip(), normalize_embeddings=True)
        return vec.tolist()
    except Exception as e:
        log.error(f"Embed error: {e}")
        return None


def embed_batch(model, records: list[dict], stats: EmbeddingStats) -> list[dict]:
    """Embed a batch of records and return formatted results."""
    results = []
    for i, record in enumerate(records):
        news_id = record.get("id")
        description = record.get("description", "")

        if not description or not str(description).strip():
            log.warning(f"Record {news_id} has empty description — skipping")
            stats.record_error()
            continue

        log.info(f"Embedding record {news_id} ({i+1}/{len(records)}) ...")
        vector = embed_text(model, str(description).strip())

        if vector is None:
            log.warning(f"Failed to embed record {news_id} — AI-error")
            stats.record_error()
            results.append({
                "id": news_id,
                "status": "AI-error",
                "node_name": NODE_NAME,
            })
            continue

        stats.record_embedded()
        results.append({
            "id": news_id,
            "vector": vector,
            "status": "done",
            "node_name": NODE_NAME,
        })
        log.info(f"Record {news_id} — embedded ({len(vector)} dims)")

    if stats.total_embedded > 0 and stats.total_embedded % 10 == 0:
        log.info(f"[STATS] Total: {stats.total_embedded} embedded, {stats.total_errors} errors")

    return results
