"""Memory forgetting curves — faithful port of memory_system.gd apply_daily_forgetting().

Observations/environment: stability *= 0.7 per day (if never accessed)
Other types: stability *= 0.85 per day (if never accessed)
Protected memories never decay (importance >= 8, player_dialogue, reflection).
"""

from __future__ import annotations

import math

# Constants from memory_system.gd
FORGETTING_RATE_OBSERVATION = 0.7
FORGETTING_RATE_OTHER = 0.85
MIN_STABILITY = 1.0
EFFECTIVELY_FORGOTTEN_THRESHOLD = 0.05


def apply_daily_forgetting(
    memories: list[dict],
    current_game_time: int,
) -> int:
    """Decay stability for non-protected memories. Returns count of decayed memories."""
    decayed = 0
    for mem in memories:
        if mem.get("protected", False):
            continue

        mem_type = mem.get("type", "")
        access_count = mem.get("access_count", 0)
        stability = mem.get("stability", 12.0)

        if access_count == 0 and mem_type in ("observation", "environment"):
            stability = max(stability * FORGETTING_RATE_OBSERVATION, MIN_STABILITY)
            decayed += 1
        elif access_count == 0:
            stability = max(stability * FORGETTING_RATE_OTHER, MIN_STABILITY)
            decayed += 1

        mem["stability"] = stability

        # Check if effectively forgotten
        last_time = mem.get("last_accessed", mem.get("timestamp", 0))
        hours = max((current_game_time - last_time) / 60.0, 0.0)
        s = max(stability, 0.1)
        recency = math.pow(1.0 + 0.234 * hours / s, -0.5)
        if recency < EFFECTIVELY_FORGOTTEN_THRESHOLD:
            mem["effectively_forgotten"] = True

    return decayed
