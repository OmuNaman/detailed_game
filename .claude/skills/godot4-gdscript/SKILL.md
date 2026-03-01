---
name: godot4-gdscript
description: Godot 4 game development with GDScript. Use when creating, editing, or debugging any Godot project files (.gd, .tscn, .tres, .godot), writing GDScript code, creating scenes, or working with Godot's node system. Prevents Godot 3 mistakes.
---

# Godot 4 + GDScript Development Skill

## CRITICAL: Godot 3 vs 4 — DO NOT MIX
Claude's training data contains a LOT of Godot 3 code. NEVER use these Godot 3 patterns:

| Godot 3 (WRONG)              | Godot 4 (CORRECT)                    |
|-------------------------------|---------------------------------------|
| `KinematicBody2D`            | `CharacterBody2D`                    |
| `move_and_slide(velocity)`   | `velocity = vel; move_and_slide()`   |
| `Spatial`                    | `Node3D`                             |
| `instance()`                 | `instantiate()`                      |
| `rand_range(a, b)`           | `randf_range(a, b)` / `randi_range(a, b)` |
| `deg2rad()` / `rad2deg()`   | `deg_to_rad()` / `rad_to_deg()`     |
| `stepify()`                  | `snapped()`                          |
| `BUTTON_LEFT`               | `MOUSE_BUTTON_LEFT`                  |
| `connect("signal", obj, "method")` | `signal.connect(method)` or `signal.connect(Callable(obj, "method"))` |
| `yield()`                    | `await`                              |
| `export var`                 | `@export var`                        |
| `onready var`               | `@onready var`                       |
| `tool`                       | `@tool`                              |
| `translation` (3D position) | `position` (now consistent with 2D)  |
| `rect_position` (Control)   | `position`                           |
| `rect_size` (Control)       | `size`                               |
| `RectangleShape2D.extents`  | `RectangleShape2D.size` (full size, not half) |
| `randomize()` needed         | NOT needed — automatic in Godot 4    |
| JSON parse via `JSON.parse()`| `var json = JSON.new(); json.parse(str); json.data` |

## GDScript 2.0 Style Guide

### Naming
- Files: `snake_case.gd`
- Classes: `PascalCase` (class_name MyClass)
- Functions/variables: `snake_case`
- Constants/enums: `CONSTANT_CASE`
- Private members: prefix with `_underscore`
- Signals: past tense — `health_changed`, `enemy_died`
- Booleans: prefix with `is_`, `has_`, `can_` — `is_alive`, `has_key`

### Always Use Static Typing
```gdscript
# WRONG — untyped
var health = 100
var name = "John"
func take_damage(amount):

# CORRECT — typed
var health: int = 100
var name: String = "John"
func take_damage(amount: int) -> void:
```

### Script Order (follow strictly)
```gdscript
# 1. @tool (if needed)
# 2. class_name
# 3. extends
# 4. ## Docstring

# 5. Signals
signal health_changed(new_health: int)

# 6. Enums
enum State { IDLE, WALKING, RUNNING }

# 7. Constants
const MAX_SPEED: float = 200.0

# 8. @export variables
@export var speed: float = 100.0

# 9. Public variables
var current_state: State = State.IDLE

# 10. Private variables
var _velocity: Vector2 = Vector2.ZERO

# 11. @onready variables
@onready var sprite: Sprite2D = %Sprite2D
@onready var collision: CollisionShape2D = %CollisionShape2D

# 12. Built-in virtual callbacks (_ready, _process, etc.)
func _ready() -> void:
    pass

func _process(delta: float) -> void:
    pass

func _physics_process(delta: float) -> void:
    pass

# 13. Public methods
func take_damage(amount: int) -> void:
    pass

# 14. Private methods
func _update_health_bar() -> void:
    pass

# 15. Signal callbacks (prefix with _on_)
func _on_area_entered(area: Area2D) -> void:
    pass
```

### Scene Unique Nodes (use these!)
```gdscript
# WRONG — fragile, breaks if you rearrange scene tree
@onready var label: Label = $MarginContainer/VBoxContainer/Label

# CORRECT — unique node reference, survives rearrangement
@onready var label: Label = %Label
```
Mark nodes as unique in the editor (right-click → "Access as Unique Name").

## Scene Architecture

### Composition Over Inheritance
Build NPCs and entities as composed scenes:
```
NPC (CharacterBody2D)
├── Sprite2D
├── CollisionShape2D
├── NavigationAgent2D
├── PerceptionArea (Area2D)
│   └── CollisionShape2D (circle, ~5 tile radius)
├── AIBrain (Node — script handles decision-making)
├── MemoryStream (Node — manages MemoryRecords)
├── NeedsSystem (Node — hunger, energy, social, etc.)
└── InteractionArea (Area2D)
    └── CollisionShape2D
```

### Autoloads (Global Singletons)
Register in Project → Project Settings → Autoload:
```
GameClock     → res://scripts/core/game_clock.gd
EventBus      → res://scripts/core/event_bus.gd
CrimeSystem   → res://scripts/systems/crime_system.gd
ReputationSystem → res://scripts/systems/reputation_system.gd
SaveManager   → res://scripts/core/save_manager.gd
```

### EventBus Pattern (decoupled communication)
```gdscript
# event_bus.gd (Autoload)
extends Node

signal crime_committed(crime_data: Dictionary)
signal npc_observed_event(observer_id: String, event_data: Dictionary)
signal reputation_changed(target_id: String, amount: float)
signal time_hour_changed(hour: int)
signal gossip_spread(from_id: String, to_id: String, memory: Dictionary)
```

## Godot 4 Signals (New Syntax)
```gdscript
# Declaring
signal health_changed(new_value: int)

# Connecting in code
health_changed.connect(_on_health_changed)

# Connecting with bind
button.pressed.connect(_on_button_pressed.bind(item_id))

# Emitting
health_changed.emit(current_health)

# One-shot connection
health_changed.connect(_on_health_changed, CONNECT_ONE_SHOT)

# Awaiting a signal
await get_tree().create_timer(1.0).timeout
```

## Navigation (for NPC pathfinding)
```gdscript
# NPC movement with NavigationAgent2D
@onready var nav_agent: NavigationAgent2D = %NavigationAgent2D

func move_to(target_pos: Vector2) -> void:
    nav_agent.target_position = target_pos

func _physics_process(delta: float) -> void:
    if nav_agent.is_navigation_finished():
        return
    var next_pos: Vector2 = nav_agent.get_next_path_position()
    var direction: Vector2 = global_position.direction_to(next_pos)
    velocity = direction * speed
    move_and_slide()
```
IMPORTANT: Add a `NavigationRegion2D` to your tilemap with a baked navigation polygon.

## TileMap (Godot 4 way)
Godot 4 uses `TileMapLayer` nodes (as of 4.3+). Each layer is a separate node.
```
World
├── TileMapLayer (ground)
├── TileMapLayer (buildings)
├── TileMapLayer (decoration)
└── NavigationRegion2D
```
For older 4.x: `TileMap` node with layers configured in the TileSet.

## HTTP Requests (for Gemini API)
```gdscript
# gemini_client.gd
extends Node

const API_URL: String = "https://generativelanguage.googleapis.com/v1beta/models/"
var _api_key: String = ""
var _http: HTTPRequest

func _ready() -> void:
    _http = HTTPRequest.new()
    add_child(_http)
    _http.request_completed.connect(_on_request_completed)
    _load_api_key()

func _load_api_key() -> void:
    # Load from .env or user settings — NEVER hardcode
    var file := FileAccess.open("user://.env", FileAccess.READ)
    if file:
        _api_key = file.get_line().strip_edges()

func generate(model: String, prompt: String, system: String = "") -> void:
    var url: String = API_URL + model + ":generateContent?key=" + _api_key
    var body: Dictionary = {
        "contents": [{"parts": [{"text": prompt}]}]
    }
    if system != "":
        body["system_instruction"] = {"parts": [{"text": system}]}
    var json: String = JSON.stringify(body)
    var headers: PackedStringArray = ["Content-Type: application/json"]
    _http.request(url, headers, HTTPClient.METHOD_POST, json)

func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
    if code != 200:
        push_warning("Gemini API error: " + str(code))
        return
    var json := JSON.new()
    json.parse(body.get_string_from_utf8())
    var text: String = json.data["candidates"][0]["content"]["parts"][0]["text"]
    # Emit signal with result or use callback
```

## Data Serialization (Save/Load)
```gdscript
# Save entire world state
func save_game() -> void:
    var save_data: Dictionary = {
        "time": GameClock.get_state(),
        "npcs": _serialize_all_npcs(),
        "reputation": ReputationSystem.get_state(),
        "crimes": CrimeSystem.get_state(),
    }
    var json: String = JSON.stringify(save_data, "\t")
    var file := FileAccess.open("user://savegame.json", FileAccess.WRITE)
    file.store_string(json)

func load_game() -> void:
    var file := FileAccess.open("user://savegame.json", FileAccess.READ)
    if not file:
        return
    var json := JSON.new()
    json.parse(file.get_as_text())
    var data: Dictionary = json.data
    # Restore all systems from data
```

## Performance Tips for Simulation
- Use `_physics_process` for NPC movement, `_process` for UI only
- Offscreen NPCs: reduce tick rate. Use a timer (every 2-5 seconds) instead of every frame
- Group NPCs: `add_to_group("npcs")` → `get_tree().get_nodes_in_group("npcs")`
- Use `call_deferred()` for operations that modify the scene tree
- For 20+ NPCs: stagger processing — don't update all NPCs on the same frame
- Use `ResourceLoader.load_threaded_request()` for async loading

## Common Gotchas
1. `move_and_slide()` in Godot 4 takes NO arguments — set `velocity` property first
2. `@onready` vars are null in `_init()` — only use them in `_ready()` or later
3. Signals connected in editor persist across scene reloads — prefer code connections
4. `FileAccess.open()` returns null on failure — always check before using
5. `get_node()` / `$` returns null if node doesn't exist — use `has_node()` or `%UniqueNode`
6. Timer nodes auto-start only if `autostart` is checked — otherwise call `.start()`
7. `Area2D` signals need collision layers/masks set correctly on BOTH bodies
8. JSON in Godot 4: use `var json = JSON.new(); json.parse(text); var data = json.data`