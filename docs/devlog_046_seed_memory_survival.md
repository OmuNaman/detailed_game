# Devlog 046 — Seed Event Memory Survival in Planning Context

## What Changed

Seed events (importance 7.0) were getting buried by EnvScan observations (importance 2.5) in the planning context. `get_recent(10)` is purely time-based — after 10+ low-importance observations, the party memory falls out of the recent window before the planner sees it.

### Fix: High-Importance Memory Pass

Added a second pass in `_build_planning_context()` that scans today's episodic memories for anything with importance >= 6.0 and adds it to the recent events list if not already there. This ensures seed events (7.0), player dialogues (6-8), and reflections (7.0) always reach the planner, while EnvScan (2.5) and routine observations (2.0) don't pollute the context.

## Files Changed

| File | Change |
|------|--------|
| `scripts/npc/npc_planner.gd` | High-importance memory pass in `_build_planning_context()` |
