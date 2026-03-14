extends CharacterBody2D
## Controls a single NPC: needs-driven movement, perception, memory, conversations, LLM dialogue.
## Uses AStarGrid2D waypoint-following instead of NavigationAgent2D.
## Three-tier MemorySystem with scored retrieval, backed by Python API.

const SPEED: float = 80.0
const TILE_SIZE: int = 32

var npc_name: String = ""
var job: String = ""
var age: int = 30
var personality: String = ""
var speech_style: String = ""
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

# Three-tier memory system
var memory: MemorySystem = MemorySystem.new()

# A* waypoint following
var _path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _is_moving: bool = false
var _astar: AStarGrid2D = null
var _town_map: Node2D = null

# Conversation lock — prevents movement and schedule changes while talking
var _in_conversation: bool = false
var _conversation_partner_name: String = ""
var in_conversation: bool:
	get: return _in_conversation



@onready var sprite: Sprite2D = $Sprite2D
@onready var name_label: Label = $NameLabel
@onready var world_knowledge: Node = $NPCWorldKnowledge
@onready var gossip: Node = $NPCGossip
@onready var perception: Node = $NPCPerception
@onready var reflection: Node = $NPCReflection
@onready var activity: Node = $NPCActivity
@onready var planner: Node = $NPCPlanner
@onready var dialogue: Node = $NPCDialogue
@onready var conversation: Node = $NPCConversation

# Convenience getters — activity component owns data, controller proxies for external access
var current_activity: String:
	get: return activity.current_activity if activity else ""
	set(value): if activity: activity.current_activity = value

var _current_object_id: String:
	get: return activity._current_object_id if activity else ""


func initialize(data: Dictionary, building_positions: Dictionary, building_interiors: Dictionary = {}) -> void:
	## Call BEFORE adding to scene tree. Sets NPC identity and building targets.
	npc_name = data.get("name", "NPC")
	job = data.get("job", "")
	age = data.get("age", 30)
	personality = data.get("personality", "")
	speech_style = data.get("speech_style", "")
	home_building = data.get("home", "")
	workplace_building = data.get("workplace", "")
	sprite_path = data.get("sprite", "")
	_building_positions = building_positions
	_building_interiors = building_interiors

	# Initialize three-tier memory system
	memory.initialize(npc_name, personality, PlayerProfile.player_name)


func _ready() -> void:
	add_to_group("npcs")

	if sprite_path != "":
		var tex: Texture2D = load(sprite_path)
		if tex:
			sprite.texture = tex

	name_label.text = npc_name

	EventBus.time_hour_changed.connect(_on_hour_changed)
	EventBus.time_tick.connect(_on_time_tick)
	$PerceptionArea.body_entered.connect(func(body: Node2D) -> void: perception.on_perception_body_entered(body))

	# Initialize activity visuals (sleep texture, activity label)
	if activity:
		activity.init_visuals()

	# Wait one frame for the scene tree to be fully built, then grab the A* grid
	await get_tree().process_frame
	var town_map: Node2D = get_parent().get_node_or_null("TownMap")
	if town_map and town_map.has_method("get_astar"):
		_astar = town_map.get_astar()
		_town_map = town_map
		print("[%s] Got AStarGrid2D reference" % npc_name)
	else:
		push_error("[%s] Could not find TownMap or get_astar()!" % npc_name)
		return

	# Initialize world knowledge after tree is ready
	if world_knowledge:
		world_knowledge.init_known_world()

	# Populate memory cache from backend
	memory.refresh_cache()

	# Initial destination based on current hour
	_update_destination(GameClock.hour)

	# Bug 8: Late planning trigger — if loaded after hour 5, still generate today's plan
	planner.call_deferred("check_planning_on_load")


func _physics_process(delta: float) -> void:
	if _in_conversation:
		velocity = Vector2.ZERO
		return
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
	_resolve_tile_collision()
	planner.dest_arrival_time = GameClock.total_minutes  # Bug 9: Track arrival for minimum stay
	activity.claim_work_object()
	activity.update_activity()
	world_knowledge.learn_building(_current_destination)
	perception.on_arrive_at_building()
	conversation.check_approach_arrived()


func _get_current_day() -> int:
	## Monotonic day counter (doesn't reset on season change unlike GameClock.day).
	return GameClock.total_minutes / 1440


func _trigger_reflection() -> void:
	## Called via call_deferred from reflection component.
	reflection.enhanced_reflect()













func _pair_key(a: String, b: String) -> String:
	## Canonical key for a pair of NPC names (alphabetical order).
	if a < b:
		return a + ":" + b
	return b + ":" + a


func _face_toward(target_pos: Vector2) -> void:
	## Flip sprite to face toward the target position.
	if target_pos.x < global_position.x:
		sprite.flip_h = true
	elif target_pos.x > global_position.x:
		sprite.flip_h = false


func lock_for_conversation(partner_name: String) -> void:
	## Freeze this NPC for a conversation. Stops movement, schedule, and destination updates.
	_in_conversation = true
	_conversation_partner_name = partner_name
	if _is_moving:
		_is_moving = false
		_path = PackedVector2Array()
		velocity = Vector2.ZERO
	if OS.is_debug_build():
		print("[Conv Lock] %s locked (talking to %s)" % [npc_name, partner_name])


func unlock_conversation() -> void:
	## Unfreeze this NPC after conversation ends. Resumes normal behavior.
	var was_locked: bool = _in_conversation
	_in_conversation = false
	_conversation_partner_name = ""
	if was_locked:
		_update_destination(GameClock.hour)
		if not _is_moving:
			activity.update_activity()
		if OS.is_debug_build():
			print("[Conv Lock] %s unlocked" % npc_name)


func _resolve_tile_collision() -> void:
	## If another NPC is on our tile, nudge to the nearest free adjacent tile.
	var my_grid := Vector2i(int(global_position.x) / TILE_SIZE, int(global_position.y) / TILE_SIZE)
	for other: Node in get_tree().get_nodes_in_group("npcs"):
		if other == self:
			continue
		var other_npc: CharacterBody2D = other as CharacterBody2D
		if other_npc._is_moving:
			continue
		var other_grid := Vector2i(int(other_npc.global_position.x) / TILE_SIZE, int(other_npc.global_position.y) / TILE_SIZE)
		if my_grid == other_grid:
			var free_pos: Vector2 = _find_nearest_free_tile(my_grid)
			if free_pos != Vector2.ZERO:
				global_position = free_pos
				if OS.is_debug_build():
					print("[Tile] %s: Nudged off tile to avoid stacking with %s" % [npc_name, other_npc.npc_name])
			return


func _find_nearest_free_tile(from_grid: Vector2i) -> Vector2:
	## Find the closest walkable tile not occupied by any NPC or the player.
	if _astar == null:
		return Vector2.ZERO
	var grid_w: int = _town_map.MAP_WIDTH if _town_map else 60
	var grid_h: int = _town_map.MAP_HEIGHT if _town_map else 45
	var occupied: Dictionary = {}
	for other: Node in get_tree().get_nodes_in_group("npcs"):
		if other == self:
			continue
		var o: CharacterBody2D = other as CharacterBody2D
		if o._is_moving:
			continue
		occupied[Vector2i(int(o.global_position.x) / TILE_SIZE, int(o.global_position.y) / TILE_SIZE)] = true
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		occupied[Vector2i(int(player.global_position.x) / TILE_SIZE, int(player.global_position.y) / TILE_SIZE)] = true
	for ring: int in range(1, 4):
		var best_pos: Vector2 = Vector2.ZERO
		var best_dist: float = INF
		for dx: int in range(-ring, ring + 1):
			for dy: int in range(-ring, ring + 1):
				if dx == 0 and dy == 0:
					continue
				var check := Vector2i(from_grid.x + dx, from_grid.y + dy)
				if check.x < 0 or check.x >= grid_w or check.y < 0 or check.y >= grid_h:
					continue
				if _astar.is_point_solid(check):
					continue
				if occupied.has(check):
					continue
				var d: float = from_grid.distance_to(Vector2(check))
				if d < best_dist:
					best_dist = d
					best_pos = Vector2(check.x * TILE_SIZE + TILE_SIZE / 2, check.y * TILE_SIZE + TILE_SIZE / 2)
		if best_pos != Vector2.ZERO:
			return best_pos
	return Vector2.ZERO


func _on_hour_changed(hour: int) -> void:
	# Midnight: reset counts + run memory maintenance + clear L2/L3 plans
	if hour == 0:
		conversation.reset_daily_counts()
		planner.clear_decomposed_plans()
		reflection.run_midnight_maintenance()

	# Emotional state decay: 3+ quiet hours → drift to neutral
	if dialogue.last_significant_event_time > 0:
		var quiet_hours: float = float(GameClock.total_minutes - dialogue.last_significant_event_time) / 60.0
		if quiet_hours >= 3.0:
			var current_emotion: String = memory.core_memory.get("emotional_state", "")
			if current_emotion != "" and not current_emotion.begins_with("Feeling neutral"):
				memory.update_emotional_state("Feeling neutral, going about the day.")
				dialogue.last_significant_event_time = 0
				if OS.is_debug_build():
					print("[Emotion] %s: Mood decayed to neutral after %.1f quiet hours" % [npc_name, quiet_hours])

	# Instant hunger restoration at meal times if at home
	if _current_destination == home_building and hour in [7, 12, 19]:
		hunger = minf(hunger + 30.0, 100.0)
	if not _in_conversation:
		_update_destination(hour)
	# Activities change by time of day even without destination change
	if not _is_moving and not _in_conversation:
		activity.update_activity()
	if OS.is_debug_build():
		print("[Activity] %s: %s (at %s)" % [npc_name, current_activity, _current_destination])

	# Daily planning — generate plan at dawn
	if hour == 5 and planner._last_plan_day != _get_current_day():
		planner.generate_daily_plan()


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

	# Just-in-time L2/L3 decomposition every 5 min
	if GameClock.total_minutes % 5 == 0:
		planner.tick_decomposition()

	# Re-evaluate destination every 5 game minutes based on needs
	if GameClock.total_minutes % 5 == 0 and not _in_conversation:
		var new_dest: String = _get_schedule_destination(GameClock.hour)
		if new_dest != _current_destination:
			# Bug 9: Enforce minimum stay (except emergencies and sleep)
			var is_emergency: bool = hunger < 20.0 or energy < 20.0 or GameClock.hour >= 23 or GameClock.hour < 5
			var can_leave: bool = is_emergency or planner.dest_arrival_time <= 0 or (GameClock.total_minutes - planner.dest_arrival_time) >= planner.MIN_STAY_MINUTES
			if can_leave:
				_update_destination(GameClock.hour)

	# Try NPC-to-NPC conversation every 15 game minutes when not moving
	if GameClock.total_minutes % 15 == 0 and not _is_moving and not _in_conversation:
		conversation.try_npc_conversation()

	# Check conversation approach completion
	if conversation._approaching_target != null and not _is_moving:
		conversation.check_approach_arrived()

	# Periodic perception scan every 30 game minutes (fix for already-overlapping bodies)
	if GameClock.total_minutes % 30 == 0:
		perception.scan_perception_area()
		perception.scan_environment()

	# Reflections now triggered by importance threshold in _add_memory_with_embedding()


func get_mood() -> float:
	return (hunger + energy + social) / 3.0


# --- Dialogue (thin wrappers — implementation in NPCDialogue component) ---

func get_dialogue_response() -> String:
	return dialogue.get_dialogue_response()


func get_dialogue_response_async(callback: Callable) -> void:
	dialogue.get_dialogue_response_async(callback)


func get_conversation_reply_async(player_message: String, history: Array[Dictionary], callback: Callable) -> void:
	dialogue.get_conversation_reply_async(player_message, history, callback)


func on_player_conversation_ended() -> void:
	dialogue.on_player_conversation_ended()



# --- Scheduling ---

func _update_destination(hour: int) -> void:
	if _astar == null:
		return
	if _in_conversation:
		return

	var dest: String = _get_schedule_destination(hour)
	if dest == _current_destination:
		return

	# Release current furniture and tile reservation before moving
	activity.release_current_object()
	if _town_map and _town_map.has_method("release_tile"):
		var old_grid := Vector2i(int(global_position.x) / TILE_SIZE, int(global_position.y) / TILE_SIZE)
		_town_map.release_tile(old_grid, npc_name)

	_current_destination = dest

	# Determine target position — prefer tile next to work furniture
	var target_pos: Vector2 = Vector2.ZERO
	var target_type: String = activity.get_target_furniture_type(dest)
	if target_type != "" and _town_map:
		var obj_id: String = WorldObjects.find_object_for_npc(dest, target_type, npc_name)
		if obj_id != "" and WorldObjects._objects.has(obj_id):
			var obj_grid: Vector2i = WorldObjects._objects[obj_id]["grid_pos"]
			if _town_map.has_method("get_furniture_adjacent_tile"):
				target_pos = _town_map.get_furniture_adjacent_tile(obj_grid)

	# Fallback to unreserved interior tile if no furniture target
	if target_pos == Vector2.ZERO:
		if _building_interiors.has(dest) and _building_interiors[dest].size() > 0:
			if _town_map and _town_map.has_method("get_unreserved_interior_tile"):
				target_pos = _town_map.get_unreserved_interior_tile(dest, npc_name)
			else:
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
	var map_w: int = _town_map.MAP_WIDTH if _town_map else 60
	var map_h: int = _town_map.MAP_HEIGHT if _town_map else 45
	from_grid.x = clampi(from_grid.x, 0, map_w - 1)
	from_grid.y = clampi(from_grid.y, 0, map_h - 1)
	to_grid.x = clampi(to_grid.x, 0, map_w - 1)
	to_grid.y = clampi(to_grid.y, 0, map_h - 1)

	# Get path from A*
	_path = _astar.get_point_path(from_grid, to_grid)

	if _path.is_empty():
		push_warning("[%s] A* found no path from %s to %s (dest: '%s')" % [
			npc_name, from_grid, to_grid, dest])
		return

	_path_index = 0
	_is_moving = true
	activity.update_activity()
	print("[%s] Hour %d -> '%s' | Path: %d waypoints | From %s -> %s" % [
		npc_name, hour, dest, _path.size(), from_grid, to_grid])


func _get_schedule_destination(hour: int) -> String:
	## Needs-driven scheduling with personality-based flexibility.
	## NOW INCLUDES: daily plan overrides.

	# Emergency overrides (ALWAYS highest priority)
	if hunger < 20.0 or energy < 20.0:
		if conversation._approaching_target != null:
			conversation._approaching_target = null
		return home_building

	# Sleep time — everyone goes home (ALWAYS)
	if hour >= 23 or hour < 5:
		return home_building

	# --- CHECK DAILY PLAN ---
	var plan_dest: String = planner.get_active_plan_destination(hour)
	if plan_dest != "":
		return plan_dest

	# Morning wake-up (5-6) — head to work
	if hour >= 5 and hour < 6:
		return workplace_building

	# Core work hours (6-15)
	if hour >= 6 and hour < 15:
		# Lunch break: go home to eat if hungry
		if hour >= 11 and hour < 13 and hunger < 60.0:
			return home_building
		# Bug 11: Only allow spontaneous Church visits after hour 8 (not during early work)
		if hour >= 8 and planner.wants_to_visit("Church", hour):
			return "Church"
		return workplace_building

	# Afternoon (15-17) — flexible time
	if hour >= 15 and hour < 17:
		if social < 40.0:
			return "Tavern"
		if hunger < 50.0:
			return home_building
		return workplace_building

	# Evening (17-20) — social time
	if hour >= 17 and hour < 20:
		# Bug 9: Only leave Tavern if truly exhausted (was: social > 80 && energy < 40)
		if energy < 20.0:
			return home_building
		return "Tavern"

	# Late evening (20-23) — winding down
	if hour >= 20 and hour < 23:
		if energy < 50.0:
			return home_building
		if social < 50.0:
			return "Tavern"
		return home_building

	return home_building


# --- Memory bridge ---

func _add_memory_with_embedding(description: String, type: String, actor: String,
		participants: Array[String], observer_loc: String, observed_loc: String,
		importance: float, valence: float) -> void:
	## Routes memory creation to the Python backend via ApiClient.
	## Falls back to local MemorySystem if backend is unavailable or API call fails.
	if ApiClient.is_available():
		var body: Dictionary = {
			"text": description,
			"type": type,
			"actor": actor,
			"participants": Array(participants),
			"observer_location": observer_loc,
			"observed_near": observed_loc,
			"importance": importance,
			"valence": valence,
			"game_time": GameClock.total_minutes,
			"game_day": GameClock.total_minutes / 1440,
			"game_hour": GameClock.hour,
		}
		ApiClient.post("/memory/%s/add" % npc_name, body, func(response: Dictionary, success: bool) -> void:
			if success and OS.is_debug_build():
				print("[Memory API] %s: stored '%s'" % [npc_name, description.left(60)])
			elif not success:
				# Fallback: store locally if API failed
				memory.add_memory(description, type, actor, participants,
					observer_loc, observed_loc, importance, valence)
		)
	else:
		# No backend — use local memory system
		memory.add_memory(description, type, actor, participants,
			observer_loc, observed_loc, importance, valence)

	# Reflection trigger: delegate importance tracking to reflection component
	if reflection:
		reflection.on_memory_added(importance, type)

	# Safety valve: trigger maintenance if memories grow too large
	if memory.get_memory_count() > 500 and reflection:
		reflection.run_midnight_maintenance()
