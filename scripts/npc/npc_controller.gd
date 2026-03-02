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
	if sprite_path != "":
		var tex: Texture2D = load(sprite_path)
		if tex:
			sprite.texture = tex
	name_label.text = npc_name

	EventBus.time_hour_changed.connect(_on_hour_changed)

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


func _physics_process(_delta: float) -> void:
	if not _is_moving or _path.is_empty():
		return

	var target: Vector2 = _path[_path_index]
	var distance: float = global_position.distance_to(target)

	if distance < 4.0:
		# Reached this waypoint, advance to next
		_path_index += 1
		if _path_index >= _path.size():
			# Reached final destination
			_is_moving = false
			_path = PackedVector2Array()
			velocity = Vector2.ZERO
			print("[%s] Arrived at '%s'" % [npc_name, _current_destination])
			return
		target = _path[_path_index]

	# Move toward current waypoint
	var direction: Vector2 = global_position.direction_to(target)
	velocity = direction * SPEED
	move_and_slide()

	# Flip sprite based on movement direction
	if velocity.x < -1.0:
		sprite.flip_h = true
	elif velocity.x > 1.0:
		sprite.flip_h = false


func _on_hour_changed(hour: int) -> void:
	_update_destination(hour)


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
	## 22-06: sleep at home | 06-17: work | 17-22: tavern
	if hour >= 22 or hour < 6:
		return home_building
	elif hour >= 6 and hour < 17:
		return workplace_building
	else:
		return "Tavern"
