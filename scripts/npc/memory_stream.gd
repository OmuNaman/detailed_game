class_name MemoryStream
extends RefCounted
## Scored memory storage and retrieval system inspired by Stanford Generative Agents.
## Each NPC holds one instance. Pure data class — no signals, no process loop.

var memories: Array[Dictionary] = []
const MAX_MEMORIES: int = 200


# --- Core operations ---

func add_memory(description: String, type: String, actor: String,
		participants: Array[String], observer_location: String,
		observed_near: String, importance: float, valence: float,
		embedding: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	## Creates a new memory record, appends it, enforces cap, returns the record.
	var record: Dictionary = {
		"description": description,
		"type": type,
		"actor": actor,
		"participants": participants,
		"observer_location": observer_location,
		"observed_near": observed_near,
		"game_time": GameClock.total_minutes,
		"importance": clampf(importance, 1.0, 10.0),
		"emotional_valence": clampf(valence, -1.0, 1.0),
		"embedding": embedding,
		"last_accessed": GameClock.total_minutes,
		"access_count": 0,
	}

	# Evict lowest-value memory if at capacity
	if memories.size() >= MAX_MEMORIES:
		_evict_one()

	memories.append(record)
	return record


func retrieve(query_embedding: PackedFloat32Array, current_time: int,
		count: int = 5) -> Array[Dictionary]:
	## Core retrieval algorithm. Scores every memory using:
	##   recency + importance + relevance (equal weights)
	if memories.is_empty():
		return []

	var scored: Array[Dictionary] = []
	for mem: Dictionary in memories:
		var hours_since: float = maxf((current_time - mem.get("game_time", 0)) / 60.0, 0.0)
		var recency: float = pow(0.99, hours_since)
		var importance_score: float = mem.get("importance", 1.0) / 10.0
		var relevance: float = cosine_similarity(query_embedding, mem.get("embedding", PackedFloat32Array()))
		var final_score: float = (recency * 1.0) + (importance_score * 1.0) + (relevance * 1.0)
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
		results.append(mem)

	return results


func retrieve_by_keywords(keywords: Array[String], current_time: int,
		count: int = 5) -> Array[Dictionary]:
	## Fallback when embeddings unavailable. Relevance = keyword match ratio.
	if memories.is_empty() or keywords.is_empty():
		return []

	var scored: Array[Dictionary] = []
	for mem: Dictionary in memories:
		var hours_since: float = maxf((current_time - mem.get("game_time", 0)) / 60.0, 0.0)
		var recency: float = pow(0.99, hours_since)
		var importance_score: float = mem.get("importance", 1.0) / 10.0

		# Keyword matching — count how many keywords appear in description
		var desc_lower: String = mem.get("description", "").to_lower()
		var match_count: int = 0
		for kw: String in keywords:
			if desc_lower.contains(kw.to_lower()):
				match_count += 1
		var relevance: float = float(match_count) / float(keywords.size())

		var final_score: float = (recency * 1.0) + (importance_score * 1.0) + (relevance * 1.0)
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
		results.append(mem)

	return results


func get_recent(count: int = 10) -> Array[Dictionary]:
	## Most recent memories by game_time descending. No scoring.
	if memories.is_empty():
		return []
	var sorted_mems: Array[Dictionary] = memories.duplicate()
	sorted_mems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("game_time", 0) > b.get("game_time", 0)
	)
	return sorted_mems.slice(0, mini(count, sorted_mems.size()))


func get_by_type(type: String) -> Array[Dictionary]:
	## Filter memories by type ("observation", "reflection", etc.)
	var results: Array[Dictionary] = []
	for mem: Dictionary in memories:
		if mem.get("type", "") == type:
			results.append(mem)
	return results


func get_importance_sum_since(since_time: int) -> float:
	## Sum importance of all memories created after since_time.
	## Used to trigger reflections (when sum > 50, NPC should reflect).
	var total: float = 0.0
	for mem: Dictionary in memories:
		if mem.get("game_time", 0) > since_time:
			total += mem.get("importance", 0.0)
	return total


func get_memories_about(actor: String) -> Array[Dictionary]:
	## All memories where actor field matches or actor is in participants.
	var results: Array[Dictionary] = []
	for mem: Dictionary in memories:
		if mem.get("actor", "") == actor:
			results.append(mem)
		elif actor in mem.get("participants", []):
			if mem not in results:
				results.append(mem)
	return results


# --- Utility ---

static func cosine_similarity(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	## Returns -1.0 to 1.0. If either array is empty, return 0.0.
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


func _evict_one() -> void:
	## Remove the memory with the lowest eviction score.
	if memories.is_empty():
		return
	var current_time: int = GameClock.total_minutes
	var lowest_idx: int = 0
	var lowest_score: float = _calculate_eviction_score(memories[0], current_time)
	for i: int in range(1, memories.size()):
		var score: float = _calculate_eviction_score(memories[i], current_time)
		if score < lowest_score:
			lowest_score = score
			lowest_idx = i
	memories.remove_at(lowest_idx)


func _calculate_eviction_score(memory: Dictionary, current_time: int) -> float:
	## Score for eviction: lowest score gets removed.
	## importance * 0.5 + access_count * 0.3 + recency_score * 0.2
	var importance: float = memory.get("importance", 1.0) / 10.0
	var access: float = minf(memory.get("access_count", 0) / 10.0, 1.0)
	var hours_since: float = maxf((current_time - memory.get("game_time", 0)) / 60.0, 0.0)
	var recency: float = pow(0.99, hours_since)
	return (importance * 0.5) + (access * 0.3) + (recency * 0.2)


# --- Persistence ---

func serialize() -> Dictionary:
	## Returns all data as plain Dictionary/Array for JSON.
	var serialized_memories: Array[Dictionary] = []
	for mem: Dictionary in memories:
		var s: Dictionary = mem.duplicate()
		# Convert PackedFloat32Array to regular Array for JSON
		var emb: PackedFloat32Array = s.get("embedding", PackedFloat32Array())
		var emb_array: Array[float] = []
		for v: float in emb:
			emb_array.append(v)
		s["embedding"] = emb_array
		serialized_memories.append(s)
	return {"memories": serialized_memories}


func deserialize(data: Dictionary) -> void:
	## Restores from serialized data.
	memories.clear()
	var raw_memories: Array = data.get("memories", [])
	for raw: Dictionary in raw_memories:
		var mem: Dictionary = raw.duplicate()
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
		memories.append(mem)
