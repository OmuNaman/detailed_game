# DevLog 012 — Needs, Observation & Interaction Systems

**Date:** 2026-03-02
**Phase:** Phase 1 — Foundation
**Status:** NPCs now have basic autonomy via needs, can perceive nearby entities, and respond to player interaction.

---

## What Was Added

This devlog covers 5 interconnected systems that give NPCs their first taste of autonomy beyond fixed schedules.

---

### System 0: NPC Speed Scaling

**Problem:** At 60x game speed (F6 key), NPCs barely moved one tile before the hour changed and they got a new destination. They'd jitter in place, never actually arriving anywhere.

**Solution:** NPC movement now scales with `GameClock.time_scale`, but with a twist — at high speeds, we don't just multiply velocity (which causes NPCs to overshoot waypoints). Instead:

- **time_scale 1x-10x:** Normal smooth movement with `velocity = direction * SPEED * GameClock.time_scale`. NPCs walk faster but still animate smoothly.
- **time_scale > 10x:** NPCs snap directly to waypoints. Each physics frame, the NPC teleports through multiple waypoints in the path array. At 30x or 60x, NPCs effectively teleport to their destination in a few frames.

The key code in `_physics_process()`:
```gdscript
var step: float = SPEED * GameClock.time_scale * delta
if step >= distance or GameClock.time_scale > 10.0:
    # Snap to waypoint, consume multiple per frame at high speed
    global_position = target
    _path_index += 1
    while GameClock.time_scale > 10.0 and _path_index < _path.size():
        global_position = _path[_path_index]
        _path_index += 1
```

This means at 1x speed NPCs walk normally (80px/s), at 5x they jog (400px/s), and at 60x they teleport-walk through the entire path instantly.

---

### System 1: Needs (hunger, energy, social)

Every NPC now has three needs that decay over time and drive their behavior.

**How they're stored:** Three float variables on each NPC instance in `npc_controller.gd`:
```gdscript
var hunger: float = 100.0   # 0 = starving, 100 = full
var energy: float = 100.0   # 0 = exhausted, 100 = rested
var social: float = 100.0   # 0 = lonely, 100 = fulfilled
```

**How they decay:** Every game minute, `EventBus.time_tick` fires and each NPC's `_on_time_tick()` runs:

| Need | Decay Rate | What This Means |
|------|-----------|-----------------|
| Hunger | -0.08/min | Loses ~5 points/hour. An NPC starting at 100 gets hungry (~20) after about 17 hours. |
| Energy | -0.1/min | Loses ~6 points/hour. An NPC who doesn't sleep hits exhaustion in ~17 hours. |
| Social | -0.05/min | Loses ~3 points/hour. Slowest decay — NPCs can go ~33 hours before getting lonely. |

Because decay is tied to `time_tick` (which fires once per game minute), it automatically scales with game speed. At 60x, the clock ticks 60 game-minutes per real second, so needs drain 60x faster too. No extra multiplier needed.

**How they restore:**
- **Energy:** +0.5/min while the NPC is at home during sleep hours (22:00-06:00). That's +30/hour, so 8 hours of sleep restores energy from ~52 back to 100. If an NPC's energy drops critically, they go home early (see emergency behavior).
- **Hunger:** +30.0 instantly at meal times (hours 7, 12, 19) IF the NPC is at home. This simulates eating breakfast, lunch, and dinner. If the NPC is at work or the tavern during these hours, they miss the meal and hunger keeps dropping.
- **Social:** +0.3/min when any other NPC is within 3 tiles (96 pixels). The code checks every NPC in the `"npcs"` group and measures distance. Only needs one nearby NPC — being in a crowd doesn't give extra benefit. This means NPCs naturally restore social at the tavern (17:00-22:00) since multiple NPCs gather there.

**Emergency behavior:** If hunger or energy drops below 20, the NPC overrides their normal schedule and goes home immediately. This check happens in `_get_schedule_destination()` BEFORE the schedule logic:
```gdscript
func _get_schedule_destination(hour: int) -> String:
    if hunger < 20.0 or energy < 20.0:
        return home_building  # Emergency override
    # Normal schedule follows...
```
The emergency re-evaluation also runs every game minute in `_on_time_tick()`, not just on hour changes. So if Maria's hunger drops to 19.8 at 10:32 AM, she'll immediately leave the Bakery and head home — she doesn't wait until 11:00.

**Mood:** `get_mood()` returns the simple average: `(hunger + energy + social) / 3.0`. A well-fed, well-rested, socially fulfilled NPC has mood ~100. A starving insomniac loner has mood ~0. Mood drives dialogue responses (see System 3).

---

### System 2: Observation

NPCs can now perceive entities that enter their vicinity. This is the foundation for the Memory Stream system coming later.

**How perception works:** Each NPC has a `PerceptionArea` node — an `Area2D` with a `CircleShape2D` of radius 160px (5 tiles). When any `CharacterBody2D` enters this circle, the `body_entered` signal fires.

The collision setup:
- PerceptionArea collision_layer = 0 (invisible, doesn't broadcast itself)
- PerceptionArea collision_mask = 6 (binary `110` = detects layer 2 + layer 4)
- Player is on collision layer 2 → detected
- NPCs are on collision layer 4 → detected

**What gets stored:** When perception triggers, the NPC creates an observation dictionary:
```gdscript
{
    "description": "Saw Player near Blacksmith",
    "actor": "Player",           # who they saw
    "location": "Blacksmith",    # the NPC's current destination (where THEY are)
    "game_time": 487,            # GameClock.total_minutes when it happened
    "importance": 5,             # 5 for player, 2 for other NPCs
}
```

**Important detail — `location` is where the OBSERVING NPC is, not where the observed entity is.** So if Gideon is at the Blacksmith and sees the player walk by, the observation says "Saw Player near Blacksmith" because Gideon is at the Blacksmith. This means if you walk into the Tavern and talk to an NPC there, they'll say "I saw you near the Tavern earlier" — because that's where THEY were when they spotted you.

**Cooldowns:** To prevent spam (NPCs would constantly re-observe each other while standing in the same building), there's a 60 game-minute cooldown per actor:
```gdscript
var _observation_cooldowns: Dictionary = {}  # {actor_name: last_observed_game_minute}
```
If Gideon saw the player 30 minutes ago, he won't create another observation until the cooldown expires.

**Storage limits:** Capped at 50 observations per NPC. When full, the oldest observation is removed (`pop_front()`). This is a simple FIFO queue — the upcoming Memory Stream will replace this with importance-weighted retention.

**What this means in practice:** Walk near any NPC and they silently log that they saw you. Walk into the Tavern at 18:00 when 5 NPCs are there, and each one creates an observation about seeing you. Press F3 to see observation counts ticking up in the debug overlay.

---

### System 3: Player Interaction

Press E near an NPC to talk to them. This is template-based dialogue (v1) — Gemini LLM integration comes later.

**How it works step by step:**

1. Player presses E (or Space — both mapped to `"interact"` in project.godot)
2. `player_controller.gd` receives the input in `_unhandled_input()`
3. If the dialogue box is already showing → close it and return
4. Otherwise, search all nodes in group `"npcs"` for the nearest one within 48px (1.5 tiles)
5. If no NPC nearby → nothing happens
6. Generate a response string based on the NPC's current state
7. Show it in the dialogue box

**Response generation** follows a priority cascade — first matching condition wins:

| Priority | Condition | Response | Why |
|----------|-----------|----------|-----|
| 1 | `energy < 20` | "*yawns* I'm exhausted... heading home to rest." | NPC is in emergency state |
| 2 | `hunger < 20` | "I'm starving, need to go eat." | NPC is in emergency state |
| 3 | Has any observation where `actor == "Player"` | "I saw you near the {location} earlier." | NPC remembers seeing you |
| 4 | `mood > 70` | "Beautiful day! Work at the {workplace} is going well." | NPC is happy |
| 5 | `mood > 40` | "Just another day at the {workplace}." | NPC is neutral |
| 6 | else | "I'm not feeling great today..." | NPC is unhappy |

**Known quirk with observations:** The location in "I saw you near the {location}" is where the NPC was, not where you were. So if you're standing in the Tavern and talk to Thomas who is also in the Tavern, and Thomas's most recent player observation was recorded while he was in the Tavern, he'll say "I saw you near the Tavern earlier" — even though you're both in the Tavern right now. This is technically correct (he DID see you near the Tavern) but feels a bit odd. The upcoming Memory Stream with relevance scoring will fix this by selecting the most contextually appropriate memory, not just the first match.

**The dialogue box itself:**
- CanvasLayer at layer 20 (above gameplay, below debug overlay)
- PanelContainer anchored to bottom of screen, full width, ~80px tall
- Gold-colored name label (NPC name) + white dialogue text below
- Starts hidden, toggled by E key

---

### System 4: Debug Overlay

Press F3 to see a real-time panel showing every NPC's internal state.

**What it shows per NPC:**
- Name and job (bold)
- Current destination (where they're heading or staying)
- Three colored bars (10 blocks each, filled/empty):
  - **Hunger** — orange (`#E8A040`)
  - **Energy** — blue (`#4080E8`)
  - **Social** — green (`#40C840`)
- Mood value (0-100 number)
- Observation count (how many observations stored)

**Example output:**
```
Maria (Baker) → Bakery
H:████████░░ E:███████░░░ S:██████░░░░  Mood:72  Obs:3
```

**Performance:** Updates every 0.5 seconds via a Timer node, not every frame. Each refresh destroys and recreates RichTextLabel nodes (fine for 5 NPCs, would need pooling at 50+).

---

## How Everything Connects

Here's the flow of a typical game session with all systems running:

1. **6:00 AM** — Game starts. All NPCs have hunger/energy/social at 100. They leave home for work.
2. **6:00-17:00** — NPCs at workplaces. Hunger decays to ~56, energy to ~34, social decays unless other NPCs are nearby. Player walks around, NPCs create observations when player enters their 5-tile radius.
3. **12:00** — NPCs at home get +30 hunger (lunch). But Maria is at the Bakery, so she misses lunch. Her hunger drops faster.
4. **~14:30** — Maria's energy hits 20. Emergency override kicks in — she abandons the Bakery mid-shift and walks home. Other NPCs keep working.
5. **17:00** — Remaining NPCs head to Tavern. Social restoration kicks in (+0.3/min per nearby NPC). By 22:00, social is topped up.
6. **18:00** — Player enters Tavern, walks up to Thomas, presses E. Thomas has an observation of the player from earlier today near the General Store. He says "I saw you near the General Store earlier."
7. **22:00** — NPCs go home. Energy restoration begins (+0.5/min during sleep). By 6:00, energy is back to ~100.
8. **Press F3** anytime to see all this happening in real-time with colored bars.

---

## Current Limitations (To Be Fixed by Memory Stream)

1. **Observations are a flat array.** No scoring, no weighting. First player observation found = response used. An observation from 3 game-days ago is treated the same as one from 5 minutes ago.
2. **Location is observer-relative.** "I saw you near the Tavern" means the NPC was at the Tavern when they saw you. Would be more useful if it tracked where the observed entity was.
3. **No memory persistence.** All observations are lost on game restart. No save/load.
4. **Template responses are static.** The same NPC state always produces the same response. No personality variation, no LLM-generated dialogue.
5. **Observations only on perception entry.** If you're already standing next to an NPC when the game starts, no observation is created (body_entered only fires on entry, not for already-overlapping bodies).

These will all be addressed when the Memory Stream system replaces the simple observation array with the Stanford Generative Agents-inspired architecture (recency + importance + relevance weighted retrieval).

---

## Technical Details

### Collision Layer Map
| Layer | Bit | Used By |
|-------|-----|---------|
| 1 | 1 | TileMap (walls, water) |
| 2 | 2 | Player (CharacterBody2D) |
| 4 | 4 | NPCs (CharacterBody2D) |

PerceptionArea: layer=0 (invisible), mask=6 (detects player + NPCs)

### Group Memberships
| Group | Members | Added In |
|-------|---------|----------|
| `"npcs"` | All 5 NPCs | `npc_controller.gd _ready()` |
| `"player"` | Player | `player_controller.gd _ready()` |
| `"dialogue_box"` | DialogueBox UI | `dialogue_box.gd _ready()` |

### Signal Connections (per NPC)
| Signal | Handler | Purpose |
|--------|---------|---------|
| `EventBus.time_hour_changed` | `_on_hour_changed()` | Schedule changes, meal times |
| `EventBus.time_tick` | `_on_time_tick()` | Needs decay/restore every game minute |
| `PerceptionArea.body_entered` | `_on_perception_body_entered()` | Observation creation |

---

## Files Modified
| File | Changes |
|------|---------|
| `scripts/npc/npc_controller.gd` | Speed scaling, needs system, observation system, group membership, mood |
| `scripts/player/player_controller.gd` | E key interaction, NPC proximity search, template dialogue generation, player group |
| `scenes/npcs/npc.tscn` | Added PerceptionArea (Area2D + CircleShape2D 160px), removed unused NavigationAgent2D |
| `scenes/world/town.tscn` | Added DialogueBox and DebugOverlay scene instances |

## Files Created
| File | Purpose |
|------|---------|
| `scenes/ui/dialogue_box.tscn` | Dialogue UI — bottom-anchored panel with name + text labels |
| `scripts/ui/dialogue_box.gd` | Show/hide dialogue, group membership for access |
| `scenes/ui/debug_overlay.tscn` | Debug panel — top-right, semi-transparent, Timer-updated |
| `scripts/ui/debug_overlay.gd` | F3 toggle, NPC status bars with BBCode coloring |

---

## Controls Reference
| Key | Action |
|-----|--------|
| W/A/S/D or Arrows | Move player |
| E / Space | Talk to nearest NPC (toggle) |
| F3 | Toggle debug overlay |
| F6 | Cycle time speed (1x → 2x → 5x → 10x → 30x → 60x) |

---

## Phase 1 Checklist Progress

### Completed (9/19)
- [x] Project setup
- [x] Tile map with buildings
- [x] Player movement
- [x] Game clock with day/night cycle
- [x] NPC spawning with core descriptions
- [x] NPC pathfinding (A* on tilemap)
- [x] **Basic needs system** ← NEW
- [x] **Observation system** ← NEW
- [x] **Interaction system** ← NEW

### Remaining (10/19)
- [ ] Memory Stream — replace flat observation array with scored MemoryRecords
- [ ] Memory Retrieval — recency + importance + relevance weighted retrieval
- [ ] Daily Planning — NPCs generate morning plans
- [ ] Gossip propagation — NPCs share observations during social time
- [ ] Reflection system — periodic insight generation
- [ ] Crime detection — witness-based
- [ ] Sheriff arrest mechanic
- [ ] Simple court trial
- [ ] Reputation tracking
- [ ] LLM integration (Gemini API)

### Progress: 47% complete (9 of 19 items)
