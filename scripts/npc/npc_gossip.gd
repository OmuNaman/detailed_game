extends Node
## Handles gossip selection, sharing, and natural information diffusion via third-party mentions.

var npc: CharacterBody2D

const GOSSIP_TRUST_THRESHOLD: float = 15.0  # Minimum trust to share gossip
const GOSSIP_CHANCE: float = 0.2             # 20% chance of explicit gossiping (reduced — natural diffusion handles the rest)
const GOSSIP_MIN_IMPORTANCE: float = 3.0     # Only share important-ish memories
const GOSSIP_MAX_AGE_HOURS: int = 48         # Don't share ancient news
const GOSSIP_MAX_HOPS: int = 3               # Max propagation depth


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


func pick_gossip_for(other_npc: CharacterBody2D) -> Dictionary:
	## Select an interesting memory to share with another NPC.
	## Returns the memory Dictionary, or {} if nothing worth sharing.

	# Trust check — don't gossip with people you don't trust
	var trust: int = Relationships.get_relationship(npc.npc_name, other_npc.npc_name)["trust"]
	if trust < GOSSIP_TRUST_THRESHOLD:
		return {}

	# Random chance — not every conversation includes gossip
	if randf() > GOSSIP_CHANCE:
		return {}

	# Gather candidate memories: recent, important, about THIRD PARTIES
	var candidates: Array[Dictionary] = []
	var current_time: int = GameClock.total_minutes

	for mem: Dictionary in npc.memory.memories:
		# Must be recent enough
		var hours_ago: float = (current_time - mem.get("game_time", 0)) / 60.0
		if hours_ago > GOSSIP_MAX_AGE_HOURS:
			continue

		# Must be important enough
		if mem.get("importance", 0.0) < GOSSIP_MIN_IMPORTANCE:
			continue

		# Must be about someone other than the conversation partner or self
		var actor: String = mem.get("actor", "")
		if actor == other_npc.npc_name or actor == npc.npc_name or actor == "":
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


func share_gossip_with(receiver_npc: CharacterBody2D, original_memory: Dictionary) -> void:
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
		gossip_desc = "%s told me: %s" % [npc.npc_name, original_desc]
	else:
		# Second-hand+
		gossip_desc = "%s mentioned that they heard: %s" % [npc.npc_name, original_desc]

	# Importance degrades with each hop (gossip is less reliable)
	var gossip_importance: float = maxf(original_memory.get("importance", 3.0) - (hop_count * 1.0), 2.0)

	# Create the gossip memory for the receiver
	receiver_npc._add_memory_with_embedding(
		gossip_desc,
		"gossip",
		about,
		[npc.npc_name, receiver_npc.npc_name, about] as Array[String],
		receiver_npc._current_destination,
		npc._current_destination,
		gossip_importance,
		original_memory.get("emotional_valence", 0.0)
	)

	# Tag the receiver's new gossip memory with tracking metadata
	if not receiver_npc.memory.memories.is_empty():
		var new_mem: Dictionary = receiver_npc.memory.memories[-1]
		new_mem["gossip_source"] = npc.npc_name
		new_mem["gossip_hops"] = hop_count
		new_mem["original_description"] = original_desc

	# Create a memory for the SHARER that they told someone
	npc._add_memory_with_embedding(
		"Told %s about %s" % [receiver_npc.npc_name, original_desc.left(60)],
		"gossip_shared",
		receiver_npc.npc_name,
		[npc.npc_name, receiver_npc.npc_name] as Array[String],
		npc._current_destination, npc._current_destination,
		2.0, 0.0
	)

	# Bug 3: Track that we told this person (prevents repeat gossip)
	if not original_memory.has("shared_with"):
		original_memory["shared_with"] = []
	if receiver_npc.npc_name not in original_memory["shared_with"]:
		original_memory["shared_with"].append(receiver_npc.npc_name)

	# Sharing gossip builds trust slightly (intimacy of shared secrets)
	Relationships.modify_mutual(npc.npc_name, receiver_npc.npc_name, 1, 0, 0)

	# Mark as significant event for the receiver (emotional decay tracking)
	receiver_npc.dialogue.last_significant_event_time = GameClock.total_minutes

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
			npc.npc_name, receiver_npc.npc_name, gossip_desc.left(80), hop_count, gossip_importance])


func detect_third_party_mentions(speaker_name: String, line_text: String, listener: CharacterBody2D) -> void:
	## Scan dialogue text for mentions of third-party NPCs/player.
	## Creates gossip-type memory for the listener about what was said.
	if not is_instance_valid(listener) or not "memory" in listener:
		return

	var all_names: Array[String] = []
	for npc_node: Node in npc.get_tree().get_nodes_in_group("npcs"):
		if npc_node.npc_name != speaker_name and npc_node.npc_name != listener.npc_name:
			all_names.append(npc_node.npc_name)
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
