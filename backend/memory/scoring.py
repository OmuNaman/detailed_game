"""Hybrid memory scoring — faithful port of memory_retrieval.gd.

Score = 0.5 * relevance + 0.3 * recency + 0.2 * importance
"""

from __future__ import annotations

import math

# Weights from memory_system.gd
RETRIEVAL_WEIGHT_RELEVANCE = 0.5
RETRIEVAL_WEIGHT_RECENCY = 0.3
RETRIEVAL_WEIGHT_IMPORTANCE = 0.2

# Stability constants
MAX_STABILITY = 500.0
TESTING_EFFECT_MULTIPLIER = 1.1

# Stability by memory type (from memory_system.gd)
STABILITY_BY_TYPE: dict[str, float] = {
    "observation": 6.0,
    "environment": 6.0,
    "conversation": 24.0,
    "dialogue": 24.0,
    "reflection": 72.0,
    "plan": 12.0,
    "gossip": 18.0,
    "gossip_heard": 18.0,
    "gossip_shared": 12.0,
    "player_dialogue": 48.0,
    "episode_summary": 168.0,
    "period_summary": 336.0,
}


def compute_stability(mem_type: str, valence: float) -> float:
    """Calculate initial stability for a memory.

    Matches memory_system.gd create_memory():
        base_stability * (1.0 + abs(valence) * 3.0)
    """
    base = STABILITY_BY_TYPE.get(mem_type, 12.0)
    return min(base * (1.0 + abs(valence) * 3.0), MAX_STABILITY)


def compute_recency(hours_elapsed: float, stability: float) -> float:
    """Power-law recency decay.

    Matches memory_retrieval.gd score_memory():
        recency = (1 + 0.234 * hours_elapsed / S)^(-0.5)
    """
    s = max(stability, 0.1)
    return math.pow(1.0 + 0.234 * hours_elapsed / s, -0.5)


def score_memory(
    chroma_distance: float,
    last_accessed: int,
    timestamp: int,
    current_game_time: int,
    importance: float,
    stability: float,
    summary_level: int = 0,
) -> float:
    """Hybrid score combining relevance, recency, and importance.

    Matches memory_retrieval.gd score_memory() exactly.

    Args:
        chroma_distance: ChromaDB L2 distance (lower = more similar).
            Converted to cosine-like similarity, then normalized to [0,1].
        last_accessed: Last access time in game minutes.
        timestamp: Creation time in game minutes.
        current_game_time: Current game time in minutes.
        importance: Memory importance (1-10).
        stability: Memory stability value.
        summary_level: 0=raw, 1=episode, 2=period. Summaries get 1.1x boost.
    """
    # RELEVANCE: ChromaDB returns L2 distance. Convert to similarity score.
    # ChromaDB distance range is roughly 0 (identical) to ~2 (orthogonal for normalized vectors).
    # The GDScript normalizes cosine similarity from [-1,1] to [0,1] via (cos_sim + 1) / 2.
    # For ChromaDB L2 on normalized embeddings: distance² = 2 - 2*cos_sim
    # So cos_sim = 1 - distance²/2, then normalize: (cos_sim + 1) / 2
    cos_sim = 1.0 - (chroma_distance ** 2) / 2.0
    cos_sim = max(min(cos_sim, 1.0), -1.0)
    relevance = (cos_sim + 1.0) / 2.0
    relevance = max(min(relevance, 1.0), 0.0)

    # RECENCY: power-law decay based on stability
    mem_time = last_accessed if last_accessed > 0 else timestamp
    hours_elapsed = max((current_game_time - mem_time) / 60.0, 0.0)
    recency = compute_recency(hours_elapsed, stability)

    # IMPORTANCE: normalized to [0,1]
    norm_importance = importance / 10.0

    score = (
        RETRIEVAL_WEIGHT_RELEVANCE * relevance
        + RETRIEVAL_WEIGHT_RECENCY * recency
        + RETRIEVAL_WEIGHT_IMPORTANCE * norm_importance
    )

    # Archival summaries get 1.1x boost (from retrieve_by_query_text)
    if summary_level > 0:
        score *= 1.1

    return score


def apply_testing_effect(stability: float) -> float:
    """Retrieved memories grow stronger. Matches GDScript testing effect."""
    return min(stability * TESTING_EFFECT_MULTIPLIER, MAX_STABILITY)


def score_by_keywords(
    text: str,
    keywords: list[str],
    last_accessed: int,
    timestamp: int,
    current_game_time: int,
    importance: float,
    stability: float,
    summary_level: int = 0,
) -> float:
    """Keyword-based scoring fallback. Matches retrieve_by_query_text()."""
    if not keywords:
        return 0.0

    text_lower = text.lower()
    match_count = sum(1 for kw in keywords if kw in text_lower)
    relevance = match_count / len(keywords)

    mem_time = last_accessed if last_accessed > 0 else timestamp
    hours_elapsed = max((current_game_time - mem_time) / 60.0, 0.0)
    recency = compute_recency(hours_elapsed, stability)

    norm_importance = importance / 10.0

    score = (
        RETRIEVAL_WEIGHT_RELEVANCE * relevance
        + RETRIEVAL_WEIGHT_RECENCY * recency
        + RETRIEVAL_WEIGHT_IMPORTANCE * norm_importance
    )

    if summary_level > 0:
        score *= 1.1

    return score


# Stop words for keyword extraction (from memory_retrieval.gd)
STOP_WORDS: set[str] = {
    "the", "and", "was", "with", "that", "this", "from",
    "they", "their", "have", "been", "what", "about", "there", "would", "said",
    "just", "near", "here", "some", "will", "also", "very", "like", "when", "only",
    "your", "into", "more", "than", "then", "does", "which", "could", "should", "were",
}


def extract_keywords(query: str, max_keywords: int = 10) -> list[str]:
    """Extract search keywords from free text. Matches GDScript retrieve_by_query_text()."""
    keywords = []
    for word in query.split():
        cleaned = word.lower().strip().replace(".", "").replace(",", "").replace("?", "").replace("!", "").replace('"', "")
        if len(cleaned) > 2 and cleaned not in STOP_WORDS:
            keywords.append(cleaned)
    return keywords[:max_keywords]
