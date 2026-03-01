# DevLog 002 — GameClock, EventBus & Day/Night Cycle

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** Working — time ticks, HUD updates, screen tints with time of day

---

## What We Did

### 1. EventBus Autoload (`scripts/core/event_bus.gd`)
Global signal hub for decoupled communication. Currently declares:
- `time_tick(game_minute)` — fires every game minute (every real second)
- `time_hour_changed(hour)` — fires when the hour rolls over
- `time_day_changed(day)` — fires when a new day starts
- `time_season_changed(season)` — fires when the season changes

Also stubs for future NPC signals: `crime_committed`, `npc_observed_event`, `reputation_changed`, `gossip_spread`.

### 2. GameClock Autoload (`scripts/core/game_clock.gd`)
Core time simulation:
- **Rate:** 1 real second = 1 game minute (configurable via `REAL_SECONDS_PER_GAME_MINUTE`)
- **Tracks:** `minute`, `hour`, `day`, `season`, `total_minutes`
- **Starts at:** 6:00 AM, Day 1, Spring
- **Seasons:** Spring → Summer → Autumn → Winter, 28 days each
- **Signals:** Emits via EventBus at each boundary (minute tick, hour change, day change, season change)
- **Pausable:** `is_paused` flag stops time advancing
- **Serializable:** `get_state()` / `load_state()` for save/load
- **Helper:** `get_hour_fraction()` returns 0.0-1.0 for smooth day/night interpolation

### 3. Time HUD (`scenes/ui/time_hud.tscn` + `scripts/ui/time_hud.gd`)
- CanvasLayer (layer 10) so it renders above everything
- Top-left label: "Spring, Day 1 - 06:00"
- White text with black shadow for readability on any background
- Updates every game minute via `time_tick` signal

### 4. Day/Night Cycle (`scripts/world/day_night_cycle.gd`)
CanvasModulate node that tints the entire scene:

| Time | Hour | Color | Description |
|------|------|-------|-------------|
| 0.00 | 00:00 | `(0.15, 0.15, 0.30)` | Deep night — dark blue |
| 0.20 | 04:48 | `(0.15, 0.15, 0.30)` | Still dark |
| 0.25 | 06:00 | `(0.85, 0.55, 0.35)` | Dawn — warm orange |
| 0.30 | 07:12 | `(0.95, 0.85, 0.70)` | Early morning warmth |
| 0.35 | 08:24 | `(1.0, 1.0, 1.0)` | Full daylight |
| 0.50 | 12:00 | `(1.0, 1.0, 1.0)` | Noon — brightest |
| 0.70 | 16:48 | `(1.0, 1.0, 1.0)` | Afternoon — still bright |
| 0.75 | 18:00 | `(0.95, 0.75, 0.50)` | Dusk — golden hour |
| 0.80 | 19:12 | `(0.80, 0.45, 0.30)` | Sunset orange |
| 0.85 | 20:24 | `(0.35, 0.25, 0.45)` | Twilight purple |
| 0.90 | 21:36 | `(0.15, 0.15, 0.30)` | Night falls |

Colors interpolate linearly between keyframes for smooth transitions.

### 5. Autoload Registration
Added to `project.godot` under `[autoload]`:
- `EventBus` → `res://scripts/core/event_bus.gd`
- `GameClock` → `res://scripts/core/game_clock.gd`

Order matters: EventBus loads first so GameClock can reference it.

### 6. Town Scene Updated
`scenes/world/town.tscn` now includes:
- `DayNightCycle` (CanvasModulate) — tints the world
- `TimeHUD` instance — shows the clock

---

## Architecture Decisions

1. **EventBus pattern over direct signal connections:** Systems don't need to know about each other. GameClock emits to EventBus, HUD and DayNight listen to EventBus. Easy to add new listeners later.

2. **CanvasModulate for day/night:** Simplest approach — one node tints everything under it. CanvasLayer (HUD) is above it so text stays readable. Later we can add point lights for lanterns/windows.

3. **time_tick fires every game minute (every real second):** Frequent enough for smooth HUD updates and day/night transitions, cheap enough to not matter for performance.

4. **Keyframe color array over Gradient resource:** Kept in code for easy version-control diffing and tweaking. Could move to a .tres Gradient resource later if artists want to tune it in-editor.

---

## Files Changed/Created
- **Created:** `scripts/core/event_bus.gd`, `scripts/core/game_clock.gd`
- **Created:** `scripts/ui/time_hud.gd`, `scenes/ui/time_hud.tscn`
- **Created:** `scripts/world/day_night_cycle.gd`
- **Modified:** `scenes/world/town.tscn` (added DayNightCycle + TimeHUD)
- **Modified:** `project.godot` (added [autoload] section)

---

## Checklist Progress (Phase 1)
- [x] Project setup
- [x] Tile map with buildings
- [x] Player movement (top-down, 4-directional)
- [x] Game clock with day/night cycle ← **NEW**
- [ ] NPC spawning with core descriptions and personality traits
- [ ] NPC pathfinding (A* on tilemap)
- [ ] Basic needs system (hunger, energy, social)
- [ ] ...everything else

---

## Next Steps
- NPC base scene with pathfinding (NavigationRegion2D)
- NPC data definitions in `data/npcs.json`
- Basic schedule system (NPCs go to work, eat, sleep based on clock)
