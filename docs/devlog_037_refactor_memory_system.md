# Devlog 037 — Refactor memory_system.gd into 3 Files

## What Changed

Split the 1,004-line `memory_system.gd` into a 589-line orchestrator + 2 sub-component scripts. Zero behavior changes — pure organizational restructure. Public API 100% preserved via thin delegation methods.

## Architecture

```
MemorySystem (RefCounted)           ← memory_system.gd (589 lines)
├── MemoryRetrieval (RefCounted)    ← memory_retrieval.gd (280 lines)
└── MemoryPersistence (RefCounted)  ← memory_persistence.gd (238 lines)
```

Sub-components are RefCounted objects owned by MemorySystem via composition. They access shared data (episodic_memories, core_memory, archival_summaries) through an untyped `_mem` parent reference (avoids circular class_name dependency).

## What Moved Where

### memory_retrieval.gd (7 functions)
- `retrieve()` — embedding-based scored retrieval
- `retrieve_memories()` — full hybrid retrieval with filters (episodic + archival)
- `retrieve_by_keywords()` — fallback keyword retrieval
- `retrieve_by_query_text()` — keyword extraction + dual-tier search
- `score_memory()` — hybrid scoring formula (relevance × 0.5 + recency × 0.3 + importance × 0.2)
- `assemble_memory_context()` — builds full Gemini context string
- `cosine_similarity()` — static utility

### memory_persistence.gd (9 functions)
- `save_core_memory()` — JSON save for Tier 0
- `save_all()` — full three-tier save (core + episodic + embeddings + archival)
- `serialize_episodic()` / `deserialize_episodic()` — episodic JSON serialization
- `save_embeddings()` / `load_embeddings()` — binary embedding files
- `serialize_compat()` / `deserialize_compat()` — old MemoryStream format
- `migrate_from_memory_stream()` — migration from legacy system

### What Stays on MemorySystem
- All constants (shared by sub-components)
- All shared state (core_memory, episodic_memories, archival_summaries)
- Memory creation + deduplication (create_memory, add_memory)
- Core memory updates (update_emotional_state, update_player_summary, etc.)
- Backward-compat accessors (get_recent, get_by_type, get_memories_about)
- Compression API (get_compression_candidates, apply_episode/period_compression)
- Forgetting curves (apply_daily_forgetting)
- Thin delegation methods preserving the public API

## Circular Dependency Fix

Godot 4 doesn't allow circular `class_name` references between scripts. Since sub-components need to reference MemorySystem constants and MemorySystem needs to instantiate sub-components:
- Sub-components have NO `class_name` — use untyped `_mem` parent reference
- MemorySystem uses `preload()` to load sub-component scripts
- Constants accessed via `_mem.CONSTANT` (instance access works at runtime)

## Files Changed

| File | Action |
|------|--------|
| `scripts/npc/memory_system.gd` | 1,004 → 589 lines |
| `scripts/npc/memory_retrieval.gd` | NEW (280 lines) |
| `scripts/npc/memory_persistence.gd` | NEW (238 lines) |
| All other scripts | NO CHANGES — public API preserved |
