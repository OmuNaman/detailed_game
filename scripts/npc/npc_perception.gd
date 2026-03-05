extends Node
## Handles NPC perception: body entered observations, periodic area scans, environment scans, arrival checks.

var npc: CharacterBody2D

var _observation_cooldowns: Dictionary = {}  # {actor_name: last_observed_game_minute}
const OBSERVATION_COOLDOWN_MINUTES: int = 60

var _last_environment_scan: int = -120  # Start cold so first scan triggers
const ENVIRONMENT_SCAN_INTERVAL: int = 30  # Every 30 game minutes


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func on_perception_body_entered(body: Node2D) -> void:
	if body == npc:
		return
	if not (body is CharacterBody2D):
		return
	# Skip NPC observations during conversation (still notice player)
	if npc.in_conversation and body.is_in_group("npcs"):
		return

	var actor_name: String = ""
	if body.is_in_group("player"):
		actor_name = PlayerProfile.player_name
	elif body.is_in_group("npcs"):
		actor_name = body.npc_name
	else:
		return

	# Cooldown: don't re-observe same actor within 60 game minutes
	var current_time: int = GameClock.total_minutes
	if _observation_cooldowns.has(actor_name):
		if current_time - _observation_cooldowns[actor_name] < OBSERVATION_COOLDOWN_MINUTES:
			return
	_observation_cooldowns[actor_name] = current_time

	# Determine where the observed entity actually is (not where WE are)
	var observed_location: String = estimate_location(body.global_position)
	var my_location: String = npc._current_destination

	var importance: float = 2.0  # Default for NPC sightings
	var valence: float = 0.0     # Neutral
	if body.is_in_group("player"):
		importance = 5.0
		valence = 0.1  # Slightly positive — player is interesting

	# Include the observed NPC's current activity and object state in the description
	var description: String = ""
	if body.is_in_group("npcs") and "current_activity" in body and body.current_activity != "":
		var other_object_id: String = body._current_object_id if "_current_object_id" in body else ""
		if other_object_id != "":
			var obj_state: String = WorldObjects.get_state(other_object_id)
			description = "Saw %s %s near the %s" % [actor_name, body.current_activity, observed_location]
			if obj_state != "idle" and obj_state != "unknown":
				description += " (the %s was %s)" % [
					other_object_id.get_slice(":", 1),
					obj_state
				]
		else:
			description = "Saw %s %s near the %s" % [actor_name, body.current_activity, observed_location]
	else:
		description = "Saw %s near the %s" % [actor_name, observed_location]

	# Create memory with async embedding
	npc._add_memory_with_embedding(description, "observation", actor_name,
		[npc.npc_name, actor_name] as Array[String], my_location, observed_location, importance, valence)

	# Evaluate reaction for significant observations
	if importance >= npc.planner.REACTION_IMPORTANCE_THRESHOLD:
		npc.planner.evaluate_reaction(description, importance)


func estimate_location(pos: Vector2) -> String:
	## Returns the name of the nearest building to a world position.
	var closest_name: String = "town center"
	var closest_dist: float = INF
	for bld_name: String in npc._building_positions:
		var bld_pos: Vector2 = npc._building_positions[bld_name]
		var dist: float = pos.distance_to(bld_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_name = bld_name
	return closest_name


func scan_perception_area() -> void:
	## Re-check bodies already inside PerceptionArea. Cooldowns prevent duplicates.
	var perception_area: Area2D = npc.get_node("PerceptionArea")
	for body: Node2D in perception_area.get_overlapping_bodies():
		on_perception_body_entered(body)


func scan_environment() -> void:
	## Perceive object states in the current building.
	## Creates memories about notable states: active objects, empty workstations, etc.

	# Bug 1: Don't scan while sleeping
	if npc.current_activity.begins_with("sleeping"):
		return

	if npc.in_conversation:
		return

	if GameClock.total_minutes - _last_environment_scan < ENVIRONMENT_SCAN_INTERVAL:
		return
	_last_environment_scan = GameClock.total_minutes

	if npc._current_destination == "" or npc._is_moving:
		return

	var objects: Array[Dictionary] = WorldObjects.get_objects_in_building(npc._current_destination)
	if objects.is_empty():
		return

	var notable: Array[String] = []

	for obj: Dictionary in objects:
		var obj_type: String = obj["tile_type"]
		var state: String = obj["state"]
		var user: String = obj["user"]

		if state == "idle" or state == "unknown":
			# Notable if this is a work object that SHOULD be active during work hours
			if _is_work_hours() and _is_workplace_object(obj_type):
				if user == "":
					notable.append("the %s at the %s was idle" % [obj_type, npc._current_destination])
			continue

		# Active objects — always notable if someone else is using them
		if user != "" and user != npc.npc_name:
			notable.append("%s was using the %s (%s)" % [user, obj_type, state])
		elif user == npc.npc_name:
			continue
		else:
			# Object is in a non-idle state but no user — interesting
			notable.append("the %s was %s" % [obj_type, state])

	# Create at most 2 environment memories per scan (avoid spam)
	var count: int = 0
	for observation: String in notable:
		if count >= 2:
			break

		var description: String = "Noticed %s at the %s" % [observation, npc._current_destination]

		npc._add_memory_with_embedding(
			description,
			"environment",
			"",
			[npc.npc_name] as Array[String],
			npc._current_destination,
			npc._current_destination,
			2.5,
			0.0
		)
		count += 1

	if count > 0 and OS.is_debug_build():
		print("[EnvScan] %s noticed %d things at %s" % [npc.npc_name, count, npc._current_destination])

	npc.world_knowledge.update_known_object_states()


func on_arrive_at_building() -> void:
	## Check building state on arrival: abandoned objects, empty workplaces.
	var objects: Array[Dictionary] = WorldObjects.get_objects_in_building(npc._current_destination)

	# Check if any work objects are active with no users (someone left something running)
	for obj: Dictionary in objects:
		if obj["state"] != "idle" and obj["user"] == "":
			var desc: String = "Arrived at the %s and found the %s was %s with nobody around" % [
				npc._current_destination, obj["tile_type"], obj["state"]
			]
			npc._add_memory_with_embedding(
				desc, "environment", "", [npc.npc_name] as Array[String],
				npc._current_destination, npc._current_destination, 4.0, -0.1
			)
			if OS.is_debug_build():
				print("[EnvScan] %s: %s" % [npc.npc_name, desc])

	# Check if workplace is empty during work hours (coworker missing)
	if npc._current_destination == npc.workplace_building and _is_work_hours():
		var coworkers_present: bool = false
		for npc_node: Node in npc.get_tree().get_nodes_in_group("npcs"):
			if npc_node == npc:
				continue
			var other: CharacterBody2D = npc_node as CharacterBody2D
			if other.workplace_building == npc.workplace_building and other._current_destination == npc.workplace_building:
				coworkers_present = true
				break

		# Only note if there SHOULD be coworkers (some workplaces are solo)
		var expected_coworkers: bool = npc.workplace_building in ["Blacksmith", "Tavern", "Church", "Courthouse", "General Store"]
		if expected_coworkers and not coworkers_present:
			# Once per day — use observation cooldown to prevent spam
			var today: int = GameClock.total_minutes / 1440
			var check_key: String = "empty_%s_%d" % [npc.workplace_building, today]
			if not _observation_cooldowns.has(check_key):
				_observation_cooldowns[check_key] = GameClock.total_minutes
				var desc: String = "The %s was empty when I arrived for work" % npc.workplace_building
				npc._add_memory_with_embedding(
					desc, "environment", "", [npc.npc_name] as Array[String],
					npc._current_destination, npc._current_destination, 3.0, -0.1
				)


func _is_work_hours() -> bool:
	return GameClock.hour >= 6 and GameClock.hour < 17


func _is_workplace_object(tile_type: String) -> bool:
	## Is this the kind of object that should be in use during work hours?
	return tile_type in ["oven", "anvil", "counter", "desk", "altar"]
