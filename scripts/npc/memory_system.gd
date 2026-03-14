class_name MemorySystem
extends RefCounted
## Thin memory cache — syncs from the Python backend via GET /memory/{npc}/snapshot.
## All storage, retrieval, scoring, forgetting, and compression live server-side.
## This class caches the snapshot locally for synchronous GDScript reads.

# --- Cached data (populated from backend snapshot) ---

var core_memory: Dictionary = {
	"identity": "",
	"emotional_state": "Feeling neutral, starting the day.",
	"player_summary": "",
	"npc_summaries": {},
	"active_goals": [],
	"key_facts": [],
}

var _recent_memories: Array[Dictionary] = []
var _player_memories: Array[Dictionary] = []
var _gossip_candidates: Array[Dictionary] = []
var _memory_count: int = 0
var _type_counts: Dictionary = {}
var _npc_name: String = ""
var _player_name: String = ""
var _cache_valid: bool = false

# Backward-compat property — callers that iterate .memories get the cached recent list
var memories: Array[Dictionary]:
	get: return _recent_memories

# Backward-compat — .episodic_memories.size() should use get_memory_count() instead
var episodic_memories: Array[Dictionary]:
	get: return _recent_memories

# Archival summaries — not tracked locally (backend owns them)
var archival_summaries: Array[Dictionary]:
	get: return []


# --- Initialization ---

func initialize(npc_name: String, personality_prompt: String, player_name: String) -> void:
	_npc_name = npc_name
	_player_name = player_name
	core_memory["identity"] = personality_prompt
	if core_memory["player_summary"] == "":
		core_memory["player_summary"] = "I haven't met %s yet." % player_name


func load_or_init(npc_name: String, personality_prompt: String, player_name: String) -> void:
	## Backward compat — just calls initialize + refresh_cache.
	initialize(npc_name, personality_prompt, player_name)
	refresh_cache()


# --- Cache Refresh (single API call populates everything) ---

func refresh_cache(callback: Callable = Callable()) -> void:
	## Fetch full snapshot from backend. Updates core_memory, recent, counts, etc.
	if not ApiClient.is_available():
		if callback.is_valid():
			callback.call()
		return

	var url: String = "/memory/%s/snapshot?player_name=%s&game_time=%d" % [
		_npc_name, _player_name, GameClock.total_minutes]
	ApiClient.get_request(url, func(response: Dictionary, success: bool) -> void:
		if success and not response.is_empty():
			# Core memory
			var core: Dictionary = response.get("core_memory", {})
			if not core.is_empty():
				core_memory = core

			# Recent memories
			_recent_memories.clear()
			for mem: Variant in response.get("recent_memories", []):
				if mem is Dictionary:
					_recent_memories.append(mem)

			# Player memories
			_player_memories.clear()
			for mem: Variant in response.get("player_memories", []):
				if mem is Dictionary:
					_player_memories.append(mem)

			# Gossip candidates
			_gossip_candidates.clear()
			for mem: Variant in response.get("gossip_candidates", []):
				if mem is Dictionary:
					_gossip_candidates.append(mem)

			# Counts
			_memory_count = int(response.get("memory_count", 0))
			_type_counts = response.get("type_counts", {})
			_cache_valid = true

			if OS.is_debug_build():
				print("[MemCache] %s: refreshed — %d memories, %d recent, %d gossip candidates" % [
					_npc_name, _memory_count, _recent_memories.size(), _gossip_candidates.size()])

		if callback.is_valid():
			callback.call()
	)


func get_memory_count() -> int:
	return _memory_count


# --- Query Accessors (read from cache) ---

func get_recent(count: int = 10) -> Array[Dictionary]:
	return _recent_memories.slice(0, mini(count, _recent_memories.size()))


func get_by_type(type: String) -> Array[Dictionary]:
	## Returns memories of the given type from the cached recent list.
	var results: Array[Dictionary] = []
	for mem: Dictionary in _recent_memories:
		if mem.get("type", "") == type:
			results.append(mem)
	return results


func get_memories_about(entity: String) -> Array[Dictionary]:
	if entity == _player_name or entity == "Player":
		return _player_memories
	# For other entities, filter from recent
	var results: Array[Dictionary] = []
	for mem: Dictionary in _recent_memories:
		if mem.get("actor", "") == entity:
			results.append(mem)
		elif entity in mem.get("participants", []):
			if mem not in results:
				results.append(mem)
	return results


func get_gossip_candidates() -> Array[Dictionary]:
	return _gossip_candidates


# --- Core Memory Mutations (PUT /memory/{npc}/core + optimistic local update) ---

func update_emotional_state(new_state: String) -> void:
	core_memory["emotional_state"] = new_state
	_put_core_update({"emotional_state": new_state})


func update_player_summary(new_summary: String) -> void:
	core_memory["player_summary"] = new_summary
	_put_core_update({"player_summary": new_summary})


func update_npc_summary(npc_name: String, summary: String) -> void:
	core_memory["npc_summaries"][npc_name] = summary
	_put_core_update({"npc_summaries": {npc_name: summary}})


func add_key_fact(fact: String) -> void:
	var facts: Array = core_memory.get("key_facts", [])
	if fact in facts:
		return
	facts.append(fact)
	if facts.size() > 10:
		facts.pop_front()
	core_memory["key_facts"] = facts
	_put_core_update({"key_facts": [fact]})


func set_active_goals(goals: Array) -> void:
	core_memory["active_goals"] = goals
	_put_core_update({"active_goals": goals})


func _put_core_update(updates: Dictionary) -> void:
	## Send partial core memory update to backend.
	if not ApiClient.is_available():
		return
	ApiClient.put("/memory/%s/core" % _npc_name, updates, func(_response: Dictionary, _success: bool) -> void:
		pass  # Optimistic update already applied locally
	)


# --- No-ops (backend owns persistence) ---

func save_all() -> void:
	pass  # Backend auto-persists


func apply_daily_forgetting() -> void:
	pass  # Handled by /maintenance endpoint


func serialize() -> Dictionary:
	return {}  # Backend owns data


func deserialize(_data: Dictionary) -> void:
	pass  # Backend owns data


func add_memory(_text: String, _type: String, _actor: String,
		_participants: Array[String], _observer_loc: String, _observed_loc: String,
		_importance: float, _valence: float) -> Dictionary:
	## No-op — all memory adding goes through controller's _add_memory_with_embedding → API.
	return {}


func retrieve_by_query_text(_query: String, _current_time: int, _count: int = 8) -> Array[Dictionary]:
	## No-op — retrieval is done server-side in /chat and /plan endpoints.
	return []


func retrieve_by_keywords(_keywords: Array[String], _current_time: int, _count: int = 5) -> Array[Dictionary]:
	## No-op — retrieval is done server-side.
	return []
