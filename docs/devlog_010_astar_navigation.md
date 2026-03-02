# DevLog 010 — NPC Navigation Fix: AStarGrid2D (Nuclear Option)

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** Implemented — awaiting test

---

## Problem

After 3+ attempts using NavigationServer2D / NavigationPolygon / TileMapLayer native nav (devlogs 008-009), NPCs remain stationary. The navmesh appears valid (green debug overlay), but NavigationAgent2D never returns a usable path. The issue is likely in how Godot 4.6 processes programmatically-built NavigationPolygon data at runtime.

## Root Cause

NavigationServer2D requires perfectly connected navmesh polygons with edge-matching between regions. When tiles are created programmatically at runtime (not via the editor), this connectivity is fragile and breaks silently — `NavigationAgent2D.get_next_path_position()` returns the NPC's current position, so NPCs stand still.

## Solution: Replace NavigationServer2D with AStarGrid2D

Godot 4's built-in `AStarGrid2D` is designed for tile-based pathfinding:
- Operates on a simple 2D boolean grid (walkable/solid)
- Zero navmesh baking or NavigationServer dependency
- Returns `PackedVector2Array` of waypoints to follow
- Ready instantly after `update()` — no async sync delay
- Grid cells are inherently connected to neighbors (no edge-matching)

### Changes to `town_generator.gd`
1. Removed ALL NavigationPolygon / navigation layer code from TileSet
2. Set `navigation_enabled = false` on both layers
3. Added `_astar: AStarGrid2D` member variable
4. Added `_build_astar()` — creates grid matching the tile map, marks walls/water/roofs as solid
5. Added `get_astar() -> AStarGrid2D` for NPCs to query
6. `_build_astar()` called in `_ready()` after `_render_map()`

### Changes to `npc_controller.gd`
1. Removed ALL NavigationAgent2D usage (no more `nav_agent`, `_nav_ready`, retry timers)
2. Added `_path: PackedVector2Array` and `_path_index: int` for waypoint following
3. In `_ready()`: waits 1 process frame, grabs `AStarGrid2D` from `TownMap` via scene tree
4. In `_update_destination()`: converts pixel positions → grid coords, calls `_astar.get_point_path()`
5. In `_physics_process()`: follows waypoints sequentially with 4px arrival threshold
6. Much simpler code — 120 lines vs 139 lines, no async waits or retry hacks

### AStarGrid2D configuration
- `region`: `Rect2i(0, 0, 50, 40)` — matches MAP_WIDTH × MAP_HEIGHT
- `cell_size`: `Vector2(32, 32)` — matches TILE_SIZE
- `offset`: `Vector2(16, 16)` — tile center (half tile size)
- `diagonal_mode`: `DIAGONAL_MODE_NEVER` — 4-directional only

## Why This Should Work

| Problem | NavigationServer2D | AStarGrid2D |
|---------|-------------------|-------------|
| Connectivity | Fragile edge-matching between polygon regions | Grid cells inherently connected to neighbors |
| Runtime build | NavigationPolygon API has undocumented edge cases | `set_point_solid()` is one line per tile |
| Path query failure | Fails silently (returns current pos) | Returns empty array (easy to detect and log) |
| Async readiness | Needs multiple physics frames to sync | Ready instantly after `update()` |

## Expected Console Output

```
[TownMap] AStarGrid2D built: 50x40, walkable tiles marked
[Maria] Got AStarGrid2D reference
[Maria] Hour 6 -> 'Bakery' | Path: 25 waypoints | From (7, 27) -> (18, 9)
[Maria] Arrived at 'Bakery'
```

## Note

The `NavigationAgent2D` node still exists in `npc.tscn` but is no longer referenced by the script. It can be removed in a future cleanup pass.

---

## Files Modified
- `scripts/world/town_generator.gd` — removed nav layers, added `_build_astar()` and `get_astar()`
- `scripts/npc/npc_controller.gd` — complete rewrite for A* waypoint following
