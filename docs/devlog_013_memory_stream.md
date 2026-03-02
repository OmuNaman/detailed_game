# DevLog 013 — Memory Stream (Stanford Generative Agents, Pillar 1)

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** NPCs now have a scored memory system replacing the flat observation array. Memories are stored, retrieved by recency+importance+relevance, and persist across sessions.

---

## What Changed

The flat `observations: Array[Dictionary]` (capped at 50, FIFO eviction, no scoring) has been replaced by the **Memory Stream** — a scored retrieval system inspired by the Stanford Generative Agents paper (Park et al., 2023). This is Pillar 1 of the NPC cognitive architecture described in CLAUDE.md.

---

## The Memory Stream System

### Memory Record Structure

Each memory is a Dictionary stored in `MemoryStream.memories`:

| Field | Type | Description |
|-------|------|-------------|
| `description` | String | "Saw Player near the Bakery" |
| `type` | String | "observation", "reflection", "plan", "dialogue", or "rumor" |
| `actor` | String | Primary entity: "Player", "Maria", etc. |
| `participants` | Array[String] | All entities involved: ["Gideon", "Player"] |
| `observer_location` | String | Where the OBSERVER was when they saw it |
| `observed_near` | String | Where the OBSERVED entity actually was |
| `game_time` | int | GameClock.total_minutes when created |
| `importance` | float | 1.0-10.0 scale (Player sightings = 5.0, NPC sightings = 2.0) |
| `emotional_valence` | float | -1.0 (terrible) to +1.0 (wonderful) |
| `embedding` | PackedFloat32Array | 768-dim vector from Gemini, or empty if API unavailable |
| `last_accessed` | int | GameClock.total_minutes when last retrieved |
| `access_count` | int | Times this memory was retrieved (starts at 0) |

### Key fix from devlog 012: Location is now dual-tracked

**Before:** Only stored `location` — where the OBSERVING NPC was. If Gideon was at the Tavern and saw the Player walk by near the Bakery, the observation said "near Tavern".

**After:** Two separate fields:
- `observer_location`: Where the NPC was ("Tavern")
- `observed_near`: Where the entity actually was ("Bakery")

The `_estimate_location()` helper finds the nearest building to any world position by checking distance to all building door positions. Dialogue now uses `observed_near` — so NPCs correctly say "I saw you near the Bakery" instead of "near the Tavern".

---

## The Three-Score Retrieval Algorithm

When an NPC needs to recall memories (e.g., for dialogue), every memory is scored using three components:

### 1. Recency Score
```
recency = pow(0.99, hours_since_memory)
```
- Memory from 1 hour ago: 0.99^1 = 0.99
- Memory from 24 hours ago: 0.99^24 = 0.79
- Memory from 7 days (168 hours): 0.99^168 = 0.18
- Memory from 30 days (720 hours): 0.99^720 = 0.0007

Recent memories dominate. Very old memories effectively score 0 on recency alone.

### 2. Importance Score
```
importance_score = memory.importance / 10.0
```
- Routine NPC sighting (importance 2): score = 0.2
- Player sighting (importance 5): score = 0.5
- Witnessed crime (importance 9): score = 0.9
- Life event (importance 10): score = 1.0

### 3. Relevance Score (two modes)

**With embeddings (API available):**
```
relevance = cosine_similarity(query_embedding, memory.embedding)
```
Both the query context ("Player is talking to Gideon at the Tavern") and each memory description are embedded via Gemini `gemini-embedding-001` into 768-dimensional vectors. Cosine similarity measures semantic closeness (-1.0 to 1.0).

**Without embeddings (offline fallback):**
```
relevance = keyword_match_count / total_keywords
```
Keywords from the query are matched against the memory description (case-insensitive). If 3 of 5 keywords match, relevance = 0.6.

### Final Score
```
final_score = (recency * 1.0) + (importance_score * 1.0) + (relevance * 1.0)
```
Equal weights (1.0 each). Top N memories are returned. Retrieved memories get their `last_accessed` and `access_count` updated — frequently accessed memories are harder to evict.

---

## Embedding Integration

### Gemini API Setup

The `EmbeddingClient` autoload handles all API communication:
- Model: `gemini-embedding-001`
- Endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent`
- Output: 768-dimensional float vector per text input
- API key loaded from `user://.env` (first line of the file)

### Request Queue

Godot's `HTTPRequest` node handles only one request at a time. The `EmbeddingClient` solves this with a request queue:
1. `embed_text()` pushes `{text, callback}` onto `_request_queue`
2. If no request is in flight, immediately sends the first queued item
3. When `_on_request_completed` fires, it processes the response, then calls `_process_next_request()` to send the next queued item
4. This serializes all embedding requests without batching

### Async Memory Creation Flow
```
_on_perception_body_entered() fires
  → _add_memory_with_embedding() called
    → memory.add_memory() creates record immediately (embedding = empty)
    → EmbeddingClient.embed_text() fires async HTTP request
    → When response arrives: mem["embedding"] = embedding (updates in-place)
```

The memory exists immediately for retrieval. The embedding arrives later and improves future relevance scoring. If the API call fails, the empty embedding is kept and keyword-based fallback handles relevance.

### Graceful Offline Mode

The system works fully without an API key:
- No `.env` file → `EmbeddingClient.has_api_key()` returns false
- `embed_text()` immediately calls callback with empty `PackedFloat32Array()`
- All memories stored with empty embeddings
- `retrieve()` still works — cosine similarity returns 0.0 for empty embeddings, so scoring falls back to recency + importance only
- `retrieve_by_keywords()` provides explicit keyword-based relevance scoring

---

## Memory Eviction Policy

Cap: 200 memories per NPC. When full, the memory with the **lowest eviction score** is removed:

```
eviction_score = (importance/10 * 0.5) + (access_count/10 * 0.3) + (recency * 0.2)
```

This means:
- High-importance memories survive (weight 0.5)
- Frequently retrieved memories survive (weight 0.3)
- Recent memories have a slight edge (weight 0.2)

A mundane 2-day-old NPC sighting (importance 2, accessed 0 times) gets evicted before a player sighting from yesterday (importance 5, accessed 3 times).

---

## Memory Persistence

Memories now survive between game sessions.

### Auto-Save
`town.gd` listens for `NOTIFICATION_WM_CLOSE_REQUEST` (window close) and saves all NPC memory streams to `user://npc_memories.json`.

### Manual Save
Press **F5** to quicksave memories at any time. Console prints confirmation.

### Auto-Load
After NPCs spawn in `_spawn_npcs()`, `_load_all_memories()` reads `user://npc_memories.json` and deserializes each NPC's memory stream.

### Save File Format
`user://npc_memories.json` — readable JSON with indentation:
```json
{
    "Maria": {
        "memories": [
            {
                "description": "Saw Player near the Bakery",
                "type": "observation",
                "actor": "Player",
                "participants": ["Maria", "Player"],
                "observer_location": "Bakery",
                "observed_near": "Bakery",
                "game_time": 487,
                "importance": 5.0,
                "emotional_valence": 0.1,
                "embedding": [0.123, -0.456, ...],
                "last_accessed": 520,
                "access_count": 2
            }
        ]
    },
    "Gideon": { ... }
}
```

### Serialization Detail
`PackedFloat32Array` (binary) is converted to `Array[float]` (JSON-safe) on save, and converted back on load.

### What Does NOT Save Yet
- NPC needs (hunger/energy/social) — reset to 100
- NPC positions — respawn at home
- Game time — starts at Day 1, 6:00 AM
- These will be added with the full SaveManager system

---

## Periodic Perception Scan

**Fix for devlog 012 issue #5:** If NPCs start already overlapping (e.g., two NPCs at the same building at game start), `body_entered` never fires.

New: Every 30 game minutes, `_on_time_tick()` calls `_scan_perception_area()` which iterates `get_overlapping_bodies()` and re-processes each one. The existing 60-minute cooldown per actor prevents duplicate memories.

---

## How It Plays — A Walkthrough

Here's what actually happens when you run the game and interact with NPCs:

### Scenario: Fresh game start, walk to the Church, then visit the Blacksmith

1. **6:00 AM** — Game starts. All NPCs spawn at home, memories are empty (or loaded from last session via `npc_memories.json`).
2. NPCs leave home for work. The Priest walks to the Church, the Blacksmith walks to the Blacksmith shop.
3. **You walk toward the Church.** As you approach, you enter the Priest's PerceptionArea (160px = 5 tiles radius). The Priest creates a memory: `"Saw Player near the Church"` with `observed_near = "Church"`.
4. **You press E near the Priest.** His `get_dialogue_response()` finds the player memory from seconds ago. He says: **"Oh, I just saw you over by the Church! What brings you here?"** — This feels odd because you literally just walked up. He's stating the obvious. But it's technically correct — he DID just see you near the Church.
5. **You walk to the Blacksmith shop.** Here's where it gets interesting: if the Blacksmith shop is within 10 tiles of the Church, the Blacksmith's 5-tile PerceptionArea may have already detected you while you were near the Church. His memory says: `"Saw Player near the Church"` with `observed_near = "Church"`.
6. **You press E near the Blacksmith.** He says: **"Oh, I just saw you over by the Church! What brings you here?"** — This is the system working correctly. The Blacksmith has a 160px "line of sight" — think of it as looking out his window and seeing you walk past the Church.

### Why the Blacksmith knows you were at the Church

The PerceptionArea is 160px (5 tiles) radius. That's intentionally large — NPCs should notice things happening in their general vicinity, not just directly on top of them. If the Blacksmith shop and Church are close enough (within 10 tiles center-to-center), the Blacksmith's perception circle overlaps the Church area. He "saw you through the window."

### Memory persistence across sessions

Close the game → memories auto-save to `user://npc_memories.json`. Relaunch → memories load back. If you talked to the Priest yesterday (real time), he still remembers. His dialogue will say: **"I remember seeing you around the Church a while back."** (because `hours_ago > 12` in game time since the game clock resets to Day 1, 6:00 AM on restart — time doesn't persist yet).

**Gotcha:** Game time resets but memories don't. A memory from "487 total_minutes" in the last session will appear very recent if the current session is also around minute 487. Once full time persistence is added (future SaveManager), this resolves naturally.

---

## Strengths of the Current System

1. **Dual location tracking works.** NPCs correctly reference where YOU were, not where they were. "I saw you near the Bakery" means you were actually near the Bakery.
2. **Time-aware dialogue.** NPCs distinguish between "just saw you" (< 1 hour), "earlier today" (< 12 hours), and "a while back" (older). This makes conversations feel more natural.
3. **Scored retrieval is future-proof.** The recency + importance + relevance algorithm is the same one used in the Stanford Generative Agents paper. When embeddings work (valid API key), relevance scoring will surface semantically related memories, not just the most recent one.
4. **Graceful offline fallback.** No API key? System still works with recency + importance. No degradation in gameplay, just less sophisticated retrieval.
5. **Memory persistence.** Close and reopen — NPCs remember. This is the first step toward a persistent living world.
6. **Eviction is smart, not FIFO.** Old unimportant memories that nobody accesses get evicted first. A dramatic event (importance 9) from a week ago survives while yesterday's routine sighting (importance 2) gets evicted.

## Current Limitations

1. **Perception radius is large and uniform.** 160px (5 tiles) means NPCs "see through walls" — a Blacksmith in his shop can detect the player near the Church if they're close enough. No line-of-sight checks, no wall occlusion. Fix: raycast-based visibility or reduced radius inside buildings.
2. **Dialogue is still template-based.** The Memory Stream stores rich data (importance, valence, embeddings) but `get_dialogue_response()` just picks the most recent player memory and uses a hardcoded template. The real payoff comes when Gemini LLM generates dialogue using retrieved memories as context.
3. **Game time doesn't persist.** Memories save across sessions but `GameClock.total_minutes` resets to 0. This means old memories appear "recent" in a new session because the time difference is small. Will be fixed when the full SaveManager saves game time.
4. **No reflection yet.** `get_importance_sum_since()` exists to trigger reflections, but nothing calls it yet. NPCs accumulate observations but never synthesize insights. That's Pillar 2.
5. **No gossip propagation.** NPCs create "observation" type memories but never share them. Maria can't tell Gideon "I saw the Player near the Church." That's a future system.
6. **All NPCs have the same dialogue templates.** The Priest and the Blacksmith say the exact same lines in the same situations. Personality-driven dialogue requires LLM integration.
7. **Embedding API adds latency.** Each memory creation fires an HTTP request to Gemini. At high game speeds (60x), many memories are created per second, and the request queue grows. Not a problem at 5 NPCs, but at 20+ NPCs this would need batching or rate limiting.
8. **`_estimate_location()` uses door positions only.** If the player is standing in the middle of a road far from any building, the nearest building door might still be 8+ tiles away, but the system will still say "near the General Store" because it's the closest one. No concept of "in the open" or "on the road."

---

## Updated Dialogue System

Dialogue response generation moved from `player_controller.gd` into `npc_controller.gd` as `get_dialogue_response()`. The priority cascade is now:

| Priority | Condition | Response Example |
|----------|-----------|-----------------|
| 1 | energy < 20 | "*yawns* I'm exhausted..." |
| 2 | hunger < 20 | "I'm starving, need to go eat." |
| 3 | Has player memory, < 1 hour ago | "Oh, I just saw you over by the Bakery!" |
| 4 | Has player memory, < 12 hours ago | "I saw you near the Bakery earlier today." |
| 5 | Has player memory, older | "I remember seeing you around the Bakery..." |
| 6 | mood > 70 | "Beautiful day! Work at the Blacksmith..." |
| 7 | mood > 40 | "Just another day at the Blacksmith." |
| 8 | else | "I'm not feeling great today..." |

The time-aware phrasing is new — NPCs now reference *how long ago* they saw you, not just where.

---

## Updated Debug Overlay

F3 now shows per NPC:
- Name, job, destination (unchanged)
- Needs bars: hunger/energy/social (unchanged)
- **Mem: N** instead of "Obs: N" — total memories in stream
- **Top 3 recent memories** — description text (truncated to 40 chars) in gray

---

## Files Created
| File | Purpose |
|------|---------|
| `scripts/npc/memory_stream.gd` | MemoryStream class (RefCounted) — scored storage + retrieval |
| `scripts/llm/embedding_client.gd` | EmbeddingClient autoload — Gemini embedding API with request queue |

## Files Modified
| File | Changes |
|------|---------|
| `scripts/npc/npc_controller.gd` | Replaced `observations` array with `memory: MemoryStream`, added `_estimate_location()`, `_add_memory_with_embedding()`, `_scan_perception_area()`, `get_dialogue_response()` |
| `scripts/player/player_controller.gd` | Removed `_generate_npc_response()`, now calls `npc.get_dialogue_response()` |
| `scripts/ui/debug_overlay.gd` | Shows memory count + top 3 recent memory descriptions |
| `scripts/world/town.gd` | Added `_save_all_memories()`, `_load_all_memories()`, F5 quicksave, auto-save on close |
| `project.godot` | Added EmbeddingClient autoload, added `quicksave` input action (F5) |

---

## Controls Reference
| Key | Action |
|-----|--------|
| W/A/S/D or Arrows | Move player |
| E / Space | Talk to nearest NPC (toggle) |
| F3 | Toggle debug overlay |
| F5 | Quicksave NPC memories |
| F6 | Cycle time speed (1x → 2x → 5x → 10x → 30x → 60x) |

---

## Phase 1 Checklist Progress

### Completed (11/19)
- [x] Project setup
- [x] Tile map with buildings
- [x] Player movement
- [x] Game clock with day/night cycle
- [x] NPC spawning with core descriptions
- [x] NPC pathfinding (A* on tilemap)
- [x] Basic needs system
- [x] Observation system
- [x] Interaction system
- [x] **Memory Stream — scored MemoryRecords with retrieval** ← NEW
- [x] **Memory Retrieval — recency + importance + relevance** ← NEW

### Remaining (8/19)
- [ ] Daily Planning — NPCs generate morning plans
- [ ] Gossip propagation — NPCs share observations during social time
- [ ] Reflection system — periodic insight generation
- [ ] Crime detection — witness-based
- [ ] Sheriff arrest mechanic
- [ ] Simple court trial
- [ ] Reputation tracking
- [ ] LLM integration (Gemini API for dialogue)

### Progress: 58% complete (11 of 19 items)
