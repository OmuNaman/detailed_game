# Devlog 045 — Fix Seed Event Round 2 (Race Condition, Memory Flooding, L2/L3 Dashboard)

## What Changed

Testing revealed the Round 1 seed event fixes didn't work — Maria went to the Tavern but complained about rent instead of hosting a party. Three root causes found and fixed.

### Bug 1: Race Condition (Fatal)
`evaluate_reaction()` and `generate_daily_plan()` were called simultaneously after seed injection. `generate_daily_plan()` sets `_planning_in_progress = true`, which causes `evaluate_reaction()` to bail out immediately at its guard check. The reaction never fires.

**Fix:** Removed `generate_daily_plan()` from both seed injection paths. The reaction system alone handles both immediate events (override current block) and future events (insert new block via `_insert_future_event_block()`).

### Bug 2: Memory Flooding
`_build_planning_context()` used `get_recent(5)`. EnvScan observations ("Noticed table at House 1") flood recent memories, pushing the seed event out of the top 5 before the planner sees it.

**Fix:** Increased to `get_recent(10)` so high-importance seed events survive observation spam.

### Bug 3: Dashboard Blind to L2/L3
The web inspector only exported L1 (full-day blocks). The granular current task from L2 (hourly) and L3 (5-20 min) decompositions was invisible.

**Fix:** Added `current_active_task` field to NPC export via `get_current_plan()`. Dashboard now shows a green "Current Action (L2/L3)" card above the L1 schedule in the Plan tab.

## Files Changed

| File | Change |
|------|--------|
| `scripts/ui/inspector_export.gd` | Remove `generate_daily_plan()`, add `current_active_task` export |
| `scripts/ui/admin_panel.gd` | Remove `generate_daily_plan()` |
| `scripts/npc/npc_planner.gd` | `get_recent(5)` → `get_recent(10)` |
| `tools/inspector_server.py` | `renderPlan()` shows L2/L3 current task card |
