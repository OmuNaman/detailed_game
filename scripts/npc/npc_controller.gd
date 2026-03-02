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
var _town_map: Node2D = null

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
		_town_map = town_map
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


func _face_toward(target_pos: Vector2) -> void:
	## Flip sprite to face toward the target position.
	if target_pos.x < global_position.x:
		sprite.flip_h = true
	elif target_pos.x > global_position.x:
		sprite.flip_h = false


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
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		_face_toward(player.global_position)

	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	var system_prompt: String = _build_system_prompt()
	var user_message: String = _build_dialogue_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		if success and text != "":
			# Store this conversation as a memory
			_add_memory_with_embedding(
				"Talked with %s at the %s. I said: %s" % [PlayerProfile.player_name, _current_destination, text.left(80)],
				"dialogue", PlayerProfile.player_name, [npc_name, PlayerProfile.player_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func get_conversation_reply_async(player_message: String, history: Array[Dictionary], callback: Callable) -> void:
	## Generate a reply considering full conversation history.
	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	var system_prompt: String = _build_system_prompt()
	var context: String = _build_dialogue_context()
	context += "\n\nConversation so far:\n"
	for msg: Dictionary in history:
		context += "%s: \"%s\"\n" % [msg["speaker"], msg["text"]]
	context += "\n%s just said: \"%s\"\n" % [PlayerProfile.player_name, player_message]
	context += "\nRespond naturally in character. 1-3 sentences. Continue the conversation based on what %s said." % PlayerProfile.player_name

	GeminiClient.generate(system_prompt, context, func(text: String, success: bool) -> void:
		if success and text != "":
			_add_memory_with_embedding(
				"Talked with %s at the %s. They said: \"%s\" and I replied: \"%s\"" % [
					PlayerProfile.player_name, _current_destination,
					player_message.left(40), text.left(40)],
				"dialogue", PlayerProfile.player_name,
				[npc_name, PlayerProfile.player_name] as Array[String],
				_current_destination, _current_destination, 5.0, 0.3
			)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func _build_system_prompt() -> String:
	var prompt: String = "You are %s, a %d-year-old %s in the town of DeepTown. %s\n\nYour speech style: %s\n\n" % [
		npc_name, age, job, personality, speech_style
	]
	prompt += "There is a newcomer in town named %s. They recently moved into House 11 on the south row. They seem curious about the town and its people.\n\n" % PlayerProfile.player_name
	prompt += "Rules:\n- Respond in character, first person, 1-3 sentences only\n- Never break character or mention being an AI\n- Let your personality shine through every word\n- Reference your memories naturally if relevant\n- Your mood and needs should affect how you talk\n- You can ask %s questions too — be curious about the newcomer\n- React to what they say, don't just give generic responses" % PlayerProfile.player_name
	return prompt


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

	context += "%s is standing in front of you and wants to talk. They recently moved to DeepTown and live in House 11. Respond naturally." % PlayerProfile.player_name
	return context


func _get_template_response() -> String:
	## Fallback template responses when LLM is unavailable.
	if energy < 20.0:
		return "*yawns* I'm exhausted... heading home to rest."
	if hunger < 20.0:
		return "I'm starving, need to go eat."

	var player_memories: Array[Dictionary] = memory.get_memories_about(PlayerProfile.player_name)
	if player_memories.is_empty():
		player_memories = memory.get_memories_about("Player")  # backward compat
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

	# Release old tile reservation before moving to new destination
	if _town_map and _town_map.has_method("release_tile"):
		var old_grid := Vector2i(int(global_position.x) / TILE_SIZE, int(global_position.y) / TILE_SIZE)
		_town_map.release_tile(old_grid, npc_name)

	_current_destination = dest

	# Pick an unreserved interior tile if available, otherwise use door position
	var target_pos: Vector2 = Vector2.ZERO
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
	## If another NPC is within 2 tiles and we haven't talked recently, have a real conversation.
	for other: Node in get_tree().get_nodes_in_group("npcs"):
		if other == self:
			continue
		var other_npc: CharacterBody2D = other as CharacterBody2D
		if other_npc.global_position.distance_to(global_position) > 64.0:
			continue
		if other_npc._is_moving:
			continue

		var other_name: String = other_npc.npc_name

		# Cooldown check — 2 hours between conversations with same NPC
		if _last_conversation_time.has(other_name):
			if GameClock.total_minutes - _last_conversation_time[other_name] < CONVERSATION_COOLDOWN:
				continue

		# Set cooldown for both
		_last_conversation_time[other_name] = GameClock.total_minutes
		other_npc._last_conversation_time[npc_name] = GameClock.total_minutes

		# Face each other
		_face_toward(other_npc.global_position)
		other_npc._face_toward(global_position)

		# Social boost for both
		social = minf(social + 5.0, 100.0)
		other_npc.social = minf(other_npc.social + 5.0, 100.0)

		# If no API key, fall back to fake topic-label system
		if not GeminiClient.has_api_key():
			_fake_npc_conversation(other_npc)
			break

		# Real conversation: I speak first, then they reply
		_real_npc_conversation(other_npc)
		break  # Only one conversation per tick


func _fake_npc_conversation(other_npc: CharacterBody2D) -> void:
	## Fallback when Gemini is unavailable. Same as old behavior.
	var other_name: String = other_npc.npc_name
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
	print("[%s] Chatted with %s about %s (template)" % [npc_name, other_name, topic])


func _real_npc_conversation(other_npc: CharacterBody2D) -> void:
	## Gemini-powered 2-line exchange. I say something, they reply.

	# Skip if Gemini queue is backed up (cost control)
	if GeminiClient._request_queue.size() > 10:
		_fake_npc_conversation(other_npc)
		return

	var other_name: String = other_npc.npc_name
	var topic: String = _pick_conversation_topic(other_npc)

	# Build context for the initiator (me)
	var my_system: String = _build_npc_chat_system_prompt()
	var my_context: String = _build_npc_chat_context(other_npc, topic, "")

	# Step 1: I generate my opening line
	GeminiClient.generate(my_system, my_context, func(my_line: String, my_success: bool) -> void:
		if not my_success or my_line == "":
			my_line = _get_npc_chat_fallback(topic)

		my_line = my_line.strip_edges().replace("\"", "").left(120)

		# Step 2: Other NPC generates their reply
		var their_system: String = other_npc._build_npc_chat_system_prompt()
		var their_context: String = other_npc._build_npc_chat_context(self, topic, my_line)

		GeminiClient.generate(their_system, their_context, func(their_line: String, their_success: bool) -> void:
			if not their_success or their_line == "":
				their_line = other_npc._get_npc_chat_fallback(topic)

			their_line = their_line.strip_edges().replace("\"", "").left(120)

			# Store actual dialogue in both NPCs' memories
			_add_memory_with_embedding(
				"I said to %s: \"%s\" — %s replied: \"%s\" (at the %s)" % [
					other_name, my_line, other_name, their_line, _current_destination],
				"dialogue", other_name, [npc_name, other_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)

			other_npc._add_memory_with_embedding(
				"%s said to me: \"%s\" — I replied: \"%s\" (at the %s)" % [
					npc_name, my_line, their_line, _current_destination],
				"dialogue", npc_name, [other_npc.npc_name, npc_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)

			# Show speech bubbles
			_show_speech_bubble(my_line)
			get_tree().create_timer(2.0).timeout.connect(func() -> void:
				if is_instance_valid(other_npc):
					other_npc._show_speech_bubble(their_line)
			)

			print("[NPC Chat] %s: \"%s\"" % [npc_name, my_line])
			print("[NPC Chat] %s: \"%s\"" % [other_name, their_line])
			print("[NPC Chat] %s→%s at %s (queue: %d, total_calls: %d)" % [
				npc_name, other_name, _current_destination,
				GeminiClient._request_queue.size(), GeminiClient.total_requests
			])
		)
	)


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
		if mem.get("actor", "") == PlayerProfile.player_name or mem.get("actor", "") == "Player":
			topics.append("the newcomer %s" % PlayerProfile.player_name)
			break

	# Random flavor
	topics.append_array(["the weather", "town gossip", "old times", "their families"])

	return topics[randi() % topics.size()]


func _build_npc_chat_system_prompt() -> String:
	## System prompt for NPC-to-NPC conversation (shorter than player dialogue).
	return "You are %s, age %d, %s in DeepTown. %s\nSpeech style: %s\n\nRules:\n- Say ONE sentence only, in character, first person\n- This is casual chat with a fellow townsperson, not a formal speech\n- Be natural — greetings, complaints, observations, jokes, gossip\n- Reference your current mood or needs if relevant\n- NEVER break character or mention being an AI" % [
		npc_name, age, job, personality, speech_style
	]


func _build_npc_chat_context(other_npc: CharacterBody2D, topic: String, their_line: String) -> String:
	## Build the user message for NPC-to-NPC conversation.
	var hour: int = GameClock.hour
	var period: String = "morning" if hour < 12 else ("afternoon" if hour < 17 else ("evening" if hour < 21 else "night"))

	var context: String = "It's %s at the %s. " % [period, _current_destination]

	# Your current state
	if hunger < 40.0:
		context += "You're quite hungry. "
	if energy < 30.0:
		context += "You're exhausted. "
	if social > 80.0:
		context += "You're in a great mood. "

	# Recent relevant memories (top 3)
	var recent: Array[Dictionary] = memory.get_recent(3)
	if not recent.is_empty():
		context += "Recent memories: "
		for mem: Dictionary in recent:
			context += mem.get("description", "") + ". "

	# The conversation setup
	if their_line == "":
		# I'm starting the conversation
		context += "\nYou see %s (%s, age %d) nearby. Start a brief chat about %s. Say ONE sentence." % [
			other_npc.npc_name, other_npc.job, other_npc.age, topic
		]
	else:
		# I'm replying to them
		context += "\n%s just said to you: \"%s\"\nReply naturally with ONE sentence." % [
			other_npc.npc_name, their_line
		]

	return context


func _get_npc_chat_fallback(topic: String) -> String:
	## Fallback one-liner when Gemini fails mid-conversation.
	var fallbacks: Array[String] = [
		"Interesting weather we're having.",
		"Same old, same old around here.",
		"Can't complain, I suppose.",
		"Been busy at the %s lately." % workplace_building,
		"What do you think about %s?" % topic,
	]
	return fallbacks[randi() % fallbacks.size()]


func _show_speech_bubble(text: String) -> void:
	## Show floating text above this NPC's head for 4 seconds.
	# Remove any existing bubble first
	for child: Node in get_children():
		if child.has_method("show_text"):
			child.queue_free()

	var bubble: Node2D = Node2D.new()
	bubble.set_script(load("res://scripts/ui/speech_bubble.gd"))
	add_child(bubble)
	bubble.show_text(text, 4.0)


# --- Perception ---

func _on_perception_body_entered(body: Node2D) -> void:
	if body == self:
		return
	if not (body is CharacterBody2D):
		return

	var actor_name: String = ""
	if body.is_in_group("player"):
		actor_name = PlayerProfile.player_name
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
	if body.is_in_group("player"):
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
