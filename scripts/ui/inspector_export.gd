extends Node
## Periodically exports all NPC state to a JSON file for the web inspector dashboard.
## Writes to user://inspector_state.json every 5 real seconds.
## Also generates periodic "Town Chronicle" entries via Gemini 2.5 Pro.

var _timer: float = 0.0
const EXPORT_INTERVAL: float = 5.0

# Chronicle system — Gemini Pro analyzes events every 10 game minutes
var _last_chronicle_time: int = 0
var _chronicle_entries: Array[Dictionary] = []  # [{time, text}]
var _chronicle_in_progress: bool = false
const CHRONICLE_INTERVAL_MINUTES: int = 10


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= EXPORT_INTERVAL:
		_timer = 0.0
		_export_state()
		_maybe_generate_chronicle()
		_check_seed_event()


func _export_state() -> void:
	var state: Dictionary = {
		"game_time": {
			"hour": GameClock.hour,
			"minute": GameClock.minute,
			"day": GameClock.total_minutes / 1440,
			"total_minutes": GameClock.total_minutes,
			"time_scale": GameClock.time_scale,
		},
		"npcs": {},
		"world": _get_world_state(),
		"events": _get_global_events(),
		"chronicle": _chronicle_entries.duplicate(),
	}

	for npc_node: Node in get_tree().get_nodes_in_group("npcs"):
		var npc: CharacterBody2D = npc_node as CharacterBody2D
		state["npcs"][npc.npc_name] = _serialize_npc(npc)

	var file := FileAccess.open("user://inspector_state.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(state))


func _serialize_npc(npc: CharacterBody2D) -> Dictionary:
	var data: Dictionary = {}

	# Identity
	data["identity"] = {
		"name": npc.npc_name,
		"job": npc.job,
		"age": npc.age,
		"personality": npc.personality,
		"speech_style": npc.speech_style,
		"home": npc.home_building,
		"workplace": npc.workplace_building,
	}

	# Current state
	data["state"] = {
		"hunger": snapped(npc.hunger, 0.1),
		"energy": snapped(npc.energy, 0.1),
		"social": snapped(npc.social, 0.1),
		"mood": snapped(npc.get_mood(), 0.1),
		"location": npc._current_destination,
		"activity": npc.current_activity,
		"is_moving": npc._is_moving,
		"in_conversation": npc._in_conversation,
		"conversation_partner": npc._conversation_partner_name,
		"position": [snapped(npc.global_position.x, 0.1), snapped(npc.global_position.y, 0.1)],
	}

	# Core memory
	data["core_memory"] = {
		"emotional_state": npc.memory.core_memory.get("emotional_state", ""),
		"player_summary": npc.memory.core_memory.get("player_summary", ""),
		"npc_summaries": npc.memory.core_memory.get("npc_summaries", {}),
		"key_facts": npc.memory.core_memory.get("key_facts", []),
	}

	# Today's plan
	var plan_blocks: Array[Dictionary] = []
	for block: Dictionary in npc.planner._plan_level1:
		plan_blocks.append({
			"start": block.get("start_hour", 0),
			"end": block.get("end_hour", 0),
			"location": block.get("location", ""),
			"activity": str(block.get("activity", "")).left(120),
		})
	data["plan"] = plan_blocks

	# Recent memories (last 20)
	var recent_mems: Array[Dictionary] = []
	var all_mems: Array = npc.memory.episodic_memories
	var start_idx: int = maxi(all_mems.size() - 20, 0)
	for i: int in range(start_idx, all_mems.size()):
		var mem: Dictionary = all_mems[i]
		recent_mems.append({
			"text": str(mem.get("text", mem.get("description", ""))).left(200),
			"type": mem.get("type", ""),
			"importance": snapped(mem.get("importance", 0.0), 0.1),
			"valence": snapped(mem.get("emotional_valence", 0.0), 0.1),
			"time": mem.get("timestamp", mem.get("game_time", 0)),
			"actor": mem.get("actor", ""),
			"protected": mem.get("protected", false),
		})
	data["recent_memories"] = recent_mems

	# Reflections (last 10)
	var reflections: Array[Dictionary] = []
	for mem: Dictionary in npc.memory.get_by_type("reflection"):
		reflections.append({
			"text": str(mem.get("text", mem.get("description", ""))).left(300),
			"time": mem.get("timestamp", mem.get("game_time", 0)),
			"importance": snapped(mem.get("importance", 0.0), 0.1),
		})
	reflections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("time", 0) > b.get("time", 0))
	data["reflections"] = reflections.slice(0, mini(10, reflections.size()))

	# Gossip (last 10)
	var gossip_list: Array[Dictionary] = []
	for mem: Dictionary in npc.memory.get_by_type("gossip"):
		gossip_list.append({
			"text": str(mem.get("text", mem.get("description", ""))).left(200),
			"source": mem.get("gossip_source", mem.get("actor", "")),
			"hops": mem.get("gossip_hops", 0),
			"time": mem.get("timestamp", mem.get("game_time", 0)),
		})
	gossip_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("time", 0) > b.get("time", 0))
	data["gossip"] = gossip_list.slice(0, mini(10, gossip_list.size()))

	# Relationships
	var rels: Dictionary = Relationships.get_all_for(npc.npc_name)
	var rel_data: Dictionary = {}
	for target: String in rels:
		var r: Dictionary = rels[target]
		rel_data[target] = {
			"trust": r.get("trust", 0),
			"affection": r.get("affection", 0),
			"respect": r.get("respect", 0),
		}
	data["relationships"] = rel_data

	# Stats
	data["stats"] = {
		"total_memories": npc.memory.episodic_memories.size(),
		"total_conversations": npc.memory.get_by_type("dialogue").size() + npc.memory.get_by_type("player_dialogue").size(),
		"total_reflections": npc.memory.get_by_type("reflection").size(),
		"total_gossip": npc.memory.get_by_type("gossip").size(),
	}

	return data


func _get_world_state() -> Dictionary:
	var furniture: Dictionary = {}
	for obj_id: String in WorldObjects._objects:
		var obj: Dictionary = WorldObjects._objects[obj_id]
		if obj.get("state", "idle") != "idle" or obj.get("current_user", "") != "":
			furniture[obj_id] = {
				"state": obj.get("state", "idle"),
				"user": obj.get("current_user", ""),
			}

	return {
		"furniture": furniture,
		"api_stats": {
			"total_requests": GeminiClient.total_requests,
			"queue_size": GeminiClient._request_queue.size(),
			"active_requests": GeminiClient._active_requests.size(),
			"input_tokens": GeminiClient.total_input_tokens,
			"output_tokens": GeminiClient.total_output_tokens,
		},
	}


func _get_global_events() -> Array[Dictionary]:
	## Aggregate notable events from all NPCs into a global timeline.
	var events: Array[Dictionary] = []
	var cutoff: int = maxi(GameClock.total_minutes - 120, 0)  # Last 2 game hours

	for npc_node: Node in get_tree().get_nodes_in_group("npcs"):
		var npc: CharacterBody2D = npc_node as CharacterBody2D
		for mem: Dictionary in npc.memory.episodic_memories:
			var t: int = mem.get("timestamp", mem.get("game_time", 0))
			if t < cutoff:
				continue
			var mem_type: String = mem.get("type", "")
			# Only include notable event types
			if mem_type in ["dialogue", "player_dialogue", "gossip", "reflection", "plan"]:
				events.append({
					"time": t,
					"type": mem_type,
					"text": str(mem.get("text", mem.get("description", ""))).left(200),
					"actor": npc.npc_name,
					"entities": mem.get("entities", mem.get("participants", [])),
				})

	# Deduplicate (same conversation seen by both participants)
	var seen: Dictionary = {}
	var unique: Array[Dictionary] = []
	for ev: Dictionary in events:
		var key: String = "%d_%s" % [ev["time"], ev["text"].left(40)]
		if not seen.has(key):
			seen[key] = true
			unique.append(ev)

	unique.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["time"] > b["time"])
	return unique.slice(0, mini(50, unique.size()))


func _maybe_generate_chronicle() -> void:
	## Every CHRONICLE_INTERVAL_MINUTES game minutes, send recent events to Gemini Pro for narrative summary.
	if not GeminiClient.has_api_key():
		return
	if _chronicle_in_progress:
		return
	if GameClock.total_minutes - _last_chronicle_time < CHRONICLE_INTERVAL_MINUTES:
		return

	_last_chronicle_time = GameClock.total_minutes
	var events: Array[Dictionary] = _get_global_events()
	if events.is_empty():
		return

	# Build event summary for Pro
	var event_text: String = "Recent events in DeepTown (last 10 game minutes):\n"
	var count: int = 0
	for ev: Dictionary in events:
		if count >= 20:
			break
		event_text += "- [%s] %s: %s\n" % [ev["type"], ev["actor"], ev["text"].left(100)]
		count += 1

	var prompt: String = "You are a narrator for a medieval town simulation called DeepTown. Based on these recent events, write a 2-3 sentence narrative summary of what's happening in town right now. Be specific about names and locations. Write in present tense, like a town chronicle entry.\n\n%s\n\nWrite ONLY the chronicle entry:" % event_text

	_chronicle_in_progress = true
	GeminiClient.generate(
		"You are a concise medieval town narrator.",
		prompt,
		func(text: String, success: bool) -> void:
			_chronicle_in_progress = false
			if success and text.strip_edges() != "":
				_chronicle_entries.append({
					"time": GameClock.total_minutes,
					"text": text.strip_edges().left(400),
				})
				# Keep last 20 entries
				if _chronicle_entries.size() > 20:
					_chronicle_entries = _chronicle_entries.slice(_chronicle_entries.size() - 20)
				if OS.is_debug_build():
					print("[Chronicle] %s" % text.strip_edges().left(100)),
		GeminiClient.MODEL_PRO
	)


func _check_seed_event() -> void:
	## Poll for seed_event.json written by the web inspector. Inject into NPC when found.
	var seed_path: String = "user://seed_event.json"
	if not FileAccess.file_exists(seed_path):
		return
	var file := FileAccess.open(seed_path, FileAccess.READ)
	if not file:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(seed_path))
		return
	var data: Dictionary = json.data
	DirAccess.remove_absolute(ProjectSettings.globalize_path(seed_path))

	var npc_name: String = data.get("npc", "")
	var event_text: String = data.get("text", "")
	var location: String = data.get("location", "Tavern")
	var hour: int = data.get("hour", 18)

	if npc_name == "" or event_text == "":
		return

	# Find the target NPC
	var target_npc: CharacterBody2D = null
	for npc_node: Node in get_tree().get_nodes_in_group("npcs"):
		var npc: CharacterBody2D = npc_node as CharacterBody2D
		if npc.npc_name == npc_name:
			target_npc = npc
			break

	if target_npc == null:
		push_warning("[Seed Event] NPC '%s' not found" % npc_name)
		return

	# Build and inject the observation
	var obs: String = "%s heard that %s at the %s at %d:00 today. Everyone in town is welcome." % [
		npc_name, event_text, location, hour]
	target_npc._add_memory_with_embedding(
		obs, "observation", "townsfolk",
		[npc_name] as Array[String],
		target_npc._current_destination, location, 7.0, 0.6)

	# Trigger reaction evaluation + full replan so the event gets into today's schedule
	target_npc.planner.evaluate_reaction(obs, 7.0)
	target_npc.planner.generate_daily_plan()

	print("[Seed Event] Injected into %s: \"%s\" at %s hour %d" % [npc_name, event_text, location, hour])
