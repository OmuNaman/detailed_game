# Devlog 038 — Conversation Positioning & Movement Lock

## What Changed

Three immersion-breaking issues fixed:
1. **NPCs "telepathically" chatted** from across the room without walking to each other
2. **NPCs walked away mid-player-conversation** when their schedule fired
3. **NPCs could be in two conversations at once** (no mutual exclusion)

## New Systems

### Conversation Lock (`npc_controller.gd`)
- `_in_conversation` bool prevents all movement, scheduling, and destination changes while talking
- `lock_for_conversation(partner_name)` / `unlock_conversation()` lifecycle
- Guards added to: `_physics_process()`, `_update_destination()`, `_on_hour_changed()`, `_on_time_tick()`
- Safety timeout: auto-unlock after 15 game minutes if stuck
- On unlock, NPC immediately re-evaluates where they should be

### Approach-Then-Talk (`npc_conversation.gd`)
- NPCs now **walk to an adjacent tile** of their conversation target before starting
- `_start_approach(target)` — paths to cardinal-adjacent walkable tile (max 12 tiles away)
- `check_approach_arrived()` — validates target is still available, begins conversation on arrival
- Approach canceled if: target starts moving, target enters another conversation, emergency needs fire
- Activity label shows "walking over to {name}" during approach, "talking with {name}" during conversation

### Tile Anti-Stacking (`npc_controller.gd`)
- `_resolve_tile_collision()` runs on every arrival — nudges NPC to nearest free tile if stacked
- `_find_nearest_free_tile()` searches expanding rings (1-3 tiles), respects pathfinding grid and other NPCs

### Player Conversation Freeze (`npc_dialogue.gd`)
- NPC locked on player dialogue open, unlocked on close
- Schedule awareness in dialogue context — NPC mentions needing to leave if schedule says elsewhere
- Any in-progress NPC-NPC approach canceled when player starts talking

### Safety Systems
- `dialogue_box.gd`: Force-unlock fallback if NPC still locked after `on_player_conversation_ended()`
- `player_controller.gd`: Can't interact with NPC already in conversation
- `npc_perception.gd`: Skip NPC observations and env scans during conversation
- Midnight reset clears any orphaned approach state

## Files Changed

| File | Lines | Change |
|------|-------|--------|
| `scripts/npc/npc_controller.gd` | 494 → ~580 | Lock vars, lock/unlock methods, all guards, tile collision |
| `scripts/npc/npc_conversation.gd` | 558 → ~630 | Full approach-then-talk rewrite |
| `scripts/npc/npc_dialogue.gd` | 565 → ~580 | Lock on open, unlock on close, schedule awareness |
| `scripts/ui/dialogue_box.gd` | 172 → ~176 | Safety unlock fallback |
| `scripts/player/player_controller.gd` | 90 → ~93 | Busy NPC check |
| `scripts/npc/npc_perception.gd` | 212 → ~218 | Conversation guards |
