class_name MemorySystem
extends RefCounted
## Three-tier memory architecture inspired by Stanford Generative Agents + MemGPT.
## Tier 0: Core Memory — small, always in every prompt (~800 tokens)
## Tier 1: Episodic Memory — searchable, no hard cap, scored retrieval
## Tier 2: Archival Summaries — compressed old memories (future use)
##
## Replaces the flat MemoryStream with deduplication, state-change detection,
## stability-based decay, and hybrid retrieval (embedding + recency + importance).
##
## Delegates retrieval to MemoryRetrieval and persistence to MemoryPersistence.

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

# --- Tier 2: Archival Summaries ---

var archival_summaries: Array[Dictionary] = []

# --- Deduplication state ---

var _recent_observation_hashes: Dictionary = {}  # dedup_key -> memory_id
var _last_observed_states: Dictionary = {}        # state_key -> {text, memory_id}

# --- NPC reference ---

var _npc_name: String = ""

# --- Sub-components ---

const _MemoryRetrievalScript = preload("res://scripts/npc/memory_retrieval.gd")
const _MemoryPersistenceScript = preload("res://scripts/npc/memory_persistence.gd")

var _retrieval  # MemoryRetrieval instance
var _persistence  # MemoryPersistence instance


# --- Backward-compatible property ---

var memories: Array[Dictionary]:
	## Deprecation wrapper — redirects to episodic_memories.
	get:
		return episodic_memories
	set(value):
		episodic_memories = value


# --- Initialization ---

func initialize(npc_name: String, personality_prompt: String, player_name: String) -> void:
	_npc_name = npc_name
	core_memory["identity"] = personality_prompt
	if core_memory["player_summary"] == "":
		core_memory["player_summary"] = "I haven't met %s yet." % player_name
	_init_subcomponents()


func load_or_init(npc_name: String, personality_prompt: String, player_name: String) -> void:
	_npc_name = npc_name
	_init_subcomponents()

	# Try loading core memory
	var core_path: String = "res://data/npc_data/%s/core_memory.json" % npc_name
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
	var ep_path: String = "res://data/npc_data/%s/episodic_memories.json" % npc_name
	if FileAccess.file_exists(ep_path):
		var file := FileAccess.open(ep_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				_persistence.deserialize_episodic(json.data)
				print("[Memory] Loaded %d episodic memories for %s" % [episodic_memories.size(), npc_name])

	# Load embeddings from binary file
	_persistence.load_embeddings()

	# Load archival summaries
	var arch_path: String = "res://data/npc_data/%s/archival_summaries.json" % npc_name
	if FileAccess.file_exists(arch_path):
		var file := FileAccess.open(arch_path, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				var raw: Array = json.data.get("summaries", [])
				for entry: Variant in raw:
					if entry is Dictionary:
						archival_summaries.append(entry)


func _init_subcomponents() -> void:
	if not _retrieval:
		_retrieval = _MemoryRetrievalScript.new()
		_retrieval.set_parent(self)
	if not _persistence:
		_persistence = _MemoryPersistenceScript.new()
		_persistence.set_parent(self)


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


# --- Retrieval (delegated to MemoryRetrieval) ---

func retrieve(query_embedding: PackedFloat32Array, current_time: int,
		count: int = 5) -> Array[Dictionary]:
	return _retrieval.retrieve(query_embedding, current_time, count)


func retrieve_memories(query_embedding: PackedFloat32Array, k: int = 8,
		type_filter: String = "", entity_filter: String = "",
		time_range_hours: float = -1) -> Array[Dictionary]:
	return _retrieval.retrieve_memories(query_embedding, k, type_filter, entity_filter, time_range_hours)


func retrieve_by_keywords(keywords: Array[String], current_time: int,
		count: int = 5) -> Array[Dictionary]:
	return _retrieval.retrieve_by_keywords(keywords, current_time, count)


func retrieve_by_query_text(query: String, current_time: int,
		count: int = 8) -> Array[Dictionary]:
	return _retrieval.retrieve_by_query_text(query, current_time, count)


func assemble_memory_context(query_embedding: PackedFloat32Array, k: int = 8) -> String:
	return _retrieval.assemble_memory_context(query_embedding, k)


static func cosine_similarity(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	return _MemoryRetrievalScript.cosine_similarity(a, b)


# --- Backward-compatible accessors (match old MemoryStream API) ---

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
	_persistence.save_core_memory()


func update_player_summary(new_summary: String) -> void:
	core_memory["player_summary"] = new_summary
	_persistence.save_core_memory()


func update_npc_summary(npc_name: String, summary: String) -> void:
	core_memory["npc_summaries"][npc_name] = summary
	# Enforce max entries — keep top N by relationship strength
	if core_memory["npc_summaries"].size() > MAX_NPC_SUMMARIES:
		# We can't easily sort here without Relationships access, so just keep as-is
		# The caller should manage which NPCs get summaries
		pass
	_persistence.save_core_memory()


func add_key_fact(fact: String) -> void:
	var facts: Array = core_memory.get("key_facts", [])
	if fact in facts:
		return
	facts.append(fact)
	if facts.size() > MAX_KEY_FACTS:
		facts.pop_front()
	core_memory["key_facts"] = facts
	_persistence.save_core_memory()


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
	## Observations/environment decay faster (x0.7) than other types (x0.85).
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


# --- Persistence (delegated to MemoryPersistence) ---

func save_all() -> void:
	_persistence.save_all()


func serialize() -> Dictionary:
	return _persistence.serialize_compat()


func deserialize(data: Dictionary) -> void:
	_persistence.deserialize_compat(data)


func migrate_from_memory_stream(old_stream: MemoryStream) -> void:
	_persistence.migrate_from_memory_stream(old_stream)


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
