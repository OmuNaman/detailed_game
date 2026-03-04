# PROJECT: DeepTown — A Dwarf Fortress-Depth 2D Town Simulation

## Vision
A top-down 2D pixel-art town simulation (GBA Pokemon aesthetic) with Dwarf Fortress-level depth. Every NPC has memory, relationships, schedules, opinions, and agency. The town has working law, crime, courts, economy, and reputation. LLMs power NPC dialogue and decision-making. Built in **Godot 4 (GDScript)**.

## Tech Stack
- **Engine:** Godot 4.x (GDScript only, no C#)
- **Art Style:** 16x16 or 32x32 pixel tiles, top-down GBA Pokemon style
- **LLM Integration:** Gemini API (Flash for dialogue, Flash Lite for analysis/compression)
- **Embeddings:** Gemini `text-embedding-004` (768-dim) for memory retrieval
- **Target:** Desktop (Windows/Linux/Mac)

## Architecture Principles
- **Data-driven:** NPCs, items, buildings, laws, jobs defined in JSON/Resource files — NOT hardcoded
- **ECS-inspired:** Use Godot nodes as components. NPCs are scenes composed of: `AIBrain`, `Memory`, `Relationships`, `Needs`, `Schedule`, `Inventory`, `Reputation`
- **Simulation-first:** The world ticks forward even offscreen. NPCs act whether the player sees them or not
- **Memory is sacred:** Three-tier memory architecture (Core → Episodic → Archival). Memories never truly disappear — they compress into summaries. Important memories are protected forever
- **Stanford Generative Agents:** Architecture inspired by Park et al. 2023, extended with MemGPT-style Core Memory, explicit relationship tracking, and hierarchical plan decomposition

## Project Structure
```
deeptown/
├── CLAUDE.md                    # This file
├── project.godot
├── assets/
│   ├── sprites/                 # Character spritesheets, tilesets
│   ├── audio/                   # SFX, ambient
│   └── fonts/                   # Pixel fonts
├── scenes/
│   ├── world/                   # Town map, buildings, interiors
│   ├── npcs/                    # NPC base scene + variants
│   ├── ui/                      # HUD, dialogue, court UI, debug overlay
│   └── systems/                 # Autoloads and system scenes
├── scripts/
│   ├── core/                    # GameClock, EventBus, SaveManager, WorldObjects, Relationships, PlayerProfile
│   ├── npc/                     # npc_controller.gd, memory_stream.gd (being replaced by three-tier)
│   ├── systems/                 # CrimeSystem, CourtSystem, EconomySystem, ReputationSystem
│   ├── world/                   # BuildingManager, WeatherSystem, TileInteraction
│   ├── player/                  # PlayerController, PlayerInventory, PlayerActions
│   └── llm/                     # gemini_client.gd (generate, embedding endpoints)
├── data/
│   ├── npcs/                    # Per-NPC save folders (memories, conversations, gossip, core_memory.json)
│   └── ...                      # npcs.json, buildings.json, items.json, laws.json, jobs.json
└── docs/
    └── devlog_*.md              # Devlogs 001-028+
```

---

## Current State — What's Implemented

### Foundation (Pre-Prompt Systems)
- **Pathfinding:** AStarGrid2D (replaced broken NavigationServer2D). Waypoint following via `_path: PackedVector2Array`
- **Game Clock:** `GameClock` autoload. `hour`, `minute`, `total_minutes`, `time_scale` (F6 cycles 1x-60x). Signals: `time_tick(game_minute)`, `time_hour_changed(hour)`
- **Event Bus:** `EventBus` autoload for decoupled signal routing
- **Player:** Top-down 4-directional movement. E key to interact. In group `"player"`
- **NPCs:** 11 NPCs in group `"npcs"`. Each has: `npc_name`, `age`, `job`, `personality`, `home_building`, `workplace_building`
- **Gemini Client:** `GeminiClient` autoload with `generate()` for dialogue and `get_embedding()` / `get_embeddings_batch()` for vectors
- **Perception:** Area2D with CircleShape2D radius 160px, collision_mask = 6 (player layer 2 + NPC layer 4)
- **Tile Reservation:** Anti-stacking system prevents NPCs from occupying the same tile
- **Per-NPC Save Folders:** Each NPC saves memories, conversations, gossip to `data/npcs/{name}/`
- **Debug Overlay:** F3 shows needs bars, observation count, memory stats

### Prompt A — Stateful Furniture (✅ Implemented)
`WorldObjects` autoload tracks every interactable object in every building. Objects have state (idle/baking/forging/serving), current user, and transitions. NPCs claim objects on arrival, release on departure.

### Prompt B — NPC Activity System (✅ Implemented)
Visible activity descriptions derived from location + object + needs + time. Emojis above heads. Observers see activities: "Saw Maria kneading dough near the Bakery."

### Prompt C — Working Doors & Sprite States (✅ Implemented)
Doors open/close on NPC entry/exit. Visual occupancy indicators (lit windows, chimney smoke). Direction-aware sprites.

### Prompt D — Reflection System (✅ Implemented, will be REPLACED by Prompt L)
Nightly reflections at hour 22 via Gemini. 1-3 insights stored as type="reflection" with importance 7.0. Basic system — Prompt L upgrades to full Stanford two-step with 5 questions × 5 insights.

### Prompt E — Environment Perception (✅ Implemented)
Every 30 game-minutes, NPCs scan building objects for notable states. Absence awareness (empty workplace). Rich observations: "Saw Gideon hammering metal at the anvil (the anvil was forging)."

### Prompt F — Relationships (✅ Implemented)
`Relationships` autoload: Trust/Affection/Respect per NPC pair (-100 to 100). Seeded from lore. Daily decay. Currently flat +1/+1 per conversation — Prompt J upgrades to content-aware.

### Prompt G — Gossip System (✅ Implemented)
40% gossip chance during NPC-to-NPC conversations. Trust ≥ 15 gate. Hop tracking (max 3), importance decay per hop. Type="gossip" memories. Prompt N reduces to 20% and adds natural diffusion.

### Prompt H — Daily Planning (✅ Implemented)
At hour 5, each NPC generates 2-4 plans via Gemini with hour/destination/reason. Plans override default schedule. Emergency overrides (hunger/energy < 20) and sleep (23-5) always win. Prompt N extends to 3-level recursive decomposition.

---

## Pending Implementation (Prompts I–N)

These prompt documents are written and ready to feed to Claude Code **in this exact order:**

### Step 1: Prompt I — Three-Tier Memory Architecture
**REPLACES** the flat `memory_stream[200]` with FIFO eviction.
- Tier 0 (Core Memory): ~800 tokens always in every prompt. Identity, emotional_state, player_summary, npc_summaries, key_facts.
- Tier 1 (Episodic Memory): Unlimited vector-searchable archive. 768-dim embeddings. 20+ fields per memory.
- Tier 2 (Archival Summaries): Compressed summaries with embeddings.
- Retrieval: `score = 0.5×relevance + 0.3×recency + 0.2×importance`. Top 8 returned.
- Two-phase deduplication: hash-based exact match + Jaccard state-change detection.
- Migration: old memory_stream auto-converts to new format.

### Step 2: Prompt K — Bug Fix Mega-Patch (11 fixes)
EnvScan sleep guard, conversation sleep guard, gossip `shared_with` tracking, NPC-workplace mapping in plans, plan-location activity check, large building conversation distance (192px), Finn-Clara 3/day cap, Day 1 planning trigger, Tavern minimum 1-hour stay, player name consistency, Thomas routing fix.

### Step 3: Prompt J — Conversation Impact
**REPLACES** flat +1/+1 with content-aware analysis via Flash Lite.
- Player conversations: trust/affection/respect changes (-5 to +5) based on content.
- Core Memory updates: emotional_state, player_summary, key_facts evolve per conversation.
- NPC-to-NPC: bidirectional analysis (-3 to +3), npc_summaries updates.
- Gossip impact: listener's Trust toward subject shifts based on valence.
- Relationship-aware dialogue: Trust/Affection/Respect descriptions in all prompts.

### Step 4: Prompt L — Compression + Enhanced Reflections
**REPLACES** Prompt D reflection system.
- Episode summaries (Level 1): oldest 30 raw memories → 3-5 sentence summary.
- Period summaries (Level 2): oldest 7 episodes → 2-3 sentence summary.
- Forgetting curves: stability decay (×0.7 observations, ×0.85 others). Protected memories immune.
- Enhanced reflections: 100 recent memories → 5 questions → 5 insights per question with citations.
- Midnight routine: decay → reflect → forget → compress → save.

### Step 5: Prompt M — Memory-Aware Dialogue Integration
**REWIRES** all Gemini dialogue calls to use retrieval.
- Player dialogue: player text → retrieval query → top 8 memories + Core Memory + relationship in prompt.
- Working memory: last 6 turns for multi-turn conversations.
- Conversation summary: on end, summarize to single protected memory.
- Emotional state persistence: mood carries between interactions, decays to neutral after 3+ quiet hours.
- Past event recall: "Remember when we first met?" → retrieval surfaces actual first conversation.

### Step 6: Prompt N — Stanford Complete Features
**ADDS** four missing Stanford features:
1. **Recursive Plan Decomposition:** 3-level (day→hour→5min). Lazy evaluation — decompose just-in-time.
2. **Real-time Plan Re-evaluation:** On significant observations, evaluate CONTINUE or REACT. Replan from current moment.
3. **Environment Tree Traversal:** Hierarchical world tree (Building→Area→Object). Per-NPC known_world subgraph.
4. **Natural Information Diffusion:** Retrieval-driven third-party mentions in conversation. Reduces explicit gossip to 20%.
5. **Turn-by-Turn Dialogue:** Each speaker retrieves memories before generating their line.

---

## NPC Roster (11 NPCs)

| Name | Job | Workplace | Home | Key Traits |
|------|-----|-----------|------|------------|
| Maria | Baker | Bakery | House 1 | Warm, gossips, resents mayor over rent |
| Thomas | Shopkeeper | General Store | House 2 | Practical, fair, community-minded |
| Elena | Sheriff | Sheriff Office | House 3 | Tough, principled, sense of justice |
| Gideon | Blacksmith | Blacksmith | House 4 | Shy, skilled, secret crush on Maria |
| Rose | Barmaid | Tavern | House 5 | Social, observant, hears everything |
| Lyra | Clerk | Courthouse | House 6 | Meticulous, ambitious, quietly sharp |
| Finn | Farmer/Laborer | General Store | House 7 | Hardworking, simple, married to Clara |
| Clara | Churchgoer | Church | House 7 | Devout, kind, married to Finn |
| Bram | Apprentice | Blacksmith | House 8 | Eager, young, looks up to Gideon |
| Old Silas | Retired | Tavern | House 9 | Storyteller, suspicious, knows secrets |
| Father Aldric | Priest | Church | House 10 | Wise, patient, crisis counselor |

### Key Relationships (Seeded)
- Gideon → Maria: Affection 55 (secret crush)
- Finn ↔ Clara: High trust/affection (married)
- Bram → Gideon: High respect (mentor)
- Old Silas: Low trust toward most (suspicious nature)
- Elena ↔ Aldric: Mutual respect (community pillars)

---

## Autoloads

| Autoload | Purpose |
|----------|---------|
| `GameClock` | Time management. `hour`, `minute`, `total_minutes`, `time_scale` |
| `EventBus` | Signal routing. `time_tick`, `time_hour_changed` |
| `WorldObjects` | Tracks all furniture objects, states, users per building |
| `Relationships` | Trust/Affection/Respect tracking for all NPC pairs |
| `GeminiClient` | LLM API calls: `generate()`, `get_embedding()`, `get_embeddings_batch()` |
| `PlayerProfile` | Player identity: `player_name` used everywhere |

---

## Key File Locations

| File | Purpose |
|------|---------|
| `scripts/npc/npc_controller.gd` | Main NPC brain: movement, scheduling, planning, perception, conversations, activities |
| `scripts/npc/memory_stream.gd` | Current memory system (200-cap FIFO — being replaced by Prompt I) |
| `scripts/core/world_objects.gd` | Stateful furniture tracking |
| `scripts/core/relationships.gd` | Relationship scores and modification |
| `scripts/llm/gemini_client.gd` | Gemini API wrapper |
| `data/npcs/{name}/` | Per-NPC save data (memories, conversations, gossip) |

---

## Memory Types in Current System

| Type | Source | Typical Importance |
|------|--------|--------------------|
| `observation` | Seeing another NPC/Player | 2.0 (NPC), 5.0 (Player) |
| `environment` | Object state scanning | 2.5 |
| `dialogue` | NPC-to-NPC conversation | 3.0-5.0 |
| `player_dialogue` | Player conversation | 6.0-8.0 |
| `reflection` | Nightly reflection | 7.0 |
| `plan` | Daily plan summary | 3.0-4.0 |
| `gossip` | Heard from another NPC | 2.0-5.0 (degrades per hop) |
| `gossip_shared` | Record of sharing gossip | 2.0 |

After Prompt I, additional types: `episode_summary`, `period_summary`, `conversation` (replaces dialogue).

---

## Cost Budget

| System | Monthly Cost |
|--------|-------------|
| Embeddings (768-dim, Prompt I) | $0.17 |
| Conversation impact analysis (Prompt J) | $0.60 |
| Memory compression (Prompt L) | $0.42 |
| Reflections (Prompt L, 5Q×5I) | $4.62 |
| Core memory updates | $0.30 |
| Recursive planning (Prompt N) | $3.90 |
| Reaction evaluations (Prompt N) | $1.80 |
| Tree traversal (Prompt N) | $0.90 |
| **Total AI ops (excluding dialogue)** | **~$12.71/month** |

Dialogue generation (existing Gemini Flash calls) is the main cost and already running.

---

## Coding Conventions
- GDScript style: snake_case for variables/functions, PascalCase for classes/nodes
- Use signals for decoupled communication between systems
- ALWAYS use typed GDScript: `var health: int = 100`, `func get_mood() -> float:`
- Comments on WHY, not WHAT
- Keep scripts under 300 lines. Split into components if growing
- Test with print statements and F3 debug overlay
- `await` for all Gemini API calls (they're async)

## Known Bugs (Fixed by Prompt K, not yet run)
1. EnvScan fires during sleep (64 duplicate memories/day/NPC)
2. NPCs chat while sleeping (midnight conversations)
3. Gossip repeats to same listener endlessly
4. Plans hallucinate NPC names ("Sheriff Barnes")
5. Plan activity text shows at wrong location
6. Large building conversation distance too small (64px)
7. Finn-Clara talk 8+ times/day
8. Day 1 has no plans (load at hour 6, trigger at hour 5)
9. Tavern visits too brief (arrive and immediately leave)
10. "Player" hardcoded instead of PlayerProfile.player_name
11. Thomas routes to Church before General Store at hour 6

## IMPORTANT Reminders
- This is a SIMULATION first, game second. Depth over polish
- NPCs are NOT quest dispensers. They are autonomous agents living their lives
- The player is just another entity in the simulation. No special treatment by the law
- Every system should fail gracefully. If LLM is down, use templates. If pathfinding fails, NPC waits
- Save system must capture ENTIRE world state
- When implementing Prompts I-N, follow the dependency chain strictly: I → K → J → L → M → N