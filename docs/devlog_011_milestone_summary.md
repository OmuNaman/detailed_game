# DevLog 011 — Phase 1 Milestone Summary: Foundation Complete

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** Core foundation systems working. NPCs pathfinding with AStarGrid2D.

---

## What We Built (Full Timeline)

### DevLog 001 — Project Initialization & First Playable Scene
- Created Godot 4.6 project from scratch with full directory structure
- Built `town_generator.gd` — procedurally generates a 50×40 tile town with 12 buildings (shops, homes, tavern, church, courthouse, sheriff office, blacksmith)
- Player controller with 4-directional movement (GBA Pokemon style, 120px/s)
- Camera2D with 2x zoom and smooth follow
- Collision boundaries for the full map
- Originally rendered with ColorRect tiles (later replaced)

### DevLog 002 — GameClock, EventBus & Day/Night Cycle
- `GameClock` autoload — 1 real second = 1 game minute, tracks minute/hour/day/season
- `EventBus` autoload — central signal hub (`time_tick`, `time_hour_changed`, `time_day_changed`, `time_season_changed`)
- `DayNightCycle` via CanvasModulate — smooth color transitions through dawn, day, dusk, night
- `TimeHUD` — displays current time, day, and season in top-left corner
- Save/load state support for clock persistence

### DevLog 003 — NPCs with Pathfinding & Schedule-Driven Movement
- 5 NPCs defined in `data/npcs.json`: Maria (Baker), Thomas (Shopkeeper), Elena (Sheriff), Father Aldric (Priest), Gideon (Blacksmith)
- NPC scene: CharacterBody2D with Sprite2D, CollisionShape2D, NavigationAgent2D, NameLabel
- Schedule system: 22:00-06:00 sleep at home, 06:00-17:00 work, 17:00-22:00 tavern
- NPCs spawned at home positions, pathfind on hour changes

### DevLogs 004-006 — Navigation Struggles (3 Failed Approaches)
- **Attempt 1:** Outline-based NavigationPolygon with building holes — NPCs couldn't exit buildings
- **Attempt 2:** Tile-to-polygon approach (~1500 individual quads) — connectivity issues
- **Attempt 3:** Various edge-matching and margin tweaks — still broken
- **Root cause identified:** ColorRect rendering was fundamentally incompatible with reliable navmesh. Decision made to switch to TileMap.

### DevLog 007 — Graphics Overhaul: ColorRect → TileMap + Pixel Art
- Created `tools/generate_sprites.py` — Python + Pillow script generating 16 GBA-style 32×32 pixel art sprites:
  - 10 tile sprites: 3 grass variants, path, water, wall_front, wall_side, floor_wood, door, roof
  - 6 character sprites: player, Maria, Thomas, Elena, Father Aldric, Gideon (each with unique colors/features)
- Rewrote `town_generator.gd` to use TileMapLayer with programmatic TileSet:
  - Horizontal atlas built from individual PNGs at runtime
  - Two layers: GroundLayer (walkable tiles) and BuildingLayer (walls/roofs)
  - Physics collision on non-walkable tiles
  - Roof color tinting per building type
- Updated NPC system to load unique sprite textures per character

### DevLogs 008-009 — More Navigation Attempts (Still Failed)
- **Attempt 4:** Fixed center-relative coordinates for NavigationPolygon (was using top-left `(0,0)→(32,32)` instead of `(-16,-16)→(16,16)`)
- **Attempt 5:** Single NavigationRegion2D with shared-vertex quads — no edge-matching dependency
- **Attempt 6:** Back to TileMapLayer native navigation with 10-frame initialization delay
- All failed silently — NavigationAgent2D returned current position (no path found) despite valid-looking navmesh overlay
- **Conclusion:** Programmatically building NavigationPolygon data at runtime is unreliable in Godot 4.x

### DevLog 010 — AStarGrid2D (The Fix That Worked)
- **Nuclear option:** Replaced NavigationServer2D entirely with `AStarGrid2D`
- `_build_astar()` creates a 50×40 grid matching the tile map, marks walls/water/roofs as solid
- NPC controller rewritten to follow `PackedVector2Array` waypoints from `get_point_path()`
- No navmesh baking, no async sync delays, no edge-matching — just a boolean grid
- NPCs now pathfind reliably between all buildings

### Additional Improvements (This Session)
- **Time speed dev tool:** Press F6 to cycle through 1x → 2x → 5x → 10x → 30x → 60x speed
- **Building interior positions:** NPCs pick random floor tiles inside buildings instead of all stacking on the door tile — they spread out naturally
- **Door targeting:** NPCs walk through the door and stop on interior floor tiles (`gy + h - 2`) rather than on the door tile itself

---

## Architecture Overview

```
Town (Node2D) — town.gd
├── DayNightCycle (CanvasModulate) — day_night_cycle.gd
├── TownMap (Node2D) — town_generator.gd
│   ├── GroundLayer (TileMapLayer) — grass, paths, floors, doors
│   ├── BuildingLayer (TileMapLayer) — walls, roofs
│   ├── LabelLayer (Node2D) — building name labels
│   └── StaticBody2D × 4 — map boundary walls
├── Player (CharacterBody2D) — player_controller.gd
├── NPC × 5 (CharacterBody2D) — npc_controller.gd
│   ├── Sprite2D — unique per-NPC texture
│   ├── CollisionShape2D
│   ├── NavigationAgent2D — (unused, kept for future)
│   └── NameLabel (Label)
└── TimeHUD (CanvasLayer) — time_hud.gd

Autoloads:
├── GameClock — time tracking, F6 speed control
└── EventBus — signal hub for all systems
```

## Key Technical Decisions

| Decision | Why |
|----------|-----|
| AStarGrid2D over NavigationServer2D | Runtime-built navmesh was silently broken in Godot 4.6. A* grid is deterministic and instant |
| Programmatic TileSet (no .tres files) | All assets generated from Python script — no editor dependency, fully reproducible |
| Two TileMapLayers | Walls/roofs on BuildingLayer render above ground; GroundLayer handles walkable tiles |
| 4-directional movement only | GBA Pokemon aesthetic — diagonal movement disabled via `DIAGONAL_MODE_NEVER` |
| NPCs defined in JSON | Data-driven design — add new NPCs without touching code |
| Interior randomization | NPCs pick random FLOOR tiles per building — prevents stacking, adds life |

## Files in the Project

### Scripts (10 files)
- `scripts/core/game_clock.gd` — time system with speed control
- `scripts/core/event_bus.gd` — signal hub
- `scripts/world/town.gd` — scene orchestrator, NPC spawning
- `scripts/world/town_generator.gd` — map generation, TileSet, AStarGrid2D
- `scripts/world/day_night_cycle.gd` — CanvasModulate color transitions
- `scripts/npc/npc_controller.gd` — NPC movement, schedule, A* pathfinding
- `scripts/player/player_controller.gd` — player movement, camera
- `scripts/ui/time_hud.gd` — HUD display

### Scenes (4 files)
- `scenes/world/town.tscn` — main scene
- `scenes/world/player.tscn` — player character
- `scenes/npcs/npc.tscn` — NPC template
- `scenes/ui/time_hud.tscn` — time display UI

### Data (1 file)
- `data/npcs.json` — 5 NPC definitions (name, job, sprite, home, workplace)

### Assets (16 generated sprites)
- `assets/sprites/tiles/` — 10 tile sprites (grass ×3, path, water, wall_front, wall_side, floor_wood, door, roof)
- `assets/sprites/characters/` — 6 character sprites (player, Maria, Thomas, Elena, Aldric, Gideon)

### Tools (1 file)
- `tools/generate_sprites.py` — Python + Pillow sprite generator

---

## Phase 1 Checklist Progress

### Completed (6/19)
- [x] **Project setup** — Godot 4.6, directory structure, autoloads
- [x] **Tile map with buildings** — 12 buildings (6 commercial + 5 houses + 1 church), roads, pond, boundary
- [x] **Player movement** — 4-directional, 120px/s, camera with 2x zoom
- [x] **Game clock with day/night cycle** — 1s=1min, dawn/day/dusk/night transitions, season tracking
- [x] **NPC spawning with core descriptions** — 5 NPCs from JSON with unique sprites and personality-ready data
- [x] **NPC pathfinding (A* on tilemap)** — AStarGrid2D with schedule-driven movement (home→work→tavern)

### Remaining (13/19)
- [ ] **Basic needs system** — hunger, energy, social (decay over time, drive behavior)
- [ ] **Memory Stream** — NPCs observe and store MemoryRecords with importance scoring
- [ ] **Memory Retrieval** — recency + importance + relevance weighted retrieval
- [ ] **Daily Planning** — NPCs generate morning plans (template-based v1, LLM v2)
- [ ] **Observation system** — perception radius, NPCs only know what they see/hear
- [ ] **Interaction system** — talk to NPCs → retrieve memories → generate response
- [ ] **Gossip propagation** — NPCs share observations during social time
- [ ] **Reflection system** — periodic insight generation (rule-based v1, LLM v2)
- [ ] **Crime detection** — witness-based, fed by observation system
- [ ] **Sheriff arrest mechanic**
- [ ] **Simple court trial**
- [ ] **Reputation tracking** — per-NPC + town-wide, driven by memory/gossip
- [ ] **LLM integration** — Gemini API for dialogue, reflection, planning

### Progress: 32% complete (6 of 19 items)

---

## Lessons Learned

1. **NavigationServer2D is fragile with runtime-built data.** After 6 attempts across 4 devlogs, the solution was to bypass it entirely with AStarGrid2D. For tile-based games built in code, A* grids are far more reliable.

2. **ColorRect rendering was a dead end.** The original ColorRect-per-tile approach had no path to working navigation. Switching to TileMapLayer was the right call even though it required a full rewrite.

3. **Programmatic sprite generation works.** Python + Pillow generates all 16 sprites in under a second. No editor needed, fully reproducible, easy to iterate on art later.

4. **Data-driven design pays off early.** NPCs from JSON, buildings from arrays, tiles from enums — everything is easy to modify without touching logic code.

5. **Dev tools save time.** The F6 time speed toggle (1x-60x) makes testing schedule-driven behavior trivial instead of waiting 17 real minutes for the next hour change.

---

## What's Next

The next priority items for Phase 1:
1. **Basic needs system** — hunger/energy/social that decay and drive NPC behavior beyond fixed schedules
2. **Memory Stream** — the foundation for the Stanford Generative Agents-inspired cognitive architecture
3. **Interaction system** — let the player actually talk to NPCs
4. **Observation system** — NPCs should only know what they perceive within their radius
