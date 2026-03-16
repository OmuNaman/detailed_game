# Devlog 039 — 50 New NPCs, Map Expansion, API Scaling

## What Changed

Expanded DeepTown from 11 NPCs on a 60x45 map to **61 NPCs** on a **120x70 map** with 8 new commercial buildings and 36 new houses.

## New Content

### 50 New NPCs
- All 50 have **hand-written unique personalities** and speech styles
- 46 unique job types across 15 workplaces
- 14 shared houses (couples/roommates) + 22 solo houses
- Each NPC gets 2-4 seeded relationships with colleagues, neighbors, and family
- 100 new sprite PNGs (50 awake + 50 sleep) via `tools/generate_npcs.py`

### 8 New Buildings
Library, Inn, Market, Carpenter Workshop, Tailor Shop, Stables, Clinic, School — each with unique furniture layouts, roof tints, and WORLD_TREE entries.

### Map Expansion (60x45 → 120x70)
- 5 housing rows of 6-10 houses each
- 2 commercial/service rows
- Cobblestone highways + dirt path connectors
- Relocated water pond to bottom-right

## API Scaling for 61 NPCs

### Parallel HTTP Pool
GeminiClient upgraded from single-request serialization to **3 concurrent** HTTPRequest nodes. 3x throughput.

### Staggered Planning
Instead of 61 NPCs all planning at hour 5, each NPC's plan is staggered across **60 game minutes** (hours 5-6) using `npc_name.hash() % 60`.

### Raised Queue Thresholds
| Threshold | Old | New |
|-----------|-----|-----|
| Conversation → template | >10 | >25 |
| Turn limit → 2 turns | >5 | >15 |
| Impact analysis skip | >8 | >20 |
| L2/L3 decomp skip | >10 | >30 |

### Embedding Tuning
- Batch size: 10 → 20
- Batch interval: 5s → 3s

### Performance Safeguards
- Social need scan: every-minute → every-5-minutes (eliminates O(N^2) per tick)
- NPC roster in planning prompts: data-driven, filtered to known NPCs (cap 20)

## Files Changed

| File | Change |
|------|--------|
| `tools/generate_npcs.py` | NEW — sprite generator for 50 NPCs |
| `data/npcs.json` | 11 → 61 entries |
| `scripts/world/town_generator.gd` | 120x70 map, 61 buildings |
| `scripts/npc/npc_activity.gd` | 35 new job→furniture mappings |
| `scripts/npc/npc_planner.gd` | Data-driven roster, expanded valid_buildings, raised thresholds |
| `scripts/npc/npc_world_knowledge.gd` | 8 new WORLD_TREE entries |
| `scripts/npc/npc_controller.gd` | Staggered planning, embedding tuning, social scan optimization |
| `scripts/llm/gemini_client.gd` | 3-concurrent parallel HTTP pool |
| `scripts/npc/npc_conversation.gd` | Raised queue thresholds |
