extends Node
## Stanford two-step reflection system and midnight memory maintenance (compression, forgetting).

var npc: CharacterBody2D

var _unreflected_importance: float = 0.0
var _reflection_in_progress: bool = false
const REFLECTION_THRESHOLD: float = 100.0


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func on_memory_added(importance: float, type: String) -> void:
	## Called by controller after each memory is added. Accumulates importance for reflection trigger.
	if type == "reflection" or type == "episode_summary" or type == "period_summary":
		return
	_unreflected_importance += importance
	if _unreflected_importance >= REFLECTION_THRESHOLD and not _reflection_in_progress:
		_unreflected_importance = 0.0
		npc.call_deferred("_trigger_reflection")


func enhanced_reflect() -> void:
	## Stanford two-step reflection: generate questions from recent experiences,
	## then generate insights per question using relevant memories.
	if _reflection_in_progress:
		return

	_reflection_in_progress = true

	if ApiClient.is_available():
		_reflect_via_api()
	elif GeminiClient.has_api_key():
		_reflect_via_gemini()
	else:
		_reflection_in_progress = false


func _reflect_via_api() -> void:
	var body: Dictionary = {
		"npc_name": npc.npc_name,
		"npc_state": {
			"npc_name": npc.npc_name,
			"job": npc.job,
			"age": npc.age,
			"personality": npc.personality,
			"speech_style": npc.speech_style,
			"home_building": npc.home_building,
			"workplace_building": npc.workplace_building,
			"current_destination": npc._current_destination,
			"current_activity": npc.current_activity,
			"needs": {"hunger": npc.needs.hunger, "energy": npc.needs.energy, "social": npc.needs.social},
			"game_time": GameClock.total_minutes,
			"game_hour": GameClock.hour,
			"game_minute": GameClock.minute,
			"game_day": npc._get_current_day(),
			"game_season": "Spring",
		},
		"game_time": {
			"total_minutes": GameClock.total_minutes,
			"hour": GameClock.hour,
			"minute": GameClock.minute,
			"day": npc._get_current_day(),
			"season": "Spring",
		},
	}
	ApiClient.post("/reflect", body, func(response: Dictionary, success: bool) -> void:
		_reflection_in_progress = false
		if success and response.get("success", false):
			var insights: Array = response.get("insights", [])
			if not insights.is_empty():
				# Update emotional state locally from last insight
				var last_insight: String = str(insights[-1]).left(150)
				npc.memory.update_emotional_state(last_insight)
				npc.dialogue.last_significant_event_time = GameClock.total_minutes
				if OS.is_debug_build():
					print("[Reflect API] %s: %d insights from %d questions" % [
						npc.npc_name, insights.size(), response.get("questions_generated", 0)])
		else:
			# Fall back to Gemini
			if GeminiClient.has_api_key():
				_reflection_in_progress = true
				_reflect_via_gemini()
	)


func _reflect_via_gemini() -> void:
	# Gather 100 recent non-reflection memories
	var recent: Array[Dictionary] = []
	for mem: Dictionary in npc.memory.episodic_memories:
		if mem.get("type", "") != "reflection" and not mem.get("superseded", false):
			recent.append(mem)
	recent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("timestamp", 0) > b.get("timestamp", 0)
	)
	recent = recent.slice(0, mini(100, recent.size()))

	if recent.size() < 10:
		_reflection_in_progress = false
		return

	# Build memory list for the question prompt
	var memories_text: String = ""
	for mem: Dictionary in recent:
		memories_text += "- %s\n" % mem.get("text", mem.get("description", ""))

	# Step 1: Generate 5 questions
	var q_prompt: String = """Given these recent experiences of %s, what are the 5 most salient high-level questions we can answer about the subjects in the statements?

Recent experiences:
%s

Focus on: patterns in relationships, changes in feelings, things learned about others, personal growth, unresolved tensions, emerging goals, and what relationships are forming or changing.

Respond with exactly 5 questions, one per line, nothing else.""" % [npc.npc_name, memories_text]

	var q_system: String = "You are analyzing the experiences of %s, a %d-year-old %s in DeepTown. %s" % [
		npc.npc_name, npc.age, npc.job, npc.personality.left(200)]

	GeminiClient.generate(q_system, q_prompt, func(text: String, success: bool) -> void:
		if not success or text == "":
			_reflection_in_progress = false
			if OS.is_debug_build():
				print("[Reflect] %s — question generation failed" % npc.npc_name)
			return

		var questions: Array[String] = []
		for line: String in text.strip_edges().split("\n"):
			var q: String = line.strip_edges()
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
			print("[Reflect] %s: Generated %d questions" % [npc.npc_name, questions.size()])

		var _pending_questions: int = questions.size()
		for question: String in questions:
			_generate_insights_for_question(question, func() -> void:
				_pending_questions -= 1
				if _pending_questions <= 0:
					_reflection_in_progress = false
					if OS.is_debug_build():
						print("[Reflect] %s: All reflection questions processed" % npc.npc_name)
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

	var relevant: Array[Dictionary] = npc.memory.retrieve_by_keywords(keywords, GameClock.total_minutes, 10)

	var relevant_text: String = ""
	for mem: Dictionary in relevant:
		relevant_text += "- [Day %d] %s\n" % [mem.get("game_day", 0), mem.get("text", mem.get("description", ""))]

	if relevant_text == "":
		on_done.call()
		return

	var identity: String = npc.memory.core_memory.get("identity", npc.personality)
	var i_prompt: String = """You are %s reflecting on your experiences.

Question: %s

Relevant memories:
%s

Your personality: %s

What 5 high-level insights can you infer from the above statements? Write each as a 1-2 sentence personal reflection in first person as %s. Be genuine and specific — reference actual events and people. Each should feel like an internal thought, not a report.

Format: One insight per line, numbered 1-5.
Write ONLY the insights, nothing else.""" % [
		npc.npc_name, question, relevant_text, identity.left(300), npc.npc_name]

	var i_system: String = "You are %s. Write personal reflections — genuine internal thoughts, not reports." % npc.npc_name

	GeminiClient.generate(i_system, i_prompt, func(text: String, success: bool) -> void:
		if success and text != "":
			var insights: Array[String] = _parse_insight_lines(text)
			for insight: String in insights:
				# Strip citation "(because of 1, 3, 5)" if present
				var paren_idx: int = insight.rfind("(because")
				var clean_insight: String = insight.left(paren_idx).strip_edges() if paren_idx > 0 else insight

				if clean_insight.length() < 10:
					continue

				npc._add_memory_with_embedding(
					clean_insight,
					"reflection",
					npc.npc_name,
					[npc.npc_name] as Array[String],
					npc._current_destination,
					npc._current_destination,
					7.0,
					0.0
				)

				if OS.is_debug_build():
					print("[Reflect] %s: %s" % [npc.npc_name, clean_insight.left(100)])

				# If insight mentions the player, update core memory
				if PlayerProfile.player_name.to_lower() in clean_insight.to_lower():
					var old_summary: String = npc.memory.core_memory.get("player_summary", "")
					var update_prompt: String = "Based on this reflection: \"%s\"\nCurrent understanding of %s: \"%s\"\nWrite an updated 1-2 sentence understanding:" % [
						clean_insight.left(200), PlayerProfile.player_name, old_summary]
					GeminiClient.generate(
						"You are %s. Write a brief updated impression." % npc.npc_name,
						update_prompt,
						func(summary_text: String, s: bool) -> void:
							if s and summary_text != "":
								npc.memory.update_player_summary(summary_text.strip_edges().left(200))
								if OS.is_debug_build():
									print("[Memory] %s updated player summary from reflection" % npc.npc_name)
					)

			# Update emotional state from last insight
			if not insights.is_empty():
				npc.memory.update_emotional_state(insights[-1].left(150))
				npc.dialogue.last_significant_event_time = GameClock.total_minutes

			print("[Reflect] %s: %d insights from question" % [npc.npc_name, insights.size()])

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

func run_midnight_maintenance() -> void:
	## Daily memory maintenance: forgetting curves → compression → save.
	if ApiClient.is_available():
		var body: Dictionary = {"game_time": GameClock.total_minutes}
		ApiClient.post("/memory/%s/maintenance" % npc.npc_name, body, func(response: Dictionary, success: bool) -> void:
			if success:
				if OS.is_debug_build():
					print("[Memory API] %s: Midnight maintenance — forgotten: %d, compressed: %d" % [
						npc.npc_name,
						response.get("forgotten_count", 0),
						response.get("compressed_count", 0)])
			else:
				_run_local_maintenance()
		)
	else:
		_run_local_maintenance()


func _run_local_maintenance() -> void:
	# 1. Apply forgetting curves
	npc.memory.apply_daily_forgetting()

	# 2. Compress old episodic memories (async — needs Gemini)
	_compress_memories()

	# 3. Save (forgetting results saved immediately; compression saves on callback)
	npc.memory.save_all()

	if OS.is_debug_build():
		print("[Memory] %s: Midnight maintenance — Episodic: %d, Archival: %d" % [
			npc.npc_name, npc.memory.episodic_memories.size(), npc.memory.archival_summaries.size()])


func _compress_memories() -> void:
	## Compress oldest raw episodic memories into an episode summary via Gemini.
	var candidates: Array[Dictionary] = npc.memory.get_compression_candidates()
	if candidates.size() < npc.memory.COMPRESSION_MIN_BATCH:
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

Write ONLY the summary paragraph, nothing else.""" % [npc.npc_name, PlayerProfile.player_name, memories_text]

	GeminiClient.generate(
		"You summarize memories for %s into dense paragraphs." % npc.npc_name,
		prompt,
		func(text: String, success: bool) -> void:
			if not success or text == "":
				if OS.is_debug_build():
					print("[Compress] %s: Gemini failed, skipping compression" % npc.npc_name)
				return

			var summary_text: String = text.strip_edges()
			var summary_mem: Dictionary = npc.memory.apply_episode_compression(candidates, summary_text)

			npc.memory.save_all()

			print("[Compress] %s: Compressed %d memories into episode summary (Day %d)" % [
				npc.npc_name, candidates.size(), summary_mem.get("game_day", 0)])

			# Check if we can do period compression too
			_compress_episodes()
	)


func _compress_episodes() -> void:
	## Compress oldest episode summaries into a period summary via Gemini.
	var episodes: Array[Dictionary] = npc.memory.get_episode_summary_candidates()
	if episodes.size() < npc.memory.EPISODE_COMPRESSION_THRESHOLD:
		return
	if not GeminiClient.has_api_key():
		return

	var batch: Array[Dictionary] = episodes.slice(0, npc.memory.PERIOD_COMPRESSION_BATCH)

	var text: String = ""
	for ep: Dictionary in batch:
		text += "- %s\n" % ep.get("text", ep.get("description", ""))

	var prompt: String = """These are episode summaries spanning several days for %s.
Compress them into a single 2-3 sentence period summary capturing the most important developments.
PRESERVE: relationship arcs, major events, character growth, anything about %s.

Episodes:
%s

Write ONLY the period summary:""" % [npc.npc_name, PlayerProfile.player_name, text]

	GeminiClient.generate(
		"You compress episode summaries for %s into period summaries." % npc.npc_name,
		prompt,
		func(period_text: String, success: bool) -> void:
			if not success or period_text == "":
				return

			var period_mem: Dictionary = npc.memory.apply_period_compression(batch, period_text.strip_edges())

			npc.memory.save_all()

			print("[Compress] %s: Compressed %d episodes into period summary" % [npc.npc_name, batch.size()])
	)
