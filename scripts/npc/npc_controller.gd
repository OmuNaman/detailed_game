extends CharacterBody2D
## Controls a single NPC: needs-driven movement, perception, memory, conversations, LLM dialogue.
## Uses AStarGrid2D waypoint-following instead of NavigationAgent2D.
## Memory Stream replaces the old flat observation array with scored retrieval.

const SPEED: float = 80.0
const TILE_SIZE: int = 32

var npc_name: String = ""
var job: String = ""
var age: int = 30
var personality: String = ""
var speech_style: String = ""
var home_building: String = ""
var workplace_building: String = ""
var sprite_path: String = ""

var _current_destination: String = ""
var _building_positions: Dictionary = {}
var _building_interiors: Dictionary = {}

# Needs system (0-100, start full)
var hunger: float = 100.0
var energy: float = 100.0
var social: float = 100.0

# Three-tier memory system (replaces old flat MemoryStream)
var memory: MemorySystem = MemorySystem.new()
var _observation_cooldowns: Dictionary = {}  # {actor_name: last_observed_game_minute}
const OBSERVATION_COOLDOWN_MINUTES: int = 60

# Embedding queue — batch-processes pending embeddings every 5 real seconds
var _embedding_queue: Array[Dictionary] = []
var _embedding_timer: float = 0.0
const EMBEDDING_BATCH_INTERVAL: float = 5.0
const EMBEDDING_BATCH_SIZE: int = 10

# NPC-to-NPC conversation tracking
var _last_conversation_time: Dictionary = {}  # {npc_name: game_time}
const CONVERSATION_COOLDOWN: int = 120  # 2 game hours between conversations with same NPC

# Bug 7: Conversation spam prevention
var _conv_counts_today: Dictionary = {}      # "A:B" -> int
const MAX_CONV_PER_PAIR_PER_DAY: int = 3
const COOLDOWN_COHABIT_MINUTES: int = 240    # 4 game hours for cohabitants

# Random visit tracking
var _next_visit_check: int = 0

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

# A* waypoint following
var _path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _is_moving: bool = false
var _astar: AStarGrid2D = null
var _town_map: Node2D = null
var _current_object_id: String = ""  # WorldObjects ID of furniture in use
var current_activity: String = ""    # Human-readable: "kneading dough at the oven"
var _activity_emoji: String = ""     # Simple symbol above head
var _activity_label: Label = null
var _awake_texture: Texture2D = null
var _sleep_texture: Texture2D = null
var _is_visually_sleeping: bool = false

# Enhanced reflection system (Stanford two-step)
var _unreflected_importance: float = 0.0
var _reflection_in_progress: bool = false
const REFLECTION_THRESHOLD: float = 100.0

# Environment perception
var _last_environment_scan: int = -120  # Start cold so first scan triggers
const ENVIRONMENT_SCAN_INTERVAL: int = 30  # Every 30 game minutes

# Bug 9: Minimum stay duration at destinations
var _dest_arrival_time: int = -1
const MIN_STAY_MINUTES: int = 60

# NPC-to-NPC conversation totals (for summary update trigger)
var _npc_conv_totals: Dictionary = {}  # "OtherName" -> int (lifetime count)

# Daily planning
var _daily_plan: Array[Dictionary] = []  # [{hour, end_hour, destination, reason, completed}]
var _last_plan_day: int = -1
var _planning_in_progress: bool = false

@onready var sprite: Sprite2D = $Sprite2D
@onready var name_label: Label = $NameLabel


func initialize(data: Dictionary, building_positions: Dictionary, building_interiors: Dictionary = {}) -> void:
	## Call BEFORE adding to scene tree. Sets NPC identity and building targets.
	npc_name = data.get("name", "NPC")
	job = data.get("job", "")
	age = data.get("age", 30)
	personality = data.get("personality", "")
	speech_style = data.get("speech_style", "")
	home_building = data.get("home", "")
	workplace_building = data.get("workplace", "")
	sprite_path = data.get("sprite", "")
	_building_positions = building_positions
	_building_interiors = building_interiors

	# Initialize three-tier memory system
	memory.initialize(npc_name, personality, PlayerProfile.player_name)


func _ready() -> void:
	add_to_group("npcs")

	if sprite_path != "":
		var tex: Texture2D = load(sprite_path)
		if tex:
			sprite.texture = tex
	_awake_texture = sprite.texture

	# Load sleeping variant (same path but _sleep instead of _down)
	var sleep_path: String = sprite_path.replace("_down.png", "_sleep.png")
	if ResourceLoader.exists(sleep_path):
		_sleep_texture = load(sleep_path)

	name_label.text = npc_name

	EventBus.time_hour_changed.connect(_on_hour_changed)
	EventBus.time_tick.connect(_on_time_tick)
	$PerceptionArea.body_entered.connect(_on_perception_body_entered)

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
	add_child(_activity_label)

	# Wait one frame for the scene tree to be fully built, then grab the A* grid
	await get_tree().process_frame
	var town_map: Node2D = get_parent().get_node_or_null("TownMap")
	if town_map and town_map.has_method("get_astar"):
		_astar = town_map.get_astar()
		_town_map = town_map
		print("[%s] Got AStarGrid2D reference" % npc_name)
	else:
		push_error("[%s] Could not find TownMap or get_astar()!" % npc_name)
		return

	# Initial destination based on current hour
	_update_destination(GameClock.hour)

	# Bug 8: Late planning trigger — if loaded after hour 5, still generate today's plan
	call_deferred("_check_planning_on_load")


func _physics_process(delta: float) -> void:
	if not _is_moving or _path.is_empty():
		return

	var target: Vector2 = _path[_path_index]
	var distance: float = global_position.distance_to(target)
	var step: float = SPEED * GameClock.time_scale * delta

	if step >= distance or GameClock.time_scale > 10.0:
		# High speed or close enough: snap directly to waypoint
		global_position = target
		_path_index += 1
		if _path_index >= _path.size():
			_arrive()
			return
		# At very high speeds, consume multiple waypoints per frame
		while GameClock.time_scale > 10.0 and _path_index < _path.size():
			global_position = _path[_path_index]
			_path_index += 1
		if _path_index >= _path.size():
			_arrive()
			return
	else:
		# Normal speed: smooth velocity-based movement
		var direction: Vector2 = global_position.direction_to(target)
		velocity = direction * SPEED * GameClock.time_scale
		move_and_slide()

	# Flip sprite based on movement direction
	var dir_x: float = _path[mini(_path_index, _path.size() - 1)].x - global_position.x
	if dir_x < -1.0:
		sprite.flip_h = true
	elif dir_x > 1.0:
		sprite.flip_h = false


func _process(delta: float) -> void:
	# Batch-process pending embeddings every EMBEDDING_BATCH_INTERVAL real seconds
	if _embedding_queue.size() > 0:
		_embedding_timer += delta
		if _embedding_timer >= EMBEDDING_BATCH_INTERVAL:
			_embedding_timer = 0.0
			_process_embedding_queue()


func _arrive() -> void:
	_is_moving = false
	_path = PackedVector2Array()
	velocity = Vector2.ZERO
	_dest_arrival_time = GameClock.total_minutes  # Bug 9: Track arrival for minimum stay
	_claim_work_object()
	_update_activity()
	_on_arrive_at_building()


func _claim_work_object() -> void:
	## Find and claim the appropriate furniture object at the current building.
	_release_current_object()

	var target_type: String = _get_target_furniture_type(_current_destination)
	if target_type == "":
		return

	var obj_id: String = WorldObjects.find_object_for_npc(_current_destination, target_type, npc_name)
	if obj_id == "":
		return

	_current_object_id = obj_id

	var state_str: String = "in use"
	if _current_destination == workplace_building:
		state_str = JOB_OBJECT_STATES.get(job, "in use")
	elif target_type == "bed":
		state_str = "occupied"
	elif target_type == "table":
		state_str = "dining"
	elif target_type == "pew":
		state_str = "occupied"

	WorldObjects.set_state(obj_id, state_str, npc_name)


func _release_current_object() -> void:
	## Release whatever object we're currently using.
	if _current_object_id != "":
		WorldObjects.release_object(_current_object_id)
		_current_object_id = ""


func _get_target_furniture_type(destination: String) -> String:
	## What furniture should the NPC go to at this destination?
	if destination == workplace_building:
		return JOB_WORK_OBJECTS.get(job, "")
	if destination == home_building:
		if GameClock.hour >= 22 or GameClock.hour < 6:
			return "bed"
		if GameClock.hour in [7, 12, 19]:
			return "table"
	if destination == "Tavern" and destination != workplace_building:
		return "table"
	if destination == "Church" and destination != workplace_building:
		return "pew"
	return ""


func _update_activity() -> void:
	## Recompute current_activity based on location, time, object, and needs.
	if _is_moving:
		current_activity = "walking to the %s" % _current_destination
		_activity_emoji = "..."
		_update_activity_label()
		return

	if _current_destination == "":
		current_activity = "standing around"
		_activity_emoji = "..."
		_update_activity_label()
		return

	# Check if current destination is from a plan
	# Bug 5: Only show plan text if actually at the plan destination
	var active_plan: Dictionary = _get_current_plan()
	if not active_plan.is_empty():
		if _current_destination == active_plan.get("destination", ""):
			current_activity = active_plan.get("reason", "visiting")
			_activity_emoji = "!"
			_update_activity_label()
			_update_visual_state()
			return

	var hour: int = GameClock.hour

	# At home
	if _current_destination == home_building:
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
	if _current_destination == workplace_building:
		current_activity = _get_work_activity()
		_activity_emoji = _get_work_emoji()
		_update_activity_label()
		return

	# At Tavern (socializing)
	if _current_destination == "Tavern" and _current_destination != workplace_building:
		if hour >= 17:
			current_activity = "having drinks at the Tavern"
		else:
			current_activity = "relaxing at the Tavern"
		_activity_emoji = "~"
		_update_activity_label()
		return

	# Visiting Church
	if _current_destination == "Church" and _current_destination != workplace_building:
		current_activity = "praying quietly in the Church"
		_activity_emoji = "..."
		_update_activity_label()
		return

	# Fallback
	current_activity = "at the %s" % _current_destination
	_activity_emoji = "..."
	_update_activity_label()


func _get_work_activity() -> String:
	## Returns a specific activity string based on job and time of day.
	match job:
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
	return "working at the %s" % workplace_building


func _get_work_emoji() -> String:
	match job:
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
	_update_visual_state()


func _update_visual_state() -> void:
	## Swap sprite texture based on current activity (sleeping/working/idle).
	var should_sleep: bool = current_activity == "sleeping in bed"

	if should_sleep and not _is_visually_sleeping and _sleep_texture:
		sprite.texture = _sleep_texture
		sprite.modulate = Color(0.7, 0.7, 0.9, 1.0)  # Slight blue tint when sleeping
		_is_visually_sleeping = true
	elif not should_sleep and _is_visually_sleeping and _awake_texture:
		sprite.texture = _awake_texture
		sprite.modulate = Color.WHITE
		_is_visually_sleeping = false

	# Subtle work tint when actively using a furniture object
	if not _is_visually_sleeping:
		if _current_object_id != "" and not _is_moving:
			sprite.modulate = Color(1.0, 0.97, 0.93, 1.0)
		else:
			sprite.modulate = Color.WHITE


func _get_current_day() -> int:
	## Monotonic day counter (doesn't reset on season change unlike GameClock.day).
	return GameClock.total_minutes / 1440


func _enhanced_reflect() -> void:
	## Stanford two-step reflection: generate questions from recent experiences,
	## then generate insights per question using relevant memories.
	if _reflection_in_progress:
		return
	if not GeminiClient.has_api_key():
		return

	# Gather 100 recent non-reflection memories
	var recent: Array[Dictionary] = []
	for mem: Dictionary in memory.episodic_memories:
		if mem.get("type", "") != "reflection" and not mem.get("superseded", false):
			recent.append(mem)
	recent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("timestamp", 0) > b.get("timestamp", 0)
	)
	recent = recent.slice(0, mini(100, recent.size()))

	if recent.size() < 10:
		return

	_reflection_in_progress = true

	# Build memory list for the question prompt
	var memories_text: String = ""
	for mem: Dictionary in recent:
		memories_text += "- %s\n" % mem.get("text", mem.get("description", ""))

	# Step 1: Generate 5 questions
	var q_prompt: String = """Given these recent experiences of %s, what are the 5 most salient high-level questions we can answer about the subjects in the statements?

Recent experiences:
%s

Focus on: patterns in relationships, changes in feelings, things learned about others, personal growth, unresolved tensions, emerging goals, and what relationships are forming or changing.

Respond with exactly 5 questions, one per line, nothing else.""" % [npc_name, memories_text]

	var q_system: String = "You are analyzing the experiences of %s, a %d-year-old %s in DeepTown. %s" % [
		npc_name, age, job, personality.left(200)]

	GeminiClient.generate(q_system, q_prompt, func(text: String, success: bool) -> void:
		if not success or text == "":
			_reflection_in_progress = false
			if OS.is_debug_build():
				print("[Reflect] %s — question generation failed" % npc_name)
			return

		# Parse questions
		var questions: Array[String] = []
		for line: String in text.strip_edges().split("\n"):
			var q: String = line.strip_edges()
			# Strip numbering
			if q.length() > 3 and q[0].is_valid_int() and (q[1] == '.' or q[1] == ')' or q[1] == ':'):
				q = q.substr(2).strip_edges()
			elif q.length() > 4 and q[0].is_valid_int() and q[1].is_valid_int():
				var dot_pos: int = q.find(".")
				if dot_pos > 0 and dot_pos < 4:
					q = q.substr(dot_pos + 1).strip_edges()
			if q.length() > 10:
				questions.append(q)

		questions = questions.slice(0, mini(5, questions.size()))
		if questions.is_empty():
			_reflection_in_progress = false
			return

		if OS.is_debug_build():
			print("[Reflect] %s: Generated %d questions" % [npc_name, questions.size()])

		# Step 2: For each question, generate insights
		var _pending_questions: int = questions.size()
		for question: String in questions:
			_generate_insights_for_question(question, func() -> void:
				_pending_questions -= 1
				if _pending_questions <= 0:
					_reflection_in_progress = false
					if OS.is_debug_build():
						print("[Reflect] %s: All reflection questions processed" % npc_name)
			)
	)


func _generate_insights_for_question(question: String, on_done: Callable) -> void:
	## Step 2 of reflection: retrieve relevant memories for a question,
	## then generate up to 5 insights.
	# Use keyword retrieval (synchronous — no async embedding needed)
	var keywords: Array[String] = []
	for w: String in question.split(" "):
		var lower: String = w.to_lower().strip_edges()
		if lower.length() > 3 and lower not in ["what", "does", "have", "this", "that", "been", "with", "from", "they", "their", "about", "which", "there", "would", "could", "should"]:
			keywords.append(lower)
	keywords = keywords.slice(0, mini(8, keywords.size()))

	var relevant: Array[Dictionary] = memory.retrieve_by_keywords(keywords, GameClock.total_minutes, 10)

	var relevant_text: String = ""
	for mem: Dictionary in relevant:
		relevant_text += "- [Day %d] %s\n" % [mem.get("game_day", 0), mem.get("text", mem.get("description", ""))]

	if relevant_text == "":
		on_done.call()
		return

	var identity: String = memory.core_memory.get("identity", personality)
	var i_prompt: String = """You are %s reflecting on your experiences.

Question: %s

Relevant memories:
%s

Your personality: %s

What 5 high-level insights can you infer from the above statements? Write each as a 1-2 sentence personal reflection in first person as %s. Be genuine and specific — reference actual events and people. Each should feel like an internal thought, not a report.

Format: One insight per line, numbered 1-5.
Write ONLY the insights, nothing else.""" % [
		npc_name, question, relevant_text, identity.left(300), npc_name]

	var i_system: String = "You are %s. Write personal reflections — genuine internal thoughts, not reports." % npc_name

	GeminiClient.generate(i_system, i_prompt, func(text: String, success: bool) -> void:
		if success and text != "":
			var insights: Array[String] = _parse_insight_lines(text)
			for insight: String in insights:
				# Strip citation "(because of 1, 3, 5)" if present
				var paren_idx: int = insight.rfind("(because")
				var clean_insight: String = insight.left(paren_idx).strip_edges() if paren_idx > 0 else insight

				if clean_insight.length() < 10:
					continue

				_add_memory_with_embedding(
					clean_insight,
					"reflection",
					npc_name,
					[npc_name] as Array[String],
					_current_destination,
					_current_destination,
					7.0,
					0.0
				)

				if OS.is_debug_build():
					print("[Reflect] %s: %s" % [npc_name, clean_insight.left(100)])

				# If insight mentions the player, update core memory
				if PlayerProfile.player_name.to_lower() in clean_insight.to_lower():
					var old_summary: String = memory.core_memory.get("player_summary", "")
					var update_prompt: String = "Based on this reflection: \"%s\"\nCurrent understanding of %s: \"%s\"\nWrite an updated 1-2 sentence understanding:" % [
						clean_insight.left(200), PlayerProfile.player_name, old_summary]
					GeminiClient.generate(
						"You are %s. Write a brief updated impression." % npc_name,
						update_prompt,
						func(summary_text: String, s: bool) -> void:
							if s and summary_text != "":
								memory.update_player_summary(summary_text.strip_edges().left(200))
								if OS.is_debug_build():
									print("[Memory] %s updated player summary from reflection" % npc_name)
					)

			# Update emotional state from last insight
			if not insights.is_empty():
				memory.update_emotional_state(insights[-1].left(150))

			print("[Reflect] %s: %d insights from question" % [npc_name, insights.size()])

		on_done.call()
	)


func _parse_insight_lines(text: String) -> Array[String]:
	## Extract numbered insight lines from Gemini response.
	var results: Array[String] = []
	for line: String in text.split("\n"):
		var cleaned: String = line.strip_edges()
		if cleaned == "":
			continue
		# Remove numbering: "1. ", "2) ", "1: ", etc.
		var stripped: String = cleaned
		if cleaned.length() > 2:
			if cleaned[0].is_valid_int() and (cleaned[1] == '.' or cleaned[1] == ')' or cleaned[1] == ':'):
				stripped = cleaned.substr(2).strip_edges()
			elif cleaned.length() > 3 and cleaned[0].is_valid_int() and cleaned[1].is_valid_int():
				var dot_pos: int = cleaned.find(".")
				if dot_pos > 0 and dot_pos < 4:
					stripped = cleaned.substr(dot_pos + 1).strip_edges()
		if stripped.length() > 10:
			results.append(stripped)
	if results.size() > 5:
		results.resize(5)
	return results


# --- Midnight Maintenance ---

func _run_midnight_maintenance() -> void:
	## Daily memory maintenance: forgetting curves → compression → save.
	# 1. Apply forgetting curves
	memory.apply_daily_forgetting()

	# 2. Compress old episodic memories (async — needs Gemini)
	_compress_memories()

	# 3. Save (forgetting results saved immediately; compression saves on callback)
	memory.save_all()

	if OS.is_debug_build():
		print("[Memory] %s: Midnight maintenance — Episodic: %d, Archival: %d" % [
			npc_name, memory.episodic_memories.size(), memory.archival_summaries.size()])


func _compress_memories() -> void:
	## Compress oldest raw episodic memories into an episode summary via Gemini.
	var candidates: Array[Dictionary] = memory.get_compression_candidates()
	if candidates.size() < memory.COMPRESSION_MIN_BATCH:
		return
	if not GeminiClient.has_api_key():
		return

	# Build summarization prompt
	var memories_text: String = ""
	for mem: Dictionary in candidates:
		memories_text += "- [Day %d, Hour %d] %s\n" % [
			mem.get("game_day", 0), mem.get("game_hour", 0),
			mem.get("text", mem.get("description", ""))]

	var prompt: String = """Summarize these memories of %s into a dense 3-5 sentence paragraph.
PRESERVE: relationship changes, emotional peaks, promises made, surprising events, anything about %s.
COMPRESS AWAY: routine observations, repeated activities, mundane details.
DO NOT invent details not present in the memories.

Memories:
%s

Write ONLY the summary paragraph, nothing else.""" % [npc_name, PlayerProfile.player_name, memories_text]

	GeminiClient.generate(
		"You summarize memories for %s into dense paragraphs." % npc_name,
		prompt,
		func(text: String, success: bool) -> void:
			if not success or text == "":
				if OS.is_debug_build():
					print("[Compress] %s: Gemini failed, skipping compression" % npc_name)
				return

			var summary_text: String = text.strip_edges()
			var summary_mem: Dictionary = memory.apply_episode_compression(candidates, summary_text)

			# Queue embedding for the summary
			if summary_mem.get("embedding", PackedFloat32Array()).is_empty():
				_embedding_queue.append(summary_mem)

			memory.save_all()

			print("[Compress] %s: Compressed %d memories into episode summary (Day %d)" % [
				npc_name, candidates.size(), summary_mem.get("game_day", 0)])

			# Check if we can do period compression too
			_compress_episodes()
	)


func _compress_episodes() -> void:
	## Compress oldest episode summaries into a period summary via Gemini.
	var episodes: Array[Dictionary] = memory.get_episode_summary_candidates()
	if episodes.size() < memory.EPISODE_COMPRESSION_THRESHOLD:
		return
	if not GeminiClient.has_api_key():
		return

	var batch: Array[Dictionary] = episodes.slice(0, memory.PERIOD_COMPRESSION_BATCH)

	var text: String = ""
	for ep: Dictionary in batch:
		text += "- %s\n" % ep.get("text", ep.get("description", ""))

	var prompt: String = """These are episode summaries spanning several days for %s.
Compress them into a single 2-3 sentence period summary capturing the most important developments.
PRESERVE: relationship arcs, major events, character growth, anything about %s.

Episodes:
%s

Write ONLY the period summary:""" % [npc_name, PlayerProfile.player_name, text]

	GeminiClient.generate(
		"You compress episode summaries for %s into period summaries." % npc_name,
		prompt,
		func(period_text: String, success: bool) -> void:
			if not success or period_text == "":
				return

			var period_mem: Dictionary = memory.apply_period_compression(batch, period_text.strip_edges())

			# Queue embedding for the period summary
			if period_mem.get("embedding", PackedFloat32Array()).is_empty():
				_embedding_queue.append(period_mem)

			memory.save_all()

			print("[Compress] %s: Compressed %d episodes into period summary" % [npc_name, batch.size()])
	)


# --- Daily Planning ---

func _check_planning_on_load() -> void:
	## Bug 8: Generate plans if game loaded after the normal dawn trigger.
	await get_tree().process_frame
	if GameClock.hour >= 5 and _last_plan_day != _get_current_day():
		if OS.is_debug_build():
			print("[Planning] Late trigger for %s (loaded at hour %d)" % [npc_name, GameClock.hour])
		_generate_daily_plan()


func _generate_daily_plan() -> void:
	## Ask Gemini for today's plan: 2-4 specific goals with times and locations.
	if _planning_in_progress:
		return
	if not GeminiClient.has_api_key():
		_generate_fallback_plan()
		return

	_planning_in_progress = true
	_last_plan_day = _get_current_day()

	var system_prompt: String = _build_planning_system_prompt()
	var user_message: String = _build_planning_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		_planning_in_progress = false

		if not success or text == "":
			print("[Planning] %s — Gemini failed, using fallback plan" % npc_name)
			_generate_fallback_plan()
			return

		_daily_plan = _parse_plan(text)

		# Store plan as a memory + update core memory active goals
		if not _daily_plan.is_empty():
			var plan_summary: Array[String] = []
			for p: Dictionary in _daily_plan:
				plan_summary.append("%s at the %s around %d:00" % [p["reason"], p["destination"], p["hour"]])
			var plan_desc: String = "My plans for today: %s" % ", ".join(plan_summary)
			_add_memory_with_embedding(
				plan_desc, "plan", npc_name, [npc_name] as Array[String],
				home_building, home_building, 3.0, 0.1
			)
			memory.set_active_goals(plan_summary)

		if OS.is_debug_build():
			print("[Planning] %s's plan for today:" % npc_name)
			for p: Dictionary in _daily_plan:
				print("  %d:00-%d:00 → %s (%s)" % [p["hour"], p["end_hour"], p["destination"], p["reason"]])
	)


func _generate_fallback_plan() -> void:
	## Simple deterministic plan when Gemini is unavailable.
	## Adds 1-2 social visits based on relationships.
	_last_plan_day = _get_current_day()
	_daily_plan.clear()

	var friends: Array[String] = Relationships.get_closest_friends(npc_name, 2)
	if friends.is_empty():
		return

	# Visit best friend during afternoon break
	var friend_name: String = friends[0]
	var friend_workplace: String = _get_npc_workplace(friend_name)
	if friend_workplace != "" and friend_workplace != workplace_building:
		_daily_plan.append({
			"hour": 15,
			"end_hour": 16,
			"destination": friend_workplace,
			"reason": "visit %s" % friend_name,
			"completed": false,
		})

	if OS.is_debug_build():
		print("[Planning] %s — fallback plan: %d items" % [npc_name, _daily_plan.size()])


func _get_npc_workplace(target_name: String) -> String:
	## Look up another NPC's workplace.
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		var other: CharacterBody2D = npc as CharacterBody2D
		if other.npc_name == target_name:
			return other.workplace_building
	return ""


func _build_planning_system_prompt() -> String:
	var prompt: String = "You are %s, a %d-year-old %s in DeepTown. %s\n\n" % [npc_name, age, job, personality]
	prompt += "You are planning your day. Generate 2-4 specific plans beyond your normal routine. Each plan should have a TIME (hour 6-22), a DESTINATION (must be one of the buildings listed below), and a short REASON.\n\n"
	prompt += "Available buildings: Bakery, General Store, Tavern, Church, Sheriff Office, Courthouse, Blacksmith\n\n"

	# Bug 4: NPC roster to prevent hallucinated names
	prompt += "People who live and work in this town:\n"
	prompt += "- Maria: Baker, works at Bakery, lives at House 1\n"
	prompt += "- Thomas: Shopkeeper, works at General Store, lives at House 2\n"
	prompt += "- Elena: Sheriff, works at Sheriff Office, lives at House 3\n"
	prompt += "- Gideon: Blacksmith, works at Blacksmith, lives at House 4\n"
	prompt += "- Rose: Barmaid, works at Tavern, lives at House 5\n"
	prompt += "- Lyra: Clerk, works at Courthouse, lives at House 6\n"
	prompt += "- Finn: Farmer/laborer, delivers to General Store, lives at House 7 (married to Clara)\n"
	prompt += "- Clara: Devout churchgoer, helps at Church, lives at House 7 (married to Finn)\n"
	prompt += "- Bram: Apprentice blacksmith, works at Blacksmith with Gideon, lives at House 8\n"
	prompt += "- Old Silas: Retired storyteller, spends time at Tavern, lives at House 9\n"
	prompt += "- Father Aldric: Priest, works at Church, lives at House 10\n"
	prompt += "\nIMPORTANT: Only reference people from this list. Do NOT invent names.\n\n"

	prompt += "Rules:\n"
	prompt += "- You work at the %s from roughly 6-15\n" % workplace_building
	prompt += "- Plans should be for BREAKS or AFTER WORK (during work hours, plan short 1-2 hour visits only)\n"
	prompt += "- Plans should involve visiting other NPCs, checking on things, or personal goals\n"
	prompt += "- Be specific about WHO you want to see and WHY\n"
	prompt += "- Format each plan as: HOUR|DESTINATION|REASON (one per line)\n"
	prompt += "- Example: 11|Church|Visit Father Aldric to ask about the Sunday service\n"
	prompt += "- Example: 16|Tavern|Have a drink with Rose and catch up on news\n"
	prompt += "- Do NOT plan for hours 23-5 (sleep time)\n"
	prompt += "- Do NOT plan to visit your own workplace during core work hours (you're already there)"
	return prompt


func _build_planning_context() -> String:
	var context: String = ""

	# Yesterday's reflections
	var reflections: Array[Dictionary] = memory.get_by_type("reflection")
	if not reflections.is_empty():
		reflections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "Your recent thoughts:\n"
		for ref: Dictionary in reflections.slice(0, mini(3, reflections.size())):
			context += "- %s\n" % ref.get("description", "")
		context += "\n"

	# Key relationships
	var all_rels: Dictionary = Relationships.get_all_for(npc_name)
	if not all_rels.is_empty():
		context += "Your relationships:\n"
		for target: String in all_rels:
			var label: String = Relationships.get_opinion_label(npc_name, target)
			context += "- You %s %s\n" % [label, target]
		context += "\n"

	# Recent gossip (what you've heard)
	var gossip: Array[Dictionary] = memory.get_by_type("gossip")
	if not gossip.is_empty():
		gossip.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "Things you've heard recently:\n"
		for g: Dictionary in gossip.slice(0, mini(3, gossip.size())):
			context += "- %s\n" % g.get("description", "")
		context += "\n"

	# Recent notable events
	var recent: Array[Dictionary] = memory.get_recent(5)
	if not recent.is_empty():
		context += "Recent events:\n"
		for mem: Dictionary in recent:
			context += "- %s\n" % mem.get("description", "")
		context += "\n"

	context += "What 2-4 specific things do you want to do today beyond your normal routine? Format: HOUR|DESTINATION|REASON"
	return context


func _parse_plan(text: String) -> Array[Dictionary]:
	## Parse "HOUR|DESTINATION|REASON" lines from Gemini output.
	var plans: Array[Dictionary] = []
	var valid_buildings: Array[String] = [
		"Bakery", "General Store", "Tavern", "Church",
		"Sheriff Office", "Courthouse", "Blacksmith",
	]
	# Also include all house names as valid destinations
	for i: int in range(1, 12):
		valid_buildings.append("House %d" % i)

	var lines: PackedStringArray = text.split("\n")
	for line: String in lines:
		var cleaned: String = line.strip_edges()
		if cleaned == "":
			continue

		# Remove leading numbering or bullets
		if cleaned.length() > 2 and cleaned[0].is_valid_int() and (cleaned[1] == '.' or cleaned[1] == ')' or cleaned[1] == ':'):
			if cleaned[1] != '|':
				cleaned = cleaned.substr(2).strip_edges()

		var parts: PackedStringArray = cleaned.split("|")
		if parts.size() < 3:
			continue

		var hour_str: String = parts[0].strip_edges()
		var dest: String = parts[1].strip_edges()
		var reason: String = parts[2].strip_edges()

		# Validate hour
		var hour: int = hour_str.to_int()
		if hour < 6 or hour > 22:
			continue

		# Validate destination — find closest match
		var matched_dest: String = _match_building_name(dest, valid_buildings)
		if matched_dest == "":
			continue

		# Don't plan to go to your own workplace during core work hours
		if matched_dest == workplace_building and hour >= 6 and hour < 15:
			continue

		plans.append({
			"hour": hour,
			"end_hour": mini(hour + 2, 22),
			"destination": matched_dest,
			"reason": reason,
			"completed": false,
		})

	# Cap at 4 plans
	if plans.size() > 4:
		plans.resize(4)

	# Sort by hour
	plans.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["hour"] < b["hour"]
	)

	return plans


func _match_building_name(input: String, valid_names: Array[String]) -> String:
	## Fuzzy match building name from Gemini output.
	var input_lower: String = input.to_lower()
	for name: String in valid_names:
		if input_lower == name.to_lower():
			return name
		if name.to_lower().contains(input_lower) or input_lower.contains(name.to_lower()):
			return name
	return ""


func _get_active_plan_destination(hour: int) -> String:
	## Check if any plan is active for the current hour.
	## Returns the destination or "" if no active plan.
	for plan: Dictionary in _daily_plan:
		if plan["completed"]:
			continue
		if hour >= plan["hour"] and hour < plan["end_hour"]:
			return plan["destination"]
		# Mark plans as completed if we're past their window
		if hour >= plan["end_hour"]:
			plan["completed"] = true
	return ""


func _get_current_plan() -> Dictionary:
	## Returns the active plan for the current hour, or {}.
	var hour: int = GameClock.hour
	for plan: Dictionary in _daily_plan:
		if plan["completed"]:
			continue
		if hour >= plan["hour"] and hour < plan["end_hour"]:
			return plan
	return {}


func _pair_key(a: String, b: String) -> String:
	## Canonical key for a pair of NPC names (alphabetical order).
	if a < b:
		return a + ":" + b
	return b + ":" + a


func _face_toward(target_pos: Vector2) -> void:
	## Flip sprite to face toward the target position.
	if target_pos.x < global_position.x:
		sprite.flip_h = true
	elif target_pos.x > global_position.x:
		sprite.flip_h = false


func _on_hour_changed(hour: int) -> void:
	# Midnight: reset counts + run memory maintenance
	if hour == 0:
		_conv_counts_today.clear()
		_run_midnight_maintenance()

	# Instant hunger restoration at meal times if at home
	if _current_destination == home_building and hour in [7, 12, 19]:
		hunger = minf(hunger + 30.0, 100.0)
	_update_destination(hour)
	# Activities change by time of day even without destination change
	if not _is_moving:
		_update_activity()
	if OS.is_debug_build():
		print("[Activity] %s: %s (at %s)" % [npc_name, current_activity, _current_destination])

	# Daily planning — generate plan at dawn
	if hour == 5 and _last_plan_day != _get_current_day():
		_generate_daily_plan()


func _on_time_tick(_game_minute: int) -> void:
	# Decay needs every game minute
	hunger = maxf(hunger - 0.08, 0.0)
	energy = maxf(energy - 0.1, 0.0)
	social = maxf(social - 0.05, 0.0)

	# Energy restoration: sleeping at home (22-06)
	if _current_destination == home_building and (GameClock.hour >= 22 or GameClock.hour < 6):
		energy = minf(energy + 0.5, 100.0)

	# Social restoration: other NPCs within 3 tiles (96px)
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		if npc == self:
			continue
		if global_position.distance_to(npc.global_position) <= 96.0:
			social = minf(social + 0.3, 100.0)
			break  # Only need one nearby NPC to get the bonus

	# Re-evaluate destination every 5 game minutes based on needs
	if GameClock.total_minutes % 5 == 0:
		var new_dest: String = _get_schedule_destination(GameClock.hour)
		if new_dest != _current_destination:
			# Bug 9: Enforce minimum stay (except emergencies and sleep)
			var is_emergency: bool = hunger < 20.0 or energy < 20.0 or GameClock.hour >= 23 or GameClock.hour < 5
			var can_leave: bool = is_emergency or _dest_arrival_time <= 0 or (GameClock.total_minutes - _dest_arrival_time) >= MIN_STAY_MINUTES
			if can_leave:
				_update_destination(GameClock.hour)

	# Try NPC-to-NPC conversation every 15 game minutes when not moving
	if GameClock.total_minutes % 15 == 0 and not _is_moving:
		_try_npc_conversation()

	# Periodic perception scan every 30 game minutes (fix for already-overlapping bodies)
	if GameClock.total_minutes % 30 == 0:
		_scan_perception_area()
		_scan_environment()

	# Reflections now triggered by importance threshold in _add_memory_with_embedding()


func get_mood() -> float:
	return (hunger + energy + social) / 3.0


# --- Dialogue ---

func get_dialogue_response() -> String:
	## Synchronous template-based response. Used as immediate fallback.
	return _get_template_response()


func get_dialogue_response_async(callback: Callable) -> void:
	## Async dialogue: tries Gemini first, falls back to template.
	## Callback receives (response: String).
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		_face_toward(player.global_position)

	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	var system_prompt: String = _build_system_prompt()
	var user_message: String = _build_dialogue_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		if success and text != "":
			# Store this conversation as a memory
			_add_memory_with_embedding(
				"Talked with %s at the %s. I said: %s" % [PlayerProfile.player_name, _current_destination, text.left(80)],
				"dialogue", PlayerProfile.player_name, [npc_name, PlayerProfile.player_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)
			# Opening greeting — no relationship bump yet (player hasn't said anything)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func get_conversation_reply_async(player_message: String, history: Array[Dictionary], callback: Callable) -> void:
	## Generate a reply considering full conversation history.
	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	var system_prompt: String = _build_system_prompt()
	var context: String = _build_dialogue_context()
	context += "\n\nConversation so far:\n"
	for msg: Dictionary in history:
		context += "%s: \"%s\"\n" % [msg["speaker"], msg["text"]]
	context += "\n%s just said: \"%s\"\n" % [PlayerProfile.player_name, player_message]
	context += "\nRespond naturally in character. 1-3 sentences. Continue the conversation based on what %s said." % PlayerProfile.player_name

	GeminiClient.generate(system_prompt, context, func(text: String, success: bool) -> void:
		if success and text != "":
			_add_memory_with_embedding(
				"Talked with %s at the %s. They said: \"%s\" and I replied: \"%s\"" % [
					PlayerProfile.player_name, _current_destination,
					player_message.left(40), text.left(40)],
				"dialogue", PlayerProfile.player_name,
				[npc_name, PlayerProfile.player_name] as Array[String],
				_current_destination, _current_destination, 5.0, 0.3
			)
			# Content-aware impact analysis (replaces flat +1/+1 and player summary update)
			_analyze_player_conversation_impact(player_message, text)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func _build_system_prompt() -> String:
	var prompt: String = "You are %s, a %d-year-old %s in the town of DeepTown. %s\n\nYour speech style: %s\n\n" % [
		npc_name, age, job, personality, speech_style
	]

	# Core memory: emotional state
	var emotional_state: String = memory.core_memory.get("emotional_state", "")
	if emotional_state != "":
		prompt += "Current mood: %s\n" % emotional_state

	# Core memory: what I know about the player
	var player_summary: String = memory.core_memory.get("player_summary", "")
	if player_summary != "" and not player_summary.begins_with("I haven't met"):
		prompt += "What you know about %s: %s\n" % [PlayerProfile.player_name, player_summary]

	# Core memory: NPC relationship summaries
	var npc_summaries: Dictionary = memory.core_memory.get("npc_summaries", {})
	for npc_n: String in npc_summaries:
		prompt += "About %s: %s\n" % [npc_n, npc_summaries[npc_n]]

	# Core memory: key facts
	var key_facts: Array = memory.core_memory.get("key_facts", [])
	if not key_facts.is_empty():
		prompt += "Important things you know: %s\n" % ", ".join(key_facts)

	prompt += "\n"

	# Add top relationships to identity
	var friends: Array[String] = Relationships.get_closest_friends(npc_name, 3)
	if not friends.is_empty():
		var rel_lines: Array[String] = []
		for friend: String in friends:
			var label: String = Relationships.get_opinion_label(npc_name, friend)
			rel_lines.append("You %s %s" % [label, friend])
		prompt += "Key relationships: %s.\n\n" % ", ".join(rel_lines)

	prompt += "There is a newcomer in town named %s. They recently moved into House 11 on the south row. They seem curious about the town and its people.\n\n" % PlayerProfile.player_name
	prompt += "Rules:\n- Respond in character, first person, 1-3 sentences only\n- Never break character or mention being an AI\n- Let your personality shine through every word\n- Reference your memories naturally if relevant\n- Your mood and needs should affect how you talk\n- You can ask %s questions too — be curious about the newcomer\n- React to what they say, don't just give generic responses" % PlayerProfile.player_name
	return prompt


func _build_dialogue_context() -> String:
	var hour: int = GameClock.hour
	var period: String = "night"
	if hour >= 5 and hour < 8:
		period = "dawn"
	elif hour >= 8 and hour < 12:
		period = "morning"
	elif hour >= 12 and hour < 17:
		period = "afternoon"
	elif hour >= 17 and hour < 21:
		period = "evening"

	var mood: float = get_mood()
	var mood_desc: String = "miserable" if mood < 20.0 else "unhappy" if mood < 40.0 else "okay" if mood < 60.0 else "good" if mood < 80.0 else "great"

	var activity_str: String = current_activity if current_activity != "" else "standing around"
	var context: String = "Current situation: It is %s (%s). You are at the %s. You are currently %s. Your mood is %s (%d/100).\n\n" % [
		GameClock.get_time_string(), period, _current_destination, activity_str, mood_desc, int(mood)
	]

	context += "Your needs:\n"
	context += "- Hunger: %d/100 %s\n" % [int(hunger), "(starving!)" if hunger < 20.0 else "(hungry)" if hunger < 40.0 else "(fine)"]
	context += "- Energy: %d/100 %s\n" % [int(energy), "(exhausted!)" if energy < 20.0 else "(tired)" if energy < 40.0 else "(fine)"]
	context += "- Social: %d/100 %s\n\n" % [int(social), "(lonely)" if social < 30.0 else "(could use company)" if social < 50.0 else "(content)"]

	# Relationship with the player (per-dimension descriptions)
	var trust_label: String = Relationships.get_trust_label(npc_name, PlayerProfile.player_name)
	var affec_label: String = Relationships.get_affection_label(npc_name, PlayerProfile.player_name)
	var respe_label: String = Relationships.get_respect_label(npc_name, PlayerProfile.player_name)
	context += "Your relationship with %s (the person you're talking to):\n" % PlayerProfile.player_name
	context += "- Trust: You %s them\n" % trust_label
	context += "- Affection: You %s them\n" % affec_label
	context += "- Respect: You %s them\n" % respe_label
	var player_core_summary: String = memory.core_memory.get("player_summary", "")
	if player_core_summary != "":
		context += "- Your feelings: %s\n" % player_core_summary
	context += "\nRespond naturally based on these feelings. Low trust = guarded. High affection = warm. Negative respect = dismissive. Never mention numbers.\n\n"

	# Include nearby object states for richer context
	var building_objects: Array[Dictionary] = WorldObjects.get_objects_in_building(_current_destination)
	if not building_objects.is_empty():
		var active_objects: Array[String] = []
		for obj: Dictionary in building_objects:
			if obj["state"] != "idle":
				active_objects.append("the %s is %s" % [obj["tile_type"], obj["state"]])
		if not active_objects.is_empty():
			context += "Around you: %s.\n\n" % ", ".join(active_objects)

	# Retrieve top 5 recent memories
	var recent_memories: Array[Dictionary] = memory.get_recent(5)
	if not recent_memories.is_empty():
		context += "Your recent memories:\n"
		for mem: Dictionary in recent_memories:
			var hours_ago: int = maxi((GameClock.total_minutes - mem.get("game_time", 0)) / 60, 0)
			var time_str: String = "%d hours ago" % hours_ago if hours_ago > 0 else "just now"
			context += "- %s: %s\n" % [time_str, mem.get("description", "")]
		context += "\n"

	# Include recent reflections (insights) for richer dialogue
	var reflections: Array[Dictionary] = memory.get_by_type("reflection")
	if not reflections.is_empty():
		reflections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		var recent_reflections: Array[Dictionary] = reflections.slice(0, mini(3, reflections.size()))
		context += "Your recent thoughts and realizations:\n"
		for ref: Dictionary in recent_reflections:
			context += "- %s\n" % ref.get("description", "")
		context += "\n"

	# Include notable environment observations
	var env_memories: Array[Dictionary] = memory.get_by_type("environment")
	if not env_memories.is_empty():
		env_memories.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		var recent_env: Array[Dictionary] = env_memories.slice(0, mini(3, env_memories.size()))
		var env_strs: Array[String] = []
		for mem: Dictionary in recent_env:
			env_strs.append(mem.get("description", ""))
		if not env_strs.is_empty():
			context += "Things you've noticed around town: %s.\n\n" % ". ".join(env_strs)

	# Gossip the NPC has heard — may come up in conversation
	var gossip_memories: Array[Dictionary] = memory.get_by_type("gossip")
	if not gossip_memories.is_empty():
		gossip_memories.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		var recent_gossip: Array[Dictionary] = gossip_memories.slice(0, mini(2, gossip_memories.size()))
		context += "Things you've heard from others:\n"
		for g: Dictionary in recent_gossip:
			context += "- %s\n" % g.get("description", "")
		context += "\n"

	# Specifically surface gossip about the player
	var player_gossip: Array[Dictionary] = []
	for g: Dictionary in memory.get_by_type("gossip"):
		if g.get("actor", "") == PlayerProfile.player_name:
			player_gossip.append(g)
	if not player_gossip.is_empty():
		player_gossip.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "You've heard things about this person from others:\n"
		for pg: Dictionary in player_gossip.slice(0, mini(3, player_gossip.size())):
			context += "- %s\n" % pg.get("description", "")
		context += "\n"

	# Today's plans
	var upcoming_plans: Array[String] = []
	for plan: Dictionary in _daily_plan:
		if not plan["completed"]:
			upcoming_plans.append("At %d:00 — %s at the %s" % [plan["hour"], plan["reason"], plan["destination"]])
	if not upcoming_plans.is_empty():
		context += "Your plans for today:\n"
		for p: String in upcoming_plans:
			context += "- %s\n" % p
		context += "\n"

	context += "%s is standing in front of you and wants to talk. They recently moved to DeepTown and live in House 11. Respond naturally." % PlayerProfile.player_name
	return context


func _analyze_player_conversation_impact(player_text: String, npc_response: String) -> void:
	## Analyze conversation content to determine relationship impact via Flash Lite.
	## Replaces flat +1/+1 with content-aware trust/affection/respect changes.
	## Also updates core memory: emotional_state, player_summary, key_facts.
	if not GeminiClient.has_api_key():
		Relationships.modify(npc_name, PlayerProfile.player_name, 1, 1, 0)
		return

	var rel: Dictionary = Relationships.get_relationship(npc_name, PlayerProfile.player_name)
	var old_summary: String = memory.core_memory.get("player_summary", "")
	var identity_text: String = memory.core_memory.get("identity", personality)
	var summary_or_default: String = old_summary if old_summary != "" else "No prior impression"

	var prompt: String = "You are analyzing a conversation between %s and %s in a small fantasy town.\n\n%s's personality: %s\n%s's current feelings about %s: %s\nCurrent relationship — Trust: %d, Affection: %d, Respect: %d\n\nThe conversation:\n%s said: \"%s\"\n%s replied: \"%s\"\n\nBased on what %s said, how should %s's feelings change?\n\nRespond ONLY with this exact JSON, no other text:\n{\"trust_change\": 0, \"affection_change\": 0, \"respect_change\": 0, \"emotional_state\": \"how %s feels now\", \"player_summary_update\": \"updated 1-2 sentence summary of what %s thinks about %s\", \"key_fact\": \"new fact learned, or empty string\"}\n\nScoring rules:\n- Values between -5 and +5\n- 0 = neutral small talk\n- +1 to +2 = friendly, positive, helpful\n- +3 to +5 = deeply meaningful, vulnerable, generous\n- -1 to -2 = rude, dismissive\n- -3 to -5 = threatening, insulting, betrayal\n- Trust: honesty/promises (+) vs lying/sketchy (-)\n- Affection: warmth/humor/compliments (+) vs coldness/insults (-)\n- Respect: competence/bravery/wisdom (+) vs cowardice/disrespect (-)" % [
		npc_name, PlayerProfile.player_name,
		npc_name, identity_text.left(150),
		npc_name, PlayerProfile.player_name, summary_or_default,
		rel["trust"], rel["affection"], rel["respect"],
		PlayerProfile.player_name, player_text.left(200),
		npc_name, npc_response.left(200),
		PlayerProfile.player_name, npc_name,
		npc_name, npc_name, PlayerProfile.player_name
	]

	GeminiClient.generate(
		"You analyze conversation impact on relationships. Return ONLY valid JSON.",
		prompt,
		func(text: String, success: bool) -> void:
			if not success or text == "":
				Relationships.modify(npc_name, PlayerProfile.player_name, 1, 1, 0)
				return
			_apply_player_impact(text),
		GeminiClient.MODEL_LITE
	)


func _apply_player_impact(raw_json: String) -> void:
	## Parse and apply the impact analysis from Flash Lite.
	var data: Variant = GeminiClient.parse_json_response(raw_json)
	if data == null or not data is Dictionary:
		Relationships.modify(npc_name, PlayerProfile.player_name, 1, 1, 0)
		return

	var trust_d: int = clampi(int(data.get("trust_change", 0)), -5, 5)
	var affec_d: int = clampi(int(data.get("affection_change", 0)), -5, 5)
	var respe_d: int = clampi(int(data.get("respect_change", 0)), -5, 5)

	if trust_d != 0 or affec_d != 0 or respe_d != 0:
		Relationships.modify(npc_name, PlayerProfile.player_name, trust_d, affec_d, respe_d)
	else:
		# Pure small talk — tiny trust bump for showing up
		Relationships.modify(npc_name, PlayerProfile.player_name, 1, 0, 0)

	# Update core memory
	var new_emotion: String = data.get("emotional_state", "")
	if new_emotion != "":
		memory.update_emotional_state(new_emotion.left(150))

	var new_summary: String = data.get("player_summary_update", "")
	if new_summary != "":
		memory.update_player_summary(new_summary.left(200))

	var new_fact: String = data.get("key_fact", "")
	if new_fact != "" and new_fact.length() > 3:
		memory.add_key_fact(new_fact.left(100))

	# Update emotional valence on the most recent player dialogue memory
	var total: int = trust_d + affec_d + respe_d
	var recent_mems: Array = memory.memories
	for i: int in range(recent_mems.size() - 1, maxi(recent_mems.size() - 3, -1), -1):
		if recent_mems[i].get("type", "") == "dialogue" and PlayerProfile.player_name in recent_mems[i].get("entities", []):
			recent_mems[i]["emotional_valence"] = clampf(float(total) / 10.0, -1.0, 1.0)
			break

	if OS.is_debug_build():
		print("[Impact] %s→%s: T:%+d A:%+d R:%+d" % [npc_name, PlayerProfile.player_name, trust_d, affec_d, respe_d])


func _analyze_npc_conversation_impact(other_npc: CharacterBody2D, my_line: String, their_line: String) -> void:
	## Analyze NPC-to-NPC conversation for bidirectional relationship impact.
	var other_name: String = other_npc.npc_name
	_npc_conv_totals[other_name] = _npc_conv_totals.get(other_name, 0) + 1

	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 8:
		Relationships.modify_mutual(npc_name, other_name, 1, 1, 0)
		return

	var rel: Dictionary = Relationships.get_relationship(npc_name, other_name)
	var prompt: String = "Conversation between %s and %s:\n%s: \"%s\"\n%s: \"%s\"\n\nCurrent relationship: Trust:%d Affection:%d Respect:%d\n\nFor EACH person, rate how feelings change. JSON only:\n{\"a_to_b\": {\"trust\": 0, \"affection\": 0, \"respect\": 0}, \"b_to_a\": {\"trust\": 0, \"affection\": 0, \"respect\": 0}}\nValues -3 to +3. 0 for casual chat." % [
		npc_name, other_name,
		npc_name, my_line.left(120),
		other_name, their_line.left(120),
		rel["trust"], rel["affection"], rel["respect"]
	]

	GeminiClient.generate(
		"Analyze conversation impact. Return ONLY valid JSON.",
		prompt,
		func(text: String, success: bool) -> void:
			_apply_npc_impact(other_npc, text, success, my_line, their_line),
		GeminiClient.MODEL_LITE
	)


func _apply_npc_impact(other_npc: CharacterBody2D, raw_json: String, success: bool, my_line: String, their_line: String) -> void:
	## Parse and apply bidirectional NPC-NPC conversation impact.
	var other_name: String = other_npc.npc_name if is_instance_valid(other_npc) else ""
	if not success or raw_json == "" or other_name == "":
		if other_name != "":
			Relationships.modify_mutual(npc_name, other_name, 1, 1, 0)
		return

	var data: Variant = GeminiClient.parse_json_response(raw_json)
	if data == null or not data is Dictionary:
		Relationships.modify_mutual(npc_name, other_name, 1, 1, 0)
		return

	var a2b: Dictionary = data.get("a_to_b", {})
	var b2a: Dictionary = data.get("b_to_a", {})

	var a_t: int = clampi(int(a2b.get("trust", 0)), -3, 3)
	var a_a: int = clampi(int(a2b.get("affection", 0)), -3, 3)
	var a_r: int = clampi(int(a2b.get("respect", 0)), -3, 3)
	var b_t: int = clampi(int(b2a.get("trust", 0)), -3, 3)
	var b_a: int = clampi(int(b2a.get("affection", 0)), -3, 3)
	var b_r: int = clampi(int(b2a.get("respect", 0)), -3, 3)

	# If all zero, give minimal +1 trust for showing up
	if a_t == 0 and a_a == 0 and a_r == 0:
		a_t = 1
	if b_t == 0 and b_a == 0 and b_r == 0:
		b_t = 1
	Relationships.modify(npc_name, other_name, a_t, a_a, a_r)
	Relationships.modify(other_name, npc_name, b_t, b_a, b_r)

	# NPC summary update — every 3rd conversation OR total magnitude >= 3
	var total_mag: int = absi(a_t) + absi(a_a) + absi(a_r)
	var conv_count: int = _npc_conv_totals.get(other_name, 0)
	if total_mag >= 3 or conv_count % 3 == 0:
		_update_npc_summary_async(other_name, my_line, their_line)

	if OS.is_debug_build():
		print("[NPC Impact] %s→%s: T:%+d A:%+d R:%+d | %s→%s: T:%+d A:%+d R:%+d" % [
			npc_name, other_name, a_t, a_a, a_r,
			other_name, npc_name, b_t, b_a, b_r])


func _update_npc_summary_async(other_name: String, my_line: String, their_line: String) -> void:
	## Ask Flash Lite to update this NPC's impression of another NPC after conversation.
	if not GeminiClient.has_api_key():
		return
	var old_summary: String = memory.core_memory.get("npc_summaries", {}).get(other_name, "No prior impression")
	var prompt: String = "%s had this exchange with %s: \"%s\" / \"%s\"\nPrevious impression of %s: \"%s\"\nWrite a 1-2 sentence updated impression:" % [
		npc_name, other_name, my_line.left(100), their_line.left(100), other_name, old_summary
	]
	GeminiClient.generate(
		"You are %s. Write a brief 1-2 sentence impression of %s." % [npc_name, other_name],
		prompt,
		func(text: String, success: bool) -> void:
			if success and text != "":
				memory.update_npc_summary(other_name, text.strip_edges().left(200))
				if OS.is_debug_build():
					print("[Memory] %s updated summary of %s: %s" % [npc_name, other_name, text.strip_edges().left(80)]),
		GeminiClient.MODEL_LITE
	)


func _get_template_response() -> String:
	## Fallback template responses when LLM is unavailable.
	if energy < 20.0:
		return "*yawns* I'm exhausted... heading home to rest."
	if hunger < 20.0:
		return "I'm starving, need to go eat."

	# Activity-aware response (50% chance when doing something specific)
	if current_activity != "" and not current_activity.begins_with("standing") and not current_activity.begins_with("at the"):
		var activity_responses: Array[String] = [
			"Can't you see I'm %s? But sure, what do you need?" % current_activity,
			"Oh, hello! Just %s here. What brings you by?" % current_activity,
			"Ah, a visitor! I was just %s." % current_activity,
		]
		if randf() < 0.5:
			return activity_responses[randi() % activity_responses.size()]

	var player_memories: Array[Dictionary] = memory.get_memories_about(PlayerProfile.player_name)
	if player_memories.is_empty():
		player_memories = memory.get_memories_about("Player")  # backward compat
	if not player_memories.is_empty():
		var latest: Dictionary = player_memories[-1]
		var location: String = latest.get("observed_near", latest.get("observer_location", "town"))
		var hours_ago: int = (GameClock.total_minutes - latest.get("game_time", 0)) / 60
		if hours_ago < 1:
			return "Oh, I just saw you over by the %s! What brings you here?" % location
		elif hours_ago < 12:
			return "I saw you near the %s earlier today. How's your day going?" % location
		else:
			return "I remember seeing you around the %s a while back." % location

	var mood: float = get_mood()
	if mood > 70.0:
		return "Beautiful day, isn't it? Work at the %s is going well." % workplace_building
	elif mood > 40.0:
		return "Just another day at the %s." % workplace_building
	else:
		return "I'm not feeling great today..."


# --- Scheduling ---

func _update_destination(hour: int) -> void:
	if _astar == null:
		return

	var dest: String = _get_schedule_destination(hour)
	if dest == _current_destination:
		return

	# Release current furniture and tile reservation before moving
	_release_current_object()
	if _town_map and _town_map.has_method("release_tile"):
		var old_grid := Vector2i(int(global_position.x) / TILE_SIZE, int(global_position.y) / TILE_SIZE)
		_town_map.release_tile(old_grid, npc_name)

	_current_destination = dest

	# Determine target position — prefer tile next to work furniture
	var target_pos: Vector2 = Vector2.ZERO
	var target_type: String = _get_target_furniture_type(dest)
	if target_type != "" and _town_map:
		var obj_id: String = WorldObjects.find_object_for_npc(dest, target_type, npc_name)
		if obj_id != "" and WorldObjects._objects.has(obj_id):
			var obj_grid: Vector2i = WorldObjects._objects[obj_id]["grid_pos"]
			if _town_map.has_method("get_furniture_adjacent_tile"):
				target_pos = _town_map.get_furniture_adjacent_tile(obj_grid)

	# Fallback to unreserved interior tile if no furniture target
	if target_pos == Vector2.ZERO:
		if _building_interiors.has(dest) and _building_interiors[dest].size() > 0:
			if _town_map and _town_map.has_method("get_unreserved_interior_tile"):
				target_pos = _town_map.get_unreserved_interior_tile(dest, npc_name)
			else:
				var tiles: Array = _building_interiors[dest]
				target_pos = tiles[randi() % tiles.size()]
		else:
			target_pos = _building_positions.get(dest, Vector2.ZERO)

	if target_pos == Vector2.ZERO:
		push_warning("[%s] No position for building '%s'" % [npc_name, dest])
		return

	# Convert pixel positions to grid coordinates
	var from_grid := Vector2i(
		int(global_position.x) / TILE_SIZE,
		int(global_position.y) / TILE_SIZE
	)
	var to_grid := Vector2i(
		int(target_pos.x) / TILE_SIZE,
		int(target_pos.y) / TILE_SIZE
	)

	# Clamp to grid bounds
	var map_w: int = _town_map.MAP_WIDTH if _town_map else 60
	var map_h: int = _town_map.MAP_HEIGHT if _town_map else 45
	from_grid.x = clampi(from_grid.x, 0, map_w - 1)
	from_grid.y = clampi(from_grid.y, 0, map_h - 1)
	to_grid.x = clampi(to_grid.x, 0, map_w - 1)
	to_grid.y = clampi(to_grid.y, 0, map_h - 1)

	# Get path from A*
	_path = _astar.get_point_path(from_grid, to_grid)

	if _path.is_empty():
		push_warning("[%s] A* found no path from %s to %s (dest: '%s')" % [
			npc_name, from_grid, to_grid, dest])
		return

	_path_index = 0
	_is_moving = true
	_update_activity()
	print("[%s] Hour %d -> '%s' | Path: %d waypoints | From %s -> %s" % [
		npc_name, hour, dest, _path.size(), from_grid, to_grid])


func _get_schedule_destination(hour: int) -> String:
	## Needs-driven scheduling with personality-based flexibility.
	## NOW INCLUDES: daily plan overrides.

	# Emergency overrides (ALWAYS highest priority)
	if hunger < 20.0 or energy < 20.0:
		return home_building

	# Sleep time — everyone goes home (ALWAYS)
	if hour >= 23 or hour < 5:
		return home_building

	# --- CHECK DAILY PLAN ---
	var plan_dest: String = _get_active_plan_destination(hour)
	if plan_dest != "":
		return plan_dest

	# Morning wake-up (5-6) — head to work
	if hour >= 5 and hour < 6:
		return workplace_building

	# Core work hours (6-15)
	if hour >= 6 and hour < 15:
		# Lunch break: go home to eat if hungry
		if hour >= 11 and hour < 13 and hunger < 60.0:
			return home_building
		# Bug 11: Only allow spontaneous Church visits after hour 8 (not during early work)
		if hour >= 8 and _wants_to_visit("Church", hour):
			return "Church"
		return workplace_building

	# Afternoon (15-17) — flexible time
	if hour >= 15 and hour < 17:
		if social < 40.0:
			return "Tavern"
		if hunger < 50.0:
			return home_building
		return workplace_building

	# Evening (17-20) — social time
	if hour >= 17 and hour < 20:
		# Bug 9: Only leave Tavern if truly exhausted (was: social > 80 && energy < 40)
		if energy < 20.0:
			return home_building
		return "Tavern"

	# Late evening (20-23) — winding down
	if hour >= 20 and hour < 23:
		if energy < 50.0:
			return home_building
		if social < 50.0:
			return "Tavern"
		return home_building

	return home_building


func _wants_to_visit(building: String, _hour: int) -> bool:
	## Returns true occasionally based on personality.
	if GameClock.total_minutes < _next_visit_check:
		return false

	# Only check once per game hour
	_next_visit_check = GameClock.total_minutes + 60

	# 10% chance of a spontaneous Church visit during work hours
	if building == "Church" and workplace_building != "Church":
		if randf() < 0.10:
			return true

	return false


# --- NPC-to-NPC Conversations ---

func _try_npc_conversation() -> void:
	## If another NPC is within range and we haven't talked recently, have a real conversation.

	# Bug 2: Don't chat while sleeping or during night hours
	if current_activity.begins_with("sleeping"):
		return
	if GameClock.hour >= 22 or GameClock.hour < 5:
		return

	for other: Node in get_tree().get_nodes_in_group("npcs"):
		if other == self:
			continue
		var other_npc: CharacterBody2D = other as CharacterBody2D

		# Bug 2: Other NPC must also be awake
		if other_npc.current_activity.begins_with("sleeping"):
			continue

		# Bug 6: Building-aware conversation distance
		var dist: float = other_npc.global_position.distance_to(global_position)
		var same_building: bool = _current_destination != "" and _current_destination == other_npc._current_destination
		var max_dist: float = 192.0 if same_building else 64.0
		if dist > max_dist:
			continue
		if other_npc._is_moving:
			continue

		var other_name: String = other_npc.npc_name

		# Cooldown check — 2 hours between conversations with same NPC
		if _last_conversation_time.has(other_name):
			if GameClock.total_minutes - _last_conversation_time[other_name] < CONVERSATION_COOLDOWN:
				continue

		# Bug 7: Daily cap per pair
		var pair: String = _pair_key(npc_name, other_name)
		if _conv_counts_today.get(pair, 0) >= MAX_CONV_PER_PAIR_PER_DAY:
			continue

		# Bug 7: Extended cooldown for cohabitants (same building)
		if _current_destination != "" and _current_destination == other_npc._current_destination:
			if _last_conversation_time.has(other_name):
				var mins_since: int = GameClock.total_minutes - _last_conversation_time[other_name]
				if mins_since < COOLDOWN_COHABIT_MINUTES:
					continue

		# Set cooldown for both
		_last_conversation_time[other_name] = GameClock.total_minutes
		other_npc._last_conversation_time[npc_name] = GameClock.total_minutes
		_conv_counts_today[pair] = _conv_counts_today.get(pair, 0) + 1

		# Face each other
		_face_toward(other_npc.global_position)
		other_npc._face_toward(global_position)

		# Social boost for both
		social = minf(social + 5.0, 100.0)
		other_npc.social = minf(other_npc.social + 5.0, 100.0)

		# If no API key, fall back to fake topic-label system
		if not GeminiClient.has_api_key():
			_fake_npc_conversation(other_npc)
			break

		# Real conversation: I speak first, then they reply
		_real_npc_conversation(other_npc)
		break  # Only one conversation per tick


func _fake_npc_conversation(other_npc: CharacterBody2D) -> void:
	## Fallback when Gemini is unavailable. Same as old behavior.
	var other_name: String = other_npc.npc_name
	var topic: String = _pick_conversation_topic(other_npc)

	_add_memory_with_embedding(
		"Had a conversation with %s about %s at the %s" % [other_name, topic, _current_destination],
		"dialogue", other_name, [npc_name, other_name] as Array[String],
		_current_destination, _current_destination, 3.0, 0.2
	)
	other_npc._add_memory_with_embedding(
		"Had a conversation with %s about %s at the %s" % [npc_name, topic, _current_destination],
		"dialogue", npc_name, [other_npc.npc_name, npc_name] as Array[String],
		_current_destination, _current_destination, 3.0, 0.2
	)
	# Fake conversations still get flat bump (no content to analyze)
	Relationships.modify_mutual(npc_name, other_name, 1, 1, 0)

	# Gossip phase — both NPCs may share something
	var gossip_mem: Dictionary = _pick_gossip_for(other_npc)
	if not gossip_mem.is_empty():
		_share_gossip_with(other_npc, gossip_mem)
	var reverse_gossip: Dictionary = other_npc._pick_gossip_for(self)
	if not reverse_gossip.is_empty():
		other_npc._share_gossip_with(self, reverse_gossip)

	print("[%s] Chatted with %s about %s (template)" % [npc_name, other_name, topic])


func _real_npc_conversation(other_npc: CharacterBody2D) -> void:
	## Gemini-powered 2-line exchange. I say something, they reply.

	# Skip if Gemini queue is backed up (cost control)
	if GeminiClient._request_queue.size() > 10:
		_fake_npc_conversation(other_npc)
		return

	var other_name: String = other_npc.npc_name
	var topic: String = _pick_conversation_topic(other_npc)

	# Build context for the initiator (me)
	var my_system: String = _build_npc_chat_system_prompt()
	var my_context: String = _build_npc_chat_context(other_npc, topic, "")

	# Step 1: I generate my opening line
	GeminiClient.generate(my_system, my_context, func(my_line: String, my_success: bool) -> void:
		if not my_success or my_line == "":
			my_line = _get_npc_chat_fallback(topic)

		my_line = my_line.strip_edges().replace("\"", "").left(120)

		# Step 2: Other NPC generates their reply
		var their_system: String = other_npc._build_npc_chat_system_prompt()
		var their_context: String = other_npc._build_npc_chat_context(self, topic, my_line)

		GeminiClient.generate(their_system, their_context, func(their_line: String, their_success: bool) -> void:
			if not their_success or their_line == "":
				their_line = other_npc._get_npc_chat_fallback(topic)

			their_line = their_line.strip_edges().replace("\"", "").left(120)

			# Store actual dialogue in both NPCs' memories
			_add_memory_with_embedding(
				"I said to %s: \"%s\" — %s replied: \"%s\" (at the %s)" % [
					other_name, my_line, other_name, their_line, _current_destination],
				"dialogue", other_name, [npc_name, other_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)

			other_npc._add_memory_with_embedding(
				"%s said to me: \"%s\" — I replied: \"%s\" (at the %s)" % [
					npc_name, my_line, their_line, _current_destination],
				"dialogue", npc_name, [other_npc.npc_name, npc_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)

			# Content-aware relationship impact (replaces flat +1/+1)
			_analyze_npc_conversation_impact(other_npc, my_line, their_line)

			# Show speech bubbles
			_show_speech_bubble(my_line)
			get_tree().create_timer(2.0).timeout.connect(func() -> void:
				if is_instance_valid(other_npc):
					other_npc._show_speech_bubble(their_line)
			)

			print("[NPC Chat] %s: \"%s\"" % [npc_name, my_line])
			print("[NPC Chat] %s: \"%s\"" % [other_name, their_line])
			print("[NPC Chat] %s→%s at %s (queue: %d, total_calls: %d)" % [
				npc_name, other_name, _current_destination,
				GeminiClient._request_queue.size(), GeminiClient.total_requests
			])

			# Gossip phase — initiator may share something interesting
			var gossip_mem: Dictionary = _pick_gossip_for(other_npc)
			if not gossip_mem.is_empty():
				_share_gossip_with(other_npc, gossip_mem)

			# Responder may also gossip back
			if is_instance_valid(other_npc):
				var reverse_gossip: Dictionary = other_npc._pick_gossip_for(self)
				if not reverse_gossip.is_empty():
					other_npc._share_gossip_with(self, reverse_gossip)
		)
	)


func _pick_conversation_topic(other_npc: CharacterBody2D) -> String:
	## Pick a topic based on context.
	var topics: Array[String] = []

	# Time based
	if GameClock.hour >= 17:
		topics.append("how their day went")
	if GameClock.hour < 8:
		topics.append("morning plans")

	# Needs based
	if hunger < 40.0:
		topics.append("food")
	if other_npc.energy < 40.0:
		topics.append("being tired")

	# Job based
	topics.append("work at the %s" % workplace_building)

	# Memory based — if I have a memory about the player
	var recent: Array[Dictionary] = memory.get_recent(3)
	for mem: Dictionary in recent:
		if mem.get("actor", "") == PlayerProfile.player_name or mem.get("actor", "") == "Player":
			topics.append("the newcomer %s" % PlayerProfile.player_name)
			break

	# Gossip-based topics
	var gossip_mems: Array[Dictionary] = memory.get_by_type("gossip")
	if not gossip_mems.is_empty():
		var latest_gossip: Dictionary = gossip_mems[-1]
		var gossip_about: String = latest_gossip.get("actor", "")
		if gossip_about != "" and gossip_about != other_npc.npc_name:
			topics.append("what they heard about %s" % gossip_about)

	# If I have interesting player observations, share them
	var player_mems: Array[Dictionary] = memory.get_memories_about(PlayerProfile.player_name)
	if not player_mems.is_empty():
		var latest: Dictionary = player_mems[-1]
		var hours_since: float = (GameClock.total_minutes - latest.get("game_time", 0)) / 60.0
		if hours_since < 24:
			topics.append("the newcomer %s" % PlayerProfile.player_name)

	# Random flavor
	topics.append_array(["the weather", "town gossip", "old times", "their families"])

	return topics[randi() % topics.size()]


func _build_npc_chat_system_prompt() -> String:
	## System prompt for NPC-to-NPC conversation (shorter than player dialogue).
	return "You are %s, age %d, %s in DeepTown. %s\nSpeech style: %s\n\nRules:\n- Say ONE sentence only, in character, first person\n- This is casual chat with a fellow townsperson, not a formal speech\n- Be natural — greetings, complaints, observations, jokes, gossip\n- Reference your current mood or needs if relevant\n- NEVER break character or mention being an AI" % [
		npc_name, age, job, personality, speech_style
	]


func _build_npc_chat_context(other_npc: CharacterBody2D, topic: String, their_line: String) -> String:
	## Build the user message for NPC-to-NPC conversation.
	var hour: int = GameClock.hour
	var period: String = "morning" if hour < 12 else ("afternoon" if hour < 17 else ("evening" if hour < 21 else "night"))

	var context: String = "It's %s at the %s. " % [period, _current_destination]

	# What you and the other NPC are doing
	if current_activity != "":
		context += "You are currently %s. " % current_activity
	if other_npc.current_activity != "":
		context += "%s is currently %s. " % [other_npc.npc_name, other_npc.current_activity]

	# Current plan context
	var current_plan: Dictionary = _get_current_plan()
	if not current_plan.is_empty():
		context += "You're here because you planned to: %s. " % current_plan.get("reason", "visit")

	# Relationship with conversation partner (per-dimension labels)
	var trust_l: String = Relationships.get_trust_label(npc_name, other_npc.npc_name)
	var affec_l: String = Relationships.get_affection_label(npc_name, other_npc.npc_name)
	var respe_l: String = Relationships.get_respect_label(npc_name, other_npc.npc_name)
	context += "You %s %s, %s them, and %s them. " % [trust_l, other_npc.npc_name, affec_l, respe_l]

	# Your current state
	if hunger < 40.0:
		context += "You're quite hungry. "
	if energy < 30.0:
		context += "You're exhausted. "
	if social > 80.0:
		context += "You're in a great mood. "

	# Recent relevant memories (top 3)
	var recent: Array[Dictionary] = memory.get_recent(3)
	if not recent.is_empty():
		context += "Recent memories: "
		for mem: Dictionary in recent:
			context += mem.get("description", "") + ". "

	# Recent reflections (top 2)
	var reflections: Array[Dictionary] = memory.get_by_type("reflection")
	if not reflections.is_empty():
		reflections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		for ref: Dictionary in reflections.slice(0, mini(2, reflections.size())):
			context += "You've been thinking: %s " % ref.get("description", "")

	# Shared environment context
	var env_memories: Array[Dictionary] = memory.get_by_type("environment")
	if not env_memories.is_empty():
		env_memories.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		var latest_env: Dictionary = env_memories[0]
		var hours_ago: int = (GameClock.total_minutes - latest_env.get("game_time", 0)) / 60
		if hours_ago < 6:
			context += "Earlier you noticed: %s. " % latest_env.get("description", "")

	# Gossip awareness — things you've heard about people
	var gossip_memories: Array[Dictionary] = memory.get_by_type("gossip")
	if not gossip_memories.is_empty():
		gossip_memories.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		var recent_gossip: Array[Dictionary] = gossip_memories.slice(0, mini(2, gossip_memories.size()))
		var gossip_strs: Array[String] = []
		for g: Dictionary in recent_gossip:
			gossip_strs.append(g.get("description", ""))
		context += "Things you've heard recently: %s. " % ". ".join(gossip_strs)

	# The conversation setup
	if their_line == "":
		# I'm starting the conversation
		context += "\nYou see %s (%s, age %d) nearby. Start a brief chat about %s. Say ONE sentence." % [
			other_npc.npc_name, other_npc.job, other_npc.age, topic
		]
	else:
		# I'm replying to them
		context += "\n%s just said to you: \"%s\"\nReply naturally with ONE sentence." % [
			other_npc.npc_name, their_line
		]

	return context


func _get_npc_chat_fallback(topic: String) -> String:
	## Fallback one-liner when Gemini fails mid-conversation.
	var fallbacks: Array[String] = [
		"Interesting weather we're having.",
		"Same old, same old around here.",
		"Can't complain, I suppose.",
		"Been busy at the %s lately." % workplace_building,
		"What do you think about %s?" % topic,
	]
	return fallbacks[randi() % fallbacks.size()]


func _show_speech_bubble(text: String) -> void:
	## Show floating text above this NPC's head for 4 seconds.
	# Remove any existing bubble first
	for child: Node in get_children():
		if child.has_method("show_text"):
			child.queue_free()

	var bubble: Node2D = Node2D.new()
	bubble.set_script(load("res://scripts/ui/speech_bubble.gd"))
	add_child(bubble)
	bubble.show_text(text, 4.0)


# --- Perception ---

func _on_perception_body_entered(body: Node2D) -> void:
	if body == self:
		return
	if not (body is CharacterBody2D):
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
	var observed_location: String = _estimate_location(body.global_position)
	var my_location: String = _current_destination

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
	_add_memory_with_embedding(description, "observation", actor_name,
		[npc_name, actor_name] as Array[String], my_location, observed_location, importance, valence)


func _estimate_location(pos: Vector2) -> String:
	## Returns the name of the nearest building to a world position.
	var closest_name: String = "town center"
	var closest_dist: float = INF
	for bld_name: String in _building_positions:
		var bld_pos: Vector2 = _building_positions[bld_name]
		var dist: float = pos.distance_to(bld_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_name = bld_name
	return closest_name


func _add_memory_with_embedding(description: String, type: String, actor: String,
		participants: Array[String], observer_loc: String, observed_loc: String,
		importance: float, valence: float) -> void:
	## Creates the memory record via MemorySystem (with deduplication),
	## then queues an async batch embedding request.
	var mem: Dictionary = memory.add_memory(description, type, actor, participants,
		observer_loc, observed_loc, importance, valence)

	# Queue embedding (processed in batches every 5 seconds)
	if mem.get("embedding", PackedFloat32Array()).is_empty():
		_embedding_queue.append(mem)

	# Reflection trigger: accumulate importance (exclude reflections/summaries to prevent loop)
	if type != "reflection" and type != "episode_summary" and type != "period_summary":
		_unreflected_importance += importance
		if _unreflected_importance >= REFLECTION_THRESHOLD and not _reflection_in_progress:
			_unreflected_importance = 0.0
			call_deferred("_enhanced_reflect")

	# Safety valve: compress if episodic memories grow too large
	if memory.episodic_memories.size() > 500:
		_compress_memories()


func _process_embedding_queue() -> void:
	## Process pending embeddings in batches using the batch API.
	if _embedding_queue.is_empty():
		return
	var batch: Array[Dictionary] = []
	var batch_count: int = mini(EMBEDDING_BATCH_SIZE, _embedding_queue.size())
	for i: int in range(batch_count):
		batch.append(_embedding_queue[i])
	_embedding_queue = _embedding_queue.slice(batch_count)

	var texts: Array[String] = []
	for mem: Dictionary in batch:
		texts.append(mem.get("text", mem.get("description", "")))

	if not EmbeddingClient.has_api_key():
		return

	EmbeddingClient.embed_batch(texts, func(embeddings: Array[PackedFloat32Array]) -> void:
		for i: int in range(mini(batch.size(), embeddings.size())):
			batch[i]["embedding"] = embeddings[i]
		if OS.is_debug_build():
			print("[Memory] %s: batch embedded %d memories (%d still queued)" % [
				npc_name, batch.size(), _embedding_queue.size()])
	)


func _scan_perception_area() -> void:
	## Re-check bodies already inside PerceptionArea. Cooldowns prevent duplicates.
	var perception: Area2D = $PerceptionArea
	for body: Node2D in perception.get_overlapping_bodies():
		_on_perception_body_entered(body)


func _scan_environment() -> void:
	## Perceive object states in the current building.
	## Creates memories about notable states: active objects, empty workstations, etc.

	# Bug 1: Don't scan while sleeping
	if current_activity.begins_with("sleeping"):
		return

	if GameClock.total_minutes - _last_environment_scan < ENVIRONMENT_SCAN_INTERVAL:
		return
	_last_environment_scan = GameClock.total_minutes

	if _current_destination == "" or _is_moving:
		return

	var objects: Array[Dictionary] = WorldObjects.get_objects_in_building(_current_destination)
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
					notable.append("the %s at the %s was idle" % [obj_type, _current_destination])
			continue

		# Active objects — always notable if someone else is using them
		if user != "" and user != npc_name:
			notable.append("%s was using the %s (%s)" % [user, obj_type, state])
		elif user == npc_name:
			continue
		else:
			# Object is in a non-idle state but no user — interesting
			notable.append("the %s was %s" % [obj_type, state])

	# Create at most 2 environment memories per scan (avoid spam)
	var count: int = 0
	for observation: String in notable:
		if count >= 2:
			break

		var description: String = "Noticed %s at the %s" % [observation, _current_destination]

		_add_memory_with_embedding(
			description,
			"environment",
			"",
			[npc_name] as Array[String],
			_current_destination,
			_current_destination,
			2.5,
			0.0
		)
		count += 1

	if count > 0 and OS.is_debug_build():
		print("[EnvScan] %s noticed %d things at %s" % [npc_name, count, _current_destination])


func _on_arrive_at_building() -> void:
	## Check building state on arrival: abandoned objects, empty workplaces.
	var objects: Array[Dictionary] = WorldObjects.get_objects_in_building(_current_destination)

	# Check if any work objects are active with no users (someone left something running)
	for obj: Dictionary in objects:
		if obj["state"] != "idle" and obj["user"] == "":
			var desc: String = "Arrived at the %s and found the %s was %s with nobody around" % [
				_current_destination, obj["tile_type"], obj["state"]
			]
			_add_memory_with_embedding(
				desc, "environment", "", [npc_name] as Array[String],
				_current_destination, _current_destination, 4.0, -0.1
			)
			if OS.is_debug_build():
				print("[EnvScan] %s: %s" % [npc_name, desc])

	# Check if workplace is empty during work hours (coworker missing)
	if _current_destination == workplace_building and _is_work_hours():
		var coworkers_present: bool = false
		for npc: Node in get_tree().get_nodes_in_group("npcs"):
			if npc == self:
				continue
			var other: CharacterBody2D = npc as CharacterBody2D
			if other.workplace_building == workplace_building and other._current_destination == workplace_building:
				coworkers_present = true
				break

		# Only note if there SHOULD be coworkers (some workplaces are solo)
		var expected_coworkers: bool = workplace_building in ["Blacksmith", "Tavern", "Church", "Courthouse", "General Store"]
		if expected_coworkers and not coworkers_present:
			# Once per day — use observation cooldown to prevent spam
			var today: int = GameClock.total_minutes / 1440
			var check_key: String = "empty_%s_%d" % [workplace_building, today]
			if not _observation_cooldowns.has(check_key):
				_observation_cooldowns[check_key] = GameClock.total_minutes
				var desc: String = "The %s was empty when I arrived for work" % workplace_building
				_add_memory_with_embedding(
					desc, "environment", "", [npc_name] as Array[String],
					_current_destination, _current_destination, 3.0, -0.1
				)


func _is_work_hours() -> bool:
	return GameClock.hour >= 6 and GameClock.hour < 17


func _is_workplace_object(tile_type: String) -> bool:
	## Is this the kind of object that should be in use during work hours?
	return tile_type in ["oven", "anvil", "counter", "desk", "altar"]


# --- Gossip System ---

const GOSSIP_TRUST_THRESHOLD: float = 15.0  # Minimum trust to share gossip
const GOSSIP_CHANCE: float = 0.4             # 40% chance of gossiping per conversation
const GOSSIP_MIN_IMPORTANCE: float = 3.0     # Only share important-ish memories
const GOSSIP_MAX_AGE_HOURS: int = 48         # Don't share ancient news
const GOSSIP_MAX_HOPS: int = 3               # Max propagation depth


func _pick_gossip_for(other_npc: CharacterBody2D) -> Dictionary:
	## Select an interesting memory to share with another NPC.
	## Returns the memory Dictionary, or {} if nothing worth sharing.

	# Trust check — don't gossip with people you don't trust
	var trust: int = Relationships.get_relationship(npc_name, other_npc.npc_name)["trust"]
	if trust < GOSSIP_TRUST_THRESHOLD:
		return {}

	# Random chance — not every conversation includes gossip
	if randf() > GOSSIP_CHANCE:
		return {}

	# Gather candidate memories: recent, important, about THIRD PARTIES
	var candidates: Array[Dictionary] = []
	var current_time: int = GameClock.total_minutes

	for mem: Dictionary in memory.memories:
		# Must be recent enough
		var hours_ago: float = (current_time - mem.get("game_time", 0)) / 60.0
		if hours_ago > GOSSIP_MAX_AGE_HOURS:
			continue

		# Must be important enough
		if mem.get("importance", 0.0) < GOSSIP_MIN_IMPORTANCE:
			continue

		# Must be about someone other than the conversation partner or self
		var actor: String = mem.get("actor", "")
		if actor == other_npc.npc_name or actor == npc_name or actor == "":
			continue

		# Don't re-share gossip that originally came from this NPC
		var source: String = mem.get("gossip_source", "")
		if source == other_npc.npc_name:
			continue

		# Don't share memories that the other NPC was a participant in
		var participants: Array = mem.get("participants", [])
		if other_npc.npc_name in participants:
			continue

		# Bug 3: Skip if already told this person
		var shared_with: Array = mem.get("shared_with", [])
		if other_npc.npc_name in shared_with:
			continue

		# Prefer certain types
		var type: String = mem.get("type", "")
		if type in ["observation", "dialogue", "environment", "reflection", "gossip"]:
			candidates.append(mem)

	if candidates.is_empty():
		return {}

	# Sort by importance * recency — share the juiciest recent thing
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var score_a: float = a.get("importance", 0.0) * pow(0.98, (current_time - a.get("game_time", 0)) / 60.0)
		var score_b: float = b.get("importance", 0.0) * pow(0.98, (current_time - b.get("game_time", 0)) / 60.0)
		return score_a > score_b
	)

	return candidates[0]


func _share_gossip_with(receiver_npc: CharacterBody2D, original_memory: Dictionary) -> void:
	## Share a memory with another NPC as gossip.
	## The receiver gets a new memory with reduced importance and gossip tracking.

	var original_desc: String = original_memory.get("description", "")
	var about: String = original_memory.get("actor", "someone")

	# Track how many hops this gossip has traveled
	var hop_count: int = original_memory.get("gossip_hops", 0) + 1

	# Don't propagate beyond max hops
	if hop_count > GOSSIP_MAX_HOPS:
		return

	# Format depends on whether this is first-hand or already gossip
	var gossip_desc: String = ""
	if hop_count == 1:
		# First-hand sharing
		gossip_desc = "%s told me: %s" % [npc_name, original_desc]
	else:
		# Second-hand+
		gossip_desc = "%s mentioned that they heard: %s" % [npc_name, original_desc]

	# Importance degrades with each hop (gossip is less reliable)
	var gossip_importance: float = maxf(original_memory.get("importance", 3.0) - (hop_count * 1.0), 2.0)

	# Create the gossip memory for the receiver
	receiver_npc._add_memory_with_embedding(
		gossip_desc,
		"gossip",
		about,
		[npc_name, receiver_npc.npc_name, about] as Array[String],
		receiver_npc._current_destination,
		_current_destination,
		gossip_importance,
		original_memory.get("emotional_valence", 0.0)
	)

	# Tag the receiver's new gossip memory with tracking metadata
	if not receiver_npc.memory.memories.is_empty():
		var new_mem: Dictionary = receiver_npc.memory.memories[-1]
		new_mem["gossip_source"] = npc_name
		new_mem["gossip_hops"] = hop_count
		new_mem["original_description"] = original_desc

	# Create a memory for the SHARER that they told someone
	_add_memory_with_embedding(
		"Told %s about %s" % [receiver_npc.npc_name, original_desc.left(60)],
		"gossip_shared",
		receiver_npc.npc_name,
		[npc_name, receiver_npc.npc_name] as Array[String],
		_current_destination, _current_destination,
		2.0, 0.0
	)

	# Bug 3: Track that we told this person (prevents repeat gossip)
	if not original_memory.has("shared_with"):
		original_memory["shared_with"] = []
	if receiver_npc.npc_name not in original_memory["shared_with"]:
		original_memory["shared_with"].append(receiver_npc.npc_name)

	# Sharing gossip builds trust slightly (intimacy of shared secrets)
	Relationships.modify_mutual(npc_name, receiver_npc.npc_name, 1, 0, 0)

	# Gossip affects receiver's trust toward the subject (valence-proportional)
	var valence: float = original_memory.get("emotional_valence", 0.0)
	if about != "" and about != receiver_npc.npc_name:
		var impact: int = clampi(int(valence * 2.0), -3, 3)
		if impact != 0:
			Relationships.modify(receiver_npc.npc_name, about, impact, 0, 0)
			if OS.is_debug_build():
				print("[Gossip Impact] %s heard about %s → Trust %+d" % [receiver_npc.npc_name, about, impact])

	if OS.is_debug_build():
		print("[Gossip] %s told %s: '%s' (hop %d, importance %.1f)" % [
			npc_name, receiver_npc.npc_name, gossip_desc.left(80), hop_count, gossip_importance])
