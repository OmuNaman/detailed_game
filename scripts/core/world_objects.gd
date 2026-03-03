extends Node
## Tracks the state of every interactable object in the world.
## Objects are identified by a unique key: "building_name:tile_type:index"
## Example: "Bakery:oven:0", "House 1:bed:0", "Tavern:counter:1"

# Object registry: {object_id: {state, building, tile_type, grid_pos, user, last_changed}}
var _objects: Dictionary = {}


func register_object(object_id: String, building: String, tile_type: String, grid_pos: Vector2i) -> void:
	_objects[object_id] = {
		"state": "idle",
		"building": building,
		"tile_type": tile_type,
		"grid_pos": grid_pos,
		"user": "",
		"last_changed": 0,
	}


func set_state(object_id: String, new_state: String, user_name: String = "") -> void:
	if not _objects.has(object_id):
		return
	_objects[object_id]["state"] = new_state
	_objects[object_id]["user"] = user_name
	_objects[object_id]["last_changed"] = GameClock.total_minutes
	if OS.is_debug_build():
		print("[WorldObjects] %s -> '%s' (by %s)" % [object_id, new_state, user_name])


func get_state(object_id: String) -> String:
	if not _objects.has(object_id):
		return "unknown"
	return _objects[object_id]["state"]


func get_user(object_id: String) -> String:
	if not _objects.has(object_id):
		return ""
	return _objects[object_id]["user"]


func release_object(object_id: String) -> void:
	## NPC stops using this object — revert to idle.
	if not _objects.has(object_id):
		return
	_objects[object_id]["state"] = "idle"
	_objects[object_id]["user"] = ""


func get_objects_in_building(building: String) -> Array[Dictionary]:
	## Returns all objects in a building with their current states.
	var results: Array[Dictionary] = []
	for obj_id: String in _objects:
		var obj: Dictionary = _objects[obj_id]
		if obj["building"] == building:
			var entry: Dictionary = obj.duplicate()
			entry["id"] = obj_id
			results.append(entry)
	return results


func find_object_for_npc(building: String, tile_type: String, npc_name: String) -> String:
	## Find an available object of a given type in a building.
	## Returns object_id, or "" if none available.
	## Prefers objects already being used by this NPC, then idle ones.
	var best_id: String = ""
	for obj_id: String in _objects:
		var obj: Dictionary = _objects[obj_id]
		if obj["building"] != building or obj["tile_type"] != tile_type:
			continue
		if obj["user"] == npc_name:
			return obj_id
		if obj["state"] == "idle" and best_id == "":
			best_id = obj_id
	return best_id


func get_description(object_id: String) -> String:
	## Human-readable description for memory/perception.
	if not _objects.has(object_id):
		return "unknown object"
	var obj: Dictionary = _objects[object_id]
	var user_str: String = ""
	if obj["user"] != "":
		user_str = " (being used by %s)" % obj["user"]
	return "the %s at the %s is %s%s" % [obj["tile_type"], obj["building"], obj["state"], user_str]
