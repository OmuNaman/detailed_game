extends Node
## Manages the NPC's known-world subgraph: which buildings they've visited and what's inside.

var npc: CharacterBody2D

# Static hierarchical world model: Building → Area → Objects (matches town_generator.gd)
const WORLD_TREE: Dictionary = {
	"Bakery": {"Kitchen": ["oven"], "Front": ["counter", "counter"]},
	"General Store": {"Shelves": ["shelf", "shelf", "shelf"], "Counter Area": ["counter", "counter"]},
	"Tavern": {"Bar": ["counter", "counter", "counter", "counter", "barrel", "barrel"], "Seating": ["table", "table"]},
	"Church": {"Altar Area": ["altar", "altar", "altar"], "Pews": ["pew", "pew", "pew", "pew", "pew", "pew", "pew", "pew"]},
	"Sheriff Office": {"Office": ["desk", "desk", "shelf"]},
	"Courthouse": {"Clerk Area": ["desk", "desk", "desk"], "Gallery": ["pew", "pew", "pew"]},
	"Blacksmith": {"Forge": ["anvil", "barrel", "shelf"]},
}
const HOUSE_TREE: Dictionary = {"Bedroom": ["bed"], "Living Area": ["shelf", "table"]}

# Per-NPC known world subgraph (buildings the NPC has visited)
var _known_world: Dictionary = {}  # {building_name: {area_name: [object_types]}}


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func init_known_world() -> void:
	## Seed known world with home and workplace buildings.
	learn_building(npc.home_building)
	if npc.workplace_building != "" and npc.workplace_building != npc.home_building:
		learn_building(npc.workplace_building)


func learn_building(building_name: String) -> void:
	## Add a building to this NPC's known world from the static tree.
	if _known_world.has(building_name):
		return
	var tree_entry: Dictionary = {}
	if WORLD_TREE.has(building_name):
		tree_entry = WORLD_TREE[building_name]
	elif building_name.begins_with("House"):
		tree_entry = HOUSE_TREE
	else:
		return
	_known_world[building_name] = tree_entry.duplicate(true)
	if OS.is_debug_build():
		print("[World] %s learned layout of %s" % [npc.npc_name, building_name])


func update_known_object_states() -> void:
	## Sync known_world entries with actual object states from WorldObjects.
	if not _known_world.has(npc._current_destination):
		return
	var objects: Array[Dictionary] = WorldObjects.get_objects_in_building(npc._current_destination)
	# Store observed states for prompt enrichment
	for obj: Dictionary in objects:
		if obj["state"] != "idle" and obj["state"] != "unknown":
			var key: String = "%s:%s" % [npc._current_destination, obj["tile_type"]]
			_known_world[key] = obj["state"]


func describe_known_world() -> String:
	## Compact summary of known buildings and areas for prompt context.
	var parts: Array[String] = []
	for bld_name: String in _known_world:
		if ":" in bld_name:
			continue  # Skip object state entries
		var tree: Variant = _known_world[bld_name]
		if tree is Dictionary:
			var areas: Array[String] = []
			for area_name: String in tree:
				areas.append(area_name)
			parts.append("%s (%s)" % [bld_name, ", ".join(areas)])
		else:
			parts.append(bld_name)
	if parts.is_empty():
		return ""
	return "Places you know: %s" % "; ".join(parts)
