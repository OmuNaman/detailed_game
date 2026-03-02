extends CharacterBody2D
## Controls a single NPC: schedule-driven movement between buildings.
## Uses AStarGrid2D waypoint-following instead of NavigationAgent2D.
## Memory Stream replaces the old flat observation array with scored retrieval.

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

# Memory Stream (replaces old observations array)
var memory: MemoryStream = MemoryStream.new()
var _observation_cooldowns: Dictionary = {}  # {actor_name: last_observed_game_minute}
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

	# Periodic perception scan every 30 game minutes (fix for already-overlapping bodies)
	if GameClock.total_minutes % 30 == 0:
		_scan_perception_area()


func get_mood() -> float:
	return (hunger + energy + social) / 3.0


func get_dialogue_response() -> String:
	## Generates a context-aware response using memory retrieval.
	## Called by player_controller.gd when player presses E.

	# Emergency states take priority
	if energy < 20.0:
		return "*yawns* I'm exhausted... heading home to rest."
	if hunger < 20.0:
		return "I'm starving, need to go eat."

	# Try memory-based response using player memories
	var player_memories: Array[Dictionary] = memory.get_memories_about("Player")

	if not player_memories.is_empty():
		# Use the most recent player memory
		var latest: Dictionary = player_memories[-1]
		var location: String = latest.get("observed_near", latest.get("observer_location", "town"))
		var hours_ago: int = (GameClock.total_minutes - latest.get("game_time", 0)) / 60
		if hours_ago < 1:
			return "Oh, I just saw you over by the %s! What brings you here?" % location
		elif hours_ago < 12:
			return "I saw you near the %s earlier today. How's your day going?" % location
		else:
			return "I remember seeing you around the %s a while back." % location

	# Mood-based fallback
	var mood: float = get_mood()
	if mood > 70.0:
		return "Beautiful day, isn't it? Work at the %s is going well." % workplace_building
	elif mood > 40.0:
		return "Just another day at the %s." % workplace_building
	else:
		return "I'm not feeling great today..."


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
	if body.is_in_group("player"):
		actor_name = "Player"
	elif body.is_in_group("npcs"):
		actor_name = body.npc_name
	else:
		return

	# Cooldown: don't re-observe same actor within 60 game minutes
	var current_time: int = GameClock.total_minutes
	if _observation_cooldowns.has(actor_name):
		if current_time - _observation_cooldowns[actor_name] < OBSERVATION_COOLDOWN_MINUTES:
			return
	_observation_cooldowns[actor_name] = current_time

	# Determine where the observed entity actually is (not where WE are)
	var observed_location: String = _estimate_location(body.global_position)
	var my_location: String = _current_destination

	var importance: float = 2.0  # Default for NPC sightings
	var valence: float = 0.0     # Neutral
	if actor_name == "Player":
		importance = 5.0
		valence = 0.1  # Slightly positive — player is interesting

	var description: String = "Saw %s near the %s" % [actor_name, observed_location]

	# Create memory with async embedding
	_add_memory_with_embedding(description, "observation", actor_name,
		[npc_name, actor_name], my_location, observed_location, importance, valence)


func _estimate_location(pos: Vector2) -> String:
	## Returns the name of the nearest building to a world position.
	var closest_name: String = "town center"
	var closest_dist: float = INF
	for bld_name: String in _building_positions:
		var bld_pos: Vector2 = _building_positions[bld_name]
		var dist: float = pos.distance_to(bld_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_name = bld_name
	return closest_name


func _add_memory_with_embedding(description: String, type: String, actor: String,
		participants: Array[String], observer_loc: String, observed_loc: String,
		importance: float, valence: float) -> void:
	## Creates the memory record immediately (with empty embedding),
	## then fires off an async embedding request that updates in-place.
	var mem: Dictionary = memory.add_memory(description, type, actor, participants,
		observer_loc, observed_loc, importance, valence)

	# Fire async embedding request
	EmbeddingClient.embed_text(description, func(embedding: PackedFloat32Array) -> void:
		mem["embedding"] = embedding
	)


func _scan_perception_area() -> void:
	## Re-check bodies already inside PerceptionArea. Cooldowns prevent duplicates.
	var perception: Area2D = $PerceptionArea
	for body: Node2D in perception.get_overlapping_bodies():
		_on_perception_body_entered(body)
