# DevLog 005 — Tile-Based Navigation Mesh

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** NPCs reliably enter and exit buildings via door tiles

---

## Problem
After DevLog 004's wall-only navigation holes, NPCs could enter buildings but got **stuck inside their houses** and wouldn't leave for work. At 07:36 (work hours), all NPCs remained standing at their home interior positions.

**Root cause:** The 5-outline-per-building approach (roof, left wall, right wall, bottom-left wall, bottom-right wall) created outlines that **shared vertices** at corners. For example, the roof outline's bottom-left vertex `(gx*32, (gy+1)*32)` was identical to the left wall outline's top-left vertex. Godot's `make_polygons_from_outlines()` can't reliably resolve shared/touching outlines, producing a broken navmesh that isolated building interiors from the outside world.

---

## Fix: Direct Tile-Based Navigation Polygons

Replaced the entire outline-based approach with a direct tile-to-polygon strategy:

```
Before (outline + holes approach):
  1 outer boundary + 5 outlines/building + 1 water outline
  = ~63 outlines → make_polygons_from_outlines() → broken mesh

After (tile-based approach):
  Each walkable tile → 1 quad polygon in the navmesh
  Adjacent tiles share edge vertices → automatic connectivity
  No outline processing needed
```

### How It Works
1. Iterate all 50x40 = 2000 map tiles
2. For each walkable tile (grass, path, floor, door), create a quad polygon from its 4 corner vertices
3. Deduplicate vertices using a `Dictionary<Vector2i, int>` map — adjacent tiles share corner vertices automatically
4. Set `nav_poly.vertices` then call `add_polygon()` for each quad

### Why It's Better
- **No outline conflicts:** No outlines at all — polygons are defined directly
- **Correct connectivity:** Door tiles share edges with both interior floor tiles and exterior grass/path tiles, creating a continuous navigable surface through the door
- **Water/walls excluded implicitly:** Non-walkable tile types (wall=3, roof=5, water=2) simply don't get polygons
- **Simpler code:** One loop over all tiles replaces the complex outline generation with its many edge cases

### Trade-off
~1500 quad polygons vs ~20 large polygons from outlines. For a 50x40 map with 20 NPCs, this has no measurable performance impact. Can optimize later with polygon merging if needed.

---

## Files Changed
- **Modified:** `scripts/world/town_generator.gd`
  - Rewrote `_create_navigation_region()` — tile-based polygon generation
  - Replaced `_add_rect_outline()` with `_nav_vert()` vertex deduplication helper

---

## Result
NPCs now reliably pathfind from home interiors, through doors, across town, through workplace doors, and into workplace interiors. The schedule cycle (home → work → tavern → home) works correctly with NPCs entering and exiting all buildings.
