extends Node2D


func _ready() -> void:
	var town_map: Node2D = $TownMap
	var player: CharacterBody2D = $Player

	# Position player at the path intersection after map generates
	if town_map.has_method("get_player_spawn_position"):
		player.position = town_map.get_player_spawn_position()
