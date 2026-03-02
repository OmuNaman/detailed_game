# DevLog 008 — Fix NPC Navigation: TileMapLayer → NavigationRegion2D

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** Navigation rewritten, testing needed

---

## Problem

After the graphics overhaul (devlog 007), NPCs were visible in their home buildings with unique sprites but completely stationary. They should pathfind to workplaces at 06:00 and to the Tavern at 17:00.

## Root Cause Analysis

**Two bugs found:**

### Bug 1 — Navigation polygon coordinates were wrong
TileData navigation polygons use **center-relative** coordinates (0,0 = tile center), just like collision polygons. The code was using top-left-relative coordinates `(0,0)→(32,32)`, which meant each nav polygon only covered the **bottom-right quarter** of its tile. The navmesh was completely fragmented with no valid paths between tiles.

### Bug 2 — TileMapLayer per-tile regions are fragile
Even after fixing coordinates, TileMapLayer creates a **separate NavigationServer2D region per tile**. For adjacent tiles to connect, their edges must be matched by the edge_connection_margin (default 1.0px). This is inherently fragile — floating point precision, cell_size mismatches, or Godot version differences can break connectivity.

## Solution

### Replaced TileMapLayer navigation with a single NavigationRegion2D

Instead of relying on per-tile regions, we now build one unified navmesh:

1. **Disabled TileMapLayer navigation** on both ground and building layers (`navigation_enabled = false`)
2. **Removed navigation layer** from the TileSet entirely (only physics collision remains)
3. **Added `_build_navigation()`** that creates a NavigationRegion2D with:
   - A vertex grid at every tile corner: `(MAP_WIDTH+1) × (MAP_HEIGHT+1)` = 2091 vertices
   - One quad polygon per walkable tile (GRASS, PATH, FLOOR, DOOR)
   - Adjacent tiles **share corner vertices** → NavigationServer2D connects them automatically within the same region
   - No edge-matching margin dependency

### NPC controller improvements
- Wait **3 physics frames** (was 1) before first navigation attempt, giving NavigationServer time to process the region
- Added **retry mechanism**: if nav agent can't find a path, retry every 2 seconds instead of waiting for the next hour change

## Why this approach is robust
- Single region = internal edge connections (shared vertices), not cross-region edge matching
- No dependency on TileMapLayer's navigation implementation details
- Works identically across Godot versions
- ~1700 walkable tile quads with shared vertices is trivial for NavigationServer2D

---

## Files Modified
- `scripts/world/town_generator.gd` — removed TileSet nav layer, disabled layer nav, added `_build_navigation()`
- `scripts/npc/npc_controller.gd` — 3-frame wait, retry timer on failed pathfinding
