# Devlog 023 — Working Doors & NPC Sprite States

## What Changed
Doors visually open when an NPC or the player approaches, and close when they leave. NPCs sleeping now show a closed-eye sprite with a subtle blue tint. Working NPCs get a warm tint when using furniture. All changes are purely visual — no pathfinding, movement, or gameplay logic was modified.

## Door Open/Close System
- Door tiles already existed as walkable tiles — NPCs walk through them
- Added Sprite2D overlays on every door tile position in the map
- Every 5 frames, `_update_doors()` checks all doors against NPC + player positions
- If any CharacterBody2D is within 1.8 tiles (~58px) of a door, the overlay swaps to `door_open.png`
- When everyone moves away, it swaps back to `door_closed.png`
- 18 doors across all buildings, ~12 moving bodies — negligible performance cost
- Overlay Sprite2D sits at z_index 5 (above ground, below NPCs)

## NPC Sleep Sprites
- 12 sleeping character sprites generated (one per NPC + player)
- Sleeping sprite: same body/clothes as awake sprite, but eyes are horizontal lines (closed) and no mouth
- Colors matched EXACTLY from each NPC's awake gen function (not approximated)
- Sleep texture loaded at `_ready()` via `sprite_path.replace("_down.png", "_sleep.png")`
- When `current_activity == "sleeping in bed"` → swap to sleep texture + blue tint `Color(0.7, 0.7, 0.9)`
- When waking up → swap back to awake texture + normal white modulate

## Work Tint
- When an NPC is actively using a furniture object (`_current_object_id != ""` and not moving), sprite gets a subtle warm tint `Color(1.0, 0.97, 0.93)`
- Barely noticeable but adds a "this NPC is doing something" feeling
- Tint removed when NPC starts moving or releases the object

## New Sprites
- `door_open.png` — Floor visible through open doorway with door panel on right side
- `draw_character_sleeping()` — New helper function mirroring `draw_character()` but with closed eyes
- 12 per-NPC sleep generators with exact color matches

## Files Changed
| File | Action |
|------|--------|
| `tools/generate_sprites.py` | MODIFY — `gen_door_open()`, `draw_character_sleeping()`, 12 sleep gen functions, updated `main()` (50 sprites total) |
| `scripts/world/town_generator.gd` | MODIFY — Door textures, `_door_positions` tracking, Sprite2D overlays via `_init_door_sprites()`, `_process()` + `_update_doors()` proximity check |
| `scripts/npc/npc_controller.gd` | MODIFY — Sleep/awake texture loading, `_update_visual_state()` for sleep swap + work tint, wired into `_update_activity_label()` |
