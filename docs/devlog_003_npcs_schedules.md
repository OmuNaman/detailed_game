# DevLog 003 — NPCs with Pathfinding & Schedule-Driven Movement

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** 5 NPCs walk between home, work, and tavern on schedule

---

## What We Did

### 1. NPC Data Definitions (`data/npcs.json`)
5 NPCs defined with name, job, color, home, and workplace:

| NPC | Job | Color | Home | Workplace |
|-----|-----|-------|------|-----------|
| Maria | Baker | Pink | House 1 | Bakery |
| Thomas | Shopkeeper | Orange | House 2 | General Store |
| Elena | Sheriff | Teal | House 3 | Sheriff Office |
| Father Aldric | Priest | Light Gray | House 4 | Church |
| Gideon | Blacksmith | Amber | House 5 | Blacksmith |

### 2. NPC Base Scene (`scenes/npcs/npc.tscn`)
Node structure:
```
NPC (CharacterBody2D, layer=4, mask=1)
├── Sprite2D         — reuses player.png, modulated to NPC color
├── CollisionShape2D — 20x12 feet-level rectangle
├── NavigationAgent2D
└── NameLabel        — white text with shadow, centered above sprite
```

### 3. NPC Controller Script (`scripts/npc/npc_controller.gd`)

**Initialization flow:**
1. `initialize(data, building_positions)` — called before adding to scene tree, stores NPC identity and building target positions
2. `_ready()` — sets sprite color, name label, connects signals, awaits one physics frame for navigation sync, then sets initial destination

**Schedule system:**
- Listens to `EventBus.time_hour_changed`
- Determines destination based on current hour:
  - **22:00–06:00** → home (sleeping)
  - **06:00–17:00** → workplace
  - **17:00–22:00** → tavern
- Only triggers navigation if destination actually changed

**Movement:**
- Speed: 80 px/s (slower than player's 120 px/s)
- Uses `NavigationAgent2D.get_next_path_position()` in `_physics_process()`
- Sprite flips horizontally based on movement direction
- Stops cleanly when navigation finishes

### 4. Navigation Region (`town_generator.gd` update)
Generated at runtime after the map tiles are placed:

**Approach:** One large NavigationPolygon with the entire map as the outer boundary, then buildings and water carved out as holes.

- **Outer boundary:** Rectangle covering full 50×40 tile map (1600×1280 px)
- **Building holes:** 12 rectangular cutouts, one per building (covers roof + walls + interior)
- **Water hole:** Bounding box of all water tiles

NPCs pathfind on the remaining walkable area (grass + paths). They navigate AROUND buildings to reach the door position (one tile below the building).

**Building door API:** New `get_building_door_positions() -> Dictionary` returns `{building_name: Vector2}` mapping each building to the walkable position just outside its door.

### 5. NPC Spawning (`town.gd` update)
- Loads `data/npcs.json` at startup
- For each NPC: instantiates scene, calls `initialize()`, positions at home door, adds to scene tree
- NPCs begin at their homes, then immediately pathfind to their workplace (game starts at 6:00 AM)

### 6. Collision Layer Fix (`player.tscn`)
Reorganized collision layers to prevent NPCs from blocking the player:

| Entity | Layer | Mask | Collides With |
|--------|-------|------|---------------|
| Static bodies (walls) | 1 | 0 | nothing (passive) |
| Player | 2 | 1 | walls only |
| NPCs | 4 | 1 | walls only |

Player and NPCs pass through each other. NPCs pass through other NPCs.

---

## Architecture Decisions

1. **Data-driven NPC spawning:** NPCs defined in JSON, loaded at runtime. Adding a new NPC = adding a JSON entry. No code changes needed.

2. **`initialize()` before `_ready()`:** NPC data is set before the node enters the scene tree. This means `_ready()` can safely use npc_name, color, etc. without null checks.

3. **NavigationPolygon with outline holes:** Simpler than per-tile polygons. One outer boundary + building/water holes creates a clean navmesh. NPCs walk around buildings on grass, which looks natural.

4. **Door positions = one tile below building:** Since buildings are carved as nav holes, NPCs can't enter them. The target is the first walkable tile outside the door. Visually this means NPCs "arrive at the building entrance."

5. **NPCs don't collide with each other or the player:** Keeps pathfinding simple — no avoidance logic needed yet. NPCs can overlap at destinations (e.g., all at the tavern). Avoidance can be added later via NavigationAgent2D's built-in avoidance.

---

## Files Changed/Created
- **Created:** `data/npcs.json`, `scripts/npc/npc_controller.gd`, `scenes/npcs/npc.tscn`
- **Modified:** `scripts/world/town_generator.gd` (navigation region + building door API)
- **Modified:** `scripts/world/town.gd` (NPC spawning from JSON)
- **Modified:** `scenes/world/player.tscn` (collision_layer 1 → 2)
- **Modified:** `CLAUDE.md` (checked off NPC spawning + pathfinding)

---

## Checklist Progress (Phase 1)
- [x] Project setup
- [x] Tile map with buildings
- [x] Player movement (top-down, 4-directional)
- [x] Game clock with day/night cycle
- [x] NPC spawning with core descriptions and personality traits ← **NEW**
- [x] NPC pathfinding (A* on tilemap) ← **NEW**
- [ ] Basic needs system (hunger, energy, social)
- [ ] Memory Stream — NPCs observe and store MemoryRecords
- [ ] ...everything else

---

## What You'll See
- Game starts at 6 AM: 5 colored squares spawn at houses in the south
- They immediately walk north to their workplaces (bakery, store, sheriff, church, blacksmith)
- At 17:00 (11 real seconds from start): all NPCs walk to the tavern
- At 22:00 (16 real seconds from start): all NPCs walk home
- Cycle repeats each game day
- Day/night tinting changes as they walk

---

## Next Steps
- Basic needs system (hunger, energy, social)
- NPC Memory Stream (observation + storage)
- Observation system (perception radius)
