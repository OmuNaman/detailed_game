extends Node
## Tracks pairwise relationships between all entities in DeepTown.
## Each relationship has three dimensions: trust, affection, respect.
## Scores range from -100 to 100. Neutral is 0.

## {source_name: {target_name: {trust, affection, respect}}}
var _relations: Dictionary = {}


func _ready() -> void:
	load_relationships()


# --- Core API ---

func get_relationship(from_name: String, to_name: String) -> Dictionary:
	## Returns {trust, affection, respect} or defaults if not set.
	if _relations.has(from_name) and _relations[from_name].has(to_name):
		return _relations[from_name][to_name]
	return {"trust": 0, "affection": 0, "respect": 0}


func get_opinion(from_name: String, to_name: String) -> float:
	## Single overall opinion score: weighted average of all three dimensions.
	## Range: -100 to 100. Used for quick checks.
	var r: Dictionary = get_relationship(from_name, to_name)
	return (r["trust"] * 0.4 + r["affection"] * 0.35 + r["respect"] * 0.25)


func get_opinion_label(from_name: String, to_name: String) -> String:
	## Human-readable relationship label for dialogue context.
	var opinion: float = get_opinion(from_name, to_name)
	if opinion > 60: return "deeply trusts"
	if opinion > 30: return "likes"
	if opinion > 10: return "feels friendly toward"
	if opinion > -10: return "feels neutral about"
	if opinion > -30: return "dislikes"
	if opinion > -60: return "distrusts"
	return "despises"


func modify(from_name: String, to_name: String, trust_delta: int = 0,
		affection_delta: int = 0, respect_delta: int = 0) -> void:
	## Adjust relationship scores. Clamped to -100..100.
	_ensure_entry(from_name, to_name)
	var r: Dictionary = _relations[from_name][to_name]
	r["trust"] = clampi(r["trust"] + trust_delta, -100, 100)
	r["affection"] = clampi(r["affection"] + affection_delta, -100, 100)
	r["respect"] = clampi(r["respect"] + respect_delta, -100, 100)

	if OS.is_debug_build():
		print("[Relationships] %s → %s: T:%d A:%d R:%d (Δ T:%+d A:%+d R:%+d)" % [
			from_name, to_name, r["trust"], r["affection"], r["respect"],
			trust_delta, affection_delta, respect_delta])


func modify_mutual(name_a: String, name_b: String, trust_delta: int = 0,
		affection_delta: int = 0, respect_delta: int = 0) -> void:
	## Symmetric adjustment — both sides change equally.
	modify(name_a, name_b, trust_delta, affection_delta, respect_delta)
	modify(name_b, name_a, trust_delta, affection_delta, respect_delta)


func get_all_for(npc_name: String) -> Dictionary:
	## Returns all relationships FROM this NPC: {target: {trust, affection, respect}}
	if _relations.has(npc_name):
		return _relations[npc_name]
	return {}


func get_closest_friends(npc_name: String, count: int = 3) -> Array[String]:
	## Returns the names of the NPCs this person likes most.
	var all: Dictionary = get_all_for(npc_name)
	var scored: Array[Dictionary] = []
	for target: String in all:
		scored.append({"name": target, "score": get_opinion(npc_name, target)})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)
	var results: Array[String] = []
	for i: int in range(mini(count, scored.size())):
		results.append(scored[i]["name"])
	return results


func _ensure_entry(from_name: String, to_name: String) -> void:
	if not _relations.has(from_name):
		_relations[from_name] = {}
	if not _relations[from_name].has(to_name):
		_relations[from_name][to_name] = {"trust": 0, "affection": 0, "respect": 0}


# --- Decay ---

func decay_all(amount: int = 1) -> void:
	## Relationships drift toward 0 over time. Called once per game day.
	for from_name: String in _relations:
		for to_name: String in _relations[from_name]:
			var r: Dictionary = _relations[from_name][to_name]
			for dim: String in ["trust", "affection", "respect"]:
				var val: int = r[dim]
				if val > 0:
					r[dim] = maxi(val - amount, 0)
				elif val < 0:
					r[dim] = mini(val + amount, 0)


# --- Persistence ---

func save_relationships() -> void:
	var file := FileAccess.open("user://relationships.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_relations, "\t"))
		if OS.is_debug_build():
			print("[Relationships] Saved to user://relationships.json")


func load_relationships() -> void:
	var file := FileAccess.open("user://relationships.json", FileAccess.READ)
	if not file:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK:
		_relations = json.data
		if OS.is_debug_build():
			print("[Relationships] Loaded relationships for %d entities" % _relations.size())
