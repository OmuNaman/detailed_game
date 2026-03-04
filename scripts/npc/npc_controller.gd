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

# Real-time plan re-evaluation (CONTINUE/REACT)
var _last_reaction_eval_time: int = 0
var _reaction_in_progress: bool = false
const REACTION_COOLDOWN_MINUTES: int = 10
const REACTION_IMPORTANCE_THRESHOLD: float = 5.0

# NPC-to-NPC conversation totals (for summary update trigger)
var _npc_conv_totals: Dictionary = {}  # "OtherName" -> int (lifetime count)

# 3-Level Planning (Stanford recursive decomposition)
var _plan_level1: Array[Dictionary] = []  # [{start_hour, end_hour, location, activity, decomposed}]
var _plan_level2: Dictionary = {}          # {l1_index: Array[{hour, end_hour, activity}]}
var _plan_level3: Dictionary = {}          # {"l1idx_l2idx": Array[{start_min, end_min, activity}]}
var _last_plan_day: int = -1
var _planning_in_progress: bool = false
var _decomposition_in_progress: bool = false

# Working memory — player conversation tracked for summary on end
var _player_conv_history: Array[Dictionary] = []  # [{speaker, text}]

# Emotional state decay tracking
var _last_significant_event_time: int = 0

# Environment tree: known world subgraph (buildings the NPC has visited)
var _known_world: Dictionary = {}  # {building_name: {area_name: [object_types]}}

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
	_init_known_world()


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
	_learn_building(_current_destination)
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
				_last_significant_event_time = GameClock.total_minutes

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
	## Stanford 3-level planning: generate Level 1 (5-8 full-day activities).
	if _planning_in_progress:
		return
	if not GeminiClient.has_api_key():
		_generate_fallback_plan()
		return

	_planning_in_progress = true
	_last_plan_day = _get_current_day()

	var system_prompt: String = _build_level1_prompt()
	var user_message: String = _build_planning_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		_planning_in_progress = false

		if not success or text == "":
			print("[Planning] %s — Gemini failed, using fallback plan" % npc_name)
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
			_add_memory_with_embedding(
				plan_desc, "plan", npc_name, [npc_name] as Array[String],
				home_building, home_building, 4.0, 0.1
			)
			memory.set_active_goals(plan_summary)

		if OS.is_debug_build():
			print("[Planning] %s's L1 plan (%d blocks):" % [npc_name, _plan_level1.size()])
			for p: Dictionary in _plan_level1:
				print("  %d:00-%d:00 @ %s: %s" % [p["start_hour"], p["end_hour"], p["location"], p["activity"]])
	)


func _generate_fallback_plan() -> void:
	## Full-day deterministic plan when Gemini is unavailable.
	_last_plan_day = _get_current_day()
	_plan_level1.clear()
	_plan_level2.clear()
	_plan_level3.clear()

	_plan_level1.append({"start_hour": 5, "end_hour": 6, "location": home_building, "activity": "getting ready for the day", "decomposed": false})
	_plan_level1.append({"start_hour": 6, "end_hour": 12, "location": workplace_building, "activity": "working at the %s" % workplace_building, "decomposed": false})
	_plan_level1.append({"start_hour": 12, "end_hour": 13, "location": home_building, "activity": "lunch break at home", "decomposed": false})
	_plan_level1.append({"start_hour": 13, "end_hour": 16, "location": workplace_building, "activity": "afternoon work", "decomposed": false})

	var friends: Array[String] = Relationships.get_closest_friends(npc_name, 2)
	if not friends.is_empty():
		var friend_wp: String = _get_npc_workplace(friends[0])
		if friend_wp != "" and friend_wp != workplace_building:
			_plan_level1.append({"start_hour": 16, "end_hour": 17, "location": friend_wp, "activity": "visiting %s" % friends[0], "decomposed": false})
			_plan_level1.append({"start_hour": 17, "end_hour": 20, "location": "Tavern", "activity": "evening socializing at the Tavern", "decomposed": false})
		else:
			_plan_level1.append({"start_hour": 16, "end_hour": 20, "location": "Tavern", "activity": "relaxing at the Tavern", "decomposed": false})
	else:
		_plan_level1.append({"start_hour": 16, "end_hour": 20, "location": "Tavern", "activity": "evening socializing", "decomposed": false})

	_plan_level1.append({"start_hour": 20, "end_hour": 22, "location": home_building, "activity": "winding down at home", "decomposed": false})

	if OS.is_debug_build():
		print("[Planning] %s — fallback plan: %d blocks" % [npc_name, _plan_level1.size()])


func _get_npc_workplace(target_name: String) -> String:
	## Look up another NPC's workplace.
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		var other: CharacterBody2D = npc as CharacterBody2D
		if other.npc_name == target_name:
			return other.workplace_building
	return ""


func _get_npc_roster_text() -> String:
	## Reusable NPC roster for prompts (prevents hallucinated names).
	var text: String = "People who live and work in this town:\n"
	text += "- Maria: Baker, works at Bakery, lives at House 1\n"
	text += "- Thomas: Shopkeeper, works at General Store, lives at House 2\n"
	text += "- Elena: Sheriff, works at Sheriff Office, lives at House 3\n"
	text += "- Gideon: Blacksmith, works at Blacksmith, lives at House 4\n"
	text += "- Rose: Barmaid, works at Tavern, lives at House 5\n"
	text += "- Lyra: Clerk, works at Courthouse, lives at House 6\n"
	text += "- Finn: Farmer/laborer, delivers to General Store, lives at House 7 (married to Clara)\n"
	text += "- Clara: Devout churchgoer, helps at Church, lives at House 7 (married to Finn)\n"
	text += "- Bram: Apprentice blacksmith, works at Blacksmith with Gideon, lives at House 8\n"
	text += "- Old Silas: Retired storyteller, spends time at Tavern, lives at House 9\n"
	text += "- Father Aldric: Priest, works at Church, lives at House 10\n"
	text += "\nIMPORTANT: Only reference people from this list. Do NOT invent names.\n"
	return text


func _build_level1_prompt() -> String:
	## System prompt for Level 1 planning: full-day 5-8 activity blocks.
	var prompt: String = "You are %s, a %d-year-old %s in DeepTown. %s\n\n" % [npc_name, age, job, personality]
	prompt += "Plan your FULL day from waking (hour 5) to sleeping (hour 22). "
	prompt += "Generate 5-8 activity blocks covering every hour of your day.\n\n"
	prompt += "Your workplace: %s (you typically work there from 6-15)\n" % workplace_building
	prompt += "Your home: %s\n\n" % home_building
	prompt += "Available buildings: Bakery, General Store, Tavern, Church, Sheriff Office, Courthouse, Blacksmith\n\n"
	prompt += _get_npc_roster_text()
	prompt += "\nFormat each block as: START-END|LOCATION|ACTIVITY (one per line)\n"
	prompt += "Example:\n"
	prompt += "5-6|%s|Wake up, have breakfast\n" % home_building
	prompt += "6-12|%s|Morning work at the %s\n" % [workplace_building, workplace_building]
	prompt += "12-13|%s|Lunch break at home\n" % home_building
	prompt += "13-16|%s|Afternoon work\n" % workplace_building
	prompt += "16-17|Tavern|Visit Rose for a drink and catch up\n"
	prompt += "17-20|Tavern|Evening socializing\n"
	prompt += "20-22|%s|Dinner and winding down\n\n" % home_building
	prompt += "Rules:\n"
	prompt += "- Cover hours 5-22 with NO gaps\n"
	prompt += "- Include meals at home around hours 7, 12, 19\n"
	prompt += "- Be specific about WHO and WHY for social visits\n"
	prompt += "- Make today different based on your feelings and relationships\n"
	prompt += "- Include at least one social visit outside your workplace\n"
	prompt += "- Do NOT plan past hour 22"
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

	# Core memory: what I know about specific people
	var plan_npc_summaries: Dictionary = memory.core_memory.get("npc_summaries", {})
	if not plan_npc_summaries.is_empty():
		context += "What you know about people:\n"
		for summ_name: String in plan_npc_summaries:
			context += "- %s: %s\n" % [summ_name, plan_npc_summaries[summ_name]]
		context += "\n"

	var plan_player_summary: String = memory.core_memory.get("player_summary", "")
	if plan_player_summary != "" and not plan_player_summary.begins_with("I haven't met"):
		context += "About %s: %s\n\n" % [PlayerProfile.player_name, plan_player_summary]

	var world_desc: String = _describe_known_world()
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
	]
	for i: int in range(1, 12):
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
		var activity: String = parts[2].strip_edges()

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
			"activity": activity,
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
	## Lazy: called just-in-time when we enter an L1 block without L2.
	if _decomposition_in_progress or _plan_level2.has(l1_index):
		return
	if l1_index < 0 or l1_index >= _plan_level1.size():
		return

	var l1: Dictionary = _plan_level1[l1_index]
	var duration: int = l1["end_hour"] - l1["start_hour"]

	# Single-hour blocks don't need decomposition — just create one L2 entry
	if duration <= 1:
		_plan_level2[l1_index] = [{
			"hour": l1["start_hour"],
			"end_hour": l1["end_hour"],
			"activity": l1["activity"],
		}]
		return

	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 10:
		# Fallback: one L2 entry per hour with L1 activity text
		var steps: Array[Dictionary] = []
		for h: int in range(l1["start_hour"], l1["end_hour"]):
			steps.append({"hour": h, "end_hour": h + 1, "activity": l1["activity"]})
		_plan_level2[l1_index] = steps
		return

	_decomposition_in_progress = true
	var system_prompt: String = "You are %s, a %s (%s). Break this %d-hour activity block into hourly steps." % [
		npc_name, job, personality, duration
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
			if not is_instance_valid(self):
				return
			if success and text.strip_edges() != "":
				var steps: Array[Dictionary] = _parse_level2_steps(text, l1["start_hour"], l1["end_hour"])
				if not steps.is_empty():
					_plan_level2[l1_index] = steps
					if OS.is_debug_build():
						print("[Plan L2] %s: Decomposed block %d into %d hourly steps" % [npc_name, l1_index, steps.size()])
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
		var activity: String = parts[1].strip_edges()
		if not hour_str.is_valid_int():
			continue
		var h: int = hour_str.to_int()
		if h < block_start or h >= block_end:
			continue
		steps.append({"hour": h, "end_hour": h + 1, "activity": activity})

	# Sort by hour, cap to block duration
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

	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 10:
		# Fallback: single 60-min entry
		_plan_level3[l3_key] = [{"start_min": 0, "end_min": 60, "activity": l2["activity"]}]
		return

	_decomposition_in_progress = true
	var l1: Dictionary = _plan_level1[l1_idx]
	var system_prompt: String = "You are %s, a %s. Break this 1-hour activity into 3-6 specific actions (5-20 min each)." % [npc_name, job]
	var user_msg: String = "Hour %d:00 at %s: '%s'\n" % [l2["hour"], l1["location"], l2["activity"]]
	user_msg += "Format: START_MIN-END_MIN|ACTION\nExample:\n0-10|Unlock the front door and light the stove\n10-30|Knead bread dough for today's loaves\n30-50|Shape loaves and place in oven\n50-60|Clean up workspace\n"
	user_msg += "Minutes must be 0-60, covering the full hour. Only output lines."

	GeminiClient.generate(system_prompt, user_msg,
		func(text: String, success: bool) -> void:
			_decomposition_in_progress = false
			if not is_instance_valid(self):
				return
			if success and text.strip_edges() != "":
				var steps: Array[Dictionary] = _parse_level3_steps(text)
				if not steps.is_empty():
					_plan_level3[l3_key] = steps
					if OS.is_debug_build():
						print("[Plan L3] %s: Decomposed L2[%d][%d] into %d fine actions" % [npc_name, l1_idx, l2_idx, steps.size()])
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
		var activity: String = parts[1].strip_edges()
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
		steps.append({"start_min": start_m, "end_min": end_m, "activity": activity})

	steps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["start_min"] < b["start_min"]
	)
	if steps.size() > 6:
		steps.resize(6)
	return steps


func _evaluate_reaction(observation: String, importance: float) -> void:
	## Evaluate whether the NPC should react to a significant observation by replanning.
	## Flash Lite call: CONTINUE or REACT|LOCATION|NEW_ACTIVITY
	if _reaction_in_progress or _decomposition_in_progress or _planning_in_progress:
		return
	if not GeminiClient.has_api_key() or GeminiClient._request_queue.size() > 10:
		return
	# Cooldown
	var current_time: int = GameClock.total_minutes
	if current_time - _last_reaction_eval_time < REACTION_COOLDOWN_MINUTES:
		return
	# Don't react while sleeping
	if GameClock.hour >= 23 or GameClock.hour < 5:
		return

	_last_reaction_eval_time = current_time
	_reaction_in_progress = true

	var active_plan: Dictionary = _get_current_plan()
	var current_activity_text: String = active_plan.get("reason", current_activity) if not active_plan.is_empty() else current_activity

	var system_prompt: String = "You are %s, a %s in DeepTown. Decide if this observation warrants changing your current plans." % [npc_name, job]
	var user_msg: String = "You are currently: %s at the %s.\n" % [current_activity_text, _current_destination]
	user_msg += "New observation (importance %.1f): %s\n\n" % [importance, observation]
	user_msg += "Should you CONTINUE your current activity or REACT by changing plans?\n"
	user_msg += "If CONTINUE, just write: CONTINUE\n"
	user_msg += "If REACT, write: REACT|LOCATION|NEW_ACTIVITY\n"
	user_msg += "Example: REACT|Tavern|Rush to check on the commotion\n"
	user_msg += "Only react if this is truly important enough to disrupt your plans."

	GeminiClient.generate(system_prompt, user_msg,
		func(text: String, success: bool) -> void:
			_reaction_in_progress = false
			if not is_instance_valid(self):
				return
			if success and text.strip_edges() != "":
				_process_reaction_result(text.strip_edges(), observation)
			elif OS.is_debug_build():
				print("[Reaction] %s: Evaluation failed, continuing current plan" % npc_name),
		GeminiClient.MODEL_LITE
	)


func _process_reaction_result(text: String, observation: String) -> void:
	## Parse CONTINUE/REACT response and apply if reacting.
	var first_line: String = text.split("\n")[0].strip_edges().to_upper()

	if first_line.begins_with("CONTINUE"):
		if OS.is_debug_build():
			print("[Reaction] %s: CONTINUE — staying on plan" % npc_name)
		return

	if not first_line.begins_with("REACT"):
		return

	# Parse REACT|LOCATION|NEW_ACTIVITY
	var parts: PackedStringArray = first_line.split("|")
	if parts.size() < 3:
		return

	var location_raw: String = text.split("\n")[0].strip_edges().split("|")[1].strip_edges()
	var activity_raw: String = text.split("\n")[0].strip_edges().split("|")[2].strip_edges()

	# Fuzzy match location
	var valid_names: Array[String] = []
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		if npc.home_building not in valid_names:
			valid_names.append(npc.home_building)
		if npc.workplace_building not in valid_names:
			valid_names.append(npc.workplace_building)
	for bname: String in ["Tavern", "Church", "Courthouse", "Sheriff Office"]:
		if bname not in valid_names:
			valid_names.append(bname)

	var matched_loc: String = _match_building_name(location_raw, valid_names)
	if matched_loc == "":
		matched_loc = _current_destination  # Stay put but change activity

	# Override the current L1 block
	var l1_idx: int = _get_current_l1_index()
	if l1_idx >= 0:
		_plan_level1[l1_idx]["location"] = matched_loc
		_plan_level1[l1_idx]["activity"] = activity_raw if activity_raw != "" else "reacting to event"
		# Clear L2/L3 for this block so they regenerate
		_plan_level2.erase(l1_idx)
		var keys_to_erase: Array[String] = []
		for key: String in _plan_level3.keys():
			if key.begins_with(str(l1_idx) + "_"):
				keys_to_erase.append(key)
		for key: String in keys_to_erase:
			_plan_level3.erase(key)

	# Store reaction as a memory
	var react_desc: String = "Decided to react to: %s — going to %s to %s" % [observation, matched_loc, activity_raw]
	_add_memory_with_embedding(react_desc, "plan", npc_name,
		[npc_name] as Array[String], _current_destination, matched_loc, 4.0, 0.0)

	# Immediately redirect
	_update_destination(GameClock.hour)
	if OS.is_debug_build():
		print("[Reaction] %s: REACT — redirecting to %s for '%s'" % [npc_name, matched_loc, activity_raw])


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
	## Check if any L1 plan block covers the current hour.
	## Returns the location or "" if no active plan.
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


func _get_current_plan() -> Dictionary:
	## Returns the most granular active plan for the current time.
	## Cascade: L3 → L2 → L1. Returns {destination, reason, hour, end_hour}.
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
	# Midnight: reset counts + run memory maintenance + clear L2/L3 plans
	if hour == 0:
		_conv_counts_today.clear()
		_plan_level2.clear()
		_plan_level3.clear()
		_run_midnight_maintenance()

	# Emotional state decay: 3+ quiet hours → drift to neutral
	if _last_significant_event_time > 0:
		var quiet_hours: float = float(GameClock.total_minutes - _last_significant_event_time) / 60.0
		if quiet_hours >= 3.0:
			var current_emotion: String = memory.core_memory.get("emotional_state", "")
			if current_emotion != "" and not current_emotion.begins_with("Feeling neutral"):
				memory.update_emotional_state("Feeling neutral, going about the day.")
				_last_significant_event_time = 0
				if OS.is_debug_build():
					print("[Emotion] %s: Mood decayed to neutral after %.1f quiet hours" % [npc_name, quiet_hours])

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

	# Just-in-time L2 decomposition every 5 min
	if GameClock.total_minutes % 5 == 0 and not _decomposition_in_progress:
		var l1_idx: int = _get_current_l1_index()
		if l1_idx >= 0 and not _plan_level2.has(l1_idx):
			_decompose_to_level2(l1_idx)
		# L3 decomposition for the current hour's L2 step
		elif l1_idx >= 0 and _plan_level2.has(l1_idx):
			var l2_steps: Array = _plan_level2[l1_idx]
			for l2_idx: int in range(l2_steps.size()):
				var l2: Dictionary = l2_steps[l2_idx]
				if GameClock.hour >= l2["hour"] and GameClock.hour < l2["end_hour"]:
					var l3_key: String = "%d_%d" % [l1_idx, l2_idx]
					if not _plan_level3.has(l3_key):
						_decompose_to_level3(l1_idx, l2_idx)
					break

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

	# Initialize working memory for this conversation
	_player_conv_history.clear()

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
	## Uses player's message as retrieval query for targeted memory recall.
	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	# Track conversation for summary on end
	_player_conv_history = history.duplicate()

	var system_prompt: String = _build_system_prompt()
	var context: String = _build_dialogue_context_for_reply(player_message)

	# Working memory — last 6 turns
	context += "\nConversation so far:\n"
	var window_start: int = maxi(history.size() - 6, 0)
	for i: int in range(window_start, history.size()):
		var msg: Dictionary = history[i]
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
	prompt += "Rules:\n- Respond in character, first person, 1-3 sentences only\n- Never break character or mention being an AI\n- Let your personality shine through every word\n- Reference your memories naturally if relevant\n- Your mood and needs should affect how you talk\n- You can ask %s questions too — be curious about the newcomer\n- React to what they say, don't just give generic responses\n- If someone asks about past events, rely on your memories. If you don't remember, say so honestly — never make up events." % PlayerProfile.player_name
	return prompt


func _format_memory_age(mem: Dictionary) -> String:
	## Returns human-readable age label for a memory.
	var mem_time: int = mem.get("timestamp", mem.get("game_time", 0))
	var minutes_ago: int = maxi(GameClock.total_minutes - mem_time, 0)
	var hours_ago: int = minutes_ago / 60
	var days_ago: int = minutes_ago / 1440
	if minutes_ago < 30:
		return "(just now)"
	elif hours_ago < 1:
		return "(%d min ago)" % minutes_ago
	elif hours_ago < 6:
		return "(%d hours ago)" % hours_ago
	elif days_ago < 1:
		return "(today)"
	elif days_ago < 2:
		return "(yesterday)"
	elif days_ago < 7:
		return "(%d days ago)" % days_ago
	else:
		return "(over a week ago)"


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

	# RETRIEVAL-BASED MEMORIES (replaces 4 separate get_by_type calls)
	var retrieval_query: String = "%s talking with %s at the %s" % [
		npc_name, PlayerProfile.player_name, _current_destination]
	var retrieved: Array[Dictionary] = memory.retrieve_by_query_text(
		retrieval_query, GameClock.total_minutes, 8)
	if not retrieved.is_empty():
		context += "Your relevant memories:\n"
		for mem: Dictionary in retrieved:
			var age_label: String = _format_memory_age(mem)
			var mem_type: String = mem.get("type", "")
			var prefix: String = ""
			if mem_type == "reflection":
				prefix = "[Thought] "
			elif mem_type == "gossip":
				prefix = "[Heard] "
			elif mem_type == "environment":
				prefix = "[Noticed] "
			elif mem_type == "episode_summary" or mem_type == "period_summary":
				prefix = "[Summary] "
			context += "- %s%s %s\n" % [prefix, mem.get("text", mem.get("description", "")), age_label]
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
	for plan: Dictionary in _plan_level1:
		if GameClock.hour < plan["end_hour"]:
			upcoming_plans.append("%d:00-%d:00 — %s at the %s" % [plan["start_hour"], plan["end_hour"], plan["activity"], plan["location"]])
	if not upcoming_plans.is_empty():
		context += "Your plans for today:\n"
		for p: String in upcoming_plans:
			context += "- %s\n" % p
		context += "\n"

	context += "%s is standing in front of you and wants to talk. They recently moved to DeepTown and live in House 11. Respond naturally." % PlayerProfile.player_name
	return context


func _build_dialogue_context_for_reply(player_message: String) -> String:
	## Builds dialogue context using the player's message as the retrieval query.
	## Called during multi-turn conversation replies for targeted memory recall.
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

	# Nearby object states
	var building_objects: Array[Dictionary] = WorldObjects.get_objects_in_building(_current_destination)
	if not building_objects.is_empty():
		var active_objects: Array[String] = []
		for obj: Dictionary in building_objects:
			if obj["state"] != "idle":
				active_objects.append("the %s is %s" % [obj["tile_type"], obj["state"]])
		if not active_objects.is_empty():
			context += "Around you: %s.\n\n" % ", ".join(active_objects)

	# TARGETED RETRIEVAL using player's actual message
	var retrieved: Array[Dictionary] = memory.retrieve_by_query_text(
		player_message, GameClock.total_minutes, 8)
	if not retrieved.is_empty():
		context += "Your relevant memories:\n"
		for mem: Dictionary in retrieved:
			var age_label: String = _format_memory_age(mem)
			var mem_type: String = mem.get("type", "")
			var prefix: String = ""
			if mem_type == "reflection":
				prefix = "[Thought] "
			elif mem_type == "gossip":
				prefix = "[Heard] "
			elif mem_type == "environment":
				prefix = "[Noticed] "
			elif mem_type == "episode_summary" or mem_type == "period_summary":
				prefix = "[Summary] "
			context += "- %s%s %s\n" % [prefix, mem.get("text", mem.get("description", "")), age_label]
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
	for plan: Dictionary in _plan_level1:
		if GameClock.hour < plan["end_hour"]:
			upcoming_plans.append("%d:00-%d:00 — %s at the %s" % [plan["start_hour"], plan["end_hour"], plan["activity"], plan["location"]])
	if not upcoming_plans.is_empty():
		context += "Your plans for today:\n"
		for p: String in upcoming_plans:
			context += "- %s\n" % p
		context += "\n"

	context += "%s is talking to you right now." % PlayerProfile.player_name
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

	# Mark significant event for emotional decay tracking
	_last_significant_event_time = GameClock.total_minutes

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


func on_player_conversation_ended() -> void:
	## Called by dialogue_box.gd when the player closes the conversation.
	## Creates a summary memory of the entire conversation.
	if _player_conv_history.is_empty():
		return

	var history_copy: Array[Dictionary] = _player_conv_history.duplicate()
	_player_conv_history.clear()

	# Mark significant event for emotional decay
	_last_significant_event_time = GameClock.total_minutes

	# Short conversation (4 or fewer turns): simple concatenation summary
	if history_copy.size() <= 4:
		var summary_parts: Array[String] = []
		for msg: Dictionary in history_copy:
			summary_parts.append("%s: \"%s\"" % [msg["speaker"], str(msg["text"]).left(50)])
		var summary: String = "Conversation with %s at the %s. %s" % [
			PlayerProfile.player_name, _current_destination,
			". ".join(summary_parts).left(200)]
		_add_memory_with_embedding(
			summary, "player_dialogue", PlayerProfile.player_name,
			[npc_name, PlayerProfile.player_name] as Array[String],
			_current_destination, _current_destination, 8.0, 0.3
		)
		if OS.is_debug_build():
			print("[ConvSummary] %s: Short conversation summary stored" % npc_name)
		return

	# Longer conversation: use Gemini Flash to summarize
	if not GeminiClient.has_api_key():
		_add_memory_with_embedding(
			"Had a long conversation with %s at the %s about various topics" % [
				PlayerProfile.player_name, _current_destination],
			"player_dialogue", PlayerProfile.player_name,
			[npc_name, PlayerProfile.player_name] as Array[String],
			_current_destination, _current_destination, 8.0, 0.2
		)
		return

	_summarize_player_conversation(history_copy)


func _summarize_player_conversation(history: Array[Dictionary]) -> void:
	## Use Gemini Flash to create a dense summary of a player conversation.
	var transcript: String = ""
	for msg: Dictionary in history:
		transcript += "%s: \"%s\"\n" % [msg["speaker"], str(msg["text"]).left(80)]

	var prompt: String = "Summarize this conversation between %s and %s in 2-3 sentences from %s's perspective (first person).\nFocus on: what was discussed, any promises made, emotional tone, anything important learned.\n\nConversation:\n%s\nWrite ONLY the summary, nothing else." % [
		npc_name, PlayerProfile.player_name, npc_name, transcript]

	GeminiClient.generate(
		"You summarize conversations for %s. Write in first person as %s." % [npc_name, npc_name],
		prompt,
		func(text: String, success: bool) -> void:
			var summary: String
			if success and text != "":
				summary = text.strip_edges().left(300)
			else:
				summary = "Had a conversation with %s at the %s" % [
					PlayerProfile.player_name, _current_destination]

			_add_memory_with_embedding(
				summary, "player_dialogue", PlayerProfile.player_name,
				[npc_name, PlayerProfile.player_name] as Array[String],
				_current_destination, _current_destination, 8.0, 0.3
			)
			if OS.is_debug_build():
				print("[ConvSummary] %s: \"%s\"" % [npc_name, summary.left(100)])
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

const NPC_CONV_MAX_TURNS: int = 6   # Up to 6 turns (3 exchanges)
const NPC_CONV_MIN_TURNS: int = 2   # At least 1 exchange

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
	## Turn-by-turn Gemini-powered conversation (up to 6 turns).

	# Skip if Gemini queue is backed up (cost control)
	if GeminiClient._request_queue.size() > 10:
		_fake_npc_conversation(other_npc)
		return

	var topic: String = _pick_conversation_topic(other_npc)
	var max_turns: int = NPC_CONV_MAX_TURNS
	if GeminiClient._request_queue.size() > 5:
		max_turns = 2  # Throttle when busy

	# Start the recursive turn chain
	_run_conversation_turn(self, other_npc, [], 0, max_turns, topic,
		func(history: Array[Dictionary]) -> void:
			if not is_instance_valid(self) or not is_instance_valid(other_npc):
				return

			var other_name: String = other_npc.npc_name

			# Build combined memory text from all turns
			var my_lines: Array[String] = []
			var their_lines: Array[String] = []
			for entry: Dictionary in history:
				if entry["speaker"] == npc_name:
					my_lines.append(entry["text"])
				else:
					their_lines.append(entry["text"])

			var full_dialogue: String = ""
			for entry: Dictionary in history:
				full_dialogue += "%s: \"%s\" " % [entry["speaker"], entry["text"]]

			# Store dialogue memory for both NPCs (full conversation)
			_add_memory_with_embedding(
				"Conversation with %s at the %s — %s" % [other_name, _current_destination, full_dialogue.left(300)],
				"dialogue", other_name, [npc_name, other_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)

			other_npc._add_memory_with_embedding(
				"Conversation with %s at the %s — %s" % [npc_name, _current_destination, full_dialogue.left(300)],
				"dialogue", npc_name, [other_npc.npc_name, npc_name] as Array[String],
				_current_destination, _current_destination, 4.0, 0.2
			)

			# Content-aware relationship impact using first exchange
			var first_my: String = my_lines[0] if not my_lines.is_empty() else ""
			var first_their: String = their_lines[0] if not their_lines.is_empty() else ""
			if first_my != "" and first_their != "":
				_analyze_npc_conversation_impact(other_npc, first_my, first_their)

			print("[NPC Chat] %s↔%s: %d turns at %s (queue: %d)" % [
				npc_name, other_name, history.size(), _current_destination,
				GeminiClient._request_queue.size()
			])

			# Gossip phase (now 20% chance)
			var gossip_mem: Dictionary = _pick_gossip_for(other_npc)
			if not gossip_mem.is_empty():
				_share_gossip_with(other_npc, gossip_mem)

			if is_instance_valid(other_npc):
				var reverse_gossip: Dictionary = other_npc._pick_gossip_for(self)
				if not reverse_gossip.is_empty():
					other_npc._share_gossip_with(self, reverse_gossip)
	)


func _run_conversation_turn(speaker: CharacterBody2D, listener: CharacterBody2D,
		history: Array[Dictionary], turn: int, max_turns: int,
		topic: String, on_done: Callable) -> void:
	## Recursive callback chain: each turn generates one line, then swaps roles.
	if not is_instance_valid(speaker) or not is_instance_valid(listener):
		on_done.call(history)
		return

	# Build context with per-turn retrieval
	var system_prompt: String = speaker._build_npc_chat_system_prompt()
	var history_text: String = ""
	for entry: Dictionary in history:
		history_text += "%s: \"%s\"\n" % [entry["speaker"], entry["text"]]

	var context: String = speaker._build_npc_chat_context_for_turn(listener, topic, history_text, turn)

	GeminiClient.generate(system_prompt, context, func(line: String, success: bool) -> void:
		if not is_instance_valid(speaker) or not is_instance_valid(listener):
			on_done.call(history)
			return

		if not success or line.strip_edges() == "":
			line = speaker._get_npc_chat_fallback(topic)
		line = line.strip_edges().replace("\"", "").left(120)

		# Add to history
		history.append({"speaker": speaker.npc_name, "text": line})

		# Show speech bubble
		speaker._show_speech_bubble(line)
		print("[NPC Chat T%d] %s: \"%s\"" % [turn, speaker.npc_name, line])

		# Detect third-party mentions for this line
		_detect_third_party_mentions(speaker.npc_name, line, listener)

		# Check if conversation should end
		var should_end: bool = false
		if turn + 1 >= max_turns:
			should_end = true
		elif turn + 1 >= NPC_CONV_MIN_TURNS:
			# 30% chance to end after min turns
			if randf() < 0.3:
				should_end = true
		# Farewell detection
		var line_lower: String = line.to_lower()
		if line_lower.contains("goodbye") or line_lower.contains("see you") or line_lower.contains("take care") or line_lower.contains("farewell"):
			if turn + 1 >= NPC_CONV_MIN_TURNS:
				should_end = true

		if should_end:
			on_done.call(history)
			return

		# Next turn after brief delay — swap speaker and listener
		get_tree().create_timer(1.5).timeout.connect(func() -> void:
			_run_conversation_turn(listener, speaker, history, turn + 1, max_turns, topic, on_done)
		)
	)


func _build_npc_chat_context_for_turn(other_npc: CharacterBody2D, topic: String,
		history_text: String, turn: int) -> String:
	## Per-turn context with conversation history and targeted retrieval.
	var context: String = ""

	# Base context from the standard builder (without the reply line)
	var hour: int = GameClock.hour
	var period: String = "morning" if hour < 12 else ("afternoon" if hour < 17 else ("evening" if hour < 21 else "night"))
	context += "It's %s at the %s. " % [period, _current_destination]

	if current_activity != "":
		context += "You are currently %s. " % current_activity
	if other_npc.current_activity != "":
		context += "%s is currently %s. " % [other_npc.npc_name, other_npc.current_activity]

	# Relationship
	var trust_l: String = Relationships.get_trust_label(npc_name, other_npc.npc_name)
	var affec_l: String = Relationships.get_affection_label(npc_name, other_npc.npc_name)
	var respe_l: String = Relationships.get_respect_label(npc_name, other_npc.npc_name)
	context += "You %s %s, %s them, and %s them. " % [trust_l, other_npc.npc_name, affec_l, respe_l]

	# NPC summary for conversation partner from core memory
	var npc_summaries: Dictionary = memory.core_memory.get("npc_summaries", {})
	var partner_summary: String = npc_summaries.get(other_npc.npc_name, "")
	if partner_summary != "":
		context += "What you know about %s: %s " % [other_npc.npc_name, partner_summary]

	# Per-turn retrieval: use last line said as query (or topic for first turn)
	var retrieval_query: String = topic
	if not history_text.is_empty():
		var last_line: String = history_text.strip_edges().split("\n")[-1]
		if last_line.length() > 5:
			retrieval_query = last_line

	var retrieved: Array[Dictionary] = memory.retrieve_by_query_text(
		retrieval_query, GameClock.total_minutes, 3)
	if not retrieved.is_empty():
		context += "Relevant memories: "
		for mem: Dictionary in retrieved:
			context += "%s %s. " % [mem.get("text", mem.get("description", "")), _format_memory_age(mem)]

	# Conversation history so far
	if history_text != "":
		context += "\n\nConversation so far:\n" + history_text

	# Instruction
	if turn == 0:
		context += "\nYou're chatting with %s about %s. Say ONE line (max 1-2 sentences)." % [other_npc.npc_name, topic]
	else:
		context += "\nContinue the conversation with %s. Say ONE line (max 1-2 sentences). If the conversation has reached a natural end, you can say goodbye." % other_npc.npc_name

	return context


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

	# Retrieval-based memories relevant to this conversation (broadened with recent third-party names)
	var retrieval_query: String = "talking with %s at the %s" % [other_npc.npc_name, _current_destination]
	var recent_actors: Array[String] = []
	for mem: Dictionary in memory.get_recent(5):
		var actor: String = mem.get("actor", "")
		if actor != "" and actor != npc_name and actor != other_npc.npc_name:
			if actor not in recent_actors:
				recent_actors.append(actor)
	if not recent_actors.is_empty():
		retrieval_query += " " + " ".join(recent_actors.slice(0, 2))
	var retrieved: Array[Dictionary] = memory.retrieve_by_query_text(
		retrieval_query, GameClock.total_minutes, 5)
	if not retrieved.is_empty():
		context += "Relevant memories: "
		for mem: Dictionary in retrieved:
			context += "%s %s. " % [mem.get("text", mem.get("description", "")), _format_memory_age(mem)]

	# NPC summary for conversation partner (from core memory)
	var npc_summaries: Dictionary = memory.core_memory.get("npc_summaries", {})
	if npc_summaries.has(other_npc.npc_name):
		context += "What you know about %s: %s " % [other_npc.npc_name, npc_summaries[other_npc.npc_name]]

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

	# Evaluate reaction for significant observations
	if importance >= REACTION_IMPORTANCE_THRESHOLD:
		_evaluate_reaction(description, importance)


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

	_update_known_object_states()


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


# --- Natural Information Diffusion ---

func _detect_third_party_mentions(speaker_name: String, line_text: String, listener: CharacterBody2D) -> void:
	## Scan dialogue text for mentions of third-party NPCs/player.
	## Creates gossip-type memory for the listener about what was said.
	if not is_instance_valid(listener) or not "memory" in listener:
		return

	var all_names: Array[String] = []
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		if npc.npc_name != speaker_name and npc.npc_name != listener.npc_name:
			all_names.append(npc.npc_name)
	# Also check for player name
	var player_name: String = PlayerProfile.player_name
	if player_name != "" and player_name != speaker_name:
		all_names.append(player_name)

	var line_lower: String = line_text.to_lower()
	for mentioned_name: String in all_names:
		if line_lower.contains(mentioned_name.to_lower()):
			var importance: float = 3.0
			if mentioned_name == player_name:
				importance = 4.0
			var desc: String = "%s mentioned %s: \"%s\"" % [speaker_name, mentioned_name, line_text]
			# Truncate if too long
			if desc.length() > 200:
				desc = desc.substr(0, 197) + "..."

			# Add as gossip-type memory to the listener
			var mem: Dictionary = listener.memory.add_memory(
				desc, "gossip", speaker_name,
				[speaker_name, mentioned_name, listener.npc_name] as Array[String],
				listener._current_destination, listener._current_destination,
				importance, 0.0
			)
			mem["gossip_source"] = speaker_name
			mem["gossip_hops"] = 1
			if OS.is_debug_build():
				print("[Diffusion] %s heard %s mention %s" % [listener.npc_name, speaker_name, mentioned_name])


# --- Gossip System ---

const GOSSIP_TRUST_THRESHOLD: float = 15.0  # Minimum trust to share gossip
const GOSSIP_CHANCE: float = 0.2             # 20% chance of explicit gossiping (reduced — natural diffusion handles the rest)
const GOSSIP_MIN_IMPORTANCE: float = 3.0     # Only share important-ish memories
const GOSSIP_MAX_AGE_HOURS: int = 48         # Don't share ancient news
const GOSSIP_MAX_HOPS: int = 3               # Max propagation depth

# --- Environment Tree ---
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


func _init_known_world() -> void:
	## Seed known world with home and workplace buildings.
	_learn_building(home_building)
	if workplace_building != "" and workplace_building != home_building:
		_learn_building(workplace_building)


func _learn_building(building_name: String) -> void:
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
		print("[World] %s learned layout of %s" % [npc_name, building_name])


func _update_known_object_states() -> void:
	## Sync known_world entries with actual object states from WorldObjects.
	if not _known_world.has(_current_destination):
		return
	var objects: Array[Dictionary] = WorldObjects.get_objects_in_building(_current_destination)
	# Store observed states for prompt enrichment
	for obj: Dictionary in objects:
		if obj["state"] != "idle" and obj["state"] != "unknown":
			var key: String = "%s:%s" % [_current_destination, obj["tile_type"]]
			_known_world[key] = obj["state"]


func _describe_known_world() -> String:
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

	# Mark as significant event for the receiver (emotional decay tracking)
	receiver_npc._last_significant_event_time = GameClock.total_minutes

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
