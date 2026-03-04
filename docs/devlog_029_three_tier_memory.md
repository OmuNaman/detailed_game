# Devlog 029 — Three-Tier Memory Architecture

## What Changed
Replaced the flat `MemoryStream` (200-entry FIFO cap) with a three-tier memory system inspired by Stanford Generative Agents + MemGPT.

### The Problem
Environment scans generated ~64 duplicate memories per NPC per day ("the oven is baking" every 30 min), evicting meaningful conversations, reflections, and player interactions within 2-3 days.

### The Solution: Three Tiers

**Tier 0 — Core Memory** (~800 tokens, always in every Gemini call):
- `identity`: NPC personality (set once, never changes)
- `emotional_state`: Updated after reflections ("I feel uneasy about the newcomer")
- `player_summary`: Rewritten by Gemini after player conversations
- `npc_summaries`: Top 5 NPC relationship summaries (max 1-2 sentences each)
- `active_goals`: From daily planning system
- `key_facts`: Max 10 permanent learned facts
- Persisted to `user://npc_data/{name}/core_memory.json`

**Tier 1 — Episodic Memory** (no hard cap, 500-2000 memories typical):
- Full searchable memory store with new fields: `id`, `stability`, `observation_count`, `protected`, `superseded`, `summary_level`
- **Stability-based decay**: Each type has a base stability (observation=6h, reflection=72h, player_dialogue=48h). Emotional memories last 3.4× longer at ±0.8 valence
- **Protection**: Memories with importance≥8.0 or type="player_dialogue" are protected from future summarization
- **Deduplication**: Exact hash + Jaccard text similarity (0.85 threshold) prevents duplicate observations. State-change detection marks old observations as `superseded`
- Persisted to `episodic_memories.json` (metadata) + `embeddings.bin` (packed float32)

**Tier 2 — Archival Summaries** (empty structure for future use):
- Will hold compressed summaries from Prompt L (Memory Compression)
- Same structure as episodic, with `summary_level >= 1`

### Hybrid Retrieval
New scoring formula: `0.5 × relevance + 0.3 × recency + 0.2 × importance`
- **Relevance**: Cosine similarity of 768-dim Gemini embeddings
- **Recency**: Power-law decay `(1 + 0.234 × hours/stability)^(-0.5)` — stability-aware, not flat exponential
- **Importance**: Normalized 1-10 → 0-1
- **Testing effect**: Retrieved memories get +10% stability (capped at 500h) — recall strengthens memory
- Filters: type, entity, time range. Superseded memories excluded

### Batch Embeddings
- New `EmbeddingClient.embed_batch()` using Gemini `batchEmbedContents` API
- Embedding queue in each NPC: collects new memories, batch-embeds every 5 real seconds (up to 10 at a time)
- Reduces API calls from N individual requests to ceil(N/10) batch requests

### Core Memory in Prompts
- System prompt now includes: emotional state, player summary, NPC summaries, key facts
- Player summary updated by Gemini after every player conversation
- Emotional state updated from reflection insights
- Active goals set from daily planning

### Backward Compatibility
- `memory.memories` property redirects to `episodic_memories`
- Old `serialize()`/`deserialize()` still work for existing saves
- `_add_memory_with_embedding()` signature unchanged — now routes through deduplication
- Old `memory_stream.gd` kept for migration; new saves use `episodic_memories.json`
- Debug overlay, gossip system, all context builders work unchanged

## Files Changed
- **NEW** `scripts/npc/memory_system.gd` — MemorySystem class (820 lines)
- **MODIFIED** `scripts/npc/npc_controller.gd` — Swapped MemoryStream→MemorySystem, added embedding queue, core memory in prompts, player summary updates
- **MODIFIED** `scripts/llm/embedding_client.gd` — Added batch embedding API
- **MODIFIED** `scripts/world/town.gd` — Updated save/load for three-tier format

## Phase 1 Progress
- [x] Memory Stream → Three-tier memory architecture
- [x] Memory Retrieval → Hybrid (embedding + stability-decay + importance)
- [x] Observation deduplication + state-change detection
