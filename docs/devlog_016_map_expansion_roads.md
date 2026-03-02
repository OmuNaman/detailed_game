# Devlog 016 — Map Expansion & Two-Tier Roads

## Date: 2026-03-03

## Overview
Expanded the map, resized all buildings, and added a proper two-tier road system with cobblestone main roads and dirt side paths. No furniture or NPC system changes — purely structural.

---

## Map Expansion

**Before:** 50×40 tiles (1600×1280 px)
**After:** 60×45 tiles (1920×1440 px)

Only the two constants `MAP_WIDTH` and `MAP_HEIGHT` needed updating — all other code already referenced these constants.

## Building Resize & Reposition

All houses upgraded from 4×4 to **6×5** (interior goes from 2×2 = 4 floor tiles to 4×3 = 12 floor tiles — 3× more space).

Commercial/service buildings also grew slightly:
- Bakery: 5×4 → 6×5
- Church: 6×7 → 7×8
- Sheriff Office: 5×4 → 6×5
- Courthouse: 7×5 → 8×5
- Blacksmith: 5×4 → 6×5

Layout reorganized into clear zones:
- **Commercial row** (top): General Store, Bakery, Tavern, Church
- **Service row** (middle): Sheriff Office, Courthouse, Blacksmith
- **Housing row 1** (y=25): Houses 1-6
- **Housing row 2** (y=33): Houses 7-11

All building names unchanged — NPC data auto-adjusts since it references names, not coordinates.

## Two-Tier Road System

Added two new tile types to the `Tile` enum:
- `COBBLESTONE` (10) — grey stone, used for main roads
- `DIRT_PATH` (11) — brown dirt, used for side streets

**Cobblestone main roads:**
- East-west highway at y=12-13 (full map width)
- North-south highway at x=29-30 (full map height)

**Dirt side streets:**
- Housing street 1 at y=23-24
- Housing street 2 at y=31-32
- Vertical connectors to all commercial, service, and residential buildings

Both tile types are walkable for NPCs and have no physics collision for the player.

## Other Changes

- **Water:** Pond moved to bottom-right corner (center ~50,39) to avoid building overlap
- **Player spawn:** Moved to main crossroads at tile (29, 13)
- **Sprites:** Added `gen_cobblestone()` and `gen_dirt_path()` to `tools/generate_sprites.py`

---

## Files Modified
| File | Changes |
|------|---------|
| `tools/generate_sprites.py` | Added road palette colors, `gen_cobblestone()`, `gen_dirt_path()`, updated main() |
| `scripts/world/town_generator.gd` | Map 60×45, new buildings array, Tile enum + 2 road types, new road network, moved water/spawn, updated walkability |

## Notes
- This is polish pass 2A. Next passes: 2B (furniture/decoration), 2C (windows/awnings).
- NPC movement, memory, dialogue, and needs systems are completely untouched.
