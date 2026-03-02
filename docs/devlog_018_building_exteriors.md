# Devlog 018 — Building Exteriors: Windows & Awnings

## Date: 2026-03-03

## Overview
Added 3 exterior tile types to make buildings visually distinct from outside — windows in walls and awnings above shop doors. Buildings can now be told apart by structure, not just roof color. No NPC or gameplay changes.

---

## New Tile Types

3 new tiles added to the `Tile` enum (IDs 22-24):

| ID | Tile | Description |
|----|------|-------------|
| 22 | WINDOW_FRONT | Front wall with 4-pane glass window |
| 23 | WINDOW_SIDE | Side wall with narrow window |
| 24 | AWNING | Red/white striped canopy above shop doors |

All exterior tiles are **non-walkable** — they replace wall tiles and behave identically for pathfinding.

## Window Placement

`_decorate_buildings()` runs after `_place_buildings()`, before `_place_furniture()`:

- **Front windows:** Replace WALL_FRONT tiles on both sides of the door (skipping door ±1 tile). Only for buildings w≥6.
- **Side windows:** One WINDOW_SIDE per wall at row gy+2. Only for buildings h≥5.
- **Church special:** Double side windows at gy+2 and gy+4 (tall 7×8 building).

## Awning Placement

Awnings placed on the roof row (`gy`) at the door position for shops:
- **General Store** (w=7): 3-tile wide awning, tinted warm gold
- **Bakery** (w=6): 1-tile awning, tinted warm orange
- **Tavern** (w=8): 3-tile wide awning, tinted reddish

Awning tinting is automatic — the existing roof tint loop in `_render_map()` iterates the full roof row and modulates all tiles including awnings.

## Building Window Summary

| Building | Front Windows | Side Windows | Awning |
|----------|--------------|-------------|--------|
| General Store (7×5) | 2 | 2 | 3-tile |
| Bakery (6×5) | 1 | 2 | 1-tile |
| Tavern (8×6) | 3 | 2 | 3-tile |
| Church (7×8) | 2 | 4 (double) | No |
| Sheriff Office (6×5) | 1 | 2 | No |
| Courthouse (8×5) | 3 | 2 | No |
| Blacksmith (6×5) | 1 | 2 | No |
| Houses (6×5) | 1 | 2 | No |

## Rendering

Exterior tiles render on the building layer (same as walls/roofs). Updated `_render_map()` to explicitly list all building-layer tile types and bound the furniture check to BED..DESK range.

## Sprite Generation

Added 4 new palette constants and 3 generator functions to `tools/generate_sprites.py`:
- `GLASS_LIGHT`, `GLASS_MID`, `GLASS_DARK`, `FRAME_WOOD`
- `gen_window_front()`, `gen_window_side()`, `gen_awning()`
- Total sprites: 37 (12 tiles + 10 furniture + 3 exterior + 12 characters)

---

## Files Modified
| File | Changes |
|------|---------|
| `tools/generate_sprites.py` | 4 glass/frame colors, 3 generator functions, updated `main()` |
| `scripts/world/town_generator.gd` | Tile enum +3, tile_paths +3, `_render_map()` updated, `_decorate_buildings()`, updated `_ready()` call order |

## Notes
- This is polish pass 2C. Windows and awnings are purely visual.
- NPC movement, memory, dialogue, and needs systems are completely untouched.
- `_decorate_buildings()` only replaces wall tiles with window/awning variants — no interior tiles affected.
