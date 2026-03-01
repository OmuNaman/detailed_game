# DevLog 006 — Navigation Mesh Struggles (3 Failed Approaches)

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** NPCs still stuck — pivoting to TileMap-based graphics with built-in navigation

---

## Problem
After DevLog 004 enabled NPCs to enter buildings, they got stuck inside and couldn't pathfind back out. Three successive approaches failed to create a working navmesh that connects building interiors to the outside through door gaps.

## Attempt 1: Five Outlines Per Building (DevLog 004)
Split each building into 5 rectangular outlines (roof, left wall, right wall, bottom-left wall, bottom-right wall) with `make_polygons_from_outlines()`.

**Failed because:** Adjacent outlines shared corner vertices (e.g., roof bottom-left = left wall top-left). `make_polygons_from_outlines()` can't resolve touching outlines, producing a broken navmesh that isolated building interiors.

## Attempt 2: Tile-Based Direct Polygons (DevLog 005)
Each walkable tile (grass, path, floor, door) became a quad polygon via `NavigationPolygon.add_polygon()`. Adjacent tiles shared edge vertices for automatic connectivity.

**Failed because:** `add_polygon()` didn't create proper edge connections between polygons. NPCs stopped at building doors and didn't enter. The direct polygon API appears to not work reliably for runtime navmesh construction.

## Attempt 3: Single Frame-Shaped Outline Per Building
Created one complex polygon per building shaped like a picture frame with a door notch — traces CW around exterior, enters door gap, CCW around interior, exits door.

**Failed because:** Same result as Attempt 2 — NPCs stuck at doors. The complex concave outline likely confused `make_polygons_from_outlines()`.

## Attempt 4: Godot 4 Baking API (Current)
Switched to the modern `bake_navigation_polygon()` API with `PARSED_GEOMETRY_STATIC_COLLIDERS`. Let the engine auto-detect walls from StaticBody2D nodes, with `agent_radius = 0`.

**Status:** Still not working. NPCs remain in houses.

---

## Root Cause Analysis
The fundamental issue is that we're generating the map from ColorRect nodes with manual StaticBody2D collision, then trying to build a NavigationPolygon on top of that. This is fragile because:

1. `make_polygons_from_outlines()` is deprecated and buggy with complex outlines
2. `add_polygon()` doesn't reliably create connected navmesh regions
3. The baking API with static colliders may not handle per-tile collision shapes well
4. ColorRect-based rendering has no native navigation support

## Decision: Pivot to TileMap
The correct solution is to use Godot's **TileMap** (or TileMapLayer in 4.x) with a **TileSet** that has navigation layers defined per tile. This is the standard Godot approach:

- Each tile type (grass, path, floor, door) gets a navigation polygon in the TileSet
- TileMap automatically builds the navigation region from painted tiles
- Wall/roof/water tiles have no navigation polygon → automatically non-walkable
- Door tiles connect interior to exterior seamlessly
- Bonus: enables proper sprite-based graphics (Kenney assets or custom pixel art)

---

## Files Changed
- **Modified:** `scripts/world/town_generator.gd` (4th navigation approach — baking API)

---

## Next Steps
- Replace ColorRect rendering with TileMap + proper TileSet (Kenney assets or GBA-style sprites)
- Navigation will come for free from the TileSet navigation layer
- This also improves visual quality significantly
