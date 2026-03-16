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
	if not GeminiClient.has_api_key():
		_generate_fallback_plan()
		return

	_planning_in_progress = true
	_last_plan_day = npc._get_current_day()

	var system_prompt: String = _build_level1_prompt()
	var user_message: String = _build_planning_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		_planning_in_progress = false

		if not success or text == "":
			print("[Planning] %s — Gemini failed, using fallback plan" % npc.npc_name)
			_generate_fallback_plan()
			return

		_plan_level1 = _parse_level1_plan(text)
		_plan_level2.clear()
		_plan_level3.clear()

		# Store plan as a memory + update core memory active goals
		if not _plan_level1.is_empty():
			var plan_summary: Array[String] = []
			for p: Dictionary in _plan_level1:
				plan_summary.append("%s at %s (%d:00-%d:00)" % [p["activity"], p["location"], p["start_hour"], p["end_hour"]])
			var plan_desc: String = "My plans for today: %s" % ", ".join(plan_summary)
			npc._add_memory_with_embedding(
				plan_desc, "plan", npc.npc_name, [npc.npc_name] as Array[String],
				npc.home_building, npc.home_building, 4.0, 0.1
			)
			npc.memory.set_active_goals(plan_summary)

		if OS.is_debug_build():
			print("[Planning] %s's L1 plan (%d blocks):" % [npc.npc_name, _plan_level1.size()])
			for p: Dictionary in _plan_level1:
				print("  %d:00-%d:00 @ %s: %s" % [p["start_hour"], p["end_hour"], p["location"], p["activity"]])
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
	## Full-day deterministic plan when Gemini is unavailable.
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


func _get_npc_roster_text() -> String:
	## Data-driven NPC roster — includes NPCs this NPC knows (colleagues, neighbors, relationships).
	var known_names: Dictionary = {}
	# Always include workplace colleagues and housemates
	for other: Node in npc.get_tree().get_nodes_in_group("npcs"):
		var o: CharacterBody2D = other as CharacterBody2D
		if o == npc:
			continue
		if o.workplace_building == npc.workplace_building or o.home_building == npc.home_building:
			known_names[o.npc_name] = o
	# Include NPCs with non-zero relationships
	var all_rels: Dictionary = Relationships.get_all_for(npc.npc_name)
	for rel_name: String in all_rels:
		for other: Node in npc.get_tree().get_nodes_in_group("npcs"):
			var o: CharacterBody2D = other as CharacterBody2D
			if o.npc_name == rel_name:
				known_names[o.npc_name] = o
				break
	# Cap at 20 to keep prompt manageable
	var text: String = "People you know in town:\n"
	var count: int = 0
	for n: String in known_names:
		if count >= 20:
			break
		var o: CharacterBody2D = known_names[n]
		text += "- %s: %s, works at %s\n" % [o.npc_name, o.job, o.workplace_building]
		count += 1
	text += "\nIMPORTANT: Only reference people from this list. Do NOT invent names.\n"
	return text


func _build_level1_prompt() -> String:
	## System prompt for Level 1 planning: full-day 5-8 activity blocks.
	var prompt: String = "You are %s, a %d-year-old %s in DeepTown. %s\n\n" % [npc.npc_name, npc.age, npc.job, npc.personality]
	prompt += "Plan your FULL day from waking (hour 5) to sleeping (hour 22). "
	prompt += "Generate 5-8 activity blocks covering every hour of your day.\n\n"
	prompt += "Your workplace: %s (you typically work there from 6-15)\n" % npc.workplace_building
	prompt += "Your home: %s\n\n" % npc.home_building
	prompt += "Available buildings: Bakery, General Store, Tavern, Church, Sheriff Office, Courthouse, Blacksmith, Library, Inn, Market, Carpenter Workshop, Tailor Shop, Stables, Clinic, School\n\n"
	prompt += _get_npc_roster_text()
	prompt += "\nFormat each block as: START-END|LOCATION|ACTIVITY (one per line)\n"
	prompt += "Example:\n"
	prompt += "5-6|%s|Wake up, have breakfast\n" % npc.home_building
	prompt += "6-12|%s|Morning work at the %s\n" % [npc.workplace_building, npc.workplace_building]
	prompt += "12-13|%s|Lunch break at home\n" % npc.home_building
	prompt += "13-16|%s|Afternoon work\n" % npc.workplace_building
	prompt += "16-17|Tavern|Visit Rose for a drink and catch up\n"
	prompt += "17-20|Tavern|Evening socializing\n"
	prompt += "20-22|%s|Dinner and winding down\n\n" % npc.home_building
	prompt += "Rules:\n"
	prompt += "- Cover hours 5-22 with NO gaps\n"
	prompt += "- Usually include meals at home (hours 7, 12, 19), UNLESS you have a special event, party, or gathering to attend\n"
	prompt += "- PRIORITIZE attending events, festivals, or gatherings you have heard about — these are more important than routine\n"
	prompt += "- Be specific about WHO and WHY for social visits\n"
	prompt += "- Make today different based on your feelings and relationships\n"
	prompt += "- Include at least one social visit outside your workplace\n"
	prompt += "- Do NOT plan past hour 22"
	return prompt


func _build_planning_context() -> String:
	var context: String = ""

	# Yesterday's reflections
	var reflections: Array[Dictionary] = npc.memory.get_by_type("reflection")
	if not reflections.is_empty():
		reflections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "Your recent thoughts:\n"
		for ref: Dictionary in reflections.slice(0, mini(3, reflections.size())):
			context += "- %s\n" % ref.get("description", "")
		context += "\n"

	# Key relationships
	var all_rels: Dictionary = Relationships.get_all_for(npc.npc_name)
	if not all_rels.is_empty():
		context += "Your relationships:\n"
		for target: String in all_rels:
			var label: String = Relationships.get_opinion_label(npc.npc_name, target)
			context += "- You %s %s\n" % [label, target]
		context += "\n"

	# Recent gossip (what you've heard)
	var gossip_mems: Array[Dictionary] = npc.memory.get_by_type("gossip")
	if not gossip_mems.is_empty():
		gossip_mems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "Things you've heard recently:\n"
		for g: Dictionary in gossip_mems.slice(0, mini(3, gossip_mems.size())):
			context += "- %s\n" % g.get("description", "")
		context += "\n"

	# Recent notable events
	var recent: Array[Dictionary] = npc.memory.get_recent(10)
	if not recent.is_empty():
		context += "Recent events:\n"
		for mem: Dictionary in recent:
			context += "- %s\n" % mem.get("description", "")
		context += "\n"

	# Core memory: what I know about specific people
	var plan_npc_summaries: Dictionary = npc.memory.core_memory.get("npc_summaries", {})
	if not plan_npc_summaries.is_empty():
		context += "What you know about people:\n"
		for summ_name: String in plan_npc_summaries:
			context += "- %s: %s\n" % [summ_name, plan_npc_summaries[summ_name]]
		context += "\n"

	var plan_player_summary: String = npc.memory.core_memory.get("player_summary", "")
	if plan_player_summary != "" and not plan_player_summary.begins_with("I haven't met"):
		context += "About %s: %s\n\n" % [PlayerProfile.player_name, plan_player_summary]

	var world_desc: String = npc.world_knowledge.describe_known_world()
	if world_desc != "":
		context += "%s\n\n" % world_desc

	context += "Plan your full day (5-8 blocks from hour 5 to 22). Format: START-END|LOCATION|ACTIVITY"
	return context


func _parse_level1_plan(text: String) -> Array[Dictionary]:
	## Parse "START-END|LOCATION|ACTIVITY" lines from Gemini output.
	var plans: Array[Dictionary] = []
	var valid_buildings: Array[String] = [
		"Bakery", "General Store", "Tavern", "Church",
		"Sheriff Office", "Courthouse", "Blacksmith",
		"Library", "Inn", "Market", "Carpenter Workshop",
		"Tailor Shop", "Stables", "Clinic", "School",
	]
	for i: int in range(1, 47):
		valid_buildings.append("House %d" % i)

	for line: String in text.split("\n"):
		var cleaned: String = line.strip_edges()
		if cleaned == "":
			continue

		# Remove leading numbering or bullets
		if cleaned.length() > 2 and cleaned[0].is_valid_int() and (cleaned[1] == '.' or cleaned[1] == ')' or cleaned[1] == ':'):
			if cleaned[1] != '-' and cleaned[1] != '|':
				cleaned = cleaned.substr(2).strip_edges()

		var parts: PackedStringArray = cleaned.split("|")
		if parts.size() < 3:
			continue

		var time_part: String = parts[0].strip_edges()
		var location: String = parts[1].strip_edges()
		var plan_activity: String = parts[2].strip_edges()

		# Parse "START-END" format
		var time_parts: PackedStringArray = time_part.split("-")
		if time_parts.size() != 2:
			continue
		var start_h: int = time_parts[0].strip_edges().to_int()
		var end_h: int = time_parts[1].strip_edges().to_int()
		if start_h < 5 or end_h > 23 or start_h >= end_h:
			continue

		var matched_loc: String = _match_building_name(location, valid_buildings)
		if matched_loc == "":
			continue

		plans.append({
			"start_hour": start_h,
			"end_hour": end_h,
			"location": matched_loc,
			"activity": plan_activity,
			"decomposed": false,
		})

	# Cap at 8 blocks, sort by start_hour
	if plans.size() > 8:
		plans.resize(8)
	plans.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["start_hour"] < b["start_hour"]
	)
	return plans


func _decompose_to_level2(l1_index: int) -> void:
	## Break a Level 1 block into hourly steps via Flash Lite.
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

	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 50:
		var steps: Array[Dictionary] = []
		for h: int in range(l1["start_hour"], l1["end_hour"]):
			steps.append({"hour": h, "end_hour": h + 1, "activity": l1["activity"]})
		_plan_level2[l1_index] = steps
		return

	_decomposition_in_progress = true
	var system_prompt: String = "You are %s, a %s (%s). Break this %d-hour activity block into hourly steps." % [
		npc.npc_name, npc.job, npc.personality, duration
	]
	var user_msg: String = "Activity: '%s' at %s from %d:00 to %d:00.\n" % [
		l1["activity"], l1["location"], l1["start_hour"], l1["end_hour"]
	]
	user_msg += "Break this into hourly steps. One line per hour.\nFormat: HOUR|ACTIVITY\n"
	user_msg += "Example:\n6|Open the shop and arrange shelves\n7|Greet early customers and restock\n"
	user_msg += "Only output the lines, nothing else."

	GeminiClient.generate(system_prompt, user_msg,
		func(text: String, success: bool) -> void:
			_decomposition_in_progress = false
			if not is_instance_valid(npc):
				return
			if success and text.strip_edges() != "":
				var steps: Array[Dictionary] = _parse_level2_steps(text, l1["start_hour"], l1["end_hour"])
				if not steps.is_empty():
					_plan_level2[l1_index] = steps
					if OS.is_debug_build():
						print("[Plan L2] %s: Decomposed block %d into %d hourly steps" % [npc.npc_name, l1_index, steps.size()])
					return
			# Fallback: one entry per hour
			var fallback: Array[Dictionary] = []
			for h: int in range(l1["start_hour"], l1["end_hour"]):
				fallback.append({"hour": h, "end_hour": h + 1, "activity": l1["activity"]})
			_plan_level2[l1_index] = fallback,
		GeminiClient.MODEL_LITE
	)


func _parse_level2_steps(text: String, block_start: int, block_end: int) -> Array[Dictionary]:
	## Parse HOUR|ACTIVITY format into L2 step array.
	var steps: Array[Dictionary] = []
	for line: String in text.strip_edges().split("\n"):
		line = line.strip_edges()
		if line == "" or not line.contains("|"):
			continue
		var parts: PackedStringArray = line.split("|", true, 2)
		if parts.size() < 2:
			continue
		var hour_str: String = parts[0].strip_edges()
		var step_activity: String = parts[1].strip_edges()
		if not hour_str.is_valid_int():
			continue
		var h: int = hour_str.to_int()
		if h < block_start or h >= block_end:
			continue
		steps.append({"hour": h, "end_hour": h + 1, "activity": step_activity})

	steps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["hour"] < b["hour"]
	)
	var max_steps: int = block_end - block_start
	if steps.size() > max_steps:
		steps.resize(max_steps)
	return steps


func _decompose_to_level3(l1_idx: int, l2_idx: int) -> void:
	## Break an hourly L2 step into 5-20 minute actions via Flash Lite.
	var l3_key: String = "%d_%d" % [l1_idx, l2_idx]
	if _decomposition_in_progress or _plan_level3.has(l3_key):
		return
	if not _plan_level2.has(l1_idx):
		return
	var l2_steps: Array = _plan_level2[l1_idx]
	if l2_idx < 0 or l2_idx >= l2_steps.size():
		return

	var l2: Dictionary = l2_steps[l2_idx]

	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 50:
		_plan_level3[l3_key] = [{"start_min": 0, "end_min": 60, "activity": l2["activity"]}]
		return

	_decomposition_in_progress = true
	var l1: Dictionary = _plan_level1[l1_idx]
	var system_prompt: String = "You are %s, a %s. Break this 1-hour activity into 3-6 specific actions (5-20 min each)." % [npc.npc_name, npc.job]
	var user_msg: String = "Hour %d:00 at %s: '%s'\n" % [l2["hour"], l1["location"], l2["activity"]]
	user_msg += "Format: START_MIN-END_MIN|ACTION\nExample:\n0-10|Unlock the front door and light the stove\n10-30|Knead bread dough for today's loaves\n30-50|Shape loaves and place in oven\n50-60|Clean up workspace\n"
	user_msg += "Minutes must be 0-60, covering the full hour. Only output lines."

	GeminiClient.generate(system_prompt, user_msg,
		func(text: String, success: bool) -> void:
			_decomposition_in_progress = false
			if not is_instance_valid(npc):
				return
			if success and text.strip_edges() != "":
				var steps: Array[Dictionary] = _parse_level3_steps(text)
				if not steps.is_empty():
					_plan_level3[l3_key] = steps
					if OS.is_debug_build():
						print("[Plan L3] %s: Decomposed L2[%d][%d] into %d fine actions" % [npc.npc_name, l1_idx, l2_idx, steps.size()])
					return
			# Fallback: single entry
			_plan_level3[l3_key] = [{"start_min": 0, "end_min": 60, "activity": l2["activity"]}],
		GeminiClient.MODEL_LITE
	)


func _parse_level3_steps(text: String) -> Array[Dictionary]:
	## Parse START_MIN-END_MIN|ACTION format into L3 step array.
	var steps: Array[Dictionary] = []
	for line: String in text.strip_edges().split("\n"):
		line = line.strip_edges()
		if line == "" or not line.contains("|"):
			continue
		var parts: PackedStringArray = line.split("|", true, 2)
		if parts.size() < 2:
			continue
		var time_part: String = parts[0].strip_edges()
		var step_activity: String = parts[1].strip_edges()
		if not time_part.contains("-"):
			continue
		var time_parts: PackedStringArray = time_part.split("-")
		if time_parts.size() < 2:
			continue
		if not time_parts[0].strip_edges().is_valid_int() or not time_parts[1].strip_edges().is_valid_int():
			continue
		var start_m: int = time_parts[0].strip_edges().to_int()
		var end_m: int = time_parts[1].strip_edges().to_int()
		if start_m < 0 or end_m > 60 or start_m >= end_m:
			continue
		steps.append({"start_min": start_m, "end_min": end_m, "activity": step_activity})

	steps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["start_min"] < b["start_min"]
	)
	if steps.size() > 6:
		steps.resize(6)
	return steps


func evaluate_reaction(observation: String, importance: float) -> void:
	## Evaluate whether the NPC should react to a significant observation by replanning.
	if _reaction_in_progress or _decomposition_in_progress or _planning_in_progress:
		return
	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 50:
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

	var system_prompt: String = "You are %s, a %s in DeepTown. Decide if this observation warrants changing your current plans." % [npc.npc_name, npc.job]
	var user_msg: String = "Current hour: %d:00\n" % GameClock.hour
	user_msg += "You are currently: %s at the %s.\n" % [current_activity_text, npc._current_destination]
	user_msg += "New observation (importance %.1f): %s\n\n" % [importance, observation]
	user_msg += "Should you CONTINUE your current activity or REACT by changing plans?\n"
	user_msg += "If CONTINUE, just write: CONTINUE\n"
	user_msg += "If the event is happening NOW or very soon, write: REACT|LOCATION|NEW_ACTIVITY\n"
	user_msg += "If the event is in the FUTURE (later today), write: REACT|LOCATION|ACTIVITY|HOUR\n"
	user_msg += "Example (now): REACT|Tavern|Rush to check on the commotion\n"
	user_msg += "Example (future): REACT|Tavern|Attend the festival|18\n"
	user_msg += "Only react if this is truly important enough to disrupt your plans."

	GeminiClient.generate(system_prompt, user_msg,
		func(text: String, success: bool) -> void:
			_reaction_in_progress = false
			if not is_instance_valid(npc):
				return
			if success and text.strip_edges() != "":
				_process_reaction_result(text.strip_edges(), observation)
			elif OS.is_debug_build():
				print("[Reaction] %s: Evaluation failed, continuing current plan" % npc.npc_name),
		GeminiClient.MODEL_LITE
	)


func _process_reaction_result(text: String, observation: String) -> void:
	## Parse CONTINUE/REACT response and apply if reacting.
	var first_line: String = text.split("\n")[0].strip_edges().to_upper()

	if first_line.begins_with("CONTINUE"):
		if OS.is_debug_build():
			print("[Reaction] %s: CONTINUE — staying on plan" % npc.npc_name)
		return

	if not first_line.begins_with("REACT"):
		return

	var parts: PackedStringArray = first_line.split("|")
	if parts.size() < 3:
		return

	var raw_line: String = text.split("\n")[0].strip_edges()
	var raw_parts: PackedStringArray = raw_line.split("|")
	var location_raw: String = raw_parts[1].strip_edges()
	var activity_raw: String = raw_parts[2].strip_edges()
	var target_hour: int = -1
	if raw_parts.size() >= 4:
		target_hour = raw_parts[3].strip_edges().to_int()

	# Fuzzy match location
	var valid_names: Array[String] = []
	for other_node: Node in npc.get_tree().get_nodes_in_group("npcs"):
		if other_node.home_building not in valid_names:
			valid_names.append(other_node.home_building)
		if other_node.workplace_building not in valid_names:
			valid_names.append(other_node.workplace_building)
	for bname: String in ["Tavern", "Church", "Courthouse", "Sheriff Office"]:
		if bname not in valid_names:
			valid_names.append(bname)

	var matched_loc: String = _match_building_name(location_raw, valid_names)
	if matched_loc == "":
		matched_loc = npc._current_destination

	if target_hour > 0 and target_hour > GameClock.hour + 1:
		# FUTURE EVENT: Insert a new L1 block at the target hour instead of overriding now
		_insert_future_event_block(matched_loc, activity_raw, target_hour)
		var react_desc: String = "Decided to attend: %s — planning to go to %s at hour %d" % [observation, matched_loc, target_hour]
		npc._add_memory_with_embedding(react_desc, "plan", npc.npc_name,
			[npc.npc_name] as Array[String], npc._current_destination, matched_loc, 4.0, 0.0)
		if OS.is_debug_build():
			print("[Reaction] %s: REACT (future) — scheduled %s at hour %d for '%s'" % [npc.npc_name, matched_loc, target_hour, activity_raw])
	else:
		# IMMEDIATE: Override the current L1 block
		var l1_idx: int = _get_current_l1_index()
		if l1_idx >= 0:
			_plan_level1[l1_idx]["location"] = matched_loc
			_plan_level1[l1_idx]["activity"] = activity_raw if activity_raw != "" else "reacting to event"
			_plan_level2.erase(l1_idx)
			var keys_to_erase: Array[String] = []
			for key: String in _plan_level3.keys():
				if key.begins_with(str(l1_idx) + "_"):
					keys_to_erase.append(key)
			for key: String in keys_to_erase:
				_plan_level3.erase(key)

		var react_desc: String = "Decided to react to: %s — going to %s to %s" % [observation, matched_loc, activity_raw]
		npc._add_memory_with_embedding(react_desc, "plan", npc.npc_name,
			[npc.npc_name] as Array[String], npc._current_destination, matched_loc, 4.0, 0.0)

		# Immediately redirect
		npc._update_destination(GameClock.hour)
		if OS.is_debug_build():
			print("[Reaction] %s: REACT — redirecting to %s for '%s'" % [npc.npc_name, matched_loc, activity_raw])


func _match_building_name(input: String, valid_names: Array[String]) -> String:
	## Fuzzy match building name from Gemini output.
	var input_lower: String = input.to_lower()
	for bld_name: String in valid_names:
		if input_lower == bld_name.to_lower():
			return bld_name
		if bld_name.to_lower().contains(input_lower) or input_lower.contains(bld_name.to_lower()):
			return bld_name
	return ""


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


func _insert_future_event_block(location: String, activity: String, hour: int) -> void:
	## Insert a new L1 plan block for a future event, splitting the existing block if needed.
	var target_idx: int = -1
	for i: int in range(_plan_level1.size()):
		if hour >= _plan_level1[i]["start_hour"] and hour < _plan_level1[i]["end_hour"]:
			target_idx = i
			break

	if target_idx < 0:
		# No existing block covers this hour — append
		_plan_level1.append({
			"start_hour": hour, "end_hour": mini(hour + 2, 22),
			"location": location, "activity": activity, "decomposed": false
		})
		_plan_level1.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["start_hour"] < b["start_hour"])
		return

	# Split the existing block around the event
	var original: Dictionary = _plan_level1[target_idx]
	var event_end: int = mini(hour + 2, original["end_hour"])

	var new_blocks: Array[Dictionary] = []
	if hour > original["start_hour"]:
		new_blocks.append({"start_hour": original["start_hour"], "end_hour": hour,
			"location": original["location"], "activity": original["activity"], "decomposed": false})
	new_blocks.append({"start_hour": hour, "end_hour": event_end,
		"location": location, "activity": activity, "decomposed": false})
	if event_end < original["end_hour"]:
		new_blocks.append({"start_hour": event_end, "end_hour": original["end_hour"],
			"location": original["location"], "activity": original["activity"], "decomposed": false})

	# Replace the original block with the split blocks
	_plan_level1.remove_at(target_idx)
	for i: int in range(new_blocks.size()):
		_plan_level1.insert(target_idx + i, new_blocks[i])

	# Clear L2/L3 for affected indices
	_plan_level2.erase(target_idx)
	var keys_to_erase: Array[String] = []
	for key: String in _plan_level3.keys():
		if key.begins_with(str(target_idx) + "_"):
			keys_to_erase.append(key)
	for key: String in keys_to_erase:
		_plan_level3.erase(key)

	if OS.is_debug_build():
		print("[Reaction] %s: Scheduled future event at hour %d — %s at %s" % [npc.npc_name, hour, activity, location])


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
