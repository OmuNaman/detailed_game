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

	# Load/sync memories after all NPCs are in the scene tree
	_load_all_memories()


func _save_all_memories() -> void:
	## Save NPC state. Backend owns memory data (ChromaDB); we just save profile snapshots.
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		var folder: String = "res://data/npc_data/%s/" % npc.npc_name
		DirAccess.make_dir_recursive_absolute(folder)

		# Profile snapshot (always saved locally for debugging)
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
				"total_memories": npc.memory.get_memory_count(),
				"core_memory_state": npc.memory.core_memory.get("emotional_state", ""),
			}
			profile_file.store_string(JSON.stringify(profile, "\t"))

	Relationships.save_relationships()
	print("[SaveManager] Saved %d NPC profiles to res://data/npc_data/" % get_tree().get_nodes_in_group("npcs").size())


func _load_all_memories() -> void:
	## Populate memory cache from backend. Backend (ChromaDB) is the source of truth.
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		# refresh_cache() is already called in npc_controller._ready()
		# Just log the status here
		if OS.is_debug_build():
			print("[SaveManager] %s: memory cache will sync from backend" % npc.npc_name)


func _on_hour_changed(hour: int) -> void:
	# Daily relationship decay at midnight — all scores drift 1 point toward neutral
	if hour == 0:
		Relationships.decay_all(1)
		if OS.is_debug_build():
			print("[Relationships] Daily decay applied at midnight")
