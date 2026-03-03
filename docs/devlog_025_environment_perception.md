# Devlog 025 — Environment Perception (Object State Awareness)

## What Changed
NPCs now perceive the state of objects in their current building, not just the people around them. They notice active equipment, idle workstations during work hours, abandoned objects, and empty workplaces. This creates richer world-awareness — NPCs comment on what they've noticed in conversations, and their memories reflect environmental observations alongside people-watching.

## Memory Types
The system now uses three distinct memory types:
- **"observation"** — Seeing people: "Saw Maria kneading dough near the Bakery (the oven was baking)"
- **"environment"** — Noticing object states: "Noticed the oven at the Bakery was baking"
- **"reflection"** — Synthesized insights: "I think Maria works too hard at the Bakery"

## Environment Scan (`_scan_environment()`)
- Runs every 30 game minutes alongside the existing person perception scan
- Only fires when NPC is stationary at a building (not while moving)
- Iterates all objects registered in WorldObjects for the current building
- Notable observations only:
  - Active objects being used by someone else: "Maria was using the oven (baking)"
  - Objects in non-idle state with no user: "the oven was baking" (abandoned)
  - Work objects idle during work hours (6-17): "the oven at the Bakery was idle"
- Self-use is skipped (NPCs don't create memories about their own objects)
- Max 2 environment memories per scan to prevent spam
- Importance: 2.5 (between routine NPC sighting at 2.0 and player sighting at 5.0)

## Person-Perception Enrichment
The existing `_on_perception_body_entered()` now includes object state when the observed NPC is using furniture:
- Before: "Saw Maria kneading dough near the Bakery"
- After: "Saw Maria kneading dough near the Bakery (the oven was baking)"
- Object type extracted from WorldObjects ID: `"Bakery:oven:0".get_slice(":", 1)` → "oven"

## Arrival Awareness (`_on_arrive_at_building()`)
When an NPC arrives at a building, they check for two notable conditions:

1. **Abandoned objects:** Equipment in non-idle state with no user → "Arrived at the Bakery and found the oven was baking with nobody around" (importance: 4.0, slight negative valence)
2. **Empty workplace:** If arriving at their workplace during work hours and no coworkers are present (for multi-worker buildings: Blacksmith, Tavern, Church, Courthouse, General Store) → "The Blacksmith was empty when I arrived for work" (importance: 3.0, once per day via cooldown key)

## Context Enrichment
- **Player dialogue:** `_build_dialogue_context()` includes top 3 recent environment memories under "Things you've noticed around town"
- **NPC-to-NPC chat:** `_build_npc_chat_context()` includes the most recent environment observation if within 6 hours: "Earlier you noticed: ..."
- Environment memories also appear naturally in "recent memories" since they're stored through the normal memory pipeline

## Memory Examples
```
[EnvScan] Maria noticed 1 things at Bakery
  - "Noticed Gideon was using the anvil (forging) at the Blacksmith"

[EnvScan] Thomas: Arrived at the General Store and found the counter was idle with nobody around

[EnvScan] Elena: The Courthouse was empty when I arrived for work

Perception: "Saw Maria kneading dough near the Bakery (the oven was baking)"
```

## Performance
- Environment scan: max 1 per NPC per 30 game minutes, max 2 memories per scan
- Arrival check: once per destination change, lightweight WorldObjects read
- No new timers or per-frame processing
- 11 NPCs × ~2 scans/game-hour × max 2 memories = ~44 environment memories/game-hour (most will be skipped as not notable)

## Files Changed
| File | Action |
|------|--------|
| `scripts/npc/npc_controller.gd` | MODIFY — `_last_environment_scan`, `_scan_environment()`, `_is_work_hours()`, `_is_workplace_object()`, `_on_arrive_at_building()`, enhanced `_on_perception_body_entered()` with object state, environment context in `_build_dialogue_context()` + `_build_npc_chat_context()` |
