# Devlog 044 — Fix Seed Event System (NPCs Now Actually Attend the Party)

## What Changed

Three logic bugs prevented seeded events from working. NPCs would receive the memory but completely ignore it.

### Bug A: Reaction Never Fires
`evaluate_reaction()` was only called from `npc_perception.gd` during perception scans. Seed injection via admin panel or web dashboard called `_add_memory_with_embedding()` which does NOT trigger reaction evaluation. The seeded memory just sat there until the next morning's daily plan at hour 5.

**Fix:** Both `inspector_export.gd:_check_seed_event()` and `admin_panel.gd:_seed_event()` now explicitly call `evaluate_reaction()` + `generate_daily_plan()` after injecting the seed memory. Reaction handles "drop everything NOW", replan handles "restructure my day for a future event".

### Bug B: Planning Prompt Forces Meals
`_build_level1_prompt()` had a hard rule: "Include meals at home around hours 7, 12, 19". The LLM obeyed this structural constraint over event memories, causing NPCs to leave for dinner instead of attending the party.

**Fix:** Softened to "Usually include meals... UNLESS you have a special event". Added explicit "PRIORITIZE attending events, festivals, or gatherings" instruction.

### Bug C: Reaction Overwrites Current Block
`_process_reaction_result()` always overwrote the *current* L1 plan block. If an NPC heard about a party at hour 18 while at hour 10, the reaction either sent them to the Tavern 8 hours early, or the AI said CONTINUE since the event wasn't imminent.

**Fix:** New `REACT|LOCATION|ACTIVITY|HOUR` format for future events. New `_insert_future_event_block()` function splits existing L1 blocks to insert a 2-hour event block at the correct time. Reaction prompt now includes `Current hour: X:00` so the AI can distinguish immediate vs future events.

### Cosmetic: Print Truncation
`.left(60)` in seed event print statements was chopping the text in console logs, making it look like the injection was truncated.

## Files Changed

| File | Change |
|------|--------|
| `scripts/npc/npc_planner.gd` | Soft meal rules, event prioritization, `Current hour` in reaction prompt, `REACT|LOC|ACT|HOUR` format, `_insert_future_event_block()` |
| `scripts/ui/inspector_export.gd` | Call `evaluate_reaction()` + `generate_daily_plan()` after seed, remove `.left(60)` |
| `scripts/ui/admin_panel.gd` | Call `evaluate_reaction()` + `generate_daily_plan()` after seed |
