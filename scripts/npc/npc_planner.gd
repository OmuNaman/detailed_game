extends Node
## Stanford 3-level recursive plan decomposition, reaction evaluation, scheduling helpers.

var npc: CharacterBody2D

# 3-Level Planning (Stanford recursive decomposition)
var _plan_level1: Array[Dictionary] = []  # [{start_hour, end_hour, location, activity, decomposed}]
var _plan_level2: Dictionary = {}          # {l1_index: Array[{hour, end_hour, activity}]}
var _plan_level3: Dictionary = {}          # {"l1idx_l2idx": Array[{start_min, end_min, activity}]}
var _last_plan_day: int = -1
var _planning_in_progress: bool = false
var _decomposition_in_progress: bool = false

# Real-time plan re-evaluation (CONTINUE/REACT)
var _last_reaction_eval_time: int = 0
var _reaction_in_progress: bool = false
const REACTION_COOLDOWN_MINUTES: int = 10
const REACTION_IMPORTANCE_THRESHOLD: float = 5.0

# Bug 9: Minimum stay duration at destinations
var dest_arrival_time: int = -1
const MIN_STAY_MINUTES: int = 60

# Random visit tracking
var _next_visit_check: int = 0


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func check_planning_on_load() -> void:
	## Bug 8: Generate plans if game loaded after the normal dawn trigger.
	await get_tree().process_frame
	if GameClock.hour >= 5 and _last_plan_day != npc._get_current_day():
		if OS.is_debug_build():
			print("[Planning] Late trigger for %s (loaded at hour %d)" % [npc.npc_name, GameClock.hour])
		generate_daily_plan()


func generate_daily_plan() -> void:
	## Stanford 3-level planning: generate Level 1 (5-8 full-day activities).
	if _planning_in_progress:
		return

	_planning_in_progress = true
	_last_plan_day = npc._get_current_day()

	if ApiClient.is_available():
		_generate_plan_via_api()
	else:
		_planning_in_progress = false
		_generate_fallback_plan()


func _generate_plan_via_api() -> void:
	# Refresh memory cache for fresh context
	npc.memory.refresh_cache()

	var body: Dictionary = {
		"npc_name": npc.npc_name,
		"npc_state": _build_npc_state(),
		"game_time": _build_game_time(),
		"reflections": _get_recent_reflections(),
		"relationships": _get_relationship_labels(),
		"gossip": _get_recent_gossip(),
		"recent_events": _get_recent_events(),
		"npc_summaries": npc.memory.core_memory.get("npc_summaries", {}),
		"player_name": PlayerProfile.player_name,
		"player_summary": npc.memory.core_memory.get("player_summary", ""),
		"world_description": npc.world_knowledge.describe_known_world(),
	}
	ApiClient.post("/plan/daily", body, func(response: Dictionary, success: bool) -> void:
		_planning_in_progress = false
		if success and response.get("success", false):
			var raw_plans: Array = response.get("plan_level1", [])
			_plan_level1.clear()
			_plan_level2.clear()
			_plan_level3.clear()
			for p: Variant in raw_plans:
				if p is Dictionary:
					_plan_level1.append({
						"start_hour": int(p.get("start_hour", 0)),
						"end_hour": int(p.get("end_hour", 0)),
						"location": str(p.get("location", "")),
						"activity": str(p.get("activity", "")),
						"decomposed": false,
					})
			if _plan_level1.is_empty():
				_generate_fallback_plan()
			elif OS.is_debug_build():
				print("[Planning API] %s's L1 plan (%d blocks)" % [npc.npc_name, _plan_level1.size()])
				for p: Dictionary in _plan_level1:
					print("  %d:00-%d:00 @ %s: %s" % [p["start_hour"], p["end_hour"], p["location"], p["activity"]])
			# Update active goals locally
			if not _plan_level1.is_empty():
				var plan_summary: Array[String] = []
				for p: Dictionary in _plan_level1:
					plan_summary.append("%s at %s (%d:00-%d:00)" % [p["activity"], p["location"], p["start_hour"], p["end_hour"]])
				npc.memory.set_active_goals(plan_summary)
		else:
			_generate_fallback_plan()
	)


func clear_decomposed_plans() -> void:
	_plan_level2.clear()
	_plan_level3.clear()


func tick_decomposition() -> void:
	## Just-in-time L2/L3 decomposition. Called every 5 game minutes from controller.
	if _decomposition_in_progress:
		return
	var l1_idx: int = _get_current_l1_index()
	if l1_idx >= 0 and not _plan_level2.has(l1_idx):
		_decompose_to_level2(l1_idx)
	elif l1_idx >= 0 and _plan_level2.has(l1_idx):
		var l2_steps: Array = _plan_level2[l1_idx]
		for l2_idx: int in range(l2_steps.size()):
			var l2: Dictionary = l2_steps[l2_idx]
			if GameClock.hour >= l2["hour"] and GameClock.hour < l2["end_hour"]:
				var l3_key: String = "%d_%d" % [l1_idx, l2_idx]
				if not _plan_level3.has(l3_key):
					_decompose_to_level3(l1_idx, l2_idx)
				break


func _generate_fallback_plan() -> void:
	## Full-day deterministic plan when backend is unavailable.
	_last_plan_day = npc._get_current_day()
	_plan_level1.clear()
	_plan_level2.clear()
	_plan_level3.clear()

	_plan_level1.append({"start_hour": 5, "end_hour": 6, "location": npc.home_building, "activity": "getting ready for the day", "decomposed": false})
	_plan_level1.append({"start_hour": 6, "end_hour": 12, "location": npc.workplace_building, "activity": "working at the %s" % npc.workplace_building, "decomposed": false})
	_plan_level1.append({"start_hour": 12, "end_hour": 13, "location": npc.home_building, "activity": "lunch break at home", "decomposed": false})
	_plan_level1.append({"start_hour": 13, "end_hour": 16, "location": npc.workplace_building, "activity": "afternoon work", "decomposed": false})

	var friends: Array[String] = Relationships.get_closest_friends(npc.npc_name, 2)
	if not friends.is_empty():
		var friend_wp: String = _get_npc_workplace(friends[0])
		if friend_wp != "" and friend_wp != npc.workplace_building:
			_plan_level1.append({"start_hour": 16, "end_hour": 17, "location": friend_wp, "activity": "visiting %s" % friends[0], "decomposed": false})
			_plan_level1.append({"start_hour": 17, "end_hour": 20, "location": "Tavern", "activity": "evening socializing at the Tavern", "decomposed": false})
		else:
			_plan_level1.append({"start_hour": 16, "end_hour": 20, "location": "Tavern", "activity": "relaxing at the Tavern", "decomposed": false})
	else:
		_plan_level1.append({"start_hour": 16, "end_hour": 20, "location": "Tavern", "activity": "evening socializing", "decomposed": false})

	_plan_level1.append({"start_hour": 20, "end_hour": 22, "location": npc.home_building, "activity": "winding down at home", "decomposed": false})

	if OS.is_debug_build():
		print("[Planning] %s — fallback plan: %d blocks" % [npc.npc_name, _plan_level1.size()])


func _get_npc_workplace(target_name: String) -> String:
	## Look up another NPC's workplace.
	for other_node: Node in npc.get_tree().get_nodes_in_group("npcs"):
		var other: CharacterBody2D = other_node as CharacterBody2D
		if other.npc_name == target_name:
			return other.workplace_building
	return ""


func _decompose_to_level2(l1_index: int) -> void:
	## Break a Level 1 block into hourly steps via API.
	if _decomposition_in_progress or _plan_level2.has(l1_index):
		return
	if l1_index < 0 or l1_index >= _plan_level1.size():
		return

	var l1: Dictionary = _plan_level1[l1_index]
	var duration: int = l1["end_hour"] - l1["start_hour"]

	# Single-hour blocks don't need decomposition
	if duration <= 1:
		_plan_level2[l1_index] = [{
			"hour": l1["start_hour"],
			"end_hour": l1["end_hour"],
			"activity": l1["activity"],
		}]
		return

	_decomposition_in_progress = true

	if ApiClient.is_available():
		var body: Dictionary = {
			"npc_name": npc.npc_name,
			"npc_state": _build_npc_state(),
			"block": {
				"start_hour": l1["start_hour"],
				"end_hour": l1["end_hour"],
				"location": l1["location"],
				"activity": l1["activity"],
			},
			"game_time": _build_game_time(),
		}
		ApiClient.post("/plan/decompose-l2", body, func(response: Dictionary, success: bool) -> void:
			_decomposition_in_progress = false
			if not is_instance_valid(npc):
				return
			if success and response.get("success", false):
				var raw_steps: Array = response.get("steps", [])
				var steps: Array[Dictionary] = []
				for s: Variant in raw_steps:
					if s is Dictionary:
						steps.append({"hour": int(s["hour"]), "end_hour": int(s["end_hour"]), "activity": str(s["activity"])})
				if not steps.is_empty():
					_plan_level2[l1_index] = steps
					if OS.is_debug_build():
						print("[Plan L2 API] %s: Decomposed block %d into %d hourly steps" % [npc.npc_name, l1_index, steps.size()])
					return
			# Fallback: flat hourly blocks
			var fallback: Array[Dictionary] = []
			for h: int in range(l1["start_hour"], l1["end_hour"]):
				fallback.append({"hour": h, "end_hour": h + 1, "activity": l1["activity"]})
			_plan_level2[l1_index] = fallback
		)
	else:
		_decomposition_in_progress = false
		var steps: Array[Dictionary] = []
		for h: int in range(l1["start_hour"], l1["end_hour"]):
			steps.append({"hour": h, "end_hour": h + 1, "activity": l1["activity"]})
		_plan_level2[l1_index] = steps


func _decompose_to_level3(l1_idx: int, l2_idx: int) -> void:
	## Break an hourly L2 step into 5-20 minute actions via API.
	var l3_key: String = "%d_%d" % [l1_idx, l2_idx]
	if _decomposition_in_progress or _plan_level3.has(l3_key):
		return
	if not _plan_level2.has(l1_idx):
		return
	var l2_steps: Array = _plan_level2[l1_idx]
	if l2_idx < 0 or l2_idx >= l2_steps.size():
		return

	var l2: Dictionary = l2_steps[l2_idx]
	var l1: Dictionary = _plan_level1[l1_idx]

	_decomposition_in_progress = true

	if ApiClient.is_available():
		var body: Dictionary = {
			"npc_name": npc.npc_name,
			"npc_state": _build_npc_state(),
			"hour": l2["hour"],
			"location": l1["location"],
			"activity": l2["activity"],
			"game_time": _build_game_time(),
		}
		ApiClient.post("/plan/decompose-l3", body, func(response: Dictionary, success: bool) -> void:
			_decomposition_in_progress = false
			if not is_instance_valid(npc):
				return
			if success and response.get("success", false):
				var raw_steps: Array = response.get("steps", [])
				var steps: Array[Dictionary] = []
				for s: Variant in raw_steps:
					if s is Dictionary:
						steps.append({"start_min": int(s["start_min"]), "end_min": int(s["end_min"]), "activity": str(s["activity"])})
				if not steps.is_empty():
					_plan_level3[l3_key] = steps
					if OS.is_debug_build():
						print("[Plan L3 API] %s: Decomposed L2[%d][%d] into %d fine actions" % [npc.npc_name, l1_idx, l2_idx, steps.size()])
					return
			_plan_level3[l3_key] = [{"start_min": 0, "end_min": 60, "activity": l2["activity"]}]
		)
	else:
		_decomposition_in_progress = false
		_plan_level3[l3_key] = [{"start_min": 0, "end_min": 60, "activity": l2["activity"]}]


func evaluate_reaction(observation: String, importance: float) -> void:
	## Evaluate whether the NPC should react to a significant observation by replanning.
	if _reaction_in_progress or _decomposition_in_progress or _planning_in_progress:
		return
	var current_time: int = GameClock.total_minutes
	if current_time - _last_reaction_eval_time < REACTION_COOLDOWN_MINUTES:
		return
	if GameClock.hour >= 23 or GameClock.hour < 5:
		return

	_last_reaction_eval_time = current_time
	_reaction_in_progress = true

	var active_plan: Dictionary = get_current_plan()
	var current_activity_text: String = active_plan.get("reason", npc.current_activity) if not active_plan.is_empty() else npc.current_activity

	if not ApiClient.is_available():
		_reaction_in_progress = false
		return

	var body: Dictionary = {
		"npc_name": npc.npc_name,
		"npc_state": _build_npc_state(),
		"observation": observation,
		"importance": importance,
		"current_activity": current_activity_text,
		"current_destination": npc._current_destination,
		"game_time": _build_game_time(),
	}
	ApiClient.post("/plan/react", body, func(response: Dictionary, success: bool) -> void:
		_reaction_in_progress = false
		if not is_instance_valid(npc):
			return
		if success and response.get("action", "CONTINUE") == "REACT":
			var location: String = response.get("new_location", npc._current_destination)
			var activity: String = response.get("new_activity", "reacting to event")
			# Override the current L1 block
			var l1_idx: int = _get_current_l1_index()
			if l1_idx >= 0:
				_plan_level1[l1_idx]["location"] = location
				_plan_level1[l1_idx]["activity"] = activity
				_plan_level2.erase(l1_idx)
				var keys_to_erase: Array[String] = []
				for key: String in _plan_level3.keys():
					if key.begins_with(str(l1_idx) + "_"):
						keys_to_erase.append(key)
				for key: String in keys_to_erase:
					_plan_level3.erase(key)
			npc._update_destination(GameClock.hour)
			if OS.is_debug_build():
				print("[Reaction API] %s: REACT — redirecting to %s for '%s'" % [npc.npc_name, location, activity])
		elif OS.is_debug_build():
			print("[Reaction API] %s: CONTINUE" % npc.npc_name)
	)


func get_active_plan_destination(hour: int) -> String:
	## Check if any L1 plan block covers the current hour.
	for plan: Dictionary in _plan_level1:
		if hour >= plan["start_hour"] and hour < plan["end_hour"]:
			return plan["location"]
	return ""


func _get_current_l1_index() -> int:
	## Find the Level 1 plan block index for the current hour. Returns -1 if none.
	var hour: int = GameClock.hour
	for i: int in range(_plan_level1.size()):
		var plan: Dictionary = _plan_level1[i]
		if hour >= plan["start_hour"] and hour < plan["end_hour"]:
			return i
	return -1


func get_current_plan() -> Dictionary:
	## Returns the most granular active plan for the current time.
	## Cascade: L3 -> L2 -> L1. Returns {destination, reason, hour, end_hour}.
	var hour: int = GameClock.hour
	var minute: int = GameClock.minute
	var l1_idx: int = _get_current_l1_index()
	if l1_idx < 0:
		return {}

	var l1: Dictionary = _plan_level1[l1_idx]

	# Check Level 3 (most granular: 5-20min blocks)
	if _plan_level2.has(l1_idx):
		var l2_steps: Array = _plan_level2[l1_idx]
		for l2_idx: int in range(l2_steps.size()):
			var l2: Dictionary = l2_steps[l2_idx]
			if hour >= l2["hour"] and hour < l2["end_hour"]:
				var l3_key: String = "%d_%d" % [l1_idx, l2_idx]
				if _plan_level3.has(l3_key):
					var l3_steps: Array = _plan_level3[l3_key]
					for l3: Dictionary in l3_steps:
						if minute >= l3["start_min"] and minute < l3["end_min"]:
							return {
								"destination": l1["location"],
								"reason": l3["activity"],
								"hour": l2["hour"],
								"end_hour": l2["end_hour"],
							}
				# Fall through to L2
				return {
					"destination": l1["location"],
					"reason": l2["activity"],
					"hour": l2["hour"],
					"end_hour": l2["end_hour"],
				}

	# Fall through to L1
	return {
		"destination": l1["location"],
		"reason": l1["activity"],
		"hour": l1["start_hour"],
		"end_hour": l1["end_hour"],
	}


func wants_to_visit(building: String, _hour: int) -> bool:
	## Returns true occasionally based on personality.
	if GameClock.total_minutes < _next_visit_check:
		return false
	_next_visit_check = GameClock.total_minutes + 60
	if building == "Church" and npc.workplace_building != "Church":
		if randf() < 0.10:
			return true
	return false


# --- API request helpers ---

func _build_npc_state() -> Dictionary:
	return {
		"npc_name": npc.npc_name,
		"job": npc.job,
		"age": npc.age,
		"personality": npc.personality,
		"speech_style": npc.speech_style,
		"home_building": npc.home_building,
		"workplace_building": npc.workplace_building,
		"current_destination": npc._current_destination,
		"current_activity": npc.current_activity,
		"needs": {
			"hunger": npc.needs.hunger,
			"energy": npc.needs.energy,
			"social": npc.needs.social,
		},
		"game_time": GameClock.total_minutes,
		"game_hour": GameClock.hour,
		"game_minute": GameClock.minute,
		"game_day": npc._get_current_day(),
		"game_season": "Spring",
	}


func _build_game_time() -> Dictionary:
	return {
		"total_minutes": GameClock.total_minutes,
		"hour": GameClock.hour,
		"minute": GameClock.minute,
		"day": npc._get_current_day(),
		"season": "Spring",
	}


func _get_recent_reflections() -> Array:
	var result: Array = []
	var reflections: Array[Dictionary] = npc.memory.get_by_type("reflection")
	reflections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("game_time", 0) > b.get("game_time", 0)
	)
	for ref: Dictionary in reflections.slice(0, mini(3, reflections.size())):
		result.append(ref.get("description", ""))
	return result


func _get_relationship_labels() -> Dictionary:
	var result: Dictionary = {}
	var all_rels: Dictionary = Relationships.get_all_for(npc.npc_name)
	for target: String in all_rels:
		result[target] = Relationships.get_opinion_label(npc.npc_name, target)
	return result


func _get_recent_gossip() -> Array:
	var result: Array = []
	var gossip_mems: Array[Dictionary] = npc.memory.get_by_type("gossip")
	gossip_mems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("game_time", 0) > b.get("game_time", 0)
	)
	for g: Dictionary in gossip_mems.slice(0, mini(3, gossip_mems.size())):
		result.append(g.get("description", ""))
	return result


func _get_recent_events() -> Array:
	var result: Array = []
	var recent: Array[Dictionary] = npc.memory.get_recent(5)
	for mem: Dictionary in recent:
		result.append(mem.get("description", ""))
	return result
