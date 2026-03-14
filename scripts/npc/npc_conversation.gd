extends Node
## Handles NPC-to-NPC conversations: approach-then-talk, turn-by-turn generation,
## topic selection, impact analysis, speech bubbles, and gossip exchange.
## NPCs now walk to each other before talking and are locked during conversation.

var npc: CharacterBody2D

# NPC-to-NPC conversation tracking
var _last_conversation_time: Dictionary = {}  # {npc_name: game_time}
const CONVERSATION_COOLDOWN: int = 120  # 2 game hours between conversations with same NPC

# Conversation spam prevention
var _conv_counts_today: Dictionary = {}      # "A:B" -> int
const MAX_CONV_PER_PAIR_PER_DAY: int = 3
const COOLDOWN_COHABIT_MINUTES: int = 240    # 4 game hours for cohabitants

# NPC-to-NPC conversation totals (for summary update trigger)
var _npc_conv_totals: Dictionary = {}  # "OtherName" -> int (lifetime count)

const NPC_CONV_MAX_TURNS: int = 6   # Up to 6 turns (3 exchanges)
const NPC_CONV_MIN_TURNS: int = 2   # At least 1 exchange

# Approach state — NPC walks toward target before starting conversation
var _approaching_target: CharacterBody2D = null
var _approach_topic: String = ""


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func reset_daily_counts() -> void:
	## Called at midnight from controller._on_hour_changed().
	_conv_counts_today.clear()
	_approaching_target = null
	_approach_topic = ""


# --- Conversation initiation with approach phase ---

func try_npc_conversation() -> void:
	## Find a nearby NPC to talk to. If found, walk over first, then start conversation.

	# Already in a conversation or approaching someone
	if npc.in_conversation or _approaching_target != null:
		return

	# Don't chat while sleeping or during night hours
	if npc.current_activity.begins_with("sleeping"):
		return
	if GameClock.hour >= 22 or GameClock.hour < 5:
		return

	for other: Node in npc.get_tree().get_nodes_in_group("npcs"):
		if other == npc:
			continue
		var other_npc: CharacterBody2D = other as CharacterBody2D

		# Other NPC must be awake
		if other_npc.current_activity.begins_with("sleeping"):
			continue

		# Skip if other NPC is already in a conversation
		if other_npc.in_conversation:
			continue

		# Skip if other NPC is being approached by someone else
		var being_approached: bool = false
		for check_node: Node in npc.get_tree().get_nodes_in_group("npcs"):
			if check_node == npc:
				continue
			var check: CharacterBody2D = check_node as CharacterBody2D
			if check.conversation._approaching_target == other_npc:
				being_approached = true
				break
		if being_approached:
			continue

		# Building-aware conversation distance
		var dist: float = other_npc.global_position.distance_to(npc.global_position)
		var same_building: bool = npc._current_destination != "" and npc._current_destination == other_npc._current_destination
		var max_dist: float = 192.0 if same_building else 64.0
		if dist > max_dist:
			continue

		# Skip if other NPC is moving between buildings
		if other_npc._is_moving:
			continue

		var other_name: String = other_npc.npc_name

		# Cooldown check — 2 hours between conversations with same NPC
		if _last_conversation_time.has(other_name):
			if GameClock.total_minutes - _last_conversation_time[other_name] < CONVERSATION_COOLDOWN:
				continue

		# Daily cap per pair
		var pair: String = npc._pair_key(npc.npc_name, other_name)
		if _conv_counts_today.get(pair, 0) >= MAX_CONV_PER_PAIR_PER_DAY:
			continue

		# Extended cooldown for cohabitants (same building)
		if same_building:
			if _last_conversation_time.has(other_name):
				var mins_since: int = GameClock.total_minutes - _last_conversation_time[other_name]
				if mins_since < COOLDOWN_COHABIT_MINUTES:
					continue

		# FOUND a valid partner — check if we need to walk over
		if dist <= 48.0:
			# Already adjacent (within 1.5 tiles) — start immediately
			_begin_conversation(other_npc)
		else:
			# Need to walk over first
			_start_approach(other_npc)

		break  # Only one conversation attempt per tick


func _start_approach(target: CharacterBody2D) -> void:
	## Walk to an adjacent tile of the target NPC, then start conversation.
	_approaching_target = target
	_approach_topic = _pick_conversation_topic(target)

	var adjacent_pos: Vector2 = _find_adjacent_walkable_tile(target.global_position)
	if adjacent_pos == Vector2.ZERO:
		# Can't find adjacent tile — try conversation from here if close enough
		if npc.global_position.distance_to(target.global_position) <= 96.0:
			_begin_conversation(target)
		else:
			_approaching_target = null
			_approach_topic = ""
		return

	# Path to the adjacent tile using the controller's pathfinding
	var from_grid := Vector2i(
		int(npc.global_position.x) / npc.TILE_SIZE,
		int(npc.global_position.y) / npc.TILE_SIZE
	)
	var to_grid := Vector2i(
		int(adjacent_pos.x) / npc.TILE_SIZE,
		int(adjacent_pos.y) / npc.TILE_SIZE
	)

	if npc._astar == null:
		_approaching_target = null
		_approach_topic = ""
		return

	var path: PackedVector2Array = npc._astar.get_point_path(from_grid, to_grid)
	if path.is_empty():
		# Can't reach them — try from current position if close enough
		if npc.global_position.distance_to(target.global_position) <= 96.0:
			_begin_conversation(target)
		_approaching_target = null
		_approach_topic = ""
		return

	# Only walk over if it's a short path (don't cross the whole town for a chat)
	if path.size() > 12:
		_approaching_target = null
		_approach_topic = ""
		return

	# Set the path on the controller
	npc._path = path
	npc._path_index = 0
	npc._is_moving = true
	npc.current_activity = "walking over to %s" % target.npc_name
	npc.activity._update_activity_label()

	if OS.is_debug_build():
		print("[Conv] %s approaching %s (%d tiles)" % [npc.npc_name, target.npc_name, path.size()])


func _find_adjacent_walkable_tile(target_pos: Vector2) -> Vector2:
	## Find a walkable tile adjacent to the target, not occupied by any NPC.
	var target_grid := Vector2i(
		int(target_pos.x) / npc.TILE_SIZE,
		int(target_pos.y) / npc.TILE_SIZE
	)

	if npc._astar == null:
		return Vector2.ZERO

	# Collect occupied tiles (all stationary NPCs except self and target)
	var occupied: Dictionary = {}
	for other: Node in npc.get_tree().get_nodes_in_group("npcs"):
		if other == npc:
			continue
		var other_npc: CharacterBody2D = other as CharacterBody2D
		if other_npc._is_moving:
			continue
		# Don't count the target as "occupied" — we want to be NEXT to them
		if other_npc.global_position.distance_to(target_pos) < 4.0:
			continue
		var og := Vector2i(
			int(other_npc.global_position.x) / npc.TILE_SIZE,
			int(other_npc.global_position.y) / npc.TILE_SIZE
		)
		occupied[og] = true

	# Skip player's tile
	var player: Node = npc.get_tree().get_first_node_in_group("player")
	if player:
		var pg := Vector2i(
			int(player.global_position.x) / npc.TILE_SIZE,
			int(player.global_position.y) / npc.TILE_SIZE
		)
		occupied[pg] = true

	var offsets: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0),
	]

	var grid_w: int = npc._town_map.MAP_WIDTH if npc._town_map else 60
	var grid_h: int = npc._town_map.MAP_HEIGHT if npc._town_map else 45

	var my_grid := Vector2i(
		int(npc.global_position.x) / npc.TILE_SIZE,
		int(npc.global_position.y) / npc.TILE_SIZE
	)

	var best_pos: Vector2 = Vector2.ZERO
	var best_dist: float = INF

	for offset: Vector2i in offsets:
		var check: Vector2i = target_grid + offset
		if check.x < 0 or check.x >= grid_w or check.y < 0 or check.y >= grid_h:
			continue
		if npc._astar.is_point_solid(check):
			continue
		if occupied.has(check):
			continue
		var check_pos: Vector2 = Vector2(
			check.x * npc.TILE_SIZE + npc.TILE_SIZE / 2,
			check.y * npc.TILE_SIZE + npc.TILE_SIZE / 2
		)
		var d: float = my_grid.distance_to(Vector2(check))
		if d < best_dist:
			best_dist = d
			best_pos = check_pos

	return best_pos


func check_approach_arrived() -> void:
	## Called from controller's _arrive() and _on_time_tick().
	## If we were approaching someone for conversation, check if we've arrived.
	if _approaching_target == null:
		return

	if not is_instance_valid(_approaching_target):
		_approaching_target = null
		_approach_topic = ""
		return

	# Target became busy, started moving, or fell asleep — cancel
	if _approaching_target.in_conversation:
		if OS.is_debug_build():
			print("[Conv] %s: %s is now busy, canceling approach" % [npc.npc_name, _approaching_target.npc_name])
		_approaching_target = null
		_approach_topic = ""
		return

	if _approaching_target._is_moving:
		_approaching_target = null
		_approach_topic = ""
		return

	if _approaching_target.current_activity.begins_with("sleeping"):
		_approaching_target = null
		_approach_topic = ""
		return

	# Check if we've arrived close enough
	var dist: float = npc.global_position.distance_to(_approaching_target.global_position)
	if dist <= 48.0 and not npc._is_moving:
		var target: CharacterBody2D = _approaching_target
		_approaching_target = null
		_begin_conversation(target)


func _begin_conversation(other_npc: CharacterBody2D) -> void:
	## Lock both NPCs, face each other, and start the actual dialogue exchange.
	var other_name: String = other_npc.npc_name

	# Refresh memory cache for fresh topic picking
	npc.memory.refresh_cache()

	# Lock both NPCs
	npc.lock_for_conversation(other_name)
	other_npc.lock_for_conversation(npc.npc_name)

	# Face each other
	npc._face_toward(other_npc.global_position)
	other_npc._face_toward(npc.global_position)

	# Social boost for both
	npc.social = minf(npc.social + 5.0, 100.0)
	other_npc.social = minf(other_npc.social + 5.0, 100.0)

	# Set cooldown for both
	_last_conversation_time[other_name] = GameClock.total_minutes
	other_npc.conversation._last_conversation_time[npc.npc_name] = GameClock.total_minutes
	var pair: String = npc._pair_key(npc.npc_name, other_name)
	_conv_counts_today[pair] = _conv_counts_today.get(pair, 0) + 1

	# Update activity display
	npc.current_activity = "talking with %s" % other_name
	npc.activity._update_activity_label()
	other_npc.current_activity = "talking with %s" % npc.npc_name
	other_npc.activity._update_activity_label()

	# Run conversation (API > template)
	if ApiClient.is_available():
		_real_npc_conversation_locked(other_npc)
	else:
		_fake_npc_conversation_locked(other_npc)


# --- Locked conversation runners ---

func _fake_npc_conversation_locked(other_npc: CharacterBody2D) -> void:
	## Template conversation with lock/unlock lifecycle.
	var other_name: String = other_npc.npc_name
	var topic: String = _approach_topic if _approach_topic != "" else _pick_conversation_topic(other_npc)
	_approach_topic = ""

	npc._add_memory_with_embedding(
		"Had a conversation with %s about %s at the %s" % [other_name, topic, npc._current_destination],
		"dialogue", other_name, [npc.npc_name, other_name] as Array[String],
		npc._current_destination, npc._current_destination, 3.0, 0.2
	)
	other_npc._add_memory_with_embedding(
		"Had a conversation with %s about %s at the %s" % [npc.npc_name, topic, npc._current_destination],
		"dialogue", npc.npc_name, [other_npc.npc_name, npc.npc_name] as Array[String],
		npc._current_destination, npc._current_destination, 3.0, 0.2
	)
	# Fake conversations still get flat bump
	Relationships.modify_mutual(npc.npc_name, other_name, 1, 1, 0)

	# Gossip phase
	var gossip_mem: Dictionary = npc.gossip.pick_gossip_for(other_npc)
	if not gossip_mem.is_empty():
		npc.gossip.share_gossip_with(other_npc, gossip_mem)
	var reverse_gossip: Dictionary = other_npc.gossip.pick_gossip_for(npc)
	if not reverse_gossip.is_empty():
		other_npc.gossip.share_gossip_with(npc, reverse_gossip)

	print("[%s] Chatted with %s about %s (template)" % [npc.npc_name, other_name, topic])

	# Unlock both NPCs
	npc.unlock_conversation()
	if is_instance_valid(other_npc):
		other_npc.unlock_conversation()


func _real_npc_conversation_locked(other_npc: CharacterBody2D) -> void:
	## Turn-by-turn API-powered conversation with lock/unlock lifecycle.
	var topic: String = _approach_topic if _approach_topic != "" else _pick_conversation_topic(other_npc)
	_approach_topic = ""

	var max_turns: int = NPC_CONV_MAX_TURNS

	# Start the recursive turn chain
	_run_conversation_turn(npc, other_npc, [], 0, max_turns, topic,
		func(history: Array[Dictionary]) -> void:
			# Safety: unlock whoever is still valid if something went wrong
			if not is_instance_valid(npc) or not is_instance_valid(other_npc):
				if is_instance_valid(npc):
					npc.unlock_conversation()
				if is_instance_valid(other_npc):
					other_npc.unlock_conversation()
				return

			var other_name: String = other_npc.npc_name

			# Build combined memory text from all turns
			var my_lines: Array[String] = []
			var their_lines: Array[String] = []
			for entry: Dictionary in history:
				if entry["speaker"] == npc.npc_name:
					my_lines.append(entry["text"])
				else:
					their_lines.append(entry["text"])

			var full_dialogue: String = ""
			for entry: Dictionary in history:
				full_dialogue += "%s: \"%s\" " % [entry["speaker"], entry["text"]]

			# Store dialogue memory for both NPCs (full conversation)
			npc._add_memory_with_embedding(
				"Conversation with %s at the %s — %s" % [other_name, npc._current_destination, full_dialogue.left(300)],
				"dialogue", other_name, [npc.npc_name, other_name] as Array[String],
				npc._current_destination, npc._current_destination, 4.0, 0.2
			)

			other_npc._add_memory_with_embedding(
				"Conversation with %s at the %s — %s" % [npc.npc_name, npc._current_destination, full_dialogue.left(300)],
				"dialogue", npc.npc_name, [other_npc.npc_name, npc.npc_name] as Array[String],
				npc._current_destination, npc._current_destination, 4.0, 0.2
			)

			# Content-aware relationship impact using first exchange
			var first_my: String = my_lines[0] if not my_lines.is_empty() else ""
			var first_their: String = their_lines[0] if not their_lines.is_empty() else ""
			if first_my != "" and first_their != "":
				_analyze_npc_conversation_impact(other_npc, first_my, first_their)

			print("[NPC Chat] %s↔%s: %d turns at %s" % [
				npc.npc_name, other_name, history.size(), npc._current_destination])

			# Gossip phase (20% chance)
			var gossip_mem: Dictionary = npc.gossip.pick_gossip_for(other_npc)
			if not gossip_mem.is_empty():
				npc.gossip.share_gossip_with(other_npc, gossip_mem)

			if is_instance_valid(other_npc):
				var reverse_gossip: Dictionary = other_npc.gossip.pick_gossip_for(npc)
				if not reverse_gossip.is_empty():
					other_npc.gossip.share_gossip_with(npc, reverse_gossip)

			# Unlock both NPCs AFTER all processing
			npc.unlock_conversation()
			if is_instance_valid(other_npc):
				other_npc.unlock_conversation()
	)


# --- Turn-by-turn generation ---

func _run_conversation_turn(speaker: CharacterBody2D, listener: CharacterBody2D,
		history: Array[Dictionary], turn: int, max_turns: int,
		topic: String, on_done: Callable) -> void:
	## Recursive callback chain: each turn generates one line, then swaps roles.
	## Routes through ApiClient; falls back to template on failure.
	if not is_instance_valid(speaker) or not is_instance_valid(listener):
		on_done.call(history)
		return

	if ApiClient.is_available():
		_run_turn_via_api(speaker, listener, history, turn, max_turns, topic, on_done)
	else:
		# No backend — use a template line and end after min turns
		var line: String = speaker.conversation._get_npc_chat_fallback(topic)
		var should_end: bool = turn + 1 >= NPC_CONV_MIN_TURNS
		_process_turn_result(speaker, listener, history, turn, max_turns, topic, on_done, line, should_end)


func _build_npc_state_for(character: CharacterBody2D) -> Dictionary:
	return {
		"npc_name": character.npc_name,
		"job": character.job,
		"age": character.age,
		"personality": character.personality,
		"speech_style": character.speech_style,
		"home_building": character.home_building,
		"workplace_building": character.workplace_building,
		"current_destination": character._current_destination,
		"current_activity": character.current_activity,
		"needs": {"hunger": character.hunger, "energy": character.energy, "social": character.social},
		"game_time": GameClock.total_minutes,
		"game_hour": GameClock.hour,
		"game_minute": GameClock.minute,
		"game_day": GameClock.total_minutes / 1440,
	}


func _build_relationship_for(from_name: String, to_name: String) -> Dictionary:
	var rel: Dictionary = Relationships.get_relationship(from_name, to_name)
	return {
		"trust": rel.get("trust", 0),
		"affection": rel.get("affection", 0),
		"respect": rel.get("respect", 0),
		"trust_label": Relationships.get_trust_label(from_name, to_name),
		"affection_label": Relationships.get_affection_label(from_name, to_name),
		"respect_label": Relationships.get_respect_label(from_name, to_name),
	}


func _run_turn_via_api(speaker: CharacterBody2D, listener: CharacterBody2D,
		history: Array[Dictionary], turn: int, max_turns: int,
		topic: String, on_done: Callable) -> void:
	var body: Dictionary = {
		"speaker_name": speaker.npc_name,
		"speaker_state": _build_npc_state_for(speaker),
		"listener_name": listener.npc_name,
		"listener_state": _build_npc_state_for(listener),
		"topic": topic,
		"history": history,
		"turn": turn,
		"max_turns": max_turns,
		"game_time": {
			"total_minutes": GameClock.total_minutes,
			"hour": GameClock.hour,
			"minute": GameClock.minute,
			"day": GameClock.total_minutes / 1440,
		},
		"relationship": _build_relationship_for(speaker.npc_name, listener.npc_name),
	}
	ApiClient.post("/chat/npc-turn", body, func(response: Dictionary, success: bool) -> void:
		if not is_instance_valid(speaker) or not is_instance_valid(listener):
			on_done.call(history)
			return
		var line: String = ""
		var should_end: bool = false
		if success and response.get("success", false):
			line = response.get("line", "")
			should_end = response.get("should_end", false)
		if line == "":
			line = speaker.conversation._get_npc_chat_fallback(topic)
		_process_turn_result(speaker, listener, history, turn, max_turns, topic, on_done, line, should_end)
	)


func _process_turn_result(speaker: CharacterBody2D, listener: CharacterBody2D,
		history: Array[Dictionary], turn: int, max_turns: int,
		topic: String, on_done: Callable, line: String, should_end: bool) -> void:
	## Common post-processing for a completed turn.
	history.append({"speaker": speaker.npc_name, "text": line})
	speaker.conversation._show_speech_bubble(line)
	print("[NPC Chat T%d] %s: \"%s\"" % [turn, speaker.npc_name, line])
	npc.gossip.detect_third_party_mentions(speaker.npc_name, line, listener)

	if should_end:
		on_done.call(history)
		return

	# Next turn after brief delay — swap speaker and listener
	npc.get_tree().create_timer(1.5).timeout.connect(func() -> void:
		_run_conversation_turn(listener, speaker, history, turn + 1, max_turns, topic, on_done)
	)


# --- Topic selection ---

func _pick_conversation_topic(other_npc: CharacterBody2D) -> String:
	## Pick a topic based on context.
	var topics: Array[String] = []

	# Time based
	if GameClock.hour >= 17:
		topics.append("how their day went")
	if GameClock.hour < 8:
		topics.append("morning plans")

	# Needs based
	if npc.hunger < 40.0:
		topics.append("food")
	if other_npc.energy < 40.0:
		topics.append("being tired")

	# Job based
	topics.append("work at the %s" % npc.workplace_building)

	# Memory based — if I have a memory about the player
	var recent: Array[Dictionary] = npc.memory.get_recent(3)
	for mem: Dictionary in recent:
		if mem.get("actor", "") == PlayerProfile.player_name or mem.get("actor", "") == "Player":
			topics.append("the newcomer %s" % PlayerProfile.player_name)
			break

	# Gossip-based topics
	var gossip_mems: Array[Dictionary] = npc.memory.get_by_type("gossip")
	if not gossip_mems.is_empty():
		var latest_gossip: Dictionary = gossip_mems[-1]
		var gossip_about: String = latest_gossip.get("actor", "")
		if gossip_about != "" and gossip_about != other_npc.npc_name:
			topics.append("what they heard about %s" % gossip_about)

	# If I have interesting player observations, share them
	var player_mems: Array[Dictionary] = npc.memory.get_memories_about(PlayerProfile.player_name)
	if not player_mems.is_empty():
		var latest: Dictionary = player_mems[-1]
		var hours_since: float = (GameClock.total_minutes - latest.get("game_time", 0)) / 60.0
		if hours_since < 24:
			topics.append("the newcomer %s" % PlayerProfile.player_name)

	# Random flavor
	topics.append_array(["the weather", "town gossip", "old times", "their families"])

	return topics[randi() % topics.size()]


func _get_npc_chat_fallback(topic: String) -> String:
	## Fallback one-liner when API fails mid-conversation.
	var fallbacks: Array[String] = [
		"Interesting weather we're having.",
		"Same old, same old around here.",
		"Can't complain, I suppose.",
		"Been busy at the %s lately." % npc.workplace_building,
		"What do you think about %s?" % topic,
	]
	return fallbacks[randi() % fallbacks.size()]


func _show_speech_bubble(text: String) -> void:
	## Show floating text above this NPC's head for 4 seconds.
	# Remove any existing bubble first
	for child: Node in npc.get_children():
		if child.has_method("show_text"):
			child.queue_free()

	var bubble: Node2D = Node2D.new()
	bubble.set_script(load("res://scripts/ui/speech_bubble.gd"))
	npc.add_child(bubble)
	bubble.show_text(text, 4.0)


# --- Impact analysis (NPC-to-NPC) ---

func _analyze_npc_conversation_impact(other_npc: CharacterBody2D, my_line: String, their_line: String) -> void:
	## Analyze NPC-to-NPC conversation for bidirectional relationship impact.
	var other_name: String = other_npc.npc_name
	_npc_conv_totals[other_name] = _npc_conv_totals.get(other_name, 0) + 1

	if not ApiClient.is_available():
		Relationships.modify_mutual(npc.npc_name, other_name, 1, 1, 0)
		return

	var rel: Dictionary = Relationships.get_relationship(npc.npc_name, other_name)
	var body: Dictionary = {
		"speaker_name": npc.npc_name,
		"listener_name": other_name,
		"speaker_line": my_line,
		"listener_line": their_line,
		"current_relationship": rel,
		"game_time": {
			"total_minutes": GameClock.total_minutes,
			"hour": GameClock.hour,
			"minute": GameClock.minute,
			"day": GameClock.total_minutes / 1440,
		},
	}
	ApiClient.post("/chat/npc-impact", body, func(response: Dictionary, success: bool) -> void:
		if not is_instance_valid(npc):
			return
		if success:
			var a2b: Dictionary = response.get("a_to_b", {})
			var b2a: Dictionary = response.get("b_to_a", {})
			var a_t: int = clampi(int(a2b.get("trust_change", 0)), -3, 3)
			var a_a: int = clampi(int(a2b.get("affection_change", 0)), -3, 3)
			var a_r: int = clampi(int(a2b.get("respect_change", 0)), -3, 3)
			var b_t: int = clampi(int(b2a.get("trust_change", 0)), -3, 3)
			var b_a: int = clampi(int(b2a.get("affection_change", 0)), -3, 3)
			var b_r: int = clampi(int(b2a.get("respect_change", 0)), -3, 3)
			if a_t == 0 and a_a == 0 and a_r == 0: a_t = 1
			if b_t == 0 and b_a == 0 and b_r == 0: b_t = 1
			Relationships.modify(npc.npc_name, other_name, a_t, a_a, a_r)
			Relationships.modify(other_name, npc.npc_name, b_t, b_a, b_r)
			var total_mag: int = absi(a_t) + absi(a_a) + absi(a_r)
			var conv_count: int = _npc_conv_totals.get(other_name, 0)
			if total_mag >= 3 or conv_count % 3 == 0:
				_update_npc_summary_via_api(other_name, my_line, their_line)
			if OS.is_debug_build():
				print("[NPC Impact API] %s→%s: T:%+d A:%+d R:%+d | %s→%s: T:%+d A:%+d R:%+d" % [
					npc.npc_name, other_name, a_t, a_a, a_r, other_name, npc.npc_name, b_t, b_a, b_r])
		else:
			Relationships.modify_mutual(npc.npc_name, other_name, 1, 1, 0)
	)


func _update_npc_summary_via_api(other_name: String, my_line: String, their_line: String) -> void:
	## Ask the backend to update this NPC's impression of another NPC after conversation.
	var body: Dictionary = {
		"npc_name": npc.npc_name,
		"other_name": other_name,
		"my_line": my_line.left(100),
		"their_line": their_line.left(100),
	}
	ApiClient.post("/chat/npc-summary", body, func(response: Dictionary, success: bool) -> void:
		if not is_instance_valid(npc):
			return
		if success and response.get("success", false):
			var summary: String = response.get("response_text", "")
			if summary != "":
				npc.memory.update_npc_summary(other_name, summary.left(200))
				if OS.is_debug_build():
					print("[Memory API] %s updated summary of %s: %s" % [npc.npc_name, other_name, summary.left(80)])
	)
