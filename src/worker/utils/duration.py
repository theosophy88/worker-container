"""Duration parsing and formatting utilities."""

import re
import sys
from datetime import datetime, timedelta, timezone

from ..config import log


def parse_duration(raw: str) -> timedelta | None:
    """
    Parse a human duration string into a timedelta.

    Supported format: parts separated by '-'
      Nd   → N days
      Nh   → N hours
      Nm   → N minutes

    Examples:
      "30m"        → timedelta(minutes=30)
      "5h"         → timedelta(hours=5)
      "1d"         → timedelta(days=1)
      "1d-5h"      → timedelta(days=1, hours=5)
      "1d-5h-30m"  → timedelta(days=1, hours=5, minutes=30)
      "2h-45m"     → timedelta(hours=2, minutes=45)
      ""            → None  (run forever)
    """
    raw = raw.strip()
    if not raw:
        return None

    pattern = re.compile(r'^(\d+)(d|h|m)$', re.IGNORECASE)
    parts = [p.strip() for p in raw.split('-')]

    days = hours = minutes = 0
    for part in parts:
        m = pattern.match(part)
        if not m:
            log.error(
                f"Invalid STOP_AT part: '{part}'\n"
                f"  Expected format: 30m | 5h | 1d | 1d-5h | 1d-5h-30m"
            )
            sys.exit(1)
        value = int(m.group(1))
        unit = m.group(2).lower()
        if unit == 'd':
            days += value
        elif unit == 'h':
            hours += value
        elif unit == 'm':
            minutes += value

    total = timedelta(days=days, hours=hours, minutes=minutes)
    if total.total_seconds() <= 0:
        log.error("STOP_AT duration must be greater than zero.")
        sys.exit(1)

    return total


def calc_stop_time(raw: str) -> datetime | None:
    """
    Convert a duration string to an absolute UTC stop datetime
    anchored to right now (start time).
    Returns None if raw is empty (run forever).
    """
    duration = parse_duration(raw)
    if duration is None:
        return None
    return datetime.now(timezone.utc) + duration


def format_duration(td: timedelta) -> str:
    """Format a timedelta as a human-readable string."""
    total_seconds = int(td.total_seconds())
    days = total_seconds // 86400
    hours = (total_seconds % 86400) // 3600
    minutes = (total_seconds % 3600) // 60
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    return "-".join(parts) if parts else "0m"
