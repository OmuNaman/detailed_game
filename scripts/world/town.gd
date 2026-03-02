extends Node2D

const NPC_SCENE: PackedScene = preload("res://scenes/npcs/npc.tscn")


func _ready() -> void:
	var town_map: Node2D = $TownMap
	var player: CharacterBody2D = $Player

	# Position player at the path intersection after map generates
	if town_map.has_method("get_player_spawn_position"):
		player.position = town_map.get_player_spawn_position()

	_spawn_npcs(town_map)


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

	# Load saved memories after all NPCs are in the scene tree
	_load_all_memories()


func _save_all_memories() -> void:
	var save_data: Dictionary = {}
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		save_data[npc.npc_name] = npc.memory.serialize()

	var json_string: String = JSON.stringify(save_data, "\t")
	var save_file := FileAccess.open("user://npc_memories.json", FileAccess.WRITE)
	if save_file:
		save_file.store_string(json_string)
		print("[SaveManager] Saved %d NPC memory streams" % save_data.size())
	else:
		push_warning("[SaveManager] Failed to open npc_memories.json for writing")


func _load_all_memories() -> void:
	var save_file := FileAccess.open("user://npc_memories.json", FileAccess.READ)
	if not save_file:
		print("[SaveManager] No saved memories found — fresh start")
		return

	var json := JSON.new()
	var err: Error = json.parse(save_file.get_as_text())
	if err != OK:
		push_warning("[SaveManager] Failed to parse npc_memories.json")
		return

	var save_data: Dictionary = json.data
	for npc: CharacterBody2D in get_tree().get_nodes_in_group("npcs"):
		if save_data.has(npc.npc_name):
			npc.memory.deserialize(save_data[npc.npc_name])
			print("[SaveManager] Loaded %d memories for %s" % [
				npc.memory.memories.size(), npc.npc_name])
