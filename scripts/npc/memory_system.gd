class_name MemorySystem
extends RefCounted
## Three-tier memory architecture inspired by Stanford Generative Agents + MemGPT.
## Tier 0: Core Memory — small, always in every prompt (~800 tokens)
## Tier 1: Episodic Memory — searchable, no hard cap, scored retrieval
## Tier 2: Archival Summaries — compressed old memories (future use)
##
## Replaces the flat MemoryStream with deduplication, state-change detection,
## stability-based decay, and hybrid retrieval (embedding + recency + importance).

# --- Constants ---

const STABILITY_BY_TYPE: Dictionary = {
	"observation": 6.0,
	"environment": 6.0,
	"conversation": 24.0,
	"dialogue": 24.0,
	"reflection": 72.0,
	"plan": 12.0,
	"gossip": 18.0,
	"gossip_heard": 18.0,
	"gossip_shared": 12.0,
	"player_dialogue": 48.0,
	"episode_summary": 168.0,
	"period_summary": 336.0,
}

const RETRIEVAL_WEIGHT_RELEVANCE: float = 0.5
const RETRIEVAL_WEIGHT_RECENCY: float = 0.3
const RETRIEVAL_WEIGHT_IMPORTANCE: float = 0.2
const MAX_STABILITY: float = 500.0
const TESTING_EFFECT_MULTIPLIER: float = 1.1
const MAX_KEY_FACTS: int = 10
const MAX_NPC_SUMMARIES: int = 5

# Compression constants
const COMPRESSION_BATCH_SIZE: int = 30
const COMPRESSION_MIN_BATCH: int = 10
const EPISODE_COMPRESSION_THRESHOLD: int = 10
const PERIOD_COMPRESSION_BATCH: int = 7

# Forgetting constants
const FORGETTING_RATE_OBSERVATION: float = 0.7
const FORGETTING_RATE_OTHER: float = 0.85
const MIN_STABILITY: float = 1.0
const EFFECTIVELY_FORGOTTEN_THRESHOLD: float = 0.05

# --- Tier 0: Core Memory ---

var core_memory: Dictionary = {
	"identity": "",
	"emotional_state": "Feeling neutral, starting the day.",
	"player_summary": "",
	"npc_summaries": {},
	"active_goals": [],
	"key_facts": [],
}

# --- Tier 1: Episodic Memory ---

var episodic_memories: Array[Dictionary] = []
var _next_memory_id: int = 0

# --- Tier 2: Archival Summaries (future use) ---

var archival_summaries: Array[Dictionary] = []

# --- Deduplication state ---

var _recent_observation_hashes: Dictionary = {}  # dedup_key -> memory_id
var _last_observed_states: Dictionary = {}        # state_key -> {text, memory_id}

# --- NPC reference ---

var _npc_name: String = ""


# --- Initialization ---

func initialize(npc_name: String, personality_prompt: String, player_name: String) -> void:
	_npc_name = npc_name
	core_memory["identity"] = personality_prompt
	if core_memory["player_summary"] == "":
		core_memory["player_summary"] = "I haven't met %s yet." % player_name


func load_or_init(npc_name: String, personality_prompt: String, player_name: String) -> void:
	_npc_name = npc_name

	# Try loading core memory
	var core_path: String = "user://npc_data/%s/core_memory.json" % npc_name
	if FileAccess.file_exists(core_path):
		var file := FileAccess.open(core_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				core_memory = json.data
				# Ensure all keys exist
				if not core_memory.has("identity"):
					core_memory["identity"] = personality_prompt
				if not core_memory.has("emotional_state"):
					core_memory["emotional_state"] = "Feeling neutral, starting the day."
				if not core_memory.has("player_summary"):
					core_memory["player_summary"] = "I haven't met %s yet." % player_name
				if not core_memory.has("npc_summaries"):
					core_memory["npc_summaries"] = {}
				if not core_memory.has("active_goals"):
					core_memory["active_goals"] = []
				if not core_memory.has("key_facts"):
					core_memory["key_facts"] = []
				print("[Memory] Loaded core memory for %s" % npc_name)
	else:
		core_memory = {
			"identity": personality_prompt,
			"emotional_state": "Feeling neutral, starting a new day.",
			"player_summary": "I haven't met %s yet." % player_name,
			"npc_summaries": {},
			"active_goals": [],
			"key_facts": [],
		}

	# Try loading episodic memories
	var ep_path: String = "user://npc_data/%s/episodic_memories.json" % npc_name
	if FileAccess.file_exists(ep_path):
		var file := FileAccess.open(ep_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				_deserialize_episodic(json.data)
				print("[Memory] Loaded %d episodic memories for %s" % [episodic_memories.size(), npc_name])

	# Load embeddings from binary file
	_load_embeddings()

	# Load archival summaries
	var arch_path: String = "user://npc_data/%s/archival_summaries.json" % npc_name
	if FileAccess.file_exists(arch_path):
		var file := FileAccess.open(arch_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				var raw: Array = json.data.get("summaries", [])
				for entry: Variant in raw:
					if entry is Dictionary:
						archival_summaries.append(entry)


# --- Memory Creation ---

func create_memory(text: String, type: String, entities: Array[String],
		location: String, importance: float, valence: float,
		extra_fields: Dictionary = {}) -> Dictionary:
	## Creates a new episodic memory entry with proper stability and protection.
	## Does NOT handle deduplication — call add_memory() for that.
	var clamped_importance: float = clampf(importance, 1.0, 10.0)
	var clamped_valence: float = clampf(valence, -1.0, 1.0)

	var base_stability: float = STABILITY_BY_TYPE.get(type, 12.0)
	# Emotional valence modifier: highly emotional = more stable
	var stability: float = base_stability * (1.0 + absf(clamped_valence) * 3.0)

	var current_time: int = GameClock.total_minutes
	var day: int = current_time / 1440
	var hour: int = (current_time % 1440) / 60

	var mem_id: String = "mem_%04d" % _next_memory_id
	_next_memory_id += 1

	var memory: Dictionary = {
		"id": mem_id,
		"text": text,
		"description": text,  # backward compat with old MemoryStream
		"type": type,
		"importance": clamped_importance,
		"emotional_valence": clamped_valence,
		"entities": entities,
		"location": location,
		"timestamp": current_time,
		"game_time": current_time,  # backward compat
		"game_day": day,
		"game_hour": hour,
		"last_accessed": current_time,
		"access_count": 0,
		"observation_count": 1,
		"stability": stability,
		"embedding": PackedFloat32Array(),
		"protected": clamped_importance >= 8.0 or type == "player_dialogue" or type == "reflection",
		"superseded": false,
		"shared_with": [],
		"source_memory_id": "",
		"summary_level": 0,
		# Backward compat fields
		"actor": extra_fields.get("actor", ""),
		"participants": extra_fields.get("participants", entities),
		"observer_location": extra_fields.get("observer_location", location),
		"observed_near": extra_fields.get("observed_near", location),
	}

	# Merge any extra fields (gossip_source, gossip_hops, etc.)
	for key: String in extra_fields:
		if not memory.has(key):
			memory[key] = extra_fields[key]

	return memory


func add_memory(text: String, type: String, actor: String,
		participants: Array[String], observer_loc: String, observed_loc: String,
		importance: float, valence: float) -> Dictionary:
	## Main entry point — backwards-compatible with old MemoryStream.add_memory().
	## Handles deduplication for observations/environment types.

	# DEDUPLICATION for observations and environment scans
	if type == "observation" or type == "environment":
		var dedup_key: String = observed_loc + ":" + text.sha256_text().left(16)
		if _recent_observation_hashes.has(dedup_key):
			var existing_id: String = _recent_observation_hashes[dedup_key]
			var existing: Dictionary = _find_memory_by_id(existing_id)
			if existing.size() > 0:
				existing["observation_count"] = existing.get("observation_count", 1) + 1
				existing["last_accessed"] = GameClock.total_minutes
				return existing
		# Will set hash after creation below

		# STATE CHANGE DETECTION
		var state_key: String = _extract_state_key(text, observed_loc)
		if _last_observed_states.has(state_key):
			var old_text: String = _last_observed_states[state_key].get("text", "")
			if _texts_are_similar(old_text, text, 0.85):
				var old_id: String = _last_observed_states[state_key].get("memory_id", "")
				var old_mem: Dictionary = _find_memory_by_id(old_id)
				if old_mem.size() > 0:
					old_mem["observation_count"] = old_mem.get("observation_count", 1) + 1
					old_mem["last_accessed"] = GameClock.total_minutes
					return old_mem
			else:
				# State changed — mark old as superseded
				var old_id: String = _last_observed_states[state_key].get("memory_id", "")
				var old_mem: Dictionary = _find_memory_by_id(old_id)
				if old_mem.size() > 0:
					old_mem["superseded"] = true

	# Create the memory
	var extra: Dictionary = {
		"actor": actor,
		"participants": participants,
		"observer_location": observer_loc,
		"observed_near": observed_loc,
	}
	var memory: Dictionary = create_memory(text, type, participants, observed_loc, importance, valence, extra)
	episodic_memories.append(memory)

	# Update dedup tracking for observations
	if type == "observation" or type == "environment":
		var dedup_key: String = observed_loc + ":" + text.sha256_text().left(16)
		_recent_observation_hashes[dedup_key] = memory["id"]
		_last_observed_states[_extract_state_key(text, observed_loc)] = {
			"text": text,
			"memory_id": memory["id"],
		}
		# Prune old hashes
		if _recent_observation_hashes.size() > 100:
			var keys: Array = _recent_observation_hashes.keys()
			for i: int in range(50):
				_recent_observation_hashes.erase(keys[i])

	return memory


# --- Retrieval ---

func retrieve(query_embedding: PackedFloat32Array, current_time: int,
		count: int = 5) -> Array[Dictionary]:
	## Backward-compatible scored retrieval using the new hybrid formula.
	if episodic_memories.is_empty():
		return []

	var scored: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		if mem.get("superseded", false):
			continue
		var score: float = _score_memory(mem, query_embedding, float(current_time))
		scored.append({"memory": mem, "score": score})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	var results: Array[Dictionary] = []
	var limit: int = mini(count, scored.size())
	for i: int in range(limit):
		var mem: Dictionary = scored[i]["memory"]
		# Testing effect: retrieved memories grow stronger
		mem["last_accessed"] = current_time
		mem["access_count"] = mem.get("access_count", 0) + 1
		mem["stability"] = minf(mem.get("stability", 12.0) * TESTING_EFFECT_MULTIPLIER, MAX_STABILITY)
		results.append(mem)

	return results


func retrieve_memories(query_embedding: PackedFloat32Array, k: int = 8,
		type_filter: String = "", entity_filter: String = "",
		time_range_hours: float = -1) -> Array[Dictionary]:
	## Full hybrid retrieval with optional filters. Searches both episodic + archival.
	var current_time: float = float(GameClock.total_minutes)
	var candidates: Array[Dictionary] = []

	# Gather from both tiers
	var all_memories: Array[Dictionary] = episodic_memories.duplicate()
	all_memories.append_array(archival_summaries)

	for mem: Dictionary in all_memories:
		if mem.get("superseded", false):
			continue
		if type_filter != "" and mem.get("type", "") != type_filter:
			continue
		if entity_filter != "":
			var entities: Array = mem.get("entities", mem.get("participants", []))
			if entity_filter not in entities:
				continue
		if time_range_hours > 0:
			var hours_ago: float = (current_time - float(mem.get("timestamp", mem.get("game_time", 0)))) / 60.0
			if hours_ago > time_range_hours:
				continue
		candidates.append(mem)

	# Score all candidates
	var scored: Array[Dictionary] = []
	for mem: Dictionary in candidates:
		var score: float = _score_memory(mem, query_embedding, current_time)
		scored.append({"memory": mem, "score": score})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	var results: Array[Dictionary] = []
	var limit: int = mini(k, scored.size())
	for i: int in range(limit):
		var mem: Dictionary = scored[i]["memory"]
		mem["last_accessed"] = int(current_time)
		mem["access_count"] = mem.get("access_count", 0) + 1
		mem["stability"] = minf(mem.get("stability", 12.0) * TESTING_EFFECT_MULTIPLIER, MAX_STABILITY)
		results.append(mem)

	return results


func retrieve_by_keywords(keywords: Array[String], current_time: int,
		count: int = 5) -> Array[Dictionary]:
	## Fallback keyword retrieval — backward compatible.
	if episodic_memories.is_empty() or keywords.is_empty():
		return []

	var scored: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		if mem.get("superseded", false):
			continue
		var hours_since: float = maxf((float(current_time) - float(mem.get("game_time", mem.get("timestamp", 0)))) / 60.0, 0.0)
		var S: float = mem.get("stability", 12.0)
		var recency: float = pow(1.0 + 0.234 * hours_since / maxf(S, 0.1), -0.5)
		var importance_score: float = mem.get("importance", 1.0) / 10.0

		var desc_lower: String = mem.get("text", mem.get("description", "")).to_lower()
		var match_count: int = 0
		for kw: String in keywords:
			if desc_lower.contains(kw.to_lower()):
				match_count += 1
		var relevance: float = float(match_count) / float(keywords.size())

		var final_score: float = RETRIEVAL_WEIGHT_RELEVANCE * relevance + RETRIEVAL_WEIGHT_RECENCY * recency + RETRIEVAL_WEIGHT_IMPORTANCE * importance_score
		scored.append({"memory": mem, "score": final_score})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	var results: Array[Dictionary] = []
	var limit: int = mini(count, scored.size())
	for i: int in range(limit):
		var mem: Dictionary = scored[i]["memory"]
		mem["last_accessed"] = current_time
		mem["access_count"] = mem.get("access_count", 0) + 1
		mem["stability"] = minf(mem.get("stability", 12.0) * TESTING_EFFECT_MULTIPLIER, MAX_STABILITY)
		results.append(mem)

	return results


func retrieve_by_query_text(query: String, current_time: int,
		count: int = 8) -> Array[Dictionary]:
	## Convenience: extract keywords from free text, search episodic + archival.
	## Unlike retrieve_by_keywords, this searches BOTH tiers and handles keyword extraction.
	var stop_words: Array[String] = ["the", "and", "was", "with", "that", "this", "from",
		"they", "their", "have", "been", "what", "about", "there", "would", "said",
		"just", "near", "here", "some", "will", "also", "very", "like", "when", "only",
		"your", "into", "more", "than", "then", "does", "which", "could", "should", "were"]
	var keywords: Array[String] = []
	for w: String in query.split(" "):
		var lower: String = w.to_lower().strip_edges()
		lower = lower.replace(".", "").replace(",", "").replace("?", "").replace("!", "").replace("\"", "")
		if lower.length() > 2 and lower not in stop_words:
			keywords.append(lower)
	keywords = keywords.slice(0, mini(10, keywords.size()))
	if keywords.is_empty():
		return get_recent(count)

	# Search both tiers (retrieve_by_keywords only does episodic)
	var all_memories: Array[Dictionary] = episodic_memories.duplicate()
	all_memories.append_array(archival_summaries)

	var scored: Array[Dictionary] = []
	for mem: Dictionary in all_memories:
		if mem.get("superseded", false):
			continue
		var hours_since: float = maxf((float(current_time) - float(mem.get("timestamp", mem.get("game_time", 0)))) / 60.0, 0.0)
		var S: float = mem.get("stability", 12.0)
		var recency: float = pow(1.0 + 0.234 * hours_since / maxf(S, 0.1), -0.5)
		var importance_score: float = mem.get("importance", 1.0) / 10.0

		var desc_lower: String = mem.get("text", mem.get("description", "")).to_lower()
		var match_count: int = 0
		for kw: String in keywords:
			if desc_lower.contains(kw):
				match_count += 1
		var relevance: float = float(match_count) / float(keywords.size())

		# Archival summaries get 1.1x boost (same as retrieve_memories)
		var boost: float = 1.1 if mem.get("summary_level", 0) > 0 else 1.0
		var final_score: float = (RETRIEVAL_WEIGHT_RELEVANCE * relevance + RETRIEVAL_WEIGHT_RECENCY * recency + RETRIEVAL_WEIGHT_IMPORTANCE * importance_score) * boost
		scored.append({"memory": mem, "score": final_score})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	var results: Array[Dictionary] = []
	for i: int in range(mini(count, scored.size())):
		var mem: Dictionary = scored[i]["memory"]
		mem["last_accessed"] = current_time
		mem["access_count"] = mem.get("access_count", 0) + 1
		mem["stability"] = minf(mem.get("stability", 12.0) * TESTING_EFFECT_MULTIPLIER, MAX_STABILITY)
		results.append(mem)
	return results


# --- Backward-compatible accessors (match old MemoryStream API) ---

var memories: Array[Dictionary]:
	## Deprecation wrapper — redirects to episodic_memories.
	get:
		return episodic_memories
	set(value):
		episodic_memories = value


func get_recent(count: int = 10) -> Array[Dictionary]:
	if episodic_memories.is_empty():
		return []
	var sorted_mems: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		if not mem.get("superseded", false):
			sorted_mems.append(mem)
	sorted_mems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("game_time", a.get("timestamp", 0)) > b.get("game_time", b.get("timestamp", 0))
	)
	return sorted_mems.slice(0, mini(count, sorted_mems.size()))


func get_by_type(type: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		if mem.get("type", "") == type and not mem.get("superseded", false):
			results.append(mem)
	return results


func get_importance_sum_since(since_time: int) -> float:
	var total: float = 0.0
	for mem: Dictionary in episodic_memories:
		if mem.get("game_time", mem.get("timestamp", 0)) > since_time:
			total += mem.get("importance", 0.0)
	return total


func get_memories_about(actor: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		if mem.get("superseded", false):
			continue
		if mem.get("actor", "") == actor:
			results.append(mem)
		elif actor in mem.get("participants", mem.get("entities", [])):
			if mem not in results:
				results.append(mem)
	return results


# --- Core Memory Updates ---

func update_emotional_state(new_state: String) -> void:
	core_memory["emotional_state"] = new_state
	_save_core_memory()


func update_player_summary(new_summary: String) -> void:
	core_memory["player_summary"] = new_summary
	_save_core_memory()


func update_npc_summary(npc_name: String, summary: String) -> void:
	core_memory["npc_summaries"][npc_name] = summary
	# Enforce max entries — keep top N by relationship strength
	if core_memory["npc_summaries"].size() > MAX_NPC_SUMMARIES:
		# We can't easily sort here without Relationships access, so just keep as-is
		# The caller should manage which NPCs get summaries
		pass
	_save_core_memory()


func add_key_fact(fact: String) -> void:
	var facts: Array = core_memory.get("key_facts", [])
	if fact in facts:
		return
	facts.append(fact)
	if facts.size() > MAX_KEY_FACTS:
		facts.pop_front()
	core_memory["key_facts"] = facts
	_save_core_memory()


func set_active_goals(goals: Array) -> void:
	core_memory["active_goals"] = goals
	# Don't save for ephemeral goals (daily plans)


# --- Compression ---

func get_compression_candidates(batch_size: int = COMPRESSION_BATCH_SIZE) -> Array[Dictionary]:
	## Returns oldest non-protected, non-summarized, non-superseded raw memories.
	var candidates: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		if mem.get("summary_level", 0) == 0 and not mem.get("protected", false) and not mem.get("superseded", false):
			candidates.append(mem)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("timestamp", 0) < b.get("timestamp", 0)
	)
	return candidates.slice(0, mini(batch_size, candidates.size()))


func apply_episode_compression(batch: Array[Dictionary], summary_text: String) -> Dictionary:
	## Creates a Level 1 episode summary in archival, removes source memories from episodic.
	## Returns the summary memory (caller should queue embedding).
	var entities: Array[String] = _extract_entities_from_batch(batch)
	var avg_imp: float = _average_importance(batch)
	var avg_val: float = _average_valence(batch)

	var summary_mem: Dictionary = create_memory(
		summary_text, "episode_summary", entities,
		batch[0].get("location", ""), avg_imp, avg_val
	)
	summary_mem["summary_level"] = 1
	summary_mem["protected"] = true
	summary_mem["game_day"] = batch[0].get("game_day", 0)
	summary_mem["game_hour"] = batch[0].get("game_hour", 0)

	archival_summaries.append(summary_mem)
	for mem: Dictionary in batch:
		episodic_memories.erase(mem)

	return summary_mem


func get_episode_summary_candidates() -> Array[Dictionary]:
	## Returns Level 1 episode summaries from archival, sorted oldest first.
	var episodes: Array[Dictionary] = []
	for mem: Dictionary in archival_summaries:
		if mem.get("summary_level", 0) == 1:
			episodes.append(mem)
	episodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("timestamp", 0) < b.get("timestamp", 0)
	)
	return episodes


func apply_period_compression(batch: Array[Dictionary], summary_text: String) -> Dictionary:
	## Creates a Level 2 period summary in archival, removes source episode summaries.
	## Returns the period summary memory (caller should queue embedding).
	var entities: Array[String] = _extract_entities_from_batch(batch)
	var avg_imp: float = _average_importance(batch)
	var avg_val: float = _average_valence(batch)

	var period_mem: Dictionary = create_memory(
		summary_text, "period_summary", entities,
		"", avg_imp, avg_val
	)
	period_mem["summary_level"] = 2
	period_mem["protected"] = true

	archival_summaries.append(period_mem)
	for mem: Dictionary in batch:
		archival_summaries.erase(mem)

	return period_mem


# --- Forgetting Curves ---

func apply_daily_forgetting() -> void:
	## Decay stability for non-protected episodic memories. Called once per game day.
	## Observations/environment decay faster (×0.7) than other types (×0.85).
	## Memories with very low recency are marked as effectively forgotten.
	var current_time: int = GameClock.total_minutes
	for mem: Dictionary in episodic_memories:
		if mem.get("protected", false):
			continue

		var mem_type: String = mem.get("type", "")
		if mem.get("access_count", 0) == 0 and (mem_type == "observation" or mem_type == "environment"):
			mem["stability"] = maxf(mem.get("stability", 12.0) * FORGETTING_RATE_OBSERVATION, MIN_STABILITY)
		elif mem.get("access_count", 0) == 0:
			mem["stability"] = maxf(mem.get("stability", 12.0) * FORGETTING_RATE_OTHER, MIN_STABILITY)

		# Check if effectively forgotten (recency score < threshold)
		var hours: float = (float(current_time) - float(mem.get("last_accessed", mem.get("timestamp", 0)))) / 60.0
		var S: float = maxf(mem.get("stability", 12.0), 0.1)
		var recency: float = pow(1.0 + 0.234 * hours / S, -0.5)
		if recency < EFFECTIVELY_FORGOTTEN_THRESHOLD:
			mem["effectively_forgotten"] = true


# --- Compression / Forgetting Helpers ---

func _extract_entities_from_batch(batch: Array[Dictionary]) -> Array[String]:
	var entity_set: Dictionary = {}
	for mem: Dictionary in batch:
		for e: Variant in mem.get("entities", mem.get("participants", [])):
			entity_set[str(e)] = true
	var result: Array[String] = []
	for key: String in entity_set:
		result.append(key)
	return result


func _average_importance(batch: Array[Dictionary]) -> float:
	var total: float = 0.0
	for mem: Dictionary in batch:
		total += mem.get("importance", 1.0)
	return total / maxf(float(batch.size()), 1.0)


func _average_valence(batch: Array[Dictionary]) -> float:
	var total: float = 0.0
	for mem: Dictionary in batch:
		total += mem.get("emotional_valence", 0.0)
	return total / maxf(float(batch.size()), 1.0)


# --- Context Assembly ---

func assemble_memory_context(query_embedding: PackedFloat32Array, k: int = 8) -> String:
	## Build the full memory context string for Gemini calls.
	## Includes Tier 0 (always) + Tier 1/2 (top-k by hybrid score).
	var context: String = ""

	# TIER 0: Always include core memory
	context += "=== WHO I AM ===\n"
	context += core_memory.get("identity", "") + "\n"
	context += "Current mood: " + core_memory.get("emotional_state", "neutral") + "\n"

	var player_summary: String = core_memory.get("player_summary", "")
	if player_summary != "":
		context += "What I know about the player: " + player_summary + "\n"

	var npc_summaries: Dictionary = core_memory.get("npc_summaries", {})
	for npc_n: String in npc_summaries:
		context += "About %s: %s\n" % [npc_n, npc_summaries[npc_n]]

	var key_facts: Array = core_memory.get("key_facts", [])
	if not key_facts.is_empty():
		context += "Key things I know: " + ", ".join(key_facts) + "\n"

	# TIER 1+2: Retrieve relevant memories
	var retrieved: Array[Dictionary] = retrieve_memories(query_embedding, k)
	if not retrieved.is_empty():
		context += "\n=== RELEVANT MEMORIES ===\n"
		for mem: Dictionary in retrieved:
			var day: int = mem.get("game_day", 0)
			var hour: int = mem.get("game_hour", 0)
			var time_str: String = "Day %d, Hour %d" % [day, hour]
			var text: String = mem.get("text", mem.get("description", ""))
			context += "[%s] %s\n" % [time_str, text]

	return context


# --- Scoring ---

func _score_memory(memory: Dictionary, query_embedding: PackedFloat32Array, current_game_time: float) -> float:
	# RELEVANCE: cosine similarity
	var relevance: float = 0.0
	var mem_embedding: PackedFloat32Array = memory.get("embedding", PackedFloat32Array())
	if mem_embedding.size() > 0 and query_embedding.size() > 0 and mem_embedding.size() == query_embedding.size():
		var dot: float = 0.0
		var mag_a: float = 0.0
		var mag_b: float = 0.0
		for i: int in range(mem_embedding.size()):
			dot += mem_embedding[i] * query_embedding[i]
			mag_a += mem_embedding[i] * mem_embedding[i]
			mag_b += query_embedding[i] * query_embedding[i]
		mag_a = sqrt(mag_a)
		mag_b = sqrt(mag_b)
		if mag_a > 0.0001 and mag_b > 0.0001:
			relevance = dot / (mag_a * mag_b)
	relevance = clampf((relevance + 1.0) / 2.0, 0.0, 1.0)

	# RECENCY: power-law decay based on stability
	var mem_time: float = float(memory.get("last_accessed", memory.get("timestamp", memory.get("game_time", 0))))
	var hours_elapsed: float = maxf((current_game_time - mem_time) / 60.0, 0.0)
	var S: float = maxf(memory.get("stability", 12.0), 0.1)
	var recency: float = pow(1.0 + 0.234 * hours_elapsed / S, -0.5)

	# IMPORTANCE: normalized to [0,1]
	var importance: float = memory.get("importance", 1.0) / 10.0

	return RETRIEVAL_WEIGHT_RELEVANCE * relevance + RETRIEVAL_WEIGHT_RECENCY * recency + RETRIEVAL_WEIGHT_IMPORTANCE * importance


# --- Deduplication Helpers ---

func _find_memory_by_id(mem_id: String) -> Dictionary:
	for mem: Dictionary in episodic_memories:
		if mem.get("id", "") == mem_id:
			return mem
	return {}


func _extract_state_key(text: String, location: String) -> String:
	var words: PackedStringArray = text.to_lower().split(" ")
	var subject: String = ""
	for i: int in range(words.size()):
		if words[i] == "the" and i + 1 < words.size():
			subject = words[i + 1]
			break
	if subject.is_empty():
		subject = text.sha256_text().left(8)
	return location + ":" + subject


func _texts_are_similar(a: String, b: String, threshold: float) -> bool:
	var set_a: Dictionary = {}
	var set_b: Dictionary = {}
	for w: String in a.to_lower().split(" "):
		set_a[w] = true
	for w: String in b.to_lower().split(" "):
		set_b[w] = true
	var intersection: int = 0
	for w: String in set_a:
		if set_b.has(w):
			intersection += 1
	var union_size: int = set_a.size() + set_b.size() - intersection
	if union_size == 0:
		return true
	return float(intersection) / float(union_size) >= threshold


# --- Static utility ---

static func cosine_similarity(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.is_empty() or b.is_empty() or a.size() != b.size():
		return 0.0
	var dot_product: float = 0.0
	var mag_a: float = 0.0
	var mag_b: float = 0.0
	for i: int in range(a.size()):
		dot_product += a[i] * b[i]
		mag_a += a[i] * a[i]
		mag_b += b[i] * b[i]
	mag_a = sqrt(mag_a)
	mag_b = sqrt(mag_b)
	if mag_a < 0.0001 or mag_b < 0.0001:
		return 0.0
	return dot_product / (mag_a * mag_b)


# --- Persistence ---

func _save_core_memory() -> void:
	var folder: String = "user://npc_data/%s/" % _npc_name
	DirAccess.make_dir_recursive_absolute(folder)
	var file := FileAccess.open(folder + "core_memory.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(core_memory, "\t"))


func save_all() -> void:
	## Save all three tiers to disk.
	var folder: String = "user://npc_data/%s/" % _npc_name
	DirAccess.make_dir_recursive_absolute(folder)

	# Core memory
	_save_core_memory()

	# Episodic memories (metadata only, no embeddings)
	var ep_data: Dictionary = _serialize_episodic()
	var ep_file := FileAccess.open(folder + "episodic_memories.json", FileAccess.WRITE)
	if ep_file:
		ep_file.store_string(JSON.stringify(ep_data, "\t"))

	# Embeddings binary
	_save_embeddings()

	# Archival summaries
	if not archival_summaries.is_empty():
		var arch_data: Dictionary = {"summaries": archival_summaries}
		var arch_file := FileAccess.open(folder + "archival_summaries.json", FileAccess.WRITE)
		if arch_file:
			arch_file.store_string(JSON.stringify(arch_data, "\t"))


func _serialize_episodic() -> Dictionary:
	## Serialize episodic memories for JSON. Strips embeddings (saved separately).
	var serialized: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		var s: Dictionary = mem.duplicate()
		s.erase("embedding")  # Saved in binary file
		serialized.append(s)
	return {"memories": serialized, "next_id": _next_memory_id}


func _deserialize_episodic(data: Dictionary) -> void:
	episodic_memories.clear()
	_next_memory_id = data.get("next_id", 0)
	var raw_memories: Array = data.get("memories", [])
	for raw: Variant in raw_memories:
		if raw is Dictionary:
			var mem: Dictionary = raw.duplicate()
			# Ensure embedding field exists (will be loaded from binary)
			if not mem.has("embedding"):
				mem["embedding"] = PackedFloat32Array()
			# Ensure new fields exist with defaults
			if not mem.has("id"):
				mem["id"] = "mem_%04d" % _next_memory_id
				_next_memory_id += 1
			if not mem.has("text") and mem.has("description"):
				mem["text"] = mem["description"]
			if not mem.has("timestamp") and mem.has("game_time"):
				mem["timestamp"] = mem["game_time"]
			if not mem.has("stability"):
				mem["stability"] = STABILITY_BY_TYPE.get(mem.get("type", "observation"), 12.0)
			if not mem.has("observation_count"):
				mem["observation_count"] = 1
			if not mem.has("protected"):
				mem["protected"] = mem.get("importance", 0.0) >= 8.0
			if not mem.has("superseded"):
				mem["superseded"] = false
			if not mem.has("game_day"):
				var t: int = mem.get("game_time", mem.get("timestamp", 0))
				mem["game_day"] = t / 1440
				mem["game_hour"] = (t % 1440) / 60
			# Ensure participants is Array[String]
			var parts: Array = mem.get("participants", mem.get("entities", []))
			var typed_parts: Array[String] = []
			for p: Variant in parts:
				typed_parts.append(str(p))
			mem["participants"] = typed_parts
			if not mem.has("entities"):
				mem["entities"] = typed_parts

			episodic_memories.append(mem)

	# Recalculate next ID
	for mem: Dictionary in episodic_memories:
		var id_str: String = mem.get("id", "")
		if id_str.begins_with("mem_"):
			var num: int = id_str.substr(4).to_int()
			if num >= _next_memory_id:
				_next_memory_id = num + 1


func _save_embeddings() -> void:
	## Save all embeddings as a packed binary file for efficiency.
	var folder: String = "user://npc_data/%s/" % _npc_name
	var file := FileAccess.open(folder + "embeddings.bin", FileAccess.WRITE)
	if not file:
		return
	# Header: number of memories
	file.store_32(episodic_memories.size())
	for mem: Dictionary in episodic_memories:
		var emb: PackedFloat32Array = mem.get("embedding", PackedFloat32Array())
		file.store_32(emb.size())
		if emb.size() > 0:
			file.store_buffer(emb.to_byte_array())


func _load_embeddings() -> void:
	var path: String = "user://npc_data/%s/embeddings.bin" % _npc_name
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var count: int = file.get_32()
	for i: int in range(mini(count, episodic_memories.size())):
		var emb_size: int = file.get_32()
		if emb_size > 0:
			var bytes: PackedByteArray = file.get_buffer(emb_size * 4)
			episodic_memories[i]["embedding"] = bytes.to_float32_array()
		else:
			episodic_memories[i]["embedding"] = PackedFloat32Array()


# --- Old MemoryStream compatibility (serialize/deserialize) ---

func serialize() -> Dictionary:
	## Returns data in old MemoryStream format for backward compat with town.gd save.
	var serialized_memories: Array[Dictionary] = []
	for mem: Dictionary in episodic_memories:
		var s: Dictionary = mem.duplicate()
		var emb: PackedFloat32Array = s.get("embedding", PackedFloat32Array())
		var emb_array: Array[float] = []
		for v: float in emb:
			emb_array.append(v)
		s["embedding"] = emb_array
		serialized_memories.append(s)
	return {"memories": serialized_memories}


func deserialize(data: Dictionary) -> void:
	## Restores from old MemoryStream serialized format.
	episodic_memories.clear()
	var raw_memories: Array = data.get("memories", [])
	for raw: Variant in raw_memories:
		if not (raw is Dictionary):
			continue
		var mem: Dictionary = (raw as Dictionary).duplicate()
		# Convert Array back to PackedFloat32Array
		var emb_array: Array = mem.get("embedding", [])
		var emb := PackedFloat32Array()
		if not emb_array.is_empty():
			emb.resize(emb_array.size())
			for i: int in range(emb_array.size()):
				emb[i] = float(emb_array[i])
		mem["embedding"] = emb
		# Ensure participants is an Array[String]
		var parts: Array = mem.get("participants", [])
		var typed_parts: Array[String] = []
		for p: Variant in parts:
			typed_parts.append(str(p))
		mem["participants"] = typed_parts
		# Add new fields if missing
		if not mem.has("id"):
			mem["id"] = "mem_%04d" % _next_memory_id
			_next_memory_id += 1
		if not mem.has("text"):
			mem["text"] = mem.get("description", "")
		if not mem.has("timestamp"):
			mem["timestamp"] = mem.get("game_time", 0)
		if not mem.has("stability"):
			mem["stability"] = STABILITY_BY_TYPE.get(mem.get("type", "observation"), 12.0)
		if not mem.has("observation_count"):
			mem["observation_count"] = 1
		if not mem.has("protected"):
			mem["protected"] = mem.get("importance", 0.0) >= 8.0
		if not mem.has("superseded"):
			mem["superseded"] = false
		if not mem.has("game_day"):
			var t: int = mem.get("game_time", 0)
			mem["game_day"] = t / 1440
			mem["game_hour"] = (t % 1440) / 60
		if not mem.has("entities"):
			mem["entities"] = typed_parts
		episodic_memories.append(mem)


func migrate_from_memory_stream(old_stream: MemoryStream) -> void:
	## Migrate memories from old MemoryStream to new episodic tier.
	for old_mem: Dictionary in old_stream.memories:
		var mem: Dictionary = old_mem.duplicate()
		# Assign new ID
		mem["id"] = "mem_%04d" % _next_memory_id
		_next_memory_id += 1
		# Copy text field
		if not mem.has("text"):
			mem["text"] = mem.get("description", "")
		if not mem.has("timestamp"):
			mem["timestamp"] = mem.get("game_time", 0)
		if not mem.has("stability"):
			mem["stability"] = STABILITY_BY_TYPE.get(mem.get("type", "observation"), 12.0)
		if not mem.has("observation_count"):
			mem["observation_count"] = 1
		if not mem.has("protected"):
			mem["protected"] = mem.get("importance", 0.0) >= 8.0
		if not mem.has("superseded"):
			mem["superseded"] = false
		if not mem.has("game_day"):
			var t: int = mem.get("game_time", 0)
			mem["game_day"] = t / 1440
			mem["game_hour"] = (t % 1440) / 60
		if not mem.has("entities"):
			mem["entities"] = mem.get("participants", [])
		episodic_memories.append(mem)
	print("[Memory] Migrated %d old memories for %s" % [old_stream.memories.size(), _npc_name])
