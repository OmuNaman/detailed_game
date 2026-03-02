extends Node2D

const NPC_SCENE: PackedScene = preload("res://scenes/npcs/npc.tscn")


func _ready() -> void:
	var town_map: Node2D = $TownMap
	var player: CharacterBody2D = $Player

	# Position player at the path intersection after map generates
	if town_map.has_method("get_player_spawn_position"):
		player.position = town_map.get_player_spawn_position()

	_spawn_npcs(town_map)


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
