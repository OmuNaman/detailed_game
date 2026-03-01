# DevLog 004 — NPCs Now Enter Buildings

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** NPCs pathfind through doors into building interiors

---

## Problem
NPCs were standing outside building doors instead of going inside. Two issues:

1. **Entire buildings were navigation holes.** The NavigationPolygon carved out the full building rectangle, so the floor and door were non-walkable. NPCs could only reach the tile outside the door.

2. **Church overlapped the main road.** Church (gy=6, h=7) had its bottom wall at y=12, which is the main road row. This blocked the nav mesh and prevented Father Aldric from reaching the Church at all.

## Fixes

### 1. Wall-Only Navigation Holes
Instead of one big rectangular hole per building, each building now generates 5 smaller holes for just the walls:

```
Before (entire building = 1 hole):    After (walls only = up to 5 holes):
┌──────────┐                          ████████████  ← roof hole
│██████████│ ← all non-walkable       █          █  ← left/right wall holes
│██████████│                           █  floor   █  ← NAVIGABLE
│██████████│                           █          █
│████▒█████│ ← door also blocked      ██  ▒  ████  ← bottom wall holes (gap at door)
└──────────┘                                ▒ ← door = NAVIGABLE
```

The `_add_rect_outline()` helper creates each wall segment as a separate nav hole. Zero-width segments (when the door is at the edge) are automatically skipped.

### 2. Church Moved Up
Changed Church from `gy: 6` to `gy: 5`. Bottom wall now at y=11, safely above the main road at y=12. The road at (35, 12) directly connects to the Church door at (35, 11).

### 3. NPC Targets = Building Interior Center
`get_building_door_positions()` now returns the center of the floor area instead of one tile below the door:
- Old: `(door_x * 32 + 16, (gy + h) * 32 + 16)` — outside
- New: `((gx + w/2) * 32, (gy + h/2) * 32)` — interior center

### 4. Path Cleanup
Trimmed connecting paths that previously overlapped building roofs:
- Sheriff/Courthouse paths: stop at y=14 (before roof at y=15)
- Blacksmith path: stop at y=15 (before roof at y=16)
- Church path: removed (road at y=12 already touches the church door)

---

## Files Changed
- **Modified:** `scripts/world/town_generator.gd` (all 4 fixes above)

---

## Result
NPCs now walk from outside, through the door gap, into the building interior and stand at the center of the floor. When the schedule changes, they walk back out through the door.
