extends CharacterBody2D
## Controls a single NPC: schedule-driven movement between buildings.
## Uses AStarGrid2D waypoint-following instead of NavigationAgent2D.

const SPEED: float = 80.0
const TILE_SIZE: int = 32

var npc_name: String = ""
var job: String = ""
var home_building: String = ""
var workplace_building: String = ""
var sprite_path: String = ""

var _current_destination: String = ""
var _building_positions: Dictionary = {}
var _building_interiors: Dictionary = {}

# Needs system (0-100, start full)
var hunger: float = 100.0
var energy: float = 100.0
var social: float = 100.0

# Observation system
var observations: Array[Dictionary] = []
var _observation_cooldowns: Dictionary = {}  # {actor_name: last_observed_game_minute}
const MAX_OBSERVATIONS: int = 50
const OBSERVATION_COOLDOWN_MINUTES: int = 60

# A* waypoint following
var _path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _is_moving: bool = false
var _astar: AStarGrid2D = null

@onready var sprite: Sprite2D = $Sprite2D
@onready var name_label: Label = $NameLabel


func initialize(data: Dictionary, building_positions: Dictionary, building_interiors: Dictionary = {}) -> void:
	## Call BEFORE adding to scene tree. Sets NPC identity and building targets.
	npc_name = data.get("name", "NPC")
	job = data.get("job", "")
	home_building = data.get("home", "")
	workplace_building = data.get("workplace", "")
	sprite_path = data.get("sprite", "")
	_building_positions = building_positions
	_building_interiors = building_interiors


func _ready() -> void:
	add_to_group("npcs")

	if sprite_path != "":
		var tex: Texture2D = load(sprite_path)
		if tex:
			sprite.texture = tex
	name_label.text = npc_name

	EventBus.time_hour_changed.connect(_on_hour_changed)
	EventBus.time_tick.connect(_on_time_tick)
	$PerceptionArea.body_entered.connect(_on_perception_body_entered)

	# Wait one frame for the scene tree to be fully built, then grab the A* grid
	await get_tree().process_frame
	var town_map: Node2D = get_parent().get_node_or_null("TownMap")
	if town_map and town_map.has_method("get_astar"):
		_astar = town_map.get_astar()
		print("[%s] Got AStarGrid2D reference" % npc_name)
	else:
		push_error("[%s] Could not find TownMap or get_astar()!" % npc_name)
		return

	# Initial destination based on current hour
	_update_destination(GameClock.hour)


func _physics_process(delta: float) -> void:
	if not _is_moving or _path.is_empty():
		return

	var target: Vector2 = _path[_path_index]
	var distance: float = global_position.distance_to(target)
	var step: float = SPEED * GameClock.time_scale * delta

	if step >= distance or GameClock.time_scale > 10.0:
		# High speed or close enough: snap directly to waypoint
		global_position = target
		_path_index += 1
		if _path_index >= _path.size():
			_arrive()
			return
		# At very high speeds, consume multiple waypoints per frame
		while GameClock.time_scale > 10.0 and _path_index < _path.size():
			global_position = _path[_path_index]
			_path_index += 1
		if _path_index >= _path.size():
			_arrive()
			return
	else:
		# Normal speed: smooth velocity-based movement
		var direction: Vector2 = global_position.direction_to(target)
		velocity = direction * SPEED * GameClock.time_scale
		move_and_slide()

	# Flip sprite based on movement direction
	var dir_x: float = _path[mini(_path_index, _path.size() - 1)].x - global_position.x
	if dir_x < -1.0:
		sprite.flip_h = true
	elif dir_x > 1.0:
		sprite.flip_h = false


func _arrive() -> void:
	_is_moving = false
	_path = PackedVector2Array()
	velocity = Vector2.ZERO


func _on_hour_changed(hour: int) -> void:
	# Instant hunger restoration at meal times if at home
	if _current_destination == home_building and hour in [7, 12, 19]:
		hunger = minf(hunger + 30.0, 100.0)
	_update_destination(hour)


func _on_time_tick(_game_minute: int) -> void:
	# Decay needs every game minute
	hunger = maxf(hunger - 0.08, 0.0)
	energy = maxf(energy - 0.1, 0.0)
	social = maxf(social - 0.05, 0.0)

	# Energy restoration: sleeping at home (22-06)
	if _current_destination == home_building and (GameClock.hour >= 22 or GameClock.hour < 6):
		energy = minf(energy + 0.5, 100.0)

	# Social restoration: other NPCs within 3 tiles (96px)
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		if npc == self:
			continue
		if global_position.distance_to(npc.global_position) <= 96.0:
			social = minf(social + 0.3, 100.0)
			break  # Only need one nearby NPC to get the bonus

	# Emergency needs trigger re-evaluation of destination
	if (hunger < 20.0 or energy < 20.0) and _current_destination != home_building:
		_update_destination(GameClock.hour)


func get_mood() -> float:
	return (hunger + energy + social) / 3.0


func _update_destination(hour: int) -> void:
	if _astar == null:
		return

	var dest: String = _get_schedule_destination(hour)
	if dest == _current_destination:
		return

	_current_destination = dest

	# Pick a random interior tile if available, otherwise use door position
	var target_pos: Vector2 = Vector2.ZERO
	if _building_interiors.has(dest) and _building_interiors[dest].size() > 0:
		var tiles: Array = _building_interiors[dest]
		target_pos = tiles[randi() % tiles.size()]
	else:
		target_pos = _building_positions.get(dest, Vector2.ZERO)

	if target_pos == Vector2.ZERO:
		push_warning("[%s] No position for building '%s'" % [npc_name, dest])
		return

	# Convert pixel positions to grid coordinates
	var from_grid := Vector2i(
		int(global_position.x) / TILE_SIZE,
		int(global_position.y) / TILE_SIZE
	)
	var to_grid := Vector2i(
		int(target_pos.x) / TILE_SIZE,
		int(target_pos.y) / TILE_SIZE
	)

	# Clamp to grid bounds
	from_grid.x = clampi(from_grid.x, 0, 49)
	from_grid.y = clampi(from_grid.y, 0, 39)
	to_grid.x = clampi(to_grid.x, 0, 49)
	to_grid.y = clampi(to_grid.y, 0, 39)

	# Get path from A*
	_path = _astar.get_point_path(from_grid, to_grid)

	if _path.is_empty():
		push_warning("[%s] A* found no path from %s to %s (dest: '%s')" % [
			npc_name, from_grid, to_grid, dest])
		return

	_path_index = 0
	_is_moving = true
	print("[%s] Hour %d -> '%s' | Path: %d waypoints | From %s -> %s" % [
		npc_name, hour, dest, _path.size(), from_grid, to_grid])


func _get_schedule_destination(hour: int) -> String:
	## Emergency needs override normal schedule
	if hunger < 20.0 or energy < 20.0:
		return home_building
	## 22-06: sleep at home | 06-17: work | 17-22: tavern
	if hour >= 22 or hour < 6:
		return home_building
	elif hour >= 6 and hour < 17:
		return workplace_building
	else:
		return "Tavern"


func _on_perception_body_entered(body: Node2D) -> void:
	if body == self:
		return
	if not (body is CharacterBody2D):
		return

	var actor_name: String = ""
	var importance: int = 2
	if body.is_in_group("npcs"):
		actor_name = body.npc_name
	elif body.is_in_group("player"):
		actor_name = "Player"
		importance = 5
	else:
		return

	# Cooldown: don't re-observe same actor within 60 game minutes
	if _observation_cooldowns.has(actor_name):
		var last_time: int = _observation_cooldowns[actor_name]
		if GameClock.total_minutes - last_time < OBSERVATION_COOLDOWN_MINUTES:
			return

	_observation_cooldowns[actor_name] = GameClock.total_minutes

	var observation: Dictionary = {
		"description": "Saw %s near %s" % [actor_name, _current_destination],
		"actor": actor_name,
		"location": _current_destination,
		"game_time": GameClock.total_minutes,
		"importance": importance,
	}
	observations.append(observation)

	# Cap at max observations
	if observations.size() > MAX_OBSERVATIONS:
		observations.pop_front()
