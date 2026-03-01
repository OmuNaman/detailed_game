# DevLog 001 — Project Initialization & First Playable Scene

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** Working playable prototype

---

## What We Did

### 1. Project Structure
Created the full folder hierarchy from CLAUDE.md:
```
assets/sprites/    — placeholder 32x32 PNG textures
assets/audio/      — (empty, for future SFX)
assets/fonts/      — (empty, for future pixel fonts)
scenes/world/      — town and player scenes
scenes/npcs/       — (empty, for future NPC scenes)
scenes/ui/         — (empty, for future HUD/dialogue)
scenes/systems/    — (empty, for future autoload scenes)
scripts/core/      — (empty, for GameClock, EventBus, SaveManager)
scripts/npc/       — (empty, for AIBrain, Memory, etc.)
scripts/systems/   — (empty, for CrimeSystem, CourtSystem, etc.)
scripts/world/     — town.gd, town_generator.gd
scripts/player/    — player_controller.gd
scripts/llm/       — (empty, for GeminiClient)
data/dialogue/     — (empty, for dialogue templates)
docs/              — this devlog
```

### 2. project.godot Configuration
- **Engine:** Godot 4.6, GL Compatibility renderer
- **Viewport:** 640x480, scaled 2x to 1280x960 window
- **Stretch mode:** viewport (pixel-perfect scaling)
- **Texture filter:** Nearest neighbor (crisp pixel art)
- **Input map:** WASD + Arrow keys for move_up/down/left/right, E + Enter for interact

### 3. Placeholder Textures (32x32 PNGs)
Generated 9 solid-color placeholder tiles via Python:
| Texture | Color | Purpose |
|---------|-------|---------|
| grass.png | Green (#4C9900) | Ground fill |
| path.png | Sandy (#C2B280) | Roads and walkways |
| water.png | Blue (#3366CC) | Pond |
| wall.png | Brown (#8B5A2B) | Building walls |
| floor.png | Beige (#B4A078) | Building interiors |
| roof.png | Red (#B22222) | Building rooftops |
| door.png | Dark brown (#654321) | Building entrances |
| window_tile.png | Light blue (#87CEEB) | Windows (unused yet) |
| player.png | Royal blue (#4169E1) | Player character |

### 4. Player Scene (`scenes/world/player.tscn`)
- **Node type:** CharacterBody2D
- **Sprite2D:** Uses player.png, offset up by 10px so feet align with collision
- **CollisionShape2D:** 20x12 rectangle (feet-level collision)
- **Camera2D:** 2x zoom, smooth position tracking (speed 8.0)

### 5. Player Movement (`scripts/player/player_controller.gd`)
- GBA Pokemon-style: **4-directional only, no diagonal movement**
- When both axes have input, the dominant axis wins
- Speed: 120 pixels/second
- Tracks facing direction for future sprite animation
- Visual feedback: sprite alpha dims slightly when idle

### 6. Town Map Generator (`scripts/world/town_generator.gd`)
**Approach:** Procedural generation at runtime using ColorRect nodes (no TileMap node needed). This keeps the .tscn file small and the layout easy to modify in code.

**Map size:** 50x40 tiles (1600x1280 pixels)

**Town layout — 12 buildings:**
- **North (commercial):** General Store (6x5), Bakery (5x4), Tavern (7x5), Church (6x7)
- **Middle (civic):** Sheriff Office (5x4), Courthouse (7x5), Blacksmith (5x4)
- **South (residential):** 5 houses (4x4 each)

**Road network:**
- Main crossroads at tiles (25-26, 12-13) — horizontal + vertical
- Secondary residential road at y=22-23
- Connecting paths from roads to each building's door

**Buildings have:**
- Red roof (top row)
- Brown walls (perimeter)
- Beige floor (interior)
- Dark brown door (bottom center)
- White label above with building name
- StaticBody2D collision on every wall/roof tile

**Other features:**
- Elliptical pond in southeast corner (blue water tiles with collision)
- Invisible boundary walls around the entire map edge
- Player spawns at the crossroads intersection

### 7. Town Root Script (`scripts/world/town.gd`)
Simple coordinator: repositions the player to the map's spawn point after the TownMap generates.

---

## Architecture Decisions

1. **Runtime generation over .tscn tilemap:** Writing a 2000-tile tilemap in .tscn format would be fragile and huge. Generating from code is readable, version-control friendly, and easy to iterate on.

2. **ColorRect tiles instead of TileMap node:** For placeholder art, solid colors are clearer than tiny texture squares. When real pixel art arrives, we'll switch to proper TileMapLayer nodes.

3. **Per-tile StaticBody2D for collision:** Simple but not optimal for 100+ wall tiles. Will consolidate into merged collision shapes when performance matters.

4. **Camera on Player node:** Camera2D as a child of Player means it follows automatically. Smooth tracking gives a polished feel even with placeholder art.

---

## Checklist Progress (Phase 1)
- [x] Project setup
- [x] Tile map with buildings (homes, shop, tavern, sheriff office, courthouse, church)
- [x] Player movement (top-down, 4-directional, GBA Pokemon style)
- [ ] Game clock with day/night cycle
- [ ] NPC spawning with core descriptions and personality traits
- [ ] ...everything else

---

## Next Steps
- Game clock with day/night cycle (CanvasModulate for lighting)
- NPC base scene with pathfinding (NavigationRegion2D)
- EventBus autoload for decoupled communication
- Replace placeholder ColorRects with proper TileMapLayer when art is ready
