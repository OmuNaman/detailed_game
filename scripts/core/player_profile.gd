extends Node
## Stores player identity. Loaded from user://player_profile.json.

var player_name: String = "Newcomer"
var player_home: String = "House 11"
var is_name_set: bool = false


func _ready() -> void:
	_load_profile()


func _load_profile() -> void:
	var file := FileAccess.open("user://player_profile.json", FileAccess.READ)
	if not file:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK:
		player_name = json.data.get("name", "Newcomer")
		player_home = json.data.get("home", "House 11")
		is_name_set = true


func save_profile() -> void:
	var file := FileAccess.open("user://player_profile.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({
			"name": player_name,
			"home": player_home
		}, "\t"))
	is_name_set = true


func set_player_name(new_name: String) -> void:
	player_name = new_name
	save_profile()
