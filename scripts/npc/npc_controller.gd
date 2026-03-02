extends CharacterBody2D
## Controls a single NPC: needs-driven movement, perception, memory, conversations, LLM dialogue.
## Uses AStarGrid2D waypoint-following instead of NavigationAgent2D.
## Memory Stream replaces the old flat observation array with scored retrieval.

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

# Memory Stream (replaces old observations array)
var memory: MemoryStream = MemoryStream.new()
var _observation_cooldowns: Dictionary = {}  # {actor_name: last_observed_game_minute}
const OBSERVATION_COOLDOWN_MINUTES: int = 60

# NPC-to-NPC conversation tracking
var _last_conversation_time: Dictionary = {}  # {npc_name: game_time}
const CONVERSATION_COOLDOWN: int = 120  # 2 game hours between conversations with same NPC

# Random visit tracking
var _next_visit_check: int = 0

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
	age = data.get("age", 30)
	personality = data.get("personality", "")
	speech_style = data.get("speech_style", "")
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

	# Re-evaluate destination every 5 game minutes based on needs
	if GameClock.total_minutes % 5 == 0:
		var new_dest: String = _get_schedule_destination(GameClock.hour)
		if new_dest != _current_destination:
			_update_destination(GameClock.hour)

	# Try NPC-to-NPC conversation every 15 game minutes when not moving
	if GameClock.total_minutes % 15 == 0 and not _is_moving:
		_try_npc_conversation()

	# Periodic perception scan every 30 game minutes (fix for already-overlapping bodies)
	if GameClock.total_minutes % 30 == 0:
		_scan_perception_area()


func get_mood() -> float:
	return (hunger + energy + social) / 3.0


# --- Dialogue ---

func get_dialogue_response() -> String:
	## Synchronous template-based response. Used as immediate fallback.
	return _get_template_response()


func get_dialogue_response_async(callback: Callable) -> void:
	## Async dialogue: tries Gemini first, falls back to template.
	## Callback receives (response: String).
	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	var system_prompt: String = _build_system_prompt()
	var user_message: String = _build_dialogue_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		if success and text != "":
			# Store this conversation as a memory
			_add_memory_with_embedding(
				"Talked with Player at the %s. I said: %s" % [_current_destination, text.left(80)],
				"dialogue", "Player", [npc_name, "Player"] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func _build_system_prompt() -> String:
	return "You are %s, a %d-year-old %s in the town of DeepTown. %s\n\nYour speech style: %s\n\nRules:\n- Respond in character, first person, 1-3 sentences only\n- Never break character or mention being an AI\n- Let your personality shine through every word\n- Reference your memories naturally if relevant\n- Your mood and needs should affect how you talk" % [
		npc_name, age, job, personality, speech_style
	]


func _build_dialogue_context() -> String:
	var hour: int = GameClock.hour
	var period: String = "night"
	if hour >= 5 and hour < 8:
		period = "dawn"
	elif hour >= 8 and hour < 12:
		period = "morning"
	elif hour >= 12 and hour < 17:
		period = "afternoon"
	elif hour >= 17 and hour < 21:
		period = "evening"

	var mood: float = get_mood()
	var mood_desc: String = "miserable" if mood < 20.0 else "unhappy" if mood < 40.0 else "okay" if mood < 60.0 else "good" if mood < 80.0 else "great"

	var context: String = "Current situation: It is %s (%s). You are at the %s. Your mood is %s (%d/100).\n\n" % [
		GameClock.get_time_string(), period, _current_destination, mood_desc, int(mood)
	]

	context += "Your needs:\n"
	context += "- Hunger: %d/100 %s\n" % [int(hunger), "(starving!)" if hunger < 20.0 else "(hungry)" if hunger < 40.0 else "(fine)"]
	context += "- Energy: %d/100 %s\n" % [int(energy), "(exhausted!)" if energy < 20.0 else "(tired)" if energy < 40.0 else "(fine)"]
	context += "- Social: %d/100 %s\n\n" % [int(social), "(lonely)" if social < 30.0 else "(could use company)" if social < 50.0 else "(content)"]

	# Retrieve top 5 recent memories
	var recent_memories: Array[Dictionary] = memory.get_recent(5)
	if not recent_memories.is_empty():
		context += "Your recent memories:\n"
		for mem: Dictionary in recent_memories:
			var hours_ago: int = maxi((GameClock.total_minutes - mem.get("game_time", 0)) / 60, 0)
			var time_str: String = "%d hours ago" % hours_ago if hours_ago > 0 else "just now"
			context += "- %s: %s\n" % [time_str, mem.get("description", "")]
		context += "\n"

	context += "A traveler (the Player) is standing in front of you and wants to talk. Respond naturally."
	return context


func _get_template_response() -> String:
	## Fallback template responses when LLM is unavailable.
	if energy < 20.0:
		return "*yawns* I'm exhausted... heading home to rest."
	if hunger < 20.0:
		return "I'm starving, need to go eat."

	var player_memories: Array[Dictionary] = memory.get_memories_about("Player")
	if not player_memories.is_empty():
		var latest: Dictionary = player_memories[-1]
		var location: String = latest.get("observed_near", latest.get("observer_location", "town"))
		var hours_ago: int = (GameClock.total_minutes - latest.get("game_time", 0)) / 60
		if hours_ago < 1:
			return "Oh, I just saw you over by the %s! What brings you here?" % location
		elif hours_ago < 12:
			return "I saw you near the %s earlier today. How's your day going?" % location
		else:
			return "I remember seeing you around the %s a while back." % location

	var mood: float = get_mood()
	if mood > 70.0:
		return "Beautiful day, isn't it? Work at the %s is going well." % workplace_building
	elif mood > 40.0:
		return "Just another day at the %s." % workplace_building
	else:
		return "I'm not feeling great today..."


# --- Scheduling ---

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
	## Needs-driven scheduling with personality-based flexibility.
	# Emergency overrides
	if hunger < 20.0 or energy < 20.0:
		return home_building

	# Sleep time — everyone goes home
	if hour >= 23 or hour < 5:
		return home_building

	# Morning wake-up (5-6) — head to work
	if hour >= 5 and hour < 6:
		return workplace_building

	# Core work hours (6-15)
	if hour >= 6 and hour < 15:
		# Lunch break: go home to eat if hungry
		if hour >= 11 and hour < 13 and hunger < 60.0:
			return home_building
		# Occasional Church visit
		if _wants_to_visit("Church", hour):
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
		if social > 80.0 and energy < 40.0:
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


func _wants_to_visit(building: String, _hour: int) -> bool:
	## Returns true occasionally based on personality.
	if GameClock.total_minutes < _next_visit_check:
		return false

	# Only check once per game hour
	_next_visit_check = GameClock.total_minutes + 60

	# 10% chance of a spontaneous Church visit during work hours
	if building == "Church" and workplace_building != "Church":
		if randf() < 0.10:
			return true

	return false


# --- NPC-to-NPC Conversations ---

func _try_npc_conversation() -> void:
	## If another NPC is within 2 tiles and we haven't talked recently, have a brief exchange.
	for other: Node in get_tree().get_nodes_in_group("npcs"):
		if other == self:
			continue
		var other_npc: CharacterBody2D = other as CharacterBody2D
		if other_npc.global_position.distance_to(global_position) > 64.0:
			continue
		if other_npc._is_moving:
			continue

		var other_name: String = other_npc.npc_name
		# Cooldown check
		if _last_conversation_time.has(other_name):
			if GameClock.total_minutes - _last_conversation_time[other_name] < CONVERSATION_COOLDOWN:
				continue

		_last_conversation_time[other_name] = GameClock.total_minutes
		other_npc._last_conversation_time[npc_name] = GameClock.total_minutes

		# Create conversation memories for BOTH NPCs
		var topic: String = _pick_conversation_topic(other_npc)

		_add_memory_with_embedding(
			"Had a conversation with %s about %s at the %s" % [other_name, topic, _current_destination],
			"dialogue", other_name, [npc_name, other_name] as Array[String],
			_current_destination, _current_destination, 3.0, 0.2
		)

		other_npc._add_memory_with_embedding(
			"Had a conversation with %s about %s at the %s" % [npc_name, topic, _current_destination],
			"dialogue", npc_name, [other_npc.npc_name, npc_name] as Array[String],
			_current_destination, _current_destination, 3.0, 0.2
		)

		# Social boost for both
		social = minf(social + 5.0, 100.0)
		other_npc.social = minf(other_npc.social + 5.0, 100.0)

		print("[%s] Chatted with %s about %s" % [npc_name, other_name, topic])
		break  # Only one conversation per tick


func _pick_conversation_topic(other_npc: CharacterBody2D) -> String:
	## Pick a topic based on context.
	var topics: Array[String] = []

	# Time based
	if GameClock.hour >= 17:
		topics.append("how their day went")
	if GameClock.hour < 8:
		topics.append("morning plans")

	# Needs based
	if hunger < 40.0:
		topics.append("food")
	if other_npc.energy < 40.0:
		topics.append("being tired")

	# Job based
	topics.append("work at the %s" % workplace_building)

	# Memory based — if I have a memory about the player
	var recent: Array[Dictionary] = memory.get_recent(3)
	for mem: Dictionary in recent:
		if mem.get("actor", "") == "Player":
			topics.append("the stranger they saw in town")
			break

	# Random flavor
	topics.append_array(["the weather", "town gossip", "old times", "their families"])

	return topics[randi() % topics.size()]


# --- Perception ---

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
		[npc_name, actor_name] as Array[String], my_location, observed_location, importance, valence)


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
