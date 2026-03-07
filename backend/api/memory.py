"""Memory API endpoints — add, retrieve, context assembly, core memory, maintenance."""

from __future__ import annotations

import hashlib
import logging

from fastapi import APIRouter

from backend.llm import client as llm_client
from backend.memory import chroma_store
from backend.memory.compression import (
    COMPRESSION_MIN_BATCH,
    PERIOD_COMPRESSION_BATCH,
    average_importance,
    average_valence,
    build_episode_compression_prompt,
    build_period_compression_prompt,
    extract_entities_from_batch,
    get_compression_candidates,
    get_episode_summary_candidates,
    should_compress_episodes,
)
from backend.memory.forgetting import apply_daily_forgetting
from backend.memory.scoring import STABILITY_BY_TYPE, compute_stability
from backend.models.memory import (
    CoreMemory,
    CoreMemoryUpdateRequest,
    MaintenanceRequest,
    MaintenanceResponse,
    MemoryAddRequest,
    MemoryAddResponse,
    MemoryContextRequest,
    MemoryContextResponse,
    MemoryRetrieveRequest,
    MemoryRetrieveResponse,
    EpisodicMemory,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/memory", tags=["memory"])


@router.post("/{npc_name}/add", response_model=MemoryAddResponse)
async def add_memory(npc_name: str, req: MemoryAddRequest) -> MemoryAddResponse:
    """Add a new memory with embedding and deduplication."""
    # Calculate stability
    stability = compute_stability(req.type, req.valence)

    # Calculate time fields
    day = req.game_time // 1440
    hour = (req.game_time % 1440) // 60

    # Check for protected status
    protected = (
        req.importance >= 8.0
        or req.type == "player_dialogue"
        or req.type == "reflection"
    )

    memory = {
        "id": f"mem_{chroma_store.get_collection(npc_name).count():04d}",
        "text": req.text,
        "description": req.text,
        "type": req.type,
        "importance": max(min(req.importance, 10.0), 1.0),
        "emotional_valence": max(min(req.valence, 1.0), -1.0),
        "entities": req.participants,
        "participants": req.participants,
        "location": req.observed_near,
        "observer_location": req.observer_location,
        "observed_near": req.observed_near,
        "timestamp": req.game_time,
        "game_time": req.game_time,
        "game_day": req.game_day if req.game_day else day,
        "game_hour": req.game_hour if req.game_hour else hour,
        "last_accessed": req.game_time,
        "access_count": 0,
        "observation_count": 1,
        "stability": stability,
        "protected": protected,
        "superseded": False,
        "shared_with": [],
        "source_memory_id": "",
        "summary_level": 0,
        "actor": req.actor,
        "gossip_source": req.extra_fields.get("gossip_source", ""),
        "gossip_hops": req.extra_fields.get("gossip_hops", 0),
    }

    # Merge extra fields
    for key, val in req.extra_fields.items():
        if key not in memory:
            memory[key] = val

    # TODO: deduplication logic (state change detection) can be added here
    # For now, just add directly. The full dedup requires tracking recent hashes
    # server-side, which we'll implement when the old GDScript dedup is removed.

    await chroma_store.add_memory(npc_name, memory)

    return MemoryAddResponse(
        memory=EpisodicMemory(**{k: v for k, v in memory.items()
                                 if k in EpisodicMemory.model_fields}),
        deduplicated=False,
    )


@router.post("/{npc_name}/retrieve", response_model=MemoryRetrieveResponse)
async def retrieve_memories(npc_name: str, req: MemoryRetrieveRequest) -> MemoryRetrieveResponse:
    """Retrieve memories by semantic query with hybrid re-ranking."""
    memories = await chroma_store.retrieve_memories(
        npc_name=npc_name,
        query_text=req.query_text,
        current_game_time=req.game_time,
        count=req.count,
        type_filter=req.type_filter,
        time_range_hours=req.time_range_hours,
    )
    return MemoryRetrieveResponse(
        memories=[
            EpisodicMemory(**{k: v for k, v in m.items()
                             if k in EpisodicMemory.model_fields})
            for m in memories
        ]
    )


@router.post("/{npc_name}/context", response_model=MemoryContextResponse)
async def get_memory_context(npc_name: str, req: MemoryContextRequest) -> MemoryContextResponse:
    """Assemble full memory context string for prompt injection."""
    core = await chroma_store.get_core_memory(npc_name)
    retrieved = await chroma_store.retrieve_memories(
        npc_name=npc_name,
        query_text=req.query_text,
        current_game_time=req.game_time,
        count=req.count,
    )
    context = chroma_store.assemble_memory_context(core, retrieved)
    return MemoryContextResponse(context=context, retrieved_count=len(retrieved))


@router.get("/{npc_name}/core", response_model=CoreMemory)
async def get_core_memory(npc_name: str) -> CoreMemory:
    """Read core memory for an NPC."""
    core = await chroma_store.get_core_memory(npc_name)
    return CoreMemory(**core)


@router.put("/{npc_name}/core")
async def update_core_memory(npc_name: str, req: CoreMemoryUpdateRequest) -> CoreMemory:
    """Update specific core memory fields."""
    core = await chroma_store.get_core_memory(npc_name)

    if req.emotional_state is not None:
        core["emotional_state"] = req.emotional_state
    if req.player_summary is not None:
        core["player_summary"] = req.player_summary
    if req.npc_summaries is not None:
        core["npc_summaries"].update(req.npc_summaries)
    if req.active_goals is not None:
        core["active_goals"] = req.active_goals
    if req.key_facts is not None:
        # Append new facts, enforce max 10
        existing = core.get("key_facts", [])
        for fact in req.key_facts:
            if fact not in existing:
                existing.append(fact)
        core["key_facts"] = existing[-10:]  # keep last 10

    await chroma_store.save_core_memory(npc_name, core)
    return CoreMemory(**core)


@router.post("/{npc_name}/maintenance", response_model=MaintenanceResponse)
async def run_maintenance(npc_name: str, req: MaintenanceRequest) -> MaintenanceResponse:
    """Run memory maintenance: forgetting curves + compression."""
    # 1. Apply forgetting
    all_memories = chroma_store.get_all_memories(npc_name)
    forgotten_count = apply_daily_forgetting(all_memories, req.game_time)

    # Update stability values in ChromaDB
    collection = chroma_store.get_collection(npc_name)
    for mem in all_memories:
        chroma_store._update_metadata(npc_name, mem["id"], {
            "stability": mem["stability"],
        })

    # 2. Episode compression
    compressed_count = 0
    candidates = get_compression_candidates(all_memories)
    if len(candidates) >= COMPRESSION_MIN_BATCH:
        core = await chroma_store.get_core_memory(npc_name)
        player_name = "the player"  # Will be passed from Godot in future
        system, user = build_episode_compression_prompt(candidates, npc_name, player_name)
        summary_text, success = await llm_client.generate(system, user)
        if success and summary_text:
            # Create summary memory
            entities = extract_entities_from_batch(candidates)
            avg_imp = average_importance(candidates)
            avg_val = average_valence(candidates)
            summary_mem = {
                "id": f"summary_{collection.count():04d}",
                "text": summary_text,
                "description": summary_text,
                "type": "episode_summary",
                "importance": avg_imp,
                "emotional_valence": avg_val,
                "entities": entities,
                "participants": entities,
                "location": candidates[0].get("location", ""),
                "timestamp": req.game_time,
                "game_time": req.game_time,
                "game_day": candidates[0].get("game_day", 0),
                "game_hour": candidates[0].get("game_hour", 0),
                "last_accessed": req.game_time,
                "access_count": 0,
                "observation_count": 1,
                "stability": compute_stability("episode_summary", avg_val),
                "protected": True,
                "superseded": False,
                "summary_level": 1,
                "actor": "",
            }
            await chroma_store.add_memory(npc_name, summary_mem)

            # Remove compressed memories
            for mem in candidates:
                try:
                    collection.delete(ids=[mem["id"]])
                except Exception:
                    pass
            compressed_count = len(candidates)

    # 3. Period compression
    period_summaries_created = 0
    # Re-fetch after episode compression
    all_after = chroma_store.get_all_memories(npc_name)
    archival = [m for m in all_after if m.get("summary_level", 0) == 1]
    if len(archival) >= 10:
        batch = sorted(archival, key=lambda m: m.get("timestamp", 0))[:PERIOD_COMPRESSION_BATCH]
        system, user = build_period_compression_prompt(batch, npc_name, "the player")
        summary_text, success = await llm_client.generate(system, user)
        if success and summary_text:
            entities = extract_entities_from_batch(batch)
            avg_imp = average_importance(batch)
            avg_val = average_valence(batch)
            period_mem = {
                "id": f"period_{collection.count():04d}",
                "text": summary_text,
                "description": summary_text,
                "type": "period_summary",
                "importance": avg_imp,
                "emotional_valence": avg_val,
                "entities": entities,
                "participants": entities,
                "location": "",
                "timestamp": req.game_time,
                "game_time": req.game_time,
                "game_day": req.game_time // 1440,
                "game_hour": (req.game_time % 1440) // 60,
                "last_accessed": req.game_time,
                "access_count": 0,
                "observation_count": 1,
                "stability": compute_stability("period_summary", avg_val),
                "protected": True,
                "superseded": False,
                "summary_level": 2,
                "actor": "",
            }
            await chroma_store.add_memory(npc_name, period_mem)
            for mem in batch:
                try:
                    collection.delete(ids=[mem["id"]])
                except Exception:
                    pass
            period_summaries_created = 1

    return MaintenanceResponse(
        forgotten_count=forgotten_count,
        compressed_count=compressed_count,
        period_summaries_created=period_summaries_created,
    )
