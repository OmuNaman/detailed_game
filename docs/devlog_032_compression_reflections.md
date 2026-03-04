# Devlog 032 — Memory Compression + Enhanced Reflections (Prompt L)

## What Changed
Added hierarchical memory compression and replaced the old 3-insight reflection system with the Stanford two-step process (5 questions × 5 insights). Added forgetting curves so unaccessed memories decay over time. Together, these ensure NPCs remember the gist of everything while keeping memory manageable.

### Part 1: Hierarchical Memory Compression

**Episode Summaries (Level 1):** At midnight, the oldest 30 non-protected raw episodic memories are compressed into a single 3-5 sentence summary via Gemini Flash. The summary is stored in `archival_summaries` with `summary_level=1`, and the source memories are removed from episodic. Minimum batch size: 10.

**Period Summaries (Level 2):** When 10+ episode summaries accumulate, the oldest 7 are compressed into a 2-3 sentence period summary (`summary_level=2`). Old episode summaries removed.

Both summary types are always `protected=true` and get embeddings queued for retrieval.

### Part 2: Forgetting Curves

At midnight, all non-protected episodic memories have stability decayed:
- Observations/environment with 0 access: `stability × 0.7`
- Other types with 0 access: `stability × 0.85`
- Floor: `MIN_STABILITY = 1.0`
- Memories with recency score < 0.05 marked `effectively_forgotten=true`

Accessed memories (via retrieval) are not decayed — the testing effect already boosted their stability.

### Part 3: Enhanced Reflections (Stanford Two-Step)

**REPLACES** the old Prompt D reflection system (3 insights from 20 memories).

**New trigger:** Importance-based threshold (`REFLECTION_THRESHOLD = 100.0`). Every time a memory is created, its importance accumulates. When total exceeds 100, reflections trigger. Fires ~2-3 times per active day. Reflections and summaries don't count toward the threshold (prevents infinite loop).

**Step 1 — Generate Questions:** 100 recent non-reflection memories → Gemini Flash → 5 high-level questions about patterns, relationships, feelings.

**Step 2 — Generate Insights:** For each question, retrieve 10 relevant memories via keyword search, then Gemini Flash generates up to 5 insights per question. Each insight stored as `type="reflection"` with `importance=7.0`, `protected=true`.

If an insight mentions the player, `player_summary` in core memory is updated via a follow-up Gemini call.

### Part 4: Midnight Maintenance Routine

Consolidated daily maintenance into `_run_midnight_maintenance()`, called at hour 0:
1. Apply forgetting curves
2. Compress old episodic memories (async via Gemini)
3. Save all memory tiers

Safety valve: if episodic memories exceed 500, compression triggers immediately on next memory creation.

### Part 5: Memory System Enhancements

- New stability types: `episode_summary=168.0`, `period_summary=336.0`
- Reflections now auto-protected via `create_memory()` type check
- Archival summaries already searched in `retrieve_memories()` with 1.1× score boost (from Prompt I)

## Files Changed
- **MODIFIED** `scripts/npc/memory_system.gd` — Compression + forgetting:
  - New constants: `COMPRESSION_BATCH_SIZE`, `COMPRESSION_MIN_BATCH`, `EPISODE_COMPRESSION_THRESHOLD`, `PERIOD_COMPRESSION_BATCH`, `FORGETTING_RATE_*`, `MIN_STABILITY`, `EFFECTIVELY_FORGOTTEN_THRESHOLD`
  - New methods: `get_compression_candidates()`, `apply_episode_compression()`, `get_episode_summary_candidates()`, `apply_period_compression()`, `apply_daily_forgetting()`, `_extract_entities_from_batch()`, `_average_importance()`, `_average_valence()`
  - Modified: `create_memory()` (reflections auto-protected), `STABILITY_BY_TYPE` (added summary types)
- **MODIFIED** `scripts/npc/npc_controller.gd` — Enhanced reflections + midnight maintenance:
  - Deleted: `_try_reflect()`, `_build_reflection_system_prompt()`, `_build_reflection_context()`, `_parse_reflections()`, `_last_reflection_day`, `_reflection_cooldown`
  - New vars: `_unreflected_importance`, `_reflection_in_progress`, `REFLECTION_THRESHOLD`
  - New methods: `_enhanced_reflect()`, `_generate_insights_for_question()`, `_parse_insight_lines()`, `_run_midnight_maintenance()`, `_compress_memories()`, `_compress_episodes()`
  - Modified: `_on_hour_changed()` (midnight maintenance, removed hour 22 trigger), `_on_time_tick()` (removed mid-day importance trigger), `_add_memory_with_embedding()` (importance tracking + safety valve)

## Cost Impact
- Reflections: 1 question call + up to 5 insight calls per trigger × ~2-3 triggers/day = ~6-18 Gemini Flash calls/NPC/day
- Compression: 1-2 Gemini Flash calls per midnight per NPC (episode + optional period)
- Forgetting: no API calls (pure data operation)
- Player summary updates from reflections: 0-5 Gemini Flash calls per reflection trigger

## Testing Checklist
- [ ] After Day 2: `[Compress] Maria: Compressed 30 memories into episode summary (Day 0)`
- [ ] Forgetting: `[Memory] Maria: Midnight maintenance — Episodic: 85, Archival: 2`
- [ ] Reflections trigger when importance sum > 100: `[Reflect] Maria: Generated 5 questions`
- [ ] 5 questions × up to 5 insights each stored as reflections
- [ ] Archival summaries appear in retrieval results
- [ ] Core memory player_summary updates from player-mentioning insights
- [ ] No API key → midnight maintenance runs but no Gemini calls, no crashes
- [ ] Safety valve: >500 episodic memories triggers compression
- [ ] Old `_try_reflect()` completely removed — no hour 22 or mid-day triggers
- [ ] Period compression after 10+ episode summaries accumulate
