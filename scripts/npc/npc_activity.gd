extends Node
## Manages NPC activity display, work objects, visual state (sleep/work tint), and activity label.

var npc: CharacterBody2D

var _current_object_id: String = ""  # WorldObjects ID of furniture in use
var current_activity: String = ""    # Human-readable: "kneading dough at the oven"
var _activity_emoji: String = ""     # Simple symbol above head
var _activity_label: Label = null
var _awake_texture: Texture2D = null
var _sleep_texture: Texture2D = null
var _is_visually_sleeping: bool = false

# Job-to-furniture mappings
const JOB_WORK_OBJECTS: Dictionary = {
	"Baker": "oven",
	"Shopkeeper": "counter",
	"Sheriff": "desk",
	"Priest": "altar",
	"Blacksmith": "anvil",
	"Tavern Owner": "counter",
	"Farmer": "counter",
	"Herbalist": "pew",
	"Retired": "table",
	"Apprentice Blacksmith": "anvil",
	"Scholar": "desk",
}

const JOB_OBJECT_STATES: Dictionary = {
	"Baker": "baking",
	"Shopkeeper": "serving customers",
	"Sheriff": "on duty",
	"Priest": "conducting service",
	"Blacksmith": "forging",
	"Tavern Owner": "serving drinks",
	"Farmer": "delivering produce",
	"Herbalist": "preparing remedies",
	"Retired": "occupied",
	"Apprentice Blacksmith": "forging",
	"Scholar": "studying records",
}


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func init_visuals() -> void:
	## Called from controller _ready() after sprite is loaded.
	_awake_texture = npc.sprite.texture

	# Load sleeping variant (same path but _sleep instead of _down)
	var sleep_path: String = npc.sprite_path.replace("_down.png", "_sleep.png")
	if ResourceLoader.exists(sleep_path):
		_sleep_texture = load(sleep_path)

	# Activity label (floating emoji above sprite)
	_activity_label = Label.new()
	_activity_label.name = "ActivityLabel"
	_activity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_activity_label.position = Vector2(-64, -42)
	_activity_label.custom_minimum_size = Vector2(128, 0)
	_activity_label.add_theme_font_size_override("font_size", 8)
	_activity_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.7))
	_activity_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_activity_label.add_theme_constant_override("outline_size", 2)
	npc.add_child(_activity_label)


func claim_work_object() -> void:
	## Find and claim the appropriate furniture object at the current building.
	release_current_object()

	var target_type: String = get_target_furniture_type(npc._current_destination)
	if target_type == "":
		return

	var obj_id: String = WorldObjects.find_object_for_npc(npc._current_destination, target_type, npc.npc_name)
	if obj_id == "":
		return

	_current_object_id = obj_id

	var state_str: String = "in use"
	if npc._current_destination == npc.workplace_building:
		state_str = JOB_OBJECT_STATES.get(npc.job, "in use")
	elif target_type == "bed":
		state_str = "occupied"
	elif target_type == "table":
		state_str = "dining"
	elif target_type == "pew":
		state_str = "occupied"

	WorldObjects.set_state(obj_id, state_str, npc.npc_name)


func release_current_object() -> void:
	## Release whatever object we're currently using.
	if _current_object_id != "":
		WorldObjects.release_object(_current_object_id)
		_current_object_id = ""


func get_target_furniture_type(destination: String) -> String:
	## What furniture should the NPC go to at this destination?
	if destination == npc.workplace_building:
		return JOB_WORK_OBJECTS.get(npc.job, "")
	if destination == npc.home_building:
		if GameClock.hour >= 22 or GameClock.hour < 6:
			return "bed"
		if GameClock.hour in [7, 12, 19]:
			return "table"
	if destination == "Tavern" and destination != npc.workplace_building:
		return "table"
	if destination == "Church" and destination != npc.workplace_building:
		return "pew"
	return ""


func update_activity() -> void:
	## Recompute current_activity based on location, time, object, and needs.
	if npc._is_moving:
		current_activity = "walking to the %s" % npc._current_destination
		_activity_emoji = "..."
		_update_activity_label()
		return

	if npc._current_destination == "":
		current_activity = "standing around"
		_activity_emoji = "..."
		_update_activity_label()
		return

	# Check if current destination is from a plan
	# Bug 5: Only show plan text if actually at the plan destination
	var active_plan: Dictionary = npc.planner.get_current_plan()
	if not active_plan.is_empty():
		if npc._current_destination == active_plan.get("destination", ""):
			current_activity = active_plan.get("reason", "visiting")
			_activity_emoji = "!"
			_update_activity_label()
			update_visual_state()
			return

	var hour: int = GameClock.hour

	# At home
	if npc._current_destination == npc.home_building:
		if hour >= 22 or hour < 5:
			current_activity = "sleeping in bed"
			_activity_emoji = "Zzz"
		elif hour >= 5 and hour < 6:
			current_activity = "getting ready for the day"
			_activity_emoji = "!"
		elif hour in [7, 12, 19]:
			current_activity = "eating a meal at the table"
			_activity_emoji = "~"
		else:
			current_activity = "resting at home"
			_activity_emoji = "~"
		_update_activity_label()
		return

	# At workplace
	if npc._current_destination == npc.workplace_building:
		current_activity = _get_work_activity()
		_activity_emoji = _get_work_emoji()
		_update_activity_label()
		return

	# At Tavern (socializing)
	if npc._current_destination == "Tavern" and npc._current_destination != npc.workplace_building:
		if hour >= 17:
			current_activity = "having drinks at the Tavern"
		else:
			current_activity = "relaxing at the Tavern"
		_activity_emoji = "~"
		_update_activity_label()
		return

	# Visiting Church
	if npc._current_destination == "Church" and npc._current_destination != npc.workplace_building:
		current_activity = "praying quietly in the Church"
		_activity_emoji = "..."
		_update_activity_label()
		return

	# Fallback
	current_activity = "at the %s" % npc._current_destination
	_activity_emoji = "..."
	_update_activity_label()


func _get_work_activity() -> String:
	## Returns a specific activity string based on job and time of day.
	match npc.job:
		"Baker":
			if GameClock.hour < 10:
				return "kneading dough at the oven"
			elif GameClock.hour < 14:
				return "baking bread in the oven"
			else:
				return "serving fresh bread at the counter"
		"Shopkeeper":
			if GameClock.hour < 9:
				return "opening up the General Store"
			else:
				return "minding the shop at the counter"
		"Sheriff":
			if GameClock.hour < 10:
				return "reviewing reports at the desk"
			else:
				return "keeping watch from the Sheriff Office"
		"Priest":
			if GameClock.hour < 9:
				return "preparing the morning service at the altar"
			elif GameClock.hour < 12:
				return "conducting the morning service"
			else:
				return "tending to the Church"
		"Blacksmith":
			return "hammering metal at the anvil"
		"Tavern Owner":
			if GameClock.hour < 15:
				return "cleaning up the Tavern"
			else:
				return "serving drinks at the counter"
		"Farmer":
			if GameClock.hour < 10:
				return "delivering produce to the General Store"
			else:
				return "stocking shelves at the General Store"
		"Herbalist":
			return "preparing herbal remedies in the Church"
		"Retired":
			return "nursing a drink at the Tavern"
		"Apprentice Blacksmith":
			if GameClock.hour < 12:
				return "learning to forge at the anvil"
			else:
				return "practicing hammer work at the anvil"
		"Scholar":
			if GameClock.hour < 12:
				return "studying old records at the desk"
			else:
				return "writing in the town ledger at the desk"
	return "working at the %s" % npc.workplace_building


func _get_work_emoji() -> String:
	match npc.job:
		"Baker": return "*"
		"Shopkeeper": return "$"
		"Sheriff": return "!"
		"Priest": return "+"
		"Blacksmith": return "#"
		"Tavern Owner": return "~"
		"Farmer": return "%"
		"Herbalist": return "&"
		"Retired": return "~"
		"Apprentice Blacksmith": return "#"
		"Scholar": return "?"
	return "..."


func _update_activity_label() -> void:
	if _activity_label:
		_activity_label.text = _activity_emoji
	update_visual_state()


func update_visual_state() -> void:
	## Swap sprite texture based on current activity (sleeping/working/idle).
	var should_sleep: bool = current_activity == "sleeping in bed"

	if should_sleep and not _is_visually_sleeping and _sleep_texture:
		npc.sprite.texture = _sleep_texture
		npc.sprite.modulate = Color(0.7, 0.7, 0.9, 1.0)  # Slight blue tint when sleeping
		_is_visually_sleeping = true
	elif not should_sleep and _is_visually_sleeping and _awake_texture:
		npc.sprite.texture = _awake_texture
		npc.sprite.modulate = Color.WHITE
		_is_visually_sleeping = false

	# Subtle work tint when actively using a furniture object
	if not _is_visually_sleeping:
		if _current_object_id != "" and not npc._is_moving:
			npc.sprite.modulate = Color(1.0, 0.97, 0.93, 1.0)
		else:
			npc.sprite.modulate = Color.WHITE
