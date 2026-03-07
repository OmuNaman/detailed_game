"""Memory compression — episode and period summaries.

Faithful port of memory_system.gd compression logic and npc_reflection.gd midnight maintenance.
"""

from __future__ import annotations

# Constants from memory_system.gd
COMPRESSION_BATCH_SIZE = 30
COMPRESSION_MIN_BATCH = 10
EPISODE_COMPRESSION_THRESHOLD = 10
PERIOD_COMPRESSION_BATCH = 7


def get_compression_candidates(
    memories: list[dict],
    batch_size: int = COMPRESSION_BATCH_SIZE,
) -> list[dict]:
    """Returns oldest non-protected, non-summarized, non-superseded raw memories."""
    candidates = [
        m for m in memories
        if m.get("summary_level", 0) == 0
        and not m.get("protected", False)
        and not m.get("superseded", False)
    ]
    candidates.sort(key=lambda m: m.get("timestamp", 0))
    return candidates[:batch_size]


def get_episode_summary_candidates(archival: list[dict]) -> list[dict]:
    """Returns Level 1 episode summaries from archival, sorted oldest first."""
    episodes = [m for m in archival if m.get("summary_level", 0) == 1]
    episodes.sort(key=lambda m: m.get("timestamp", 0))
    return episodes


def should_compress_episodes(archival: list[dict]) -> bool:
    """Check if enough episode summaries have accumulated for period compression."""
    episode_count = sum(1 for m in archival if m.get("summary_level", 0) == 1)
    return episode_count >= EPISODE_COMPRESSION_THRESHOLD


def format_memories_for_compression(memories: list[dict], npc_name: str) -> str:
    """Format memories into a prompt-ready string for LLM compression."""
    lines = []
    for mem in memories:
        day = mem.get("game_day", 0)
        hour = mem.get("game_hour", 0)
        text = mem.get("text", mem.get("description", ""))
        lines.append(f"[Day {day}, Hour {hour}] {text}")
    return "\n".join(lines)


def build_episode_compression_prompt(
    memories: list[dict],
    npc_name: str,
    player_name: str,
) -> tuple[str, str]:
    """Build the LLM prompt for episode compression. Returns (system, user)."""
    memory_text = format_memories_for_compression(memories, npc_name)
    system = (
        f"Summarize these memories of {npc_name} into a dense 3-5 sentence paragraph.\n"
        f"PRESERVE: relationship changes, emotional peaks, promises made, surprising events, "
        f"anything about {player_name}.\n"
        f"COMPRESS AWAY: routine observations, repeated activities, mundane details.\n"
        f"DO NOT invent details not present in the memories.\n"
    )
    user = f"Memories:\n{memory_text}\n\nWrite ONLY the summary paragraph, nothing else."
    return system, user


def build_period_compression_prompt(
    episodes: list[dict],
    npc_name: str,
    player_name: str,
) -> tuple[str, str]:
    """Build the LLM prompt for period compression. Returns (system, user)."""
    episode_text = format_memories_for_compression(episodes, npc_name)
    system = (
        f"These are episode summaries spanning several days for {npc_name}.\n"
        f"Compress them into a single 2-3 sentence period summary capturing "
        f"the most important developments.\n"
        f"PRESERVE: relationship arcs, major events, character growth, "
        f"anything about {player_name}.\n"
    )
    user = f"Episodes:\n{episode_text}\n\nWrite ONLY the period summary:"
    return system, user


def extract_entities_from_batch(batch: list[dict]) -> list[str]:
    """Collect unique entities from a batch of memories."""
    entity_set: set[str] = set()
    for mem in batch:
        for e in mem.get("entities", mem.get("participants", [])):
            entity_set.add(str(e))
    return list(entity_set)


def average_importance(batch: list[dict]) -> float:
    """Average importance across a batch."""
    if not batch:
        return 1.0
    total = sum(m.get("importance", 1.0) for m in batch)
    return total / len(batch)


def average_valence(batch: list[dict]) -> float:
    """Average emotional valence across a batch."""
    if not batch:
        return 0.0
    total = sum(m.get("emotional_valence", 0.0) for m in batch)
    return total / len(batch)
