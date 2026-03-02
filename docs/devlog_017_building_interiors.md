# Devlog 017 — Building Interiors & Furniture

## Date: 2026-03-03

## Overview
Added 10 furniture tile types with GBA pixel art sprites and placed unique furniture layouts inside every building. Each building now has a distinct interior character. No NPC system changes — purely visual/structural.

---

## Furniture Tile Types

10 new tiles added to the `Tile` enum (IDs 12-21):

| ID | Tile | Used In |
|----|------|---------|
| 12 | BED | Houses |
| 13 | TABLE | Houses, Tavern |
| 14 | COUNTER | Tavern, Bakery, General Store |
| 15 | OVEN | Bakery |
| 16 | ANVIL | Blacksmith |
| 17 | PEW | Church, Courthouse |
| 18 | ALTAR | Church |
| 19 | BARREL | Tavern, Blacksmith |
| 20 | SHELF | General Store, Blacksmith, Sheriff Office, Houses |
| 21 | DESK | Sheriff Office, Courthouse |

All furniture is **non-walkable** — NPCs and players cannot walk through it. It's automatically solid because it's not in the walkable whitelist.

## Building Layouts

Furniture placed using interior offsets from each building's top-left interior corner (gx+1, gy+1):

- **Church** (5×6 interior): 3 altar tiles at front, 8 pews in two rows with center aisle
- **Tavern** (6×4 interior): 4-tile bar counter + 2 barrels in back, 2 tables on sides
- **Bakery** (4×3 interior): Oven in corner, 2-tile counter near door
- **Blacksmith** (4×3 interior): Tool shelf, anvil, barrel
- **General Store** (5×3 interior): 3-tile shelf wall, 2-tile counter
- **Sheriff Office** (4×3 interior): 2 desks, 1 shelf
- **Courthouse** (6×3 interior): 3 desks at front (judge bench), 3 pews for gallery
- **Houses ×11** (4×3 interior): Bed, shelf, table — cozy cottages

## Walkable Tiles per Building

| Building | Total Interior | Furniture | Walkable |
|----------|---------------|-----------|----------|
| Church | 30 | 11 | 19 |
| Tavern | 24 | 8 | 16 |
| Bakery | 12 | 3 | 9 |
| Blacksmith | 12 | 3 | 9 |
| General Store | 15 | 5 | 10 |
| Sheriff Office | 12 | 3 | 9 |
| Courthouse | 18 | 6 | 12 |
| Houses (each) | 12 | 3 | 9 |

## Dual-Layer Rendering

Furniture uses a two-layer approach in `_render_map()`:
- **Ground layer:** Wooden floor tile rendered underneath
- **Building layer:** Furniture sprite rendered on top

This prevents visual gaps — the wood floor is always visible around furniture edges.

## Sprite Generation

Added 10 new generator functions to `tools/generate_sprites.py`:
- 24 new furniture palette colors (blanket, brick, metal, altar, barrel, book colors)
- Each function creates a 32×32 GBA-style pixel art tile
- Total sprites: 34 (12 tiles + 10 furniture + 12 characters)

---

## Files Modified
| File | Changes |
|------|---------|
| `tools/generate_sprites.py` | Furniture palette (24 colors), 10 generator functions, updated `main()` |
| `scripts/world/town_generator.gd` | Tile enum +10, tile_paths +10, `_render_map()` dual-layer, `_place_furniture()` with per-building layouts, updated `_ready()` call order |

## Notes
- This is polish pass 2B. Next pass: 2C (windows/awnings).
- `get_building_interior_positions()` already filters on `Tile.FLOOR` only, so furniture tiles are automatically excluded from NPC standing positions.
- NPC movement, memory, dialogue, and needs systems are completely untouched.
