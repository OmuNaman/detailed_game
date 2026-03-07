"""Observe endpoint — processes NPC observations into memories."""

from __future__ import annotations

import logging

from fastapi import APIRouter

from backend.memory import chroma_store
from backend.memory.scoring import compute_stability
from backend.models.npc import ObserveRequest, ObserveResponse

logger = logging.getLogger(__name__)

router = APIRouter(tags=["observe"])


@router.post("/observe", response_model=ObserveResponse)
async def observe(req: ObserveRequest) -> ObserveResponse:
    """Process an observation and store as a memory.

    Currently uses simple heuristics for importance/valence.
    Future: LLM-based classification.
    """
    # Simple importance heuristics (matches npc_perception.gd defaults)
    importance = 2.0  # Default NPC observation
    valence = 0.0

    text_lower = req.observation.lower()

    # Player observations are more important (matches npc_perception.gd)
    if "player" in text_lower or "newcomer" in text_lower:
        importance = 5.0
        valence = 0.1

    # Calculate time fields
    day = req.game_time // 1440 if req.game_time else req.game_day
    hour = (req.game_time % 1440) // 60 if req.game_time else req.game_hour

    stability = compute_stability("observation", valence)

    memory = {
        "id": f"mem_{chroma_store.get_collection(req.npc_id).count():04d}",
        "text": req.observation,
        "description": req.observation,
        "type": "observation",
        "importance": importance,
        "emotional_valence": valence,
        "entities": [],
        "participants": [],
        "location": "",
        "observer_location": "",
        "observed_near": "",
        "timestamp": req.game_time,
        "game_time": req.game_time,
        "game_day": day,
        "game_hour": hour,
        "last_accessed": req.game_time,
        "access_count": 0,
        "observation_count": 1,
        "stability": stability,
        "protected": False,
        "superseded": False,
        "summary_level": 0,
        "actor": "",
    }

    await chroma_store.add_memory(req.npc_id, memory)

    return ObserveResponse(
        status="ok",
        importance=importance,
        valence=valence,
    )
