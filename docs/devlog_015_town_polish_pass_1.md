# Devlog 015 — Town Polish Pass 1: Positioning & Conversation Fixes

## Date: 2026-03-03

## Overview
Three targeted fixes to improve NPC visual behavior. No new systems — purely polish.

---

## Fix 1: Tile Reservation System (Anti-Stacking)

**Problem:** Multiple NPCs picked the same random interior tile and stacked on top of each other — especially bad at the Tavern with 7+ NPCs.

**Solution:** Added a tile reservation system to `town_generator.gd`:
- `_reserved_tiles: Dictionary` — maps `Vector2i` grid coords to NPC name
- `reserve_tile()` — claims a tile, fails if already claimed by another NPC
- `release_tile()` — frees a tile when an NPC leaves
- `get_unreserved_interior_tile()` — shuffles available tiles and picks the first unclaimed one

In `npc_controller.gd`:
- Stored `_town_map` reference alongside `_astar` in `_ready()`
- `_update_destination()` now releases old reservation before picking a new unreserved tile
- Falls back to random selection if `_town_map` is unavailable

## Fix 2: No More Doorway Standing

**Problem:** `get_building_interior_positions()` included the door tile as a valid standing position. NPCs sometimes stood in doorways like bouncers.

**Solution:** Removed the door-append block from `get_building_interior_positions()`. NPCs now only pick FLOOR tiles inside the building walls.

Building capacity check: smallest buildings (4x4) have 2x2 = 4 interior floor tiles, enough for 2 NPCs. Tavern (7x5) has 5x3 = 15 tiles — plenty.

## Fix 3: NPCs Face Each Other When Talking

**Problem:** During NPC-to-NPC conversations and player interactions, NPCs might face the wall or both face the same direction.

**Solution:** Added `_face_toward(target_pos)` helper that flips the sprite horizontally:
- **NPC-to-NPC conversations:** Both NPCs turn to face each other when `_try_npc_conversation()` triggers
- **Player interaction:** NPC turns to face the player at the start of `get_dialogue_response_async()`

---

## Files Modified
| File | Changes |
|------|---------|
| `scripts/world/town_generator.gd` | Added reservation system (3 methods + 1 var), removed door from interior positions |
| `scripts/npc/npc_controller.gd` | Stored `_town_map`, use reservations in `_update_destination()`, added `_face_toward()`, wired into conversations + player interaction |

## Notes
- This is polish pass 1. Future passes will cover furniture, world interaction, doors, and lighting.
- No new sprites, tiles, or systems were added.
