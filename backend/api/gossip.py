"""Gossip endpoints — pick, share, and detect third-party mentions.

Faithful port of npc_gossip.gd gossip selection, sharing, and natural diffusion.
"""

from __future__ import annotations

import json
import logging
import random

from fastapi import APIRouter

from backend.memory import chroma_store
from backend.memory.scoring import compute_stability
from backend.models.planning import (
    GossipDetectRequest,
    GossipDetectResponse,
    GossipPickRequest,
    GossipPickResponse,
    GossipShareRequest,
    GossipShareResponse,
)
from backend.models.memory import EpisodicMemory

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/gossip", tags=["gossip"])

# Constants matching npc_gossip.gd
GOSSIP_TRUST_THRESHOLD = 15.0
GOSSIP_CHANCE = 0.2
GOSSIP_MIN_IMPORTANCE = 3.0
GOSSIP_MAX_AGE_HOURS = 48
GOSSIP_MAX_HOPS = 3


@router.post("/pick", response_model=GossipPickResponse)
async def pick_gossip(req: GossipPickRequest) -> GossipPickResponse:
    """Select an interesting memory to share with another NPC.

    Port of npc_gossip.gd pick_gossip_for().
    """
    # Trust check
    if req.trust_score < GOSSIP_TRUST_THRESHOLD:
        return GossipPickResponse(should_share=False)

    # Random chance
    if random.random() > GOSSIP_CHANCE:
        return GossipPickResponse(should_share=False)

    # Get all memories for this NPC
    all_mems = chroma_store.get_all_memories(req.npc_name)

    candidates: list[dict] = []
    for mem in all_mems:
        # Must be recent enough
        hours_ago = (req.game_time - mem.get("game_time", 0)) / 60.0
        if hours_ago > GOSSIP_MAX_AGE_HOURS:
            continue

        # Must be important enough
        if mem.get("importance", 0.0) < GOSSIP_MIN_IMPORTANCE:
            continue

        # Must be about someone other than conversation partner or self
        actor = mem.get("actor", "")
        if actor == req.other_npc_name or actor == req.npc_name or not actor:
            continue

        # Don't re-share gossip from this NPC
        if mem.get("gossip_source", "") == req.other_npc_name:
            continue

        # Don't share if other NPC was a participant
        participants = mem.get("participants", [])
        if isinstance(participants, str):
            try:
                participants = json.loads(participants)
            except (json.JSONDecodeError, ValueError):
                participants = []
        if req.other_npc_name in participants:
            continue

        # Skip if already told this person
        shared_with = mem.get("shared_with", [])
        if isinstance(shared_with, str):
            try:
                shared_with = json.loads(shared_with)
            except (json.JSONDecodeError, ValueError):
                shared_with = []
        if req.other_npc_name in shared_with:
            continue

        # Prefer certain types
        mem_type = mem.get("type", "")
        if mem_type in ("observation", "dialogue", "environment", "reflection", "gossip"):
            candidates.append(mem)

    if not candidates:
        return GossipPickResponse(should_share=False)

    # Sort by importance * recency
    candidates.sort(
        key=lambda m: m.get("importance", 0.0) * (0.98 ** ((req.game_time - m.get("game_time", 0)) / 60.0)),
        reverse=True,
    )

    best = candidates[0]
    return GossipPickResponse(
        memory=EpisodicMemory(**{k: v for k, v in best.items() if k in EpisodicMemory.model_fields}),
        should_share=True,
    )


@router.post("/share", response_model=GossipShareResponse)
async def share_gossip(req: GossipShareRequest) -> GossipShareResponse:
    """Share gossip from one NPC to another.

    Port of npc_gossip.gd share_gossip_with().
    Creates gossip memory for receiver, sharing memory for sharer.
    """
    hop_count = req.gossip_hops + 1
    if hop_count > GOSSIP_MAX_HOPS:
        return GossipShareResponse(success=False)

    # Format gossip description
    if hop_count == 1:
        gossip_desc = f"{req.sharer_name} told me: {req.memory_text}"
    else:
        gossip_desc = f"{req.sharer_name} mentioned that they heard: {req.memory_text}"

    # Importance degrades with hops
    gossip_importance = max(req.memory_importance - (hop_count * 1.0), 2.0)

    day = req.game_time // 1440
    hour = (req.game_time % 1440) // 60

    # Create gossip memory for receiver
    receiver_collection = chroma_store.get_collection(req.receiver_name)
    receiver_mem = {
        "id": f"mem_{receiver_collection.count():04d}",
        "text": gossip_desc,
        "description": gossip_desc,
        "type": "gossip",
        "importance": gossip_importance,
        "emotional_valence": req.memory_valence,
        "entities": [req.sharer_name, req.receiver_name, req.memory_actor],
        "participants": [req.sharer_name, req.receiver_name, req.memory_actor],
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
        "stability": compute_stability("gossip", req.memory_valence),
        "protected": False,
        "superseded": False,
        "summary_level": 0,
        "actor": req.memory_actor,
        "gossip_source": req.sharer_name,
        "gossip_hops": hop_count,
    }
    await chroma_store.add_memory(req.receiver_name, receiver_mem)

    # Create sharing memory for the sharer
    sharer_collection = chroma_store.get_collection(req.sharer_name)
    sharer_mem = {
        "id": f"mem_{sharer_collection.count():04d}",
        "text": f"Told {req.receiver_name} about {req.memory_text[:60]}",
        "description": f"Told {req.receiver_name} about {req.memory_text[:60]}",
        "type": "gossip_shared",
        "importance": 2.0,
        "emotional_valence": 0.0,
        "entities": [req.sharer_name, req.receiver_name],
        "participants": [req.sharer_name, req.receiver_name],
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
        "stability": compute_stability("gossip_shared", 0.0),
        "protected": False,
        "superseded": False,
        "summary_level": 0,
        "actor": req.receiver_name,
    }
    await chroma_store.add_memory(req.sharer_name, sharer_mem)

    # Mark original memory as shared_with this receiver
    # (Find and update in sharer's collection)
    sharer_mems = chroma_store.get_all_memories(req.sharer_name)
    for mem in sharer_mems:
        if mem.get("text", "") == req.memory_text:
            shared_with = mem.get("shared_with", [])
            if isinstance(shared_with, str):
                try:
                    shared_with = json.loads(shared_with)
                except (json.JSONDecodeError, ValueError):
                    shared_with = []
            if req.receiver_name not in shared_with:
                shared_with.append(req.receiver_name)
                chroma_store._update_metadata(
                    req.sharer_name, mem["id"],
                    {"shared_with": json.dumps(shared_with)},
                )
            break

    return GossipShareResponse(success=True)


@router.post("/detect-mentions", response_model=GossipDetectResponse)
async def detect_mentions(req: GossipDetectRequest) -> GossipDetectResponse:
    """Detect third-party NPC/player mentions in dialogue text.

    Port of npc_gossip.gd detect_third_party_mentions().
    Creates gossip memories for mentioned names.
    """
    line_lower = req.line_text.lower()
    mentions: list[dict] = []

    # Check all NPC names and player name
    names_to_check = [
        n for n in req.all_npc_names
        if n != req.speaker_name and n != req.listener_name
    ]
    if req.player_name and req.player_name != req.speaker_name:
        names_to_check.append(req.player_name)

    for mentioned_name in names_to_check:
        if mentioned_name.lower() not in line_lower:
            continue

        importance = 4.0 if mentioned_name == req.player_name else 3.0
        desc = f'{req.speaker_name} mentioned {mentioned_name}: "{req.line_text}"'
        if len(desc) > 200:
            desc = desc[:197] + "..."

        # Store as gossip memory for the listener
        day = req.game_time // 1440
        hour = (req.game_time % 1440) // 60
        collection = chroma_store.get_collection(req.listener_name)
        mem = {
            "id": f"mem_{collection.count():04d}",
            "text": desc,
            "description": desc,
            "type": "gossip",
            "importance": importance,
            "emotional_valence": 0.0,
            "entities": [req.speaker_name, mentioned_name, req.listener_name],
            "participants": [req.speaker_name, mentioned_name, req.listener_name],
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
            "stability": compute_stability("gossip", 0.0),
            "protected": False,
            "superseded": False,
            "summary_level": 0,
            "actor": req.speaker_name,
            "gossip_source": req.speaker_name,
            "gossip_hops": 1,
        }
        await chroma_store.add_memory(req.listener_name, mem)

        mentions.append({
            "mentioned_name": mentioned_name,
            "importance": importance,
            "description": desc,
        })

    return GossipDetectResponse(mentions=mentions)
