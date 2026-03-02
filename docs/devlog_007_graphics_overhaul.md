# DevLog 007 — Graphics Overhaul: ColorRect → TileMap + Pixel Art

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** Visual overhaul complete, navigation still needs fixing

---

## What Changed

### Replaced ColorRect rendering with TileMap + pixel art sprites

The entire rendering pipeline was rewritten. Previously, the town was drawn with runtime-generated ColorRect nodes (solid colored rectangles). Now it uses Godot's TileMapLayer with a programmatically built TileSet containing real pixel art.

### Created 16 GBA Pokemon-style sprites via Python + Pillow

`tools/generate_sprites.py` generates all assets:

**10 Tile sprites** (`assets/sprites/tiles/`):
- `grass_1.png`, `grass_2.png`, `grass_3.png` — grass variants with tufts and flowers
- `path_center.png` — sandy dirt path
- `water_1.png` — blue water with wave highlights
- `wall_front.png` — horizontal wood planks
- `wall_side.png` — vertical wood planks
- `floor_wood.png` — light interior floor planks
- `door.png` — paneled door with handle
- `roof_generic.png` — red shingle pattern (color-modulated per building type)

**6 Character sprites** (`assets/sprites/characters/`):
- `player_down.png` — blue tunic, brown hair
- `maria_down.png` — Baker, pink dress + white apron + hair bun
- `thomas_down.png` — Shopkeeper, green vest + white collar
- `elena_down.png` — Sheriff, blue uniform + gold badge
- `aldric_down.png` — Priest, dark robe + white collar + gray hair
- `gideon_down.png` — Blacksmith, brown work clothes + leather apron, broad build

### TileSet built programmatically in GDScript

`town_generator.gd` creates a TileSet at runtime:
1. Loads all tile PNGs and composites them into one horizontal atlas image
2. Adds source to TileSet BEFORE creating tiles (critical for layer access)
3. Walkable tiles (grass, path, floor, door) get NavigationPolygon
4. Non-walkable tiles (wall, roof, water) get physics CollisionPolygon
5. Two TileMapLayers: GroundLayer (walkable + navigation) and BuildingLayer (walls/roofs)
6. Grass randomly varies between 3 variants for visual interest
7. Roof tiles tinted per building type (church=purple, bakery=orange, etc.)

### NPC sprites are now unique per character

- `npcs.json` has `"sprite"` field instead of `"color"`
- `npc_controller.gd` loads the NPC's texture at runtime instead of modulating a shared sprite
- Each NPC is visually distinct by profession

---

## Known Issues (to fix next)
- NPCs still stuck in houses — TileMapLayer navigation may need additional setup
- Player may still clip through roofs — collision layer interaction needs verification

---

## Files Created
- `tools/generate_sprites.py` — sprite generation script
- `assets/sprites/tiles/` — 10 tile PNGs
- `assets/sprites/characters/` — 6 character PNGs

## Files Modified
- `scripts/world/town_generator.gd` — complete rewrite (ColorRect → TileMap)
- `scripts/npc/npc_controller.gd` — per-NPC sprite loading
- `data/npcs.json` — sprite paths replace color arrays
- `scenes/world/player.tscn` — new player texture path
- `scenes/npcs/npc.tscn` — new fallback texture path
