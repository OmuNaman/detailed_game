# DevLog 009 — NPC Navigation Attempt 3: Back to TileMapLayer Native Nav

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** NPCs still not moving

---

## What Was Tried

### Reverted to TileMapLayer native navigation

Removed the manual `NavigationRegion2D` with shared-vertex quads (devlog 008) and went back to letting TileMapLayer handle navigation natively:

1. Re-added `ts.add_navigation_layer()` to the TileSet
2. Walkable tiles (grass, path, floor, door) get `set_navigation_polygon()` with center-relative coordinates `(-16,-16)→(16,16)`
3. Set `_ground_layer.navigation_enabled = true`
4. Deleted `_build_navigation()` entirely

### Fixed NPC target positions

`get_building_door_positions()` was returning the building center (deep inside walls). Now returns the **door tile position** (bottom center of building) — the actual walkable entry point NPCs should navigate to.

### Improved NPC controller timing

- `_nav_ready` flag — waits **10 physics frames** before first navigation attempt
- Guards `_physics_process` and `_on_hour_changed` with `_nav_ready` check
- Added `print()` debug logging for navigation events
- Retry timer (2s) as fallback if initial pathfinding fails

## Result

**NPCs still not moving.** Three different navigation approaches have now failed:

1. **Manual NavigationRegion2D with add_polygon()** — devlog 008 (shared-vertex quads)
2. **TileMapLayer native with center-relative nav polygons** — this devlog
3. **Various earlier attempts** — devlogs 004-006

The visible navigation debug overlay (Debug → Visible Navigation) shows green on walkable tiles, confirming the navmesh data exists. The issue may be in how NavigationAgent2D queries the map, NPC spawn positioning, or a Godot 4.6-specific behavior.

---

## Files Modified
- `scripts/world/town_generator.gd` — TileSet nav layer restored, `_build_navigation()` removed, door positions fixed
- `scripts/npc/npc_controller.gd` — 10-frame wait, `_nav_ready` guard, debug prints, retry timer
