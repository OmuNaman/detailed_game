extends RefCounted
## Handles all memory retrieval: embedding-based, keyword-based, hybrid scoring.
## Searches both episodic memories and archival summaries.
## Owned by MemorySystem — accesses shared data via _mem reference.

var _mem  # MemorySystem parent — untyped to avoid circular class_name dependency


func set_parent(parent) -> void:
	_mem = parent


# --- Embedding-based retrieval ---

func retrieve(query_embedding: PackedFloat32Array, current_time: int,
		count: int = 5) -> Array[Dictionary]:
	## Backward-compatible scored retrieval using the new hybrid formula.
	if _mem.episodic_memories.is_empty():
		return []

	var scored: Array[Dictionary] = []
	for mem: Dictionary in _mem.episodic_memories:
		if mem.get("superseded", false):
			continue
		var score: float = score_memory(mem, query_embedding, float(current_time))
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
		mem["stability"] = minf(mem.get("stability", 12.0) * _mem.TESTING_EFFECT_MULTIPLIER, _mem.MAX_STABILITY)
		results.append(mem)

	return results


func retrieve_memories(query_embedding: PackedFloat32Array, k: int = 8,
		type_filter: String = "", entity_filter: String = "",
		time_range_hours: float = -1) -> Array[Dictionary]:
	## Full hybrid retrieval with optional filters. Searches both episodic + archival.
	var current_time: float = float(GameClock.total_minutes)
	var candidates: Array[Dictionary] = []

	# Gather from both tiers
	var all_memories: Array[Dictionary] = _mem.episodic_memories.duplicate()
	all_memories.append_array(_mem.archival_summaries)

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
		var score: float = score_memory(mem, query_embedding, current_time)
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
		mem["stability"] = minf(mem.get("stability", 12.0) * _mem.TESTING_EFFECT_MULTIPLIER, _mem.MAX_STABILITY)
		results.append(mem)

	return results


# --- Keyword-based retrieval ---

func retrieve_by_keywords(keywords: Array[String], current_time: int,
		count: int = 5) -> Array[Dictionary]:
	## Fallback keyword retrieval — backward compatible.
	if _mem.episodic_memories.is_empty() or keywords.is_empty():
		return []

	var scored: Array[Dictionary] = []
	for mem: Dictionary in _mem.episodic_memories:
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

		var final_score: float = _mem.RETRIEVAL_WEIGHT_RELEVANCE * relevance + _mem.RETRIEVAL_WEIGHT_RECENCY * recency + _mem.RETRIEVAL_WEIGHT_IMPORTANCE * importance_score
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
		mem["stability"] = minf(mem.get("stability", 12.0) * _mem.TESTING_EFFECT_MULTIPLIER, _mem.MAX_STABILITY)
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
		return _mem.get_recent(count)

	# Search both tiers (retrieve_by_keywords only does episodic)
	var all_memories: Array[Dictionary] = _mem.episodic_memories.duplicate()
	all_memories.append_array(_mem.archival_summaries)

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
		var final_score: float = (_mem.RETRIEVAL_WEIGHT_RELEVANCE * relevance + _mem.RETRIEVAL_WEIGHT_RECENCY * recency + _mem.RETRIEVAL_WEIGHT_IMPORTANCE * importance_score) * boost
		scored.append({"memory": mem, "score": final_score})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	var results: Array[Dictionary] = []
	for i: int in range(mini(count, scored.size())):
		var mem: Dictionary = scored[i]["memory"]
		mem["last_accessed"] = current_time
		mem["access_count"] = mem.get("access_count", 0) + 1
		mem["stability"] = minf(mem.get("stability", 12.0) * _mem.TESTING_EFFECT_MULTIPLIER, _mem.MAX_STABILITY)
		results.append(mem)
	return results


# --- Context Assembly ---

func assemble_memory_context(query_embedding: PackedFloat32Array, k: int = 8) -> String:
	## Build the full memory context string for Gemini calls.
	## Includes Tier 0 (always) + Tier 1/2 (top-k by hybrid score).
	var context: String = ""

	# TIER 0: Always include core memory
	context += "=== WHO I AM ===\n"
	context += _mem.core_memory.get("identity", "") + "\n"
	context += "Current mood: " + _mem.core_memory.get("emotional_state", "neutral") + "\n"

	var player_summary: String = _mem.core_memory.get("player_summary", "")
	if player_summary != "":
		context += "What I know about the player: " + player_summary + "\n"

	var npc_summaries: Dictionary = _mem.core_memory.get("npc_summaries", {})
	for npc_n: String in npc_summaries:
		context += "About %s: %s\n" % [npc_n, npc_summaries[npc_n]]

	var key_facts: Array = _mem.core_memory.get("key_facts", [])
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

func score_memory(memory: Dictionary, query_embedding: PackedFloat32Array, current_game_time: float) -> float:
	## Hybrid score: relevance x 0.5 + recency x 0.3 + importance x 0.2
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

	return _mem.RETRIEVAL_WEIGHT_RELEVANCE * relevance + _mem.RETRIEVAL_WEIGHT_RECENCY * recency + _mem.RETRIEVAL_WEIGHT_IMPORTANCE * importance


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
