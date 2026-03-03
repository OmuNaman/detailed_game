# Devlog 028 — Daily Planning System

## What Changed
NPCs now generate a unique daily plan each morning at dawn (hour 5) via Gemini, making every day different. Instead of the same rigid schedule — work, eat, sleep, tavern — Maria might plan to visit Gideon at the Blacksmith to thank him for fixing her oven rack, then stop by the Church to talk to Clara. Plans are informed by reflections, relationships, gossip, and recent events.

This is the **third pillar** of the Stanford Generative Agents architecture: hierarchical planning. Combined with Memory Stream (pillar 1) and Reflection (pillar 2), NPCs now observe → remember → reflect → plan → act.

## Plan Generation (`_generate_daily_plan()`)
At hour 5 each morning, every NPC generates a plan:
- **Gemini prompt** includes: personality, workplace, recent reflections, relationships, gossip, recent events
- **Output format:** `HOUR|DESTINATION|REASON` (one per line)
- **2-4 plans** per day, capped at 4
- **Fallback** (no API key): visit closest friend's workplace at hour 15

### Planning Prompt Context
- Top 3 recent reflections
- All relationships with opinion labels
- Top 3 recent gossip memories
- Top 5 recent memories
- Available buildings list (7 commercial + 11 houses)

## Plan Structure
```gdscript
{
    "hour": 11,                  # When to start
    "end_hour": 13,              # When this plan expires (default: hour + 2)
    "destination": "Blacksmith", # Where to go (validated building name)
    "reason": "visit Gideon to thank him for fixing the oven rack",
    "completed": false,
}
```

## Schedule Integration
Plans override the default needs-driven schedule during their time window. Priority order:
1. **Emergency** (hunger/energy < 20) → always home
2. **Sleep** (23-5) → always home
3. **Active plan** → plan destination
4. **Default schedule** → work/tavern/home as before

## Plan-Aware Activities
When an NPC is following a plan, their activity shows the plan's reason instead of generic text:
- Instead of: "at the Blacksmith"
- Shows: "visit Gideon to thank him for fixing the oven rack"
- Activity emoji: `!` (indicating intentional visit)

## Context Enrichment
- **Player dialogue:** Upcoming plans listed under "Your plans for today"
- **NPC-to-NPC chat:** "You're here because you planned to: [reason]"
- **Reflections:** Plan status (completed/not yet done) included in reflection context
- **Topic selection:** Morning plans topic available before 8 AM

## Plan Memory
Plans are stored as type="plan" memories: "My plans for today: visit Gideon at Blacksmith around 11:00, have a drink at Tavern around 16:00"

## Parsing & Validation
- Fuzzy building name matching (case-insensitive, partial match)
- Hours validated: 6-22 only
- Own workplace filtered out during core work hours (6-15)
- Leading numbering/bullets stripped
- Plans sorted by hour, capped at 4

## Example Flow
```
1. Hour 5 → Maria wakes up, Gemini generates plan:
   11|Blacksmith|Visit Gideon to thank him for fixing my oven rack
   16|Tavern|Have a drink with Rose and catch up on news
2. Hours 6-10 → Maria works at Bakery (normal schedule)
3. Hour 11 → Plan activates → Maria walks to Blacksmith
   Activity: "visit Gideon to thank him for fixing the oven rack"
4. Hour 13 → Plan expires → Maria returns to Bakery
5. Hour 16 → Second plan activates → Maria walks to Tavern
6. Hour 18 → Plan expires → normal evening schedule
7. Hour 22 → Reflection: "I visited Gideon today as I planned"
```

## Cost Control
- Max 1 Gemini call per NPC per morning = 11 calls/day
- Plans are ephemeral — regenerated each morning, NOT persisted to disk
- Fallback plan requires zero API calls

## Performance
- Plan generation is async (queued via GeminiClient)
- `_get_active_plan_destination()` is O(n) where n ≤ 4 — negligible
- Plans only checked during schedule evaluation (hourly + every 5 minutes)

## Files Changed
| File | Action |
|------|--------|
| `scripts/npc/npc_controller.gd` | MODIFY — `_daily_plan`, `_generate_daily_plan()`, `_generate_fallback_plan()`, `_build_planning_system_prompt()`, `_build_planning_context()`, `_parse_plan()`, `_match_building_name()`, `_get_active_plan_destination()`, `_get_current_plan()`, `_get_npc_workplace()`, plan integration in scheduling + activities + dialogue context + NPC chat context + reflection context |
