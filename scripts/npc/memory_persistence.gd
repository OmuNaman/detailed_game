extends RefCounted
## Handles all memory save/load: JSON persistence, embedding binary files,
## and backward-compatible serialization.
## Owned by MemorySystem — accesses shared data via _mem reference.

var _mem  # MemorySystem parent — untyped to avoid circular class_name dependency


func set_parent(parent) -> void:
	_mem = parent


# --- Core Memory Persistence ---

func save_core_memory() -> void:
	var folder: String = "res://data/npc_data/%s/" % _mem._npc_name
	DirAccess.make_dir_recursive_absolute(folder)
	var file := FileAccess.open(folder + "core_memory.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_mem.core_memory, "\t"))


# --- Full Save ---

func save_all() -> void:
	## Save all three tiers to disk.
	var folder: String = "res://data/npc_data/%s/" % _mem._npc_name
	DirAccess.make_dir_recursive_absolute(folder)

	# Core memory
	save_core_memory()

	# Episodic memories (metadata only, no embeddings)
	var ep_data: Dictionary = serialize_episodic()
	var ep_file := FileAccess.open(folder + "episodic_memories.json", FileAccess.WRITE)
	if ep_file:
		ep_file.store_string(JSON.stringify(ep_data, "\t"))

	# Embeddings binary
	save_embeddings()

	# Archival summaries
	if not _mem.archival_summaries.is_empty():
		var arch_data: Dictionary = {"summaries": _mem.archival_summaries}
		var arch_file := FileAccess.open(folder + "archival_summaries.json", FileAccess.WRITE)
		if arch_file:
			arch_file.store_string(JSON.stringify(arch_data, "\t"))


# --- Episodic Serialization ---

func serialize_episodic() -> Dictionary:
	## Serialize episodic memories for JSON. Strips embeddings (saved separately).
	var serialized: Array[Dictionary] = []
	for mem: Dictionary in _mem.episodic_memories:
		var s: Dictionary = mem.duplicate()
		s.erase("embedding")  # Saved in binary file
		serialized.append(s)
	return {"memories": serialized, "next_id": _mem._next_memory_id}


func deserialize_episodic(data: Dictionary) -> void:
	_mem.episodic_memories.clear()
	_mem._next_memory_id = data.get("next_id", 0)
	var raw_memories: Array = data.get("memories", [])
	for raw: Variant in raw_memories:
		if raw is Dictionary:
			var mem: Dictionary = raw.duplicate()
			# Ensure embedding field exists (will be loaded from binary)
			if not mem.has("embedding"):
				mem["embedding"] = PackedFloat32Array()
			# Ensure new fields exist with defaults
			if not mem.has("id"):
				mem["id"] = "mem_%04d" % _mem._next_memory_id
				_mem._next_memory_id += 1
			if not mem.has("text") and mem.has("description"):
				mem["text"] = mem["description"]
			if not mem.has("timestamp") and mem.has("game_time"):
				mem["timestamp"] = mem["game_time"]
			if not mem.has("stability"):
				mem["stability"] = _mem.STABILITY_BY_TYPE.get(mem.get("type", "observation"), 12.0)
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

			_mem.episodic_memories.append(mem)

	# Recalculate next ID
	for mem: Dictionary in _mem.episodic_memories:
		var id_str: String = mem.get("id", "")
		if id_str.begins_with("mem_"):
			var num: int = id_str.substr(4).to_int()
			if num >= _mem._next_memory_id:
				_mem._next_memory_id = num + 1


# --- Embedding Binary Files ---

func save_embeddings() -> void:
	## Save all embeddings as a packed binary file for efficiency.
	var folder: String = "res://data/npc_data/%s/" % _mem._npc_name
	var file := FileAccess.open(folder + "embeddings.bin", FileAccess.WRITE)
	if not file:
		return
	# Header: number of memories
	file.store_32(_mem.episodic_memories.size())
	for mem: Dictionary in _mem.episodic_memories:
		var emb: PackedFloat32Array = mem.get("embedding", PackedFloat32Array())
		file.store_32(emb.size())
		if emb.size() > 0:
			file.store_buffer(emb.to_byte_array())


func load_embeddings() -> void:
	var path: String = "res://data/npc_data/%s/embeddings.bin" % _mem._npc_name
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var count: int = file.get_32()
	for i: int in range(mini(count, _mem.episodic_memories.size())):
		var emb_size: int = file.get_32()
		if emb_size > 0:
			var bytes: PackedByteArray = file.get_buffer(emb_size * 4)
			_mem.episodic_memories[i]["embedding"] = bytes.to_float32_array()
		else:
			_mem.episodic_memories[i]["embedding"] = PackedFloat32Array()


# --- Legacy format serialization (backward compat with town.gd save) ---

func serialize_compat() -> Dictionary:
	## Returns data in legacy format for backward compat with town.gd save.
	var serialized_memories: Array[Dictionary] = []
	for mem: Dictionary in _mem.episodic_memories:
		var s: Dictionary = mem.duplicate()
		var emb: PackedFloat32Array = s.get("embedding", PackedFloat32Array())
		var emb_array: Array[float] = []
		for v: float in emb:
			emb_array.append(v)
		s["embedding"] = emb_array
		serialized_memories.append(s)
	return {"memories": serialized_memories}


func deserialize_compat(data: Dictionary) -> void:
	## Restores from legacy serialized format.
	_mem.episodic_memories.clear()
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
			mem["id"] = "mem_%04d" % _mem._next_memory_id
			_mem._next_memory_id += 1
		if not mem.has("text"):
			mem["text"] = mem.get("description", "")
		if not mem.has("timestamp"):
			mem["timestamp"] = mem.get("game_time", 0)
		if not mem.has("stability"):
			mem["stability"] = _mem.STABILITY_BY_TYPE.get(mem.get("type", "observation"), 12.0)
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
		_mem.episodic_memories.append(mem)
