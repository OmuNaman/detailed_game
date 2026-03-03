# Devlog 021 — Stateful Furniture System

## What Changed
Furniture tiles are no longer static decoration. Every placed furniture object is now tracked by a new `WorldObjects` autoload with state, current user, and grid position. NPCs claim furniture when they arrive at a building and release it when they leave.

## WorldObjects Autoload
- New file: `scripts/core/world_objects.gd` — Dictionary-based registry
- Object IDs follow `"BuildingName:tile_type:index"` pattern (e.g., `"Bakery:oven:0"`)
- Each object tracks: state (idle/baking/forging/etc.), building, tile_type, grid_pos, current user, last_changed time
- Key methods: `register_object()`, `set_state()`, `release_object()`, `find_object_for_npc()`, `get_description()`
- Registered as autoload in `project.godot`

## Furniture Registration
- `town_generator.gd` scans all buildings after `_place_furniture()` runs
- Maps Tile enum IDs (12-21) to readable type names (bed, table, counter, oven, anvil, pew, altar, barrel, shelf, desk)
- Iterates building interiors and registers each furniture tile with WorldObjects
- Debug log: `[TownMap] Registered XX furniture objects with WorldObjects`

## NPC-to-Furniture Interaction
- Job-to-furniture mapping: Baker→oven, Shopkeeper→counter, Sheriff→desk, Priest→altar, Blacksmith→anvil, etc.
- Job-specific state strings: Baker sets oven to "baking", Blacksmith sets anvil to "forging"
- NPCs at home claim bed (nighttime) or table (mealtimes 7/12/19)
- Tavern visitors claim tables, Church visitors claim pews
- `_claim_work_object()` called on arrival, `_release_current_object()` called on departure

## Furniture-Targeted Pathfinding
- NPCs now pathfind to the floor tile ADJACENT to their work furniture (south preferred, then east/west/north)
- New `get_furniture_adjacent_tile()` method in town_generator checks walkability (FLOOR or DOOR tiles only)
- Falls back to random unreserved interior tile if no furniture target or no adjacent walkable tile

## Bug Fix: Grid Bounds
- Fixed hardcoded `clampi(..., 0, 49)` and `clampi(..., 0, 39)` in `_update_destination()`
- Now uses actual map dimensions via `_town_map.MAP_WIDTH` (60) and `_town_map.MAP_HEIGHT` (45)

## Files Changed
| File | Action |
|------|--------|
| `scripts/core/world_objects.gd` | NEW — WorldObjects autoload |
| `project.godot` | MODIFY — Added WorldObjects autoload |
| `scripts/world/town_generator.gd` | MODIFY — Registration + adjacent tile methods |
| `scripts/npc/npc_controller.gd` | MODIFY — Job mappings, claim/release, furniture pathfinding, grid fix |
