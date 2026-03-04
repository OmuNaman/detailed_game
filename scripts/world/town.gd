extends Node2D

const NPC_SCENE: PackedScene = preload("res://scenes/npcs/npc.tscn")


func _ready() -> void:
	var town_map: Node2D = $TownMap
	var player: CharacterBody2D = $Player

	# Position player at the path intersection after map generates
	if town_map.has_method("get_player_spawn_position"):
		player.position = town_map.get_player_spawn_position()

	_spawn_npcs(town_map)

	# Daily relationship decay at midnight
	EventBus.time_hour_changed.connect(_on_hour_changed)

	# Show name entry if first time
	if not PlayerProfile.is_name_set:
		_show_name_entry()


func _show_name_entry() -> void:
	get_tree().paused = true
	var name_scene: PackedScene = load("res://scenes/ui/name_entry.tscn")
	var name_ui: Node = name_scene.instantiate()
	add_child(name_ui)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_all_memories()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("quicksave"):
		_save_all_memories()
		print("[SaveManager] Manual save triggered (F5)")


func _spawn_npcs(town_map: Node2D) -> void:
	var building_positions: Dictionary = town_map.get_building_door_positions()
	var building_interiors: Dictionary = town_map.get_building_interior_positions()

	var file := FileAccess.open("res://data/npcs.json", FileAccess.READ)
	if not file:
		push_warning("Could not load npcs.json")
		return

	var json := JSON.new()
	var err: Error = json.parse(file.get_as_text())
	if err != OK:
		push_warning("Failed to parse npcs.json: " + json.get_error_message())
		return

	var npc_data_list: Array = json.data

	for npc_data: Dictionary in npc_data_list:
		var npc: CharacterBody2D = NPC_SCENE.instantiate()
		npc.initialize(npc_data, building_positions, building_interiors)

		# Spawn at home door position
		var home_name: String = npc_data.get("home", "")
		var home_pos: Vector2 = building_positions.get(home_name, Vector2(400, 400))
		npc.position = home_pos

		add_child(npc)

	# Seed initial relationships from npcs.json (only if no saved data exists)
	for npc_data_entry: Dictionary in npc_data_list:
		var from_name: String = npc_data_entry.get("name", "")
		var rels: Dictionary = npc_data_entry.get("relationships", {})
		for target_name: String in rels:
			var existing: Dictionary = Relationships.get_relationship(from_name, target_name)
			if existing["trust"] == 0 and existing["affection"] == 0 and existing["respect"] == 0:
				var r: Dictionary = rels[target_name]
				Relationships.modify(from_name, target_name,
					r.get("trust", 0), r.get("affection", 0), r.get("respect", 0))

	# Load saved memories after all NPCs are in the scene tree
	_load_all_memories()


func _save_all_memories() -> void:
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		var folder: String = "user://npc_data/%s/" % npc.npc_name
		DirAccess.make_dir_recursive_absolute(folder)

		# Save all three tiers via MemorySystem
		npc.memory.save_all()

		# Also save old-format memories.json for backward compat
		var mem_data: Dictionary = npc.memory.serialize()
		var mem_file := FileAccess.open(folder + "memories.json", FileAccess.WRITE)
		if mem_file:
			mem_file.store_string(JSON.stringify(mem_data, "\t"))

		# Human-readable conversation log
		var conversations: Array[Dictionary] = npc.memory.get_by_type("dialogue")
		var conv_file := FileAccess.open(folder + "conversations.json", FileAccess.WRITE)
		if conv_file:
			var conv_list: Array[Dictionary] = []
			for conv: Dictionary in conversations:
				conv_list.append({
					"time": conv.get("game_time", conv.get("timestamp", 0)),
					"with": conv.get("actor", "unknown"),
					"description": conv.get("text", conv.get("description", "")),
					"location": conv.get("observer_location", conv.get("location", "")),
				})
			conv_file.store_string(JSON.stringify(conv_list, "\t"))

		# Human-readable gossip log
		var gossip: Array[Dictionary] = npc.memory.get_by_type("gossip")
		if not gossip.is_empty():
			var gossip_file := FileAccess.open(folder + "gossip_heard.json", FileAccess.WRITE)
			if gossip_file:
				var gossip_list: Array[Dictionary] = []
				for g: Dictionary in gossip:
					gossip_list.append({
						"time": g.get("game_time", g.get("timestamp", 0)),
						"from": g.get("gossip_source", "unknown"),
						"about": g.get("actor", "unknown"),
						"description": g.get("text", g.get("description", "")),
						"hops": g.get("gossip_hops", 0),
					})
				gossip_file.store_string(JSON.stringify(gossip_list, "\t"))

		# Profile snapshot
		var profile_file := FileAccess.open(folder + "profile.json", FileAccess.WRITE)
		if profile_file:
			var profile: Dictionary = {
				"name": npc.npc_name,
				"job": npc.job,
				"age": npc.age,
				"personality": npc.personality,
				"current_location": npc._current_destination,
				"hunger": snapped(npc.hunger, 0.1),
				"energy": snapped(npc.energy, 0.1),
				"social": snapped(npc.social, 0.1),
				"mood": snapped(npc.get_mood(), 0.1),
				"total_memories": npc.memory.episodic_memories.size(),
				"total_conversations": npc.memory.get_by_type("dialogue").size(),
				"total_observations": npc.memory.get_by_type("observation").size(),
				"core_memory_state": npc.memory.core_memory.get("emotional_state", ""),
			}
			profile_file.store_string(JSON.stringify(profile, "\t"))

	Relationships.save_relationships()
	print("[SaveManager] Saved %d NPC data folders to user://npc_data/" % get_tree().get_nodes_in_group("npcs").size())


func _load_all_memories() -> void:
	var loaded_any: bool = false
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		# Try new three-tier format first (episodic_memories.json + core_memory.json)
		var ep_path: String = "user://npc_data/%s/episodic_memories.json" % npc.npc_name
		if FileAccess.file_exists(ep_path):
			npc.memory.load_or_init(npc.npc_name, npc.personality, PlayerProfile.player_name)
			print("[SaveManager] Loaded %d episodic memories for %s" % [
				npc.memory.episodic_memories.size(), npc.npc_name])
			loaded_any = true
			continue

		# Fall back to old memories.json format
		var mem_path: String = "user://npc_data/%s/memories.json" % npc.npc_name
		var file := FileAccess.open(mem_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK:
				npc.memory.deserialize(json.data)
				print("[SaveManager] Loaded + migrated %d memories for %s (old format)" % [
					npc.memory.episodic_memories.size(), npc.npc_name])
				loaded_any = true
				continue

	if loaded_any:
		return

	# Backward compatibility: try old flat format (user://npc_memories.json)
	var old_file := FileAccess.open("user://npc_memories.json", FileAccess.READ)
	if not old_file:
		print("[SaveManager] No saved memories found — fresh start")
		return

	print("[SaveManager] Migrating from old npc_memories.json format...")
	var json := JSON.new()
	if json.parse(old_file.get_as_text()) != OK:
		push_warning("[SaveManager] Failed to parse npc_memories.json")
		return

	var old_data: Dictionary = json.data
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		if old_data.has(npc.npc_name):
			npc.memory.deserialize(old_data[npc.npc_name])
			print("[SaveManager] Migrated %d memories for %s" % [
				npc.memory.episodic_memories.size(), npc.npc_name])


func _on_hour_changed(hour: int) -> void:
	# Daily relationship decay at midnight — all scores drift 1 point toward neutral
	if hour == 0:
		Relationships.decay_all(1)
		if OS.is_debug_build():
			print("[Relationships] Daily decay applied at midnight")
