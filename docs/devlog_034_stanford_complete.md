# Devlog 034 — Stanford Complete Features (Prompt N)

## What Changed
Added the four remaining Stanford Generative Agents features plus upgraded NPC-to-NPC conversations to multi-turn. Part 5 (Enhanced Reflections) was already fully implemented — no changes needed.

### Part 1: Recursive Plan Decomposition (3-Level Planning)

Replaced 2-4 plan `_daily_plan` system with 3-level recursive decomposition:

- **Level 1** (day): 5-8 activity blocks covering hours 5-22, generated at dawn via Gemini Flash. Format: `START-END|LOCATION|ACTIVITY`. Full-day fallback plan if no API key.
- **Level 2** (hourly): Each L1 block decomposed just-in-time into hourly steps via Flash Lite. Format: `HOUR|ACTIVITY`. Triggered every 5 game minutes when entering an undecomposed L1 block.
- **Level 3** (5-20min): Each L2 hour decomposed into 3-6 fine-grained actions via Flash Lite. Format: `START_MIN-END_MIN|ACTION`.

Lazy evaluation: L2/L3 only decompose when you're actually in that time block. L2/L3 cleared at midnight.

`_get_current_plan()` now cascades L3 → L2 → L1, returning the most granular available activity for display.

New functions: `_get_current_l1_index()`, `_decompose_to_level2()`, `_decompose_to_level3()`, `_parse_level2_steps()`, `_parse_level3_steps()`, `_build_level1_prompt()`, `_get_npc_roster_text()`, `_parse_level1_plan()`.

### Part 2: Real-Time Plan Re-evaluation

NPCs now evaluate whether to CONTINUE or REACT when perceiving significant observations (importance ≥ 5.0):

- Flash Lite evaluates: "You're doing X. New observation: Y. CONTINUE or REACT|LOCATION|NEW_ACTIVITY?"
- On REACT: overrides current L1 block's location/activity, clears its L2/L3, stores reaction memory, redirects NPC
- 10-minute cooldown prevents spam. Guard flags prevent concurrent evaluations.

Trigger: integrated into `_on_perception_body_entered()` — player sightings (importance 5.0) trigger evaluation.

### Part 3: Environment Tree Traversal

Static `WORLD_TREE` constant matching actual furniture from `town_generator.gd` — 7 commercial buildings with named areas and object inventories. `HOUSE_TREE` for residential.

Per-NPC `_known_world` subgraph: NPCs learn buildings they visit. Seeded with home + workplace on initialization.

- `_init_known_world()`: seeds home + workplace
- `_learn_building()`: called on `_arrive()`, adds building to known world
- `_update_known_object_states()`: syncs states from WorldObjects during env scans
- `_describe_known_world()`: compact summary injected into planning prompts

### Part 4: Natural Information Diffusion

`_detect_third_party_mentions()`: scans all NPC conversation lines for third-party names. When Maria mentions Gideon while talking to Rose, Rose gets a gossip-type memory: "Maria mentioned Gideon: '...'"

- Scans all 11 NPC names + player name
- Player mentions get importance 4.0, NPC mentions get 3.0
- Integrated into turn-by-turn conversation (every turn) and the on_done callback

Reduced explicit `GOSSIP_CHANCE` from 0.4 → 0.2. Natural diffusion through conversation content handles the rest.

Broadened retrieval query in `_build_npc_chat_context()`: recent third-party actors from memory added to query so conversations naturally surface relevant info about others.

### Part 5: Enhanced Reflections — NO CHANGES

Already at Stanford full scale from Prompt L:
- 100 recent memories, 5 questions, 5 insights per question
- REFLECTION_THRESHOLD = 100.0
- Reflections reference other reflections via retrieval

### Part 6: Turn-by-Turn NPC Dialogue

Replaced 2-line batch exchange with recursive multi-turn conversations:

- Up to 6 turns (3 exchanges), minimum 2 turns
- Each speaker retrieves 3 memories per turn using the last spoken line as query
- Conversation history maintained across turns
- Natural ending: 30% random end chance after min turns, farewell detection ("goodbye", "see you", "take care")
- Queue throttling: >5 queued → 2 turns max; >10 → template fallback

New functions: `_run_conversation_turn()` (recursive callback chain), `_build_npc_chat_context_for_turn()` (per-turn retrieval + history).

On completion: stores full conversation as single dialogue memory, runs content-aware impact analysis on first exchange, gossip phase with 20% chance.

## Files Changed
- **MODIFIED** `scripts/npc/npc_controller.gd` — All 5 parts (Part 5 no-op):
  - **New constants:** `WORLD_TREE`, `HOUSE_TREE`, `REACTION_COOLDOWN_MINUTES`, `REACTION_IMPORTANCE_THRESHOLD`, `NPC_CONV_MAX_TURNS`, `NPC_CONV_MIN_TURNS`
  - **Changed constants:** `GOSSIP_CHANCE` 0.4 → 0.2
  - **New variables:** `_known_world`, `_plan_level1/2/3`, `_decomposition_in_progress`, `_last_reaction_eval_time`, `_reaction_in_progress`
  - **Removed variables:** `_daily_plan`
  - **New functions (14):** `_init_known_world`, `_learn_building`, `_update_known_object_states`, `_describe_known_world`, `_build_level1_prompt`, `_get_npc_roster_text`, `_parse_level1_plan`, `_get_current_l1_index`, `_decompose_to_level2`, `_decompose_to_level3`, `_parse_level2/3_steps`, `_evaluate_reaction`, `_process_reaction_result`, `_detect_third_party_mentions`, `_run_conversation_turn`, `_build_npc_chat_context_for_turn`
  - **Rewritten functions (6):** `_generate_daily_plan`, `_generate_fallback_plan`, `_get_active_plan_destination`, `_get_current_plan`, `_build_planning_system_prompt` (→ `_build_level1_prompt`), `_real_npc_conversation`
  - **Modified functions (7):** `initialize`, `_arrive`, `_scan_environment`, `_build_planning_context`, `_build_npc_chat_context`, `_on_time_tick`, `_on_hour_changed`, `_on_perception_body_entered`

## Cost Estimate

Per NPC per day:
- L1 plan: 1 Flash call (~$0.003)
- L2 decomposition: ~5 Flash Lite calls (~$0.003)
- L3 decomposition: ~5 Flash Lite calls (~$0.003)
- Reactions: ~3 Flash Lite calls (~$0.002)
- Turn-by-turn: ~4-6 turns × 2-3 convos = ~12 Flash calls (~$0.010)
- **Per NPC/day: ~$0.021**
- **11 NPCs/day: ~$0.23**
- **Monthly: ~$7.00** (additional beyond existing ~$12.71)
- **New total: ~$19.71/month**

## Verification Checklist
- [ ] Hour 5 → L1 plan with 5-8 activities covering 5:00-22:00
- [ ] L2 decomposition fires when entering an L1 block (debug: `[Plan L2]`)
- [ ] L3 decomposition fires when L2 is available (debug: `[Plan L3]`)
- [ ] Activity display shows granular text from L2/L3 cascade
- [ ] Player approaches NPC → REACT evaluation fires (debug: `[Reaction]`)
- [ ] 10-min cooldown prevents spam reactions
- [ ] NPCs know home + workplace tree on spawn, learn new buildings on visit
- [ ] Planning context includes known world summary
- [ ] NPC conversations show 2-6 speech bubbles in sequence (~1.5s apart)
- [ ] Third-party mentions create diffusion memories (debug: `[Diffusion]`)
- [ ] GOSSIP_CHANCE is 0.2 (was 0.4)
- [ ] Retrieval query broadened with recent third-party names
- [ ] Gemini queue > 5 → conversations throttled to 2 turns
- [ ] Gemini queue > 10 → falls back to template conversation
- [ ] No API key → full-day fallback plan, template conversations, no crashes
- [ ] Emergency overrides (hunger/energy < 20) still work
- [ ] Sleep hours (23-5) never overridden
- [ ] L2/L3 cleared at midnight
