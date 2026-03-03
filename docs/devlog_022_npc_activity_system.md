# Devlog 022 — NPC Activity System

## What Changed
Every NPC now has a `current_activity` string describing what they're doing at any given moment. Activities are fully deterministic — derived from job, time of day, location, and object state. No LLM calls. This is the "doing" layer that sits on top of the stateful furniture system.

## Activity Computation
- New `_update_activity()` method recomputes activity on: arrival at destination, start of movement, and every hour change
- **At home:** sleeping (night), getting ready (dawn), eating (mealtimes 7/12/19), resting (other)
- **At workplace:** job-specific activities that shift by time of day (see table below)
- **At Tavern (social):** having drinks (evening) or relaxing (daytime)
- **At Church (visit):** praying quietly
- **Walking:** "walking to the {destination}"

## Job-Specific Activities
| NPC | Job | Activity Examples |
|-----|-----|-------------------|
| Maria | Baker | kneading dough (morning) → baking bread (midday) → serving bread (afternoon) |
| Thomas | Shopkeeper | opening up (early) → minding the shop at the counter |
| Elena | Sheriff | reviewing reports (morning) → keeping watch |
| Father Aldric | Priest | preparing service (early) → conducting service → tending to Church |
| Gideon | Blacksmith | hammering metal at the anvil |
| Rose | Tavern Owner | cleaning up (before 3pm) → serving drinks |
| Finn | Farmer | delivering produce (morning) → stocking shelves |
| Clara | Herbalist | preparing herbal remedies in the Church |
| Old Silas | Retired | nursing a drink at the Tavern |
| Bram | Apprentice Blacksmith | learning to forge (morning) → practicing hammer work |
| Lyra | Scholar | studying old records (morning) → writing in the town ledger |

## Visual: Activity Emoji Label
- Small Label node created programmatically above each NPC sprite
- Shows a single emoji/symbol character: `*` (baker), `#` (blacksmith), `$` (shopkeeper), `Zzz` (sleeping), etc.
- 8px white text with black outline, semi-transparent — minimal and non-intrusive

## Perception Upgrade
- **Before:** "Saw Maria near the Bakery"
- **After:** "Saw Maria kneading dough at the oven near the Bakery"
- NPCs now observe what others are DOING, not just where they are
- Player observations unchanged (no activity for player yet)

## Dialogue Context Enrichment
- NPC's own activity added to Gemini context: "You are currently kneading dough at the oven."
- Nearby active objects included: "Around you: the oven is baking, the counter is idle."
- Template fallback responses reference activity: "Oh, hello! Just kneading dough at the oven here."
- NPC-to-NPC conversation context includes both NPCs' activities

## Debug
- F3 overlay now shows activity string (light blue) under each NPC entry
- Hourly debug print: `[Activity] Maria: kneading dough at the oven (at Bakery)`

## Files Changed
| File | Action |
|------|--------|
| `scripts/npc/npc_controller.gd` | MODIFY — `current_activity`, `_update_activity()`, work activities, perception enrichment, dialogue enrichment, NPC chat context, activity label |
| `scripts/ui/debug_overlay.gd` | MODIFY — Activity shown in F3 overlay |
