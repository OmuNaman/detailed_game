"""ChromaDB memory store — one collection per NPC.

Replaces the GDScript JSON + binary embedding storage with ChromaDB vector search.
Post-retrieval re-ranking uses the exact hybrid scoring formula from memory_retrieval.gd.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from pathlib import Path
from typing import Any

import chromadb

from backend.config import settings
from backend.llm import client as llm_client
from backend.memory.scoring import (
    STABILITY_BY_TYPE,
    apply_testing_effect,
    compute_stability,
    extract_keywords,
    score_by_keywords,
    score_memory,
)

logger = logging.getLogger(__name__)

_chroma_client: chromadb.ClientAPI | None = None
_project_root = Path(__file__).resolve().parent.parent.parent

# Embedding batch queue — collects texts and flushes in one API call
_embed_lock = asyncio.Lock()
_embed_queue: list[tuple[str, asyncio.Future]] = []  # (text, future)
_embed_flush_task: asyncio.Task | None = None
_EMBED_BATCH_DELAY = 0.3  # seconds to wait before flushing batch
_EMBED_MAX_BATCH = 20  # max texts per batch call


def get_chroma_client() -> chromadb.ClientAPI:
    """Get or create the persistent ChromaDB client."""
    global _chroma_client
    if _chroma_client is None:
        persist_dir = str(_project_root / settings.chroma_persist_dir)
        Path(persist_dir).mkdir(parents=True, exist_ok=True)
        _chroma_client = chromadb.PersistentClient(path=persist_dir)
        logger.info("ChromaDB initialized at %s", persist_dir)
    return _chroma_client


def get_collection(npc_name: str) -> chromadb.Collection:
    """Get or create a ChromaDB collection for an NPC."""
    client = get_chroma_client()
    safe_name = npc_name.lower().replace(" ", "_")
    return client.get_or_create_collection(
        name=safe_name,
        metadata={"hnsw:space": "l2"},
    )


async def _queue_embed(text: str) -> list[float]:
    """Queue text for batch embedding. Returns embedding when batch flushes."""
    global _embed_flush_task
    loop = asyncio.get_event_loop()
    future: asyncio.Future[list[float]] = loop.create_future()

    async with _embed_lock:
        _embed_queue.append((text, future))
        # Schedule flush if not already scheduled
        if _embed_flush_task is None or _embed_flush_task.done():
            _embed_flush_task = asyncio.create_task(_flush_embed_queue())

    return await future


async def _flush_embed_queue() -> None:
    """Wait briefly for more items, then batch-embed everything queued."""
    await asyncio.sleep(_EMBED_BATCH_DELAY)

    async with _embed_lock:
        if not _embed_queue:
            return
        batch = _embed_queue[:_EMBED_MAX_BATCH]
        del _embed_queue[:_EMBED_MAX_BATCH]

    texts = [t for t, _ in batch]
    futures = [f for _, f in batch]

    embeddings = await llm_client.embed_batch(texts)

    for future, embedding in zip(futures, embeddings):
        if not future.done():
            future.set_result(embedding)

    # If there are remaining items, flush again
    async with _embed_lock:
        if _embed_queue:
            asyncio.create_task(_flush_embed_queue())


async def add_memory(
    npc_name: str,
    memory: dict,
    embed: bool = True,
) -> dict:
    """Add a memory to ChromaDB with embedding.

    Args:
        npc_name: NPC identifier.
        memory: Memory dict with all fields from EpisodicMemory.
        embed: Whether to generate embedding (skip for batch imports).

    Returns:
        The memory dict (potentially with embedding added).
    """
    collection = get_collection(npc_name)
    mem_id = memory.get("id", f"mem_{collection.count():04d}")
    text = memory.get("text", memory.get("description", ""))

    # Generate embedding via batch queue (collects multiple requests into one API call)
    embedding: list[float] = []
    if embed and text:
        embedding = await _queue_embed(text)

    # Prepare metadata (ChromaDB only stores flat string/int/float/bool)
    metadata = _memory_to_metadata(memory)

    add_kwargs: dict[str, Any] = {
        "ids": [mem_id],
        "documents": [text],
        "metadatas": [metadata],
    }
    # Always pass embedding to prevent ChromaDB from using its built-in ONNX model
    if embedding:
        add_kwargs["embeddings"] = [embedding]
    else:
        # Zero vector fallback — will be re-embedded on next retrieval if needed
        add_kwargs["embeddings"] = [[0.0] * settings.embedding_dim]

    collection.upsert(**add_kwargs)
    return memory


def _memory_to_metadata(memory: dict) -> dict[str, Any]:
    """Convert memory dict to flat ChromaDB metadata."""
    return {
        "type": memory.get("type", "observation"),
        "importance": float(memory.get("importance", 5.0)),
        "emotional_valence": float(memory.get("emotional_valence", 0.0)),
        "timestamp": int(memory.get("timestamp", 0)),
        "game_time": int(memory.get("game_time", 0)),
        "game_day": int(memory.get("game_day", 0)),
        "game_hour": int(memory.get("game_hour", 0)),
        "last_accessed": int(memory.get("last_accessed", 0)),
        "access_count": int(memory.get("access_count", 0)),
        "observation_count": int(memory.get("observation_count", 1)),
        "stability": float(memory.get("stability", 12.0)),
        "protected": memory.get("protected", False),
        "superseded": memory.get("superseded", False),
        "summary_level": int(memory.get("summary_level", 0)),
        "actor": memory.get("actor", ""),
        "location": memory.get("location", ""),
        "observer_location": memory.get("observer_location", ""),
        "observed_near": memory.get("observed_near", ""),
        # Lists stored as JSON strings
        "entities": json.dumps(memory.get("entities", [])),
        "participants": json.dumps(memory.get("participants", [])),
        "shared_with": json.dumps(memory.get("shared_with", [])),
        # Gossip fields
        "gossip_source": memory.get("gossip_source", ""),
        "gossip_hops": int(memory.get("gossip_hops", 0)) if memory.get("gossip_hops") is not None else 0,
    }


def _metadata_to_memory(
    doc_id: str,
    document: str,
    metadata: dict,
) -> dict:
    """Convert ChromaDB result back to memory dict."""
    mem: dict[str, Any] = {
        "id": doc_id,
        "text": document,
        "description": document,
        "type": metadata.get("type", "observation"),
        "importance": metadata.get("importance", 5.0),
        "emotional_valence": metadata.get("emotional_valence", 0.0),
        "timestamp": metadata.get("timestamp", 0),
        "game_time": metadata.get("game_time", 0),
        "game_day": metadata.get("game_day", 0),
        "game_hour": metadata.get("game_hour", 0),
        "last_accessed": metadata.get("last_accessed", 0),
        "access_count": metadata.get("access_count", 0),
        "observation_count": metadata.get("observation_count", 1),
        "stability": metadata.get("stability", 12.0),
        "protected": metadata.get("protected", False),
        "superseded": metadata.get("superseded", False),
        "summary_level": metadata.get("summary_level", 0),
        "actor": metadata.get("actor", ""),
        "location": metadata.get("location", ""),
        "observer_location": metadata.get("observer_location", ""),
        "observed_near": metadata.get("observed_near", ""),
        "gossip_source": metadata.get("gossip_source", "") or None,
        "gossip_hops": metadata.get("gossip_hops", 0) or None,
    }
    # Deserialize JSON list fields
    for field in ("entities", "participants", "shared_with"):
        raw = metadata.get(field, "[]")
        if isinstance(raw, str):
            try:
                mem[field] = json.loads(raw)
            except json.JSONDecodeError:
                mem[field] = []
        else:
            mem[field] = raw
    return mem


async def retrieve_memories(
    npc_name: str,
    query_text: str,
    current_game_time: int,
    count: int = 8,
    type_filter: str = "",
    time_range_hours: float = -1,
) -> list[dict]:
    """Retrieve memories using vector search + hybrid re-ranking.

    1. Embed the query
    2. ChromaDB vector search (top 50 candidates)
    3. Re-rank with exact hybrid formula from memory_retrieval.gd
    4. Apply testing effect to retrieved memories
    """
    collection = get_collection(npc_name)
    if collection.count() == 0:
        return []

    # Build ChromaDB where filter
    where_filter: dict | None = None
    conditions: list[dict] = [{"superseded": False}]
    if type_filter:
        conditions.append({"type": type_filter})
    if len(conditions) == 1:
        where_filter = conditions[0]
    elif len(conditions) > 1:
        where_filter = {"$and": conditions}

    # Embed query
    query_embedding = await llm_client.embed_text(query_text)

    n_candidates = min(50, collection.count())

    results = None

    if query_embedding:
        # Vector search
        try:
            results = collection.query(
                query_embeddings=[query_embedding],
                n_results=n_candidates,
                where=where_filter,
                include=["documents", "metadatas", "distances"],
            )
        except Exception as e:
            # ChromaDB HNSW error on collections with no embeddings on disk yet
            logger.warning("ChromaDB query failed for %s: %s — falling back to keyword search", npc_name, e)
            results = None

    if results is None:
        # Fallback: keyword search (no embedding available or vector search failed)
        keywords = extract_keywords(query_text)
        results = collection.get(
            where=where_filter,
            include=["documents", "metadatas"],
            limit=n_candidates,
        )
        # Convert get() format to query() format for uniform processing
        results = {
            "ids": [results["ids"]],
            "documents": [results["documents"]],
            "metadatas": [results["metadatas"]],
            "distances": [None],
        }

    if not results["ids"] or not results["ids"][0]:
        return []

    # Re-rank with hybrid scoring
    scored: list[tuple[float, dict]] = []
    ids = results["ids"][0]
    docs = results["documents"][0]
    metas = results["metadatas"][0]
    distances = results["distances"][0] if results.get("distances") and results["distances"][0] else None

    for i, (doc_id, doc, meta) in enumerate(zip(ids, docs, metas)):
        # Time range filter
        if time_range_hours > 0:
            hours_ago = (current_game_time - meta.get("timestamp", 0)) / 60.0
            if hours_ago > time_range_hours:
                continue

        if distances is not None:
            # Vector search — use ChromaDB distance for scoring
            hybrid_score = score_memory(
                chroma_distance=distances[i],
                last_accessed=meta.get("last_accessed", 0),
                timestamp=meta.get("timestamp", 0),
                current_game_time=current_game_time,
                importance=meta.get("importance", 5.0),
                stability=meta.get("stability", 12.0),
                summary_level=meta.get("summary_level", 0),
            )
        else:
            # Keyword fallback
            keywords = extract_keywords(query_text)
            hybrid_score = score_by_keywords(
                text=doc,
                keywords=keywords,
                last_accessed=meta.get("last_accessed", 0),
                timestamp=meta.get("timestamp", 0),
                current_game_time=current_game_time,
                importance=meta.get("importance", 5.0),
                stability=meta.get("stability", 12.0),
                summary_level=meta.get("summary_level", 0),
            )

        memory = _metadata_to_memory(doc_id, doc, meta)
        scored.append((hybrid_score, memory))

    # Sort by score descending
    scored.sort(key=lambda x: x[0], reverse=True)

    # Take top-k and apply testing effect
    results_list: list[dict] = []
    for _, mem in scored[:count]:
        # Testing effect: retrieved memories grow stronger
        mem["last_accessed"] = current_game_time
        mem["access_count"] = mem.get("access_count", 0) + 1
        mem["stability"] = apply_testing_effect(mem.get("stability", 12.0))

        # Update in ChromaDB
        _update_metadata(npc_name, mem["id"], {
            "last_accessed": current_game_time,
            "access_count": mem["access_count"],
            "stability": mem["stability"],
        })

        results_list.append(mem)

    return results_list


def _update_metadata(npc_name: str, mem_id: str, updates: dict) -> None:
    """Update specific metadata fields for a memory in ChromaDB."""
    try:
        collection = get_collection(npc_name)
        existing = collection.get(ids=[mem_id], include=["metadatas"])
        if existing["metadatas"]:
            meta = existing["metadatas"][0].copy()
            meta.update(updates)
            collection.update(ids=[mem_id], metadatas=[meta])
    except Exception as e:
        logger.warning("Failed to update metadata for %s/%s: %s", npc_name, mem_id, e)


def assemble_memory_context(
    core_memory: dict,
    retrieved_memories: list[dict],
) -> str:
    """Build the full memory context string for LLM prompts.

    Matches memory_retrieval.gd assemble_memory_context() exactly.
    """
    context = ""

    # TIER 0: Always include core memory
    context += "=== WHO I AM ===\n"
    context += core_memory.get("identity", "") + "\n"
    context += "Current mood: " + core_memory.get("emotional_state", "neutral") + "\n"

    player_summary = core_memory.get("player_summary", "")
    if player_summary:
        context += "What I know about the player: " + player_summary + "\n"

    npc_summaries = core_memory.get("npc_summaries", {})
    for npc_name, summary in npc_summaries.items():
        context += f"About {npc_name}: {summary}\n"

    key_facts = core_memory.get("key_facts", [])
    if key_facts:
        context += "Key things I know: " + ", ".join(key_facts) + "\n"

    # TIER 1+2: Retrieved memories
    if retrieved_memories:
        context += "\n=== RELEVANT MEMORIES ===\n"
        for mem in retrieved_memories:
            day = mem.get("game_day", 0)
            hour = mem.get("game_hour", 0)
            text = mem.get("text", mem.get("description", ""))
            context += f"[Day {day}, Hour {hour}] {text}\n"

    return context


async def get_core_memory(npc_name: str) -> dict:
    """Load core memory from JSON file."""
    core_path = _project_root / settings.data_dir / "npc_data" / npc_name / "core_memory.json"
    if core_path.exists():
        try:
            return json.loads(core_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to load core memory for %s: %s", npc_name, e)
    return {
        "identity": "",
        "emotional_state": "Feeling neutral, starting the day.",
        "player_summary": "",
        "npc_summaries": {},
        "active_goals": [],
        "key_facts": [],
    }


async def save_core_memory(npc_name: str, core: dict) -> None:
    """Save core memory to JSON file."""
    folder = _project_root / settings.data_dir / "npc_data" / npc_name
    folder.mkdir(parents=True, exist_ok=True)
    core_path = folder / "core_memory.json"
    core_path.write_text(json.dumps(core, indent="\t"), encoding="utf-8")


def get_all_memories(npc_name: str) -> list[dict]:
    """Get all memories from ChromaDB for an NPC."""
    collection = get_collection(npc_name)
    if collection.count() == 0:
        return []
    results = collection.get(include=["documents", "metadatas"])
    memories = []
    for doc_id, doc, meta in zip(results["ids"], results["documents"], results["metadatas"]):
        memories.append(_metadata_to_memory(doc_id, doc, meta))
    return memories


def get_recent_memories(npc_name: str, count: int = 10) -> list[dict]:
    """Get most recent non-superseded memories."""
    all_mems = get_all_memories(npc_name)
    active = [m for m in all_mems if not m.get("superseded", False)]
    active.sort(key=lambda m: m.get("timestamp", 0), reverse=True)
    return active[:count]


def get_memories_by_type(npc_name: str, mem_type: str) -> list[dict]:
    """Get all memories of a specific type."""
    collection = get_collection(npc_name)
    if collection.count() == 0:
        return []
    results = collection.get(
        where={"type": mem_type},
        include=["documents", "metadatas"],
    )
    return [
        _metadata_to_memory(doc_id, doc, meta)
        for doc_id, doc, meta in zip(results["ids"], results["documents"], results["metadatas"])
    ]


def get_memories_about_entity(npc_name: str, entity_name: str, count: int = 5) -> list[dict]:
    """Get memories where entity_name is the actor or a participant."""
    all_mems = get_all_memories(npc_name)
    entity_mems = [
        m for m in all_mems
        if not m.get("superseded", False) and (
            m.get("actor", "") == entity_name
            or entity_name in m.get("participants", [])
            or entity_name in m.get("entities", [])
        )
    ]
    entity_mems.sort(key=lambda m: m.get("timestamp", 0), reverse=True)
    return entity_mems[:count]


def get_memory_counts(npc_name: str) -> dict[str, Any]:
    """Return total count and per-type breakdown."""
    collection = get_collection(npc_name)
    total = collection.count()
    if total == 0:
        return {"total": 0, "by_type": {}}

    all_mems = get_all_memories(npc_name)
    by_type: dict[str, int] = {}
    for m in all_mems:
        t = m.get("type", "observation")
        by_type[t] = by_type.get(t, 0) + 1
    return {"total": total, "by_type": by_type}


def get_gossip_candidates(
    npc_name: str,
    current_game_time: int,
    max_age_hours: int = 48,
    min_importance: float = 3.0,
) -> list[dict]:
    """Get recent important memories eligible for gossip sharing."""
    all_mems = get_all_memories(npc_name)
    candidates = []
    for m in all_mems:
        if m.get("superseded", False):
            continue
        if m.get("importance", 0) < min_importance:
            continue
        hours_ago = (current_game_time - m.get("game_time", 0)) / 60.0
        if hours_ago > max_age_hours:
            continue
        mem_type = m.get("type", "")
        if mem_type in ("observation", "dialogue", "environment", "reflection", "gossip"):
            candidates.append(m)
    candidates.sort(
        key=lambda x: x.get("importance", 0) * pow(0.98, (current_game_time - x.get("game_time", 0)) / 60.0),
        reverse=True,
    )
    return candidates[:30]


def texts_are_similar(a: str, b: str, threshold: float = 0.85) -> bool:
    """Check if two texts are similar by word overlap. Matches memory_system.gd."""
    set_a = set(a.lower().split())
    set_b = set(b.lower().split())
    intersection = len(set_a & set_b)
    union = len(set_a | set_b)
    if union == 0:
        return True
    return intersection / union >= threshold
