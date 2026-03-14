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
	)


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
	## Local-only maintenance: forgetting curves + save. No compression (requires backend).
	npc.memory.apply_daily_forgetting()
	npc.memory.save_all()

	if OS.is_debug_build():
		print("[Memory] %s: Local maintenance — Episodic: %d, Archival: %d" % [
			npc.npc_name, npc.memory.episodic_memories.size(), npc.memory.archival_summaries.size()])
