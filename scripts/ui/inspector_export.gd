extends Node
## Periodically exports all NPC state to a JSON file for the web inspector dashboard.
## Writes to user://inspector_state.json every 5 real seconds.

var _timer: float = 0.0
const EXPORT_INTERVAL: float = 5.0


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= EXPORT_INTERVAL:
		_timer = 0.0
		_export_state()


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
