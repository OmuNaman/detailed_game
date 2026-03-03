# Devlog 026 — Relationship System

## What Changed
NPCs now track numerical relationships with every other entity (NPCs + Player) across three dimensions: trust, affection, and respect. Relationships evolve from interactions — conversations build trust and affection, while daily decay drifts unused relationships toward neutral. This turns flavor text ("Gideon has a crush on Maria") into living, trackable data that affects dialogue, reflections, and NPC awareness.

## Relationships Autoload (`scripts/core/relationships.gd`)
New `Relationships` autoload stores pairwise scores in `{source: {target: {trust, affection, respect}}}`.

**Three dimensions (-100 to 100):**
- **Trust** — reliability, honesty, dependability
- **Affection** — warmth, fondness, emotional closeness
- **Respect** — admiration, professional regard

**Overall opinion** = weighted average: trust×0.4 + affection×0.35 + respect×0.25

**Opinion labels** (used in dialogue context):
| Range | Label |
|-------|-------|
| >60 | deeply trusts |
| >30 | likes |
| >10 | feels friendly toward |
| >-10 | feels neutral about |
| >-30 | dislikes |
| >-60 | distrusts |
| ≤-60 | despises |

## Initial Seeds (`data/npcs.json`)
Each NPC entry now has a `"relationships"` field with starting values derived from personality text:
- **Gideon → Maria:** T:20 A:55 R:30 (secret crush — high affection, low trust from shyness)
- **Finn ↔ Clara:** T:80 A:75 R:60 (married couple — all dimensions high)
- **Bram ↔ Lyra:** T:10 A:-5 R:25/15 (rivalry — negative affection, grudging respect)
- **Rose ↔ Maria:** mutual warmth (gossip friends)
- **Rose ↔ Old Silas:** warm (tavern regular)
- **All → Player:** starts 0/0/0 (newcomer, unknown)

Seeds only apply on first run — saved relationships are never overwritten.

## Relationship Evolution

### Conversations (+1 trust, +1 affection per interaction)
- NPC-to-NPC conversation (real or template) → `modify_mutual()` both sides
- Player dialogue (first greeting or continued exchange) → `modify()` NPC→Player

### Daily Decay
- At midnight (hour 0), all scores drift 1 point toward 0
- Strong relationships (e.g., Finn↔Clara at 80) take 80 days to fully decay without interaction
- Active relationships easily outpace decay with regular conversations

## Context Enrichment

### Player Dialogue (`_build_dialogue_context()`)
Added after needs: "Your feelings toward {player}: you {label} them. (Trust: X, Affection: Y, Respect: Z)"

### NPC-to-NPC Chat (`_build_npc_chat_context()`)
Added after activities: "You {label} {other_name}. (Trust: X, Affection: Y, Respect: Z)"

### System Prompt (`_build_system_prompt()`)
Added top 3 closest friends with labels: "Key relationships: You like Rose, You feel friendly toward Gideon"

### Reflection Prompt (`_build_reflection_system_prompt()`)
Added full relationship summary so reflections can generate insights like "My trust in the newcomer is growing" or "I've realized I don't respect Thomas as much as I used to"

## Debug Overlay
F3 now shows top 2 relationships per NPC: `Rels: Rose:+35 Gideon:+22`

## Persistence
- Saved to `user://relationships.json` alongside NPC memory saves (F5, window close)
- Loaded automatically on game start via `Relationships._ready()`
- JSON format: nested dictionaries, human-readable with tab indentation

## Performance
- No per-frame processing — updates only on conversation events
- Daily decay: one pass through all pairs at midnight
- Lightweight Dictionary lookups for context building

## Files Changed
| File | Action |
|------|--------|
| `scripts/core/relationships.gd` | NEW — Relationships autoload |
| `project.godot` | MODIFY — Added Relationships autoload |
| `data/npcs.json` | MODIFY — Added relationship seed data to all 11 NPCs |
| `scripts/world/town.gd` | MODIFY — Seed on spawn, daily decay at midnight, save on close |
| `scripts/npc/npc_controller.gd` | MODIFY — Relationship updates after conversations, relationship context in dialogue/chat/system/reflection prompts |
| `scripts/ui/debug_overlay.gd` | MODIFY — Top 2 relationships per NPC in F3 |
