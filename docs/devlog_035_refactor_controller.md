# Devlog 035 — Refactor npc_controller.gd into 8 Components

## What Changed

Split the 3,225-line god-object `npc_controller.gd` into a thin 494-line orchestrator + 8 component scripts. Zero behavior changes — pure organizational restructure.

## New Scene Tree

```
NPC (CharacterBody2D)         ← npc_controller.gd (494 lines)
├── Sprite2D
├── CollisionShape2D
├── PerceptionArea (Area2D)
│   └── CollisionShape2D
├── NameLabel (Label)
├── NPCWorldKnowledge (Node)  ← npc_world_knowledge.gd (77 lines)
├── NPCGossip (Node)          ← npc_gossip.gd (199 lines)
├── NPCPerception (Node)      ← npc_perception.gd (211 lines)
├── NPCReflection (Node)      ← npc_reflection.gd (329 lines)
├── NPCActivity (Node)        ← npc_activity.gd (290 lines)
├── NPCPlanner (Node)         ← npc_planner.gd (653 lines)
├── NPCDialogue (Node)        ← npc_dialogue.gd (564 lines)
└── NPCConversation (Node)    ← npc_conversation.gd (557 lines)
```

## Architecture

- Each component extends `Node`, gets parent ref via `npc = get_parent()` in `_ready()`
- Components access controller data via `npc.*`, other components via `npc.planner.*`, `npc.gossip.*`, etc.
- Autoloads (GameClock, GeminiClient, etc.) accessed directly
- Controller keeps: identity, needs, memory, pathfinding, scheduling, memory bridge, thin dialogue wrappers
- External files (dialogue_box.gd, debug_overlay.gd, town.gd) unchanged — convenience getters on controller proxy to components

## What Stays on the Controller

- Identity vars: `npc_name`, `job`, `age`, `personality`, `speech_style`, `home_building`, `workplace_building`
- Needs: `hunger`, `energy`, `social`
- Memory bridge: `_add_memory_with_embedding()`, `_process_embedding_queue()`
- Pathfinding: `_path`, `_astar`, `_is_moving`, `_physics_process()`
- Scheduling: `_update_destination()`, `_get_schedule_destination()`
- Orchestration: `_on_hour_changed()`, `_on_time_tick()`, `_ready()`
- Thin wrappers: `get_dialogue_response()`, `get_dialogue_response_async()`, `get_conversation_reply_async()`, `on_player_conversation_ended()`

## Files Changed

| File | Action |
|------|--------|
| `scripts/npc/npc_controller.gd` | 3,225 → 494 lines |
| `scripts/npc/npc_world_knowledge.gd` | NEW (77 lines) |
| `scripts/npc/npc_gossip.gd` | NEW (199 lines) |
| `scripts/npc/npc_perception.gd` | NEW (211 lines) |
| `scripts/npc/npc_reflection.gd` | NEW (329 lines) |
| `scripts/npc/npc_activity.gd` | NEW (290 lines) |
| `scripts/npc/npc_planner.gd` | NEW (653 lines) |
| `scripts/npc/npc_dialogue.gd` | NEW (564 lines) |
| `scripts/npc/npc_conversation.gd` | NEW (557 lines) |
| `scenes/npcs/npc.tscn` | Added 8 child Node entries |
