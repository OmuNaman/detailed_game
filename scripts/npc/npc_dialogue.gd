extends Node
## Handles all player-facing dialogue: greeting, multi-turn replies,
## conversation impact analysis, conversation summaries, and template fallbacks.

var npc: CharacterBody2D

# Working memory — player conversation tracked for summary on end
var _player_conv_history: Array[Dictionary] = []  # [{speaker, text}]

# Emotional state decay tracking
var last_significant_event_time: int = 0


func _ready() -> void:
	npc = get_parent() as CharacterBody2D


# --- Public API (controller wrappers call these) ---

func get_dialogue_response() -> String:
	## Synchronous template-based response. Used as immediate fallback.
	return _get_template_response()


func get_dialogue_response_async(callback: Callable) -> void:
	## Async dialogue: tries Gemini first, falls back to template.
	## Callback receives (response: String).
	var player: Node = npc.get_tree().get_first_node_in_group("player")
	if player:
		npc._face_toward(player.global_position)

	# Initialize working memory for this conversation
	_player_conv_history.clear()

	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	var system_prompt: String = _build_system_prompt()
	var user_message: String = _build_dialogue_context()

	GeminiClient.generate(system_prompt, user_message, func(text: String, success: bool) -> void:
		if not is_instance_valid(npc):
			return
		if success and text != "":
			npc._add_memory_with_embedding(
				"Talked with %s at the %s. I said: %s" % [PlayerProfile.player_name, npc._current_destination, text.left(80)],
				"dialogue", PlayerProfile.player_name, [npc.npc_name, PlayerProfile.player_name] as Array[String],
				npc._current_destination, npc._current_destination, 4.0, 0.2
			)
			# Opening greeting — no relationship bump yet (player hasn't said anything)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func get_conversation_reply_async(player_message: String, history: Array[Dictionary], callback: Callable) -> void:
	## Generate a reply considering full conversation history.
	## Uses player's message as retrieval query for targeted memory recall.
	if not GeminiClient.has_api_key():
		callback.call(_get_template_response())
		return

	# Track conversation for summary on end
	_player_conv_history = history.duplicate()

	var system_prompt: String = _build_system_prompt()
	var context: String = _build_dialogue_context_for_reply(player_message)

	# Working memory — last 6 turns
	context += "\nConversation so far:\n"
	var window_start: int = maxi(history.size() - 6, 0)
	for i: int in range(window_start, history.size()):
		var msg: Dictionary = history[i]
		context += "%s: \"%s\"\n" % [msg["speaker"], msg["text"]]
	context += "\n%s just said: \"%s\"\n" % [PlayerProfile.player_name, player_message]
	context += "\nRespond naturally in character. 1-3 sentences. Continue the conversation based on what %s said." % PlayerProfile.player_name

	GeminiClient.generate(system_prompt, context, func(text: String, success: bool) -> void:
		if not is_instance_valid(npc):
			return
		if success and text != "":
			npc._add_memory_with_embedding(
				"Talked with %s at the %s. They said: \"%s\" and I replied: \"%s\"" % [
					PlayerProfile.player_name, npc._current_destination,
					player_message.left(40), text.left(40)],
				"dialogue", PlayerProfile.player_name,
				[npc.npc_name, PlayerProfile.player_name] as Array[String],
				npc._current_destination, npc._current_destination, 5.0, 0.3
			)
			# Content-aware impact analysis (replaces flat +1/+1 and player summary update)
			_analyze_player_conversation_impact(player_message, text)
			callback.call(text)
		else:
			callback.call(_get_template_response())
	)


func on_player_conversation_ended() -> void:
	## Called by dialogue_box.gd when the player closes the conversation.
	## Creates a summary memory of the entire conversation.
	if _player_conv_history.is_empty():
		return

	var history_copy: Array[Dictionary] = _player_conv_history.duplicate()
	_player_conv_history.clear()

	# Mark significant event for emotional decay
	last_significant_event_time = GameClock.total_minutes

	# Short conversation (4 or fewer turns): simple concatenation summary
	if history_copy.size() <= 4:
		var summary_parts: Array[String] = []
		for msg: Dictionary in history_copy:
			summary_parts.append("%s: \"%s\"" % [msg["speaker"], str(msg["text"]).left(50)])
		var summary: String = "Conversation with %s at the %s. %s" % [
			PlayerProfile.player_name, npc._current_destination,
			". ".join(summary_parts).left(200)]
		npc._add_memory_with_embedding(
			summary, "player_dialogue", PlayerProfile.player_name,
			[npc.npc_name, PlayerProfile.player_name] as Array[String],
			npc._current_destination, npc._current_destination, 8.0, 0.3
		)
		if OS.is_debug_build():
			print("[ConvSummary] %s: Short conversation summary stored" % npc.npc_name)
		return

	# Longer conversation: use Gemini Flash to summarize
	if not GeminiClient.has_api_key():
		npc._add_memory_with_embedding(
			"Had a long conversation with %s at the %s about various topics" % [
				PlayerProfile.player_name, npc._current_destination],
			"player_dialogue", PlayerProfile.player_name,
			[npc.npc_name, PlayerProfile.player_name] as Array[String],
			npc._current_destination, npc._current_destination, 8.0, 0.2
		)
		return

	_summarize_player_conversation(history_copy)


# --- Context builders ---

func _build_system_prompt() -> String:
	var prompt: String = "You are %s, a %d-year-old %s in the town of DeepTown. %s\n\nYour speech style: %s\n\n" % [
		npc.npc_name, npc.age, npc.job, npc.personality, npc.speech_style
	]

	# Core memory: emotional state
	var emotional_state: String = npc.memory.core_memory.get("emotional_state", "")
	if emotional_state != "":
		prompt += "Current mood: %s\n" % emotional_state

	# Core memory: what I know about the player
	var player_summary: String = npc.memory.core_memory.get("player_summary", "")
	if player_summary != "" and not player_summary.begins_with("I haven't met"):
		prompt += "What you know about %s: %s\n" % [PlayerProfile.player_name, player_summary]

	# Core memory: NPC relationship summaries
	var npc_summaries: Dictionary = npc.memory.core_memory.get("npc_summaries", {})
	for npc_n: String in npc_summaries:
		prompt += "About %s: %s\n" % [npc_n, npc_summaries[npc_n]]

	# Core memory: key facts
	var key_facts: Array = npc.memory.core_memory.get("key_facts", [])
	if not key_facts.is_empty():
		prompt += "Important things you know: %s\n" % ", ".join(key_facts)

	prompt += "\n"

	# Add top relationships to identity
	var friends: Array[String] = Relationships.get_closest_friends(npc.npc_name, 3)
	if not friends.is_empty():
		var rel_lines: Array[String] = []
		for friend: String in friends:
			var label: String = Relationships.get_opinion_label(npc.npc_name, friend)
			rel_lines.append("You %s %s" % [label, friend])
		prompt += "Key relationships: %s.\n\n" % ", ".join(rel_lines)

	prompt += "There is a newcomer in town named %s. They recently moved into House 11 on the south row. They seem curious about the town and its people.\n\n" % PlayerProfile.player_name
	prompt += "Rules:\n- Respond in character, first person, 1-3 sentences only\n- Never break character or mention being an AI\n- Let your personality shine through every word\n- Reference your memories naturally if relevant\n- Your mood and needs should affect how you talk\n- You can ask %s questions too — be curious about the newcomer\n- React to what they say, don't just give generic responses\n- If someone asks about past events, rely on your memories. If you don't remember, say so honestly — never make up events." % PlayerProfile.player_name
	return prompt


func format_memory_age(mem: Dictionary) -> String:
	## Returns human-readable age label for a memory.
	var mem_time: int = mem.get("timestamp", mem.get("game_time", 0))
	var minutes_ago: int = maxi(GameClock.total_minutes - mem_time, 0)
	var hours_ago: int = minutes_ago / 60
	var days_ago: int = minutes_ago / 1440
	if minutes_ago < 30:
		return "(just now)"
	elif hours_ago < 1:
		return "(%d min ago)" % minutes_ago
	elif hours_ago < 6:
		return "(%d hours ago)" % hours_ago
	elif days_ago < 1:
		return "(today)"
	elif days_ago < 2:
		return "(yesterday)"
	elif days_ago < 7:
		return "(%d days ago)" % days_ago
	else:
		return "(over a week ago)"


func _build_dialogue_context() -> String:
	var hour: int = GameClock.hour
	var period: String = "night"
	if hour >= 5 and hour < 8:
		period = "dawn"
	elif hour >= 8 and hour < 12:
		period = "morning"
	elif hour >= 12 and hour < 17:
		period = "afternoon"
	elif hour >= 17 and hour < 21:
		period = "evening"

	var mood: float = npc.get_mood()
	var mood_desc: String = "miserable" if mood < 20.0 else "unhappy" if mood < 40.0 else "okay" if mood < 60.0 else "good" if mood < 80.0 else "great"

	var activity_str: String = npc.current_activity if npc.current_activity != "" else "standing around"
	var context: String = "Current situation: It is %s (%s). You are at the %s. You are currently %s. Your mood is %s (%d/100).\n\n" % [
		GameClock.get_time_string(), period, npc._current_destination, activity_str, mood_desc, int(mood)
	]

	context += "Your needs:\n"
	context += "- Hunger: %d/100 %s\n" % [int(npc.hunger), "(starving!)" if npc.hunger < 20.0 else "(hungry)" if npc.hunger < 40.0 else "(fine)"]
	context += "- Energy: %d/100 %s\n" % [int(npc.energy), "(exhausted!)" if npc.energy < 20.0 else "(tired)" if npc.energy < 40.0 else "(fine)"]
	context += "- Social: %d/100 %s\n\n" % [int(npc.social), "(lonely)" if npc.social < 30.0 else "(could use company)" if npc.social < 50.0 else "(content)"]

	# Relationship with the player (per-dimension descriptions)
	var trust_label: String = Relationships.get_trust_label(npc.npc_name, PlayerProfile.player_name)
	var affec_label: String = Relationships.get_affection_label(npc.npc_name, PlayerProfile.player_name)
	var respe_label: String = Relationships.get_respect_label(npc.npc_name, PlayerProfile.player_name)
	context += "Your relationship with %s (the person you're talking to):\n" % PlayerProfile.player_name
	context += "- Trust: You %s them\n" % trust_label
	context += "- Affection: You %s them\n" % affec_label
	context += "- Respect: You %s them\n" % respe_label
	var player_core_summary: String = npc.memory.core_memory.get("player_summary", "")
	if player_core_summary != "":
		context += "- Your feelings: %s\n" % player_core_summary
	context += "\nRespond naturally based on these feelings. Low trust = guarded. High affection = warm. Negative respect = dismissive. Never mention numbers.\n\n"

	# Include nearby object states for richer context
	var building_objects: Array[Dictionary] = WorldObjects.get_objects_in_building(npc._current_destination)
	if not building_objects.is_empty():
		var active_objects: Array[String] = []
		for obj: Dictionary in building_objects:
			if obj["state"] != "idle":
				active_objects.append("the %s is %s" % [obj["tile_type"], obj["state"]])
		if not active_objects.is_empty():
			context += "Around you: %s.\n\n" % ", ".join(active_objects)

	# RETRIEVAL-BASED MEMORIES (replaces 4 separate get_by_type calls)
	var retrieval_query: String = "%s talking with %s at the %s" % [
		npc.npc_name, PlayerProfile.player_name, npc._current_destination]
	var retrieved: Array[Dictionary] = npc.memory.retrieve_by_query_text(
		retrieval_query, GameClock.total_minutes, 8)
	if not retrieved.is_empty():
		context += "Your relevant memories:\n"
		for mem: Dictionary in retrieved:
			var age_label: String = format_memory_age(mem)
			var mem_type: String = mem.get("type", "")
			var prefix: String = ""
			if mem_type == "reflection":
				prefix = "[Thought] "
			elif mem_type == "gossip":
				prefix = "[Heard] "
			elif mem_type == "environment":
				prefix = "[Noticed] "
			elif mem_type == "episode_summary" or mem_type == "period_summary":
				prefix = "[Summary] "
			context += "- %s%s %s\n" % [prefix, mem.get("text", mem.get("description", "")), age_label]
		context += "\n"

	# Specifically surface gossip about the player
	var player_gossip: Array[Dictionary] = []
	for g: Dictionary in npc.memory.get_by_type("gossip"):
		if g.get("actor", "") == PlayerProfile.player_name:
			player_gossip.append(g)
	if not player_gossip.is_empty():
		player_gossip.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "You've heard things about this person from others:\n"
		for pg: Dictionary in player_gossip.slice(0, mini(3, player_gossip.size())):
			context += "- %s\n" % pg.get("description", "")
		context += "\n"

	# Today's plans
	var upcoming_plans: Array[String] = []
	for plan: Dictionary in npc.planner._plan_level1:
		if GameClock.hour < plan["end_hour"]:
			upcoming_plans.append("%d:00-%d:00 — %s at the %s" % [plan["start_hour"], plan["end_hour"], plan["activity"], plan["location"]])
	if not upcoming_plans.is_empty():
		context += "Your plans for today:\n"
		for p: String in upcoming_plans:
			context += "- %s\n" % p
		context += "\n"

	context += "%s is standing in front of you and wants to talk. They recently moved to DeepTown and live in House 11. Respond naturally." % PlayerProfile.player_name
	return context


func _build_dialogue_context_for_reply(player_message: String) -> String:
	## Builds dialogue context using the player's message as the retrieval query.
	## Called during multi-turn conversation replies for targeted memory recall.
	var hour: int = GameClock.hour
	var period: String = "night"
	if hour >= 5 and hour < 8:
		period = "dawn"
	elif hour >= 8 and hour < 12:
		period = "morning"
	elif hour >= 12 and hour < 17:
		period = "afternoon"
	elif hour >= 17 and hour < 21:
		period = "evening"

	var mood: float = npc.get_mood()
	var mood_desc: String = "miserable" if mood < 20.0 else "unhappy" if mood < 40.0 else "okay" if mood < 60.0 else "good" if mood < 80.0 else "great"

	var activity_str: String = npc.current_activity if npc.current_activity != "" else "standing around"
	var context: String = "Current situation: It is %s (%s). You are at the %s. You are currently %s. Your mood is %s (%d/100).\n\n" % [
		GameClock.get_time_string(), period, npc._current_destination, activity_str, mood_desc, int(mood)
	]

	context += "Your needs:\n"
	context += "- Hunger: %d/100 %s\n" % [int(npc.hunger), "(starving!)" if npc.hunger < 20.0 else "(hungry)" if npc.hunger < 40.0 else "(fine)"]
	context += "- Energy: %d/100 %s\n" % [int(npc.energy), "(exhausted!)" if npc.energy < 20.0 else "(tired)" if npc.energy < 40.0 else "(fine)"]
	context += "- Social: %d/100 %s\n\n" % [int(npc.social), "(lonely)" if npc.social < 30.0 else "(could use company)" if npc.social < 50.0 else "(content)"]

	# Relationship with the player (per-dimension descriptions)
	var trust_label: String = Relationships.get_trust_label(npc.npc_name, PlayerProfile.player_name)
	var affec_label: String = Relationships.get_affection_label(npc.npc_name, PlayerProfile.player_name)
	var respe_label: String = Relationships.get_respect_label(npc.npc_name, PlayerProfile.player_name)
	context += "Your relationship with %s (the person you're talking to):\n" % PlayerProfile.player_name
	context += "- Trust: You %s them\n" % trust_label
	context += "- Affection: You %s them\n" % affec_label
	context += "- Respect: You %s them\n" % respe_label
	var player_core_summary: String = npc.memory.core_memory.get("player_summary", "")
	if player_core_summary != "":
		context += "- Your feelings: %s\n" % player_core_summary
	context += "\nRespond naturally based on these feelings. Low trust = guarded. High affection = warm. Negative respect = dismissive. Never mention numbers.\n\n"

	# Nearby object states
	var building_objects: Array[Dictionary] = WorldObjects.get_objects_in_building(npc._current_destination)
	if not building_objects.is_empty():
		var active_objects: Array[String] = []
		for obj: Dictionary in building_objects:
			if obj["state"] != "idle":
				active_objects.append("the %s is %s" % [obj["tile_type"], obj["state"]])
		if not active_objects.is_empty():
			context += "Around you: %s.\n\n" % ", ".join(active_objects)

	# TARGETED RETRIEVAL using player's actual message
	var retrieved: Array[Dictionary] = npc.memory.retrieve_by_query_text(
		player_message, GameClock.total_minutes, 8)
	if not retrieved.is_empty():
		context += "Your relevant memories:\n"
		for mem: Dictionary in retrieved:
			var age_label: String = format_memory_age(mem)
			var mem_type: String = mem.get("type", "")
			var prefix: String = ""
			if mem_type == "reflection":
				prefix = "[Thought] "
			elif mem_type == "gossip":
				prefix = "[Heard] "
			elif mem_type == "environment":
				prefix = "[Noticed] "
			elif mem_type == "episode_summary" or mem_type == "period_summary":
				prefix = "[Summary] "
			context += "- %s%s %s\n" % [prefix, mem.get("text", mem.get("description", "")), age_label]
		context += "\n"

	# Specifically surface gossip about the player
	var player_gossip: Array[Dictionary] = []
	for g: Dictionary in npc.memory.get_by_type("gossip"):
		if g.get("actor", "") == PlayerProfile.player_name:
			player_gossip.append(g)
	if not player_gossip.is_empty():
		player_gossip.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.get("game_time", 0) > b.get("game_time", 0)
		)
		context += "You've heard things about this person from others:\n"
		for pg: Dictionary in player_gossip.slice(0, mini(3, player_gossip.size())):
			context += "- %s\n" % pg.get("description", "")
		context += "\n"

	# Today's plans
	var upcoming_plans: Array[String] = []
	for plan: Dictionary in npc.planner._plan_level1:
		if GameClock.hour < plan["end_hour"]:
			upcoming_plans.append("%d:00-%d:00 — %s at the %s" % [plan["start_hour"], plan["end_hour"], plan["activity"], plan["location"]])
	if not upcoming_plans.is_empty():
		context += "Your plans for today:\n"
		for p: String in upcoming_plans:
			context += "- %s\n" % p
		context += "\n"

	context += "%s is talking to you right now." % PlayerProfile.player_name
	return context


# --- Impact analysis ---

func _analyze_player_conversation_impact(player_text: String, npc_response: String) -> void:
	## Analyze conversation content to determine relationship impact via Flash Lite.
	## Replaces flat +1/+1 with content-aware trust/affection/respect changes.
	## Also updates core memory: emotional_state, player_summary, key_facts.
	if not GeminiClient.has_api_key():
		Relationships.modify(npc.npc_name, PlayerProfile.player_name, 1, 1, 0)
		return

	var rel: Dictionary = Relationships.get_relationship(npc.npc_name, PlayerProfile.player_name)
	var old_summary: String = npc.memory.core_memory.get("player_summary", "")
	var identity_text: String = npc.memory.core_memory.get("identity", npc.personality)
	var summary_or_default: String = old_summary if old_summary != "" else "No prior impression"

	var prompt: String = "You are analyzing a conversation between %s and %s in a small fantasy town.\n\n%s's personality: %s\n%s's current feelings about %s: %s\nCurrent relationship — Trust: %d, Affection: %d, Respect: %d\n\nThe conversation:\n%s said: \"%s\"\n%s replied: \"%s\"\n\nBased on what %s said, how should %s's feelings change?\n\nRespond ONLY with this exact JSON, no other text:\n{\"trust_change\": 0, \"affection_change\": 0, \"respect_change\": 0, \"emotional_state\": \"how %s feels now\", \"player_summary_update\": \"updated 1-2 sentence summary of what %s thinks about %s\", \"key_fact\": \"new fact learned, or empty string\"}\n\nScoring rules:\n- Values between -5 and +5\n- 0 = neutral small talk\n- +1 to +2 = friendly, positive, helpful\n- +3 to +5 = deeply meaningful, vulnerable, generous\n- -1 to -2 = rude, dismissive\n- -3 to -5 = threatening, insulting, betrayal\n- Trust: honesty/promises (+) vs lying/sketchy (-)\n- Affection: warmth/humor/compliments (+) vs coldness/insults (-)\n- Respect: competence/bravery/wisdom (+) vs cowardice/disrespect (-)" % [
		npc.npc_name, PlayerProfile.player_name,
		npc.npc_name, identity_text.left(150),
		npc.npc_name, PlayerProfile.player_name, summary_or_default,
		rel["trust"], rel["affection"], rel["respect"],
		PlayerProfile.player_name, player_text.left(200),
		npc.npc_name, npc_response.left(200),
		PlayerProfile.player_name, npc.npc_name,
		npc.npc_name, npc.npc_name, PlayerProfile.player_name
	]

	GeminiClient.generate(
		"You analyze conversation impact on relationships. Return ONLY valid JSON.",
		prompt,
		func(text: String, success: bool) -> void:
			if not is_instance_valid(npc):
				return
			if not success or text == "":
				Relationships.modify(npc.npc_name, PlayerProfile.player_name, 1, 1, 0)
				return
			_apply_player_impact(text),
		GeminiClient.MODEL_LITE
	)


func _apply_player_impact(raw_json: String) -> void:
	## Parse and apply the impact analysis from Flash Lite.
	var data: Variant = GeminiClient.parse_json_response(raw_json)
	if data == null or not data is Dictionary:
		Relationships.modify(npc.npc_name, PlayerProfile.player_name, 1, 1, 0)
		return

	var trust_d: int = clampi(int(data.get("trust_change", 0)), -5, 5)
	var affec_d: int = clampi(int(data.get("affection_change", 0)), -5, 5)
	var respe_d: int = clampi(int(data.get("respect_change", 0)), -5, 5)

	if trust_d != 0 or affec_d != 0 or respe_d != 0:
		Relationships.modify(npc.npc_name, PlayerProfile.player_name, trust_d, affec_d, respe_d)
	else:
		# Pure small talk — tiny trust bump for showing up
		Relationships.modify(npc.npc_name, PlayerProfile.player_name, 1, 0, 0)

	# Mark significant event for emotional decay tracking
	last_significant_event_time = GameClock.total_minutes

	# Update core memory
	var new_emotion: String = data.get("emotional_state", "")
	if new_emotion != "":
		npc.memory.update_emotional_state(new_emotion.left(150))

	var new_summary: String = data.get("player_summary_update", "")
	if new_summary != "":
		npc.memory.update_player_summary(new_summary.left(200))

	var new_fact: String = data.get("key_fact", "")
	if new_fact != "" and new_fact.length() > 3:
		npc.memory.add_key_fact(new_fact.left(100))

	# Update emotional valence on the most recent player dialogue memory
	var total: int = trust_d + affec_d + respe_d
	var recent_mems: Array = npc.memory.memories
	for i: int in range(recent_mems.size() - 1, maxi(recent_mems.size() - 3, -1), -1):
		if recent_mems[i].get("type", "") == "dialogue" and PlayerProfile.player_name in recent_mems[i].get("entities", []):
			recent_mems[i]["emotional_valence"] = clampf(float(total) / 10.0, -1.0, 1.0)
			break

	if OS.is_debug_build():
		print("[Impact] %s→%s: T:%+d A:%+d R:%+d" % [npc.npc_name, PlayerProfile.player_name, trust_d, affec_d, respe_d])


# --- Conversation summary ---

func _summarize_player_conversation(history: Array[Dictionary]) -> void:
	## Use Gemini Flash to create a dense summary of a player conversation.
	var transcript: String = ""
	for msg: Dictionary in history:
		transcript += "%s: \"%s\"\n" % [msg["speaker"], str(msg["text"]).left(80)]

	var prompt: String = "Summarize this conversation between %s and %s in 2-3 sentences from %s's perspective (first person).\nFocus on: what was discussed, any promises made, emotional tone, anything important learned.\n\nConversation:\n%s\nWrite ONLY the summary, nothing else." % [
		npc.npc_name, PlayerProfile.player_name, npc.npc_name, transcript]

	GeminiClient.generate(
		"You summarize conversations for %s. Write in first person as %s." % [npc.npc_name, npc.npc_name],
		prompt,
		func(text: String, success: bool) -> void:
			if not is_instance_valid(npc):
				return
			var summary: String
			if success and text != "":
				summary = text.strip_edges().left(300)
			else:
				summary = "Had a conversation with %s at the %s" % [
					PlayerProfile.player_name, npc._current_destination]

			npc._add_memory_with_embedding(
				summary, "player_dialogue", PlayerProfile.player_name,
				[npc.npc_name, PlayerProfile.player_name] as Array[String],
				npc._current_destination, npc._current_destination, 8.0, 0.3
			)
			if OS.is_debug_build():
				print("[ConvSummary] %s: \"%s\"" % [npc.npc_name, summary.left(100)])
	)


# --- Template fallback ---

func _get_template_response() -> String:
	## Fallback template responses when LLM is unavailable.
	if npc.energy < 20.0:
		return "*yawns* I'm exhausted... heading home to rest."
	if npc.hunger < 20.0:
		return "I'm starving, need to go eat."

	# Activity-aware response (50% chance when doing something specific)
	if npc.current_activity != "" and not npc.current_activity.begins_with("standing") and not npc.current_activity.begins_with("at the"):
		var activity_responses: Array[String] = [
			"Can't you see I'm %s? But sure, what do you need?" % npc.current_activity,
			"Oh, hello! Just %s here. What brings you by?" % npc.current_activity,
			"Ah, a visitor! I was just %s." % npc.current_activity,
		]
		if randf() < 0.5:
			return activity_responses[randi() % activity_responses.size()]

	var player_memories: Array[Dictionary] = npc.memory.get_memories_about(PlayerProfile.player_name)
	if player_memories.is_empty():
		player_memories = npc.memory.get_memories_about("Player")  # backward compat
	if not player_memories.is_empty():
		var latest: Dictionary = player_memories[-1]
		var location: String = latest.get("observed_near", latest.get("observer_location", "town"))
		var hours_ago: int = (GameClock.total_minutes - latest.get("game_time", 0)) / 60
		if hours_ago < 1:
			return "Oh, I just saw you over by the %s! What brings you here?" % location
		elif hours_ago < 12:
			return "I saw you near the %s earlier today. How's your day going?" % location
		else:
			return "I remember seeing you around the %s a while back." % location

	var mood: float = npc.get_mood()
	if mood > 70.0:
		return "Beautiful day, isn't it? Work at the %s is going well." % npc.workplace_building
	elif mood > 40.0:
		return "Just another day at the %s." % npc.workplace_building
	else:
		return "I'm not feeling great today..."
