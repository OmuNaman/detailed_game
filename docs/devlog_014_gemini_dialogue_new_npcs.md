# Devlog 014 — Gemini Dialogue, New NPCs, and a Living Town

**Date:** 2026-03-02
**Phase:** 1 — Foundation (14/19 complete, ~74%)

---

## What Changed

This session adds 6 new townsfolk, Gemini 2.0 Flash dialogue generation, NPC-to-NPC conversations, organic needs-driven schedules, per-NPC save folders, and an updated debug overlay. The town went from 5 NPCs on fixed schedules to 11 NPCs with personality-driven behavior and AI-generated dialogue.

---

## Part 1: Six New NPCs

### The New Townsfolk

| Name | Job | Age | Home | Workplace | Personality |
|------|-----|-----|------|-----------|-------------|
| Rose | Tavern Owner | 45 | House 6 | Tavern | Boisterous ex-adventurer, sharp tongue, big heart |
| Finn | Farmer | 36 | House 7 | General Store | Salt-of-the-earth, worries about weather, married to Clara |
| Clara | Herbalist | 33 | House 7 | Church | Quiet, observant, slightly mysterious, married to Finn |
| Old Silas | Retired | 71 | House 8 | Tavern | Grumpy ex-miner, town drunk, surprisingly sharp memory |
| Bram | Apprentice | 19 | House 9 | Blacksmith | Eager, enthusiastic, rivalrous with Lyra |
| Lyra | Scholar | 25 | House 10 | Courthouse | Brilliant, condescending, secretly writes poetry |

**Relationships baked in:**
- Clara & Finn share House 7 (married couple)
- Rose owns the Tavern — she's not just a visitor
- Old Silas's "workplace" is the Tavern (he drinks there all day)
- Bram apprentices under Gideon at the Blacksmith
- Bram and Lyra have a rivalry over who's smarter
- Gideon has a secret crush on Maria

### New Houses on the Map

6 new 4x4 houses added to `town_generator.gd`:
- Houses 6-7 at y=24 (extending the residential row east, gx=35 and gx=41)
- Houses 8-11 at y=30 (new southern residential row)

New road infrastructure:
- Secondary road extended east (x=3 to x=43) for Houses 6-7
- Tertiary road at y=28-29 connecting southern houses
- Vertical connecting paths from secondary to tertiary road

### Sprite Generation

6 new character sprites generated via `tools/generate_sprites.py`:
- Rose: red hair bun, deep red dress, tan apron
- Finn: straw blond, olive work shirt
- Clara: dark brown short hair, sage green dress
- Silas: white/gray balding hair, worn brown clothes
- Bram: black hair, tan work shirt, stocky build
- Lyra: auburn short hair, purple tunic, book detail

### Personality Data

All 11 NPCs now have rich personality data in `npcs.json`:
- `personality`: 2-3 sentence character description
- `speech_style`: how they talk (used in Gemini system prompt)
- `age`: integer, affects dialogue context

The existing 5 NPCs (Maria, Thomas, Elena, Father Aldric, Gideon) were retroactively given personality fields.

---

## Part 2: Organic Needs-Driven Schedules

### Before (rigid)
```
6-17: work | 17-22: tavern | 22-06: home
```

### After (needs-driven)
```
5-6:   Head to work (wake-up)
6-15:  Work, BUT:
       - 11-13: Go home for lunch if hunger < 60
       - 10% chance of spontaneous Church visit per hour
15-17: Flexible:
       - social < 40 → Tavern early
       - hunger < 50 → home to eat
       - else → keep working
17-20: Social time (Tavern), unless:
       - social > 80 AND energy < 40 → home early
20-23: Winding down:
       - energy < 50 → home
       - social < 50 → stay at Tavern
       - else → home
23-5:  Sleep at home
```

**Key change:** Destination is now re-evaluated every 5 game minutes (via `_on_time_tick()`), not just on hour change. This means NPCs react to changing needs mid-hour.

### `_wants_to_visit()` — Random Organic Movement

NPCs occasionally decide to visit the Church during work hours (~10% chance per hour-check). Only applies to NPCs whose workplace is NOT the Church. Creates organic movement variety — not everyone follows the exact same pattern.

---

## Part 3: NPC-to-NPC Conversations

NPCs now talk to each other when they're near and stationary.

### How It Works

Every 15 game minutes, each NPC checks if another NPC is:
1. Within 2 tiles (64px)
2. Not currently walking
3. Not talked to within the last 2 hours (120 game minutes)

If all conditions met, both NPCs create a "dialogue" type memory and get +5 social.

### Conversation Topics

`_pick_conversation_topic()` selects from context-based options:
- Time-based: "how their day went" (evening), "morning plans" (early)
- Needs-based: "food" (if hungry), "being tired" (if other is tired)
- Job-based: "work at the {workplace}"
- Memory-based: "the stranger they saw in town" (if player was seen recently)
- Random flavor: "the weather", "town gossip", "old times", "their families"

### Console Output

Conversations are logged: `[Maria] Chatted with Rose about town gossip`

These create real memories that affect future dialogue. If you talk to Maria after she chatted with Rose, her LLM response might reference that conversation.

---

## Part 4: Gemini 2.0 Flash Dialogue

### GeminiClient Autoload

New `scripts/llm/gemini_client.gd`:
- Model: `gemini-2.0-flash`
- Same API key as EmbeddingClient (first line of `user://.env`)
- Request queue (same pattern as embedding client)
- 5-second timeout — falls back to template if API is slow
- Cost tracking: estimates input/output tokens

### System Prompt Structure

```
You are {name}, a {age}-year-old {job} in the town of DeepTown. {personality}

Your speech style: {speech_style}

Rules:
- Respond in character, first person, 1-3 sentences only
- Never break character or mention being an AI
- Let your personality shine through every word
- Reference your memories naturally if relevant
- Your mood and needs should affect how you talk
```

### User Message Context

The dialogue context includes:
- Current time and period (dawn/morning/afternoon/evening/night)
- Current location
- Mood description (miserable/unhappy/okay/good/great)
- All three needs with status labels
- Top 5 recent memories with timestamps
- Prompt: "A traveler (the Player) is standing in front of you"

### Async Flow

1. Player presses E → dialogue box shows "..." (typing indicator)
2. `get_dialogue_response_async()` sends request to Gemini
3. On success: display LLM response, store conversation as memory
4. On failure/timeout: fall back to `_get_template_response()`
5. Template responses preserved exactly as before (energy/hunger/memory/mood cascade)

### Cost Tracking

Visible in debug overlay (F3):
```
Gemini: 5 calls, ~$0.0003 est. (1250 in / 200 out tokens)
```

Pricing: Gemini 2.0 Flash ~$0.10/1M input, ~$0.40/1M output.

---

## Part 5: Per-NPC Save Folders

### Before
Single flat file: `user://npc_memories.json`

### After
```
user://npc_data/
├── Maria/
│   ├── memories.json      # Full memory stream (all records)
│   ├── conversations.json # Just "dialogue" type, human-readable
│   └── profile.json       # Current state snapshot
├── Thomas/
│   └── ...
├── Rose/
│   └── ...
└── ... (11 folders total)
```

### `profile.json` Example
```json
{
    "name": "Maria",
    "job": "Baker",
    "age": 34,
    "personality": "Warm and nurturing but gossips relentlessly...",
    "current_location": "Tavern",
    "hunger": 72.3,
    "energy": 45.1,
    "social": 88.6,
    "mood": 68.7,
    "total_memories": 23,
    "total_conversations": 5,
    "total_observations": 18
}
```

### `conversations.json` Example
```json
[
    {
        "time": 487,
        "with": "Rose",
        "description": "Had a conversation with Rose about town gossip at the Tavern",
        "location": "Tavern"
    }
]
```

### Backward Compatibility

On load, the system first checks for `user://npc_data/{name}/memories.json`. If no per-NPC folders exist, it falls back to `user://npc_memories.json` and loads from the old format. Migration message printed to console.

---

## Part 6: Debug Overlay Updates

F3 overlay now shows per NPC:
- Name, job, **age**, current destination
- Needs bars (hunger/energy/social)
- Mood + memory count + **conversation count**
- Top **2** recent memories (was 3, reduced for space with 11 NPCs)

Bottom of overlay: Gemini API cost tracker showing total calls and estimated cost.

---

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `tools/generate_sprites.py` | Modified | 6 new gen_* functions for Rose, Finn, Clara, Silas, Bram, Lyra |
| `scripts/world/town_generator.gd` | Modified | 6 new houses + connecting paths |
| `data/npcs.json` | Rewritten | 11 NPCs with personality/speech_style/age |
| `scripts/npc/npc_controller.gd` | Rewritten | Personality vars, organic schedules, NPC conversations, LLM dialogue |
| `scripts/player/player_controller.gd` | Modified | Async dialogue with "..." typing indicator |
| `scripts/world/town.gd` | Modified | Per-NPC folder save/load with backward compat |
| `scripts/ui/debug_overlay.gd` | Modified | Age, conv count, Gemini cost tracker |
| `project.godot` | Modified | GeminiClient autoload registration |
| `scripts/llm/gemini_client.gd` | **New** | Gemini 2.0 Flash dialogue generation |
| 6 sprite PNGs | **New** | New character art |

---

## Phase 1 Checklist

- [x] Project setup
- [x] Tile map with buildings
- [x] Player movement
- [x] Game clock with day/night cycle
- [x] NPC spawning with core descriptions and personality traits
- [x] NPC pathfinding (A* on tilemap)
- [x] Basic needs system (hunger, energy, social)
- [x] Memory Stream — scored retrieval with embeddings
- [x] Memory Retrieval — recency + importance + relevance
- [ ] Daily Planning — NPCs generate morning plans
- [x] Observation system — perception radius
- [x] Interaction system — talk to NPCs with memory-aware responses
- [x] NPC-to-NPC conversations
- [x] LLM integration (Gemini for dialogue)
- [ ] Gossip propagation — NPCs share observations
- [ ] Reflection system — periodic insight generation
- [ ] Crime detection (witness-based)
- [ ] Sheriff arrest mechanic
- [ ] Simple court trial
- [ ] Reputation tracking

**Progress: 14/19 (74%)**

---

## Addendum: Gemini 2.5 Flash Migration

### Problem
After updating the API key, `gemini-2.0-flash` returned 404 — Google retired the model for new API keys. Switched to `gemini-2.5-flash`.

### Thinking Token Issue
Gemini 2.5 Flash has a built-in "thinking" mode that consumes internal reasoning tokens before producing output. With the original `maxOutputTokens: 150`, the model spent ~143 tokens on thinking, leaving only 3-7 tokens for the actual NPC dialogue — responses were cut off mid-sentence ("Well hello there" → stop).

### Fix
Disabled thinking and raised the output cap:
```gdscript
"generationConfig": {
    "maxOutputTokens": 256,
    "temperature": 0.8,
    "thinkingConfig": {"thinkingBudget": 0}
}
```

### Result
| Config | Thinking Tokens | Output Tokens | Total | Response Quality |
|--------|----------------|---------------|-------|-----------------|
| Before (150, thinking on) | ~143 | 3-7 | ~246 | Truncated, unusable |
| After (256, thinking off) | 0 | ~38 | ~124 | Full 1-3 sentences, great personality |

For short NPC dialogue (1-3 sentences), thinking adds no value — just cost and latency. ~3.4x cheaper per request.
