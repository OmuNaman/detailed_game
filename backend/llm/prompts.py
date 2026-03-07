"""Prompt templates — faithful port of GDScript dialogue/conversation prompts.

Each function matches its GDScript counterpart exactly in structure and phrasing.
"""

from __future__ import annotations

from backend.models.conversation import (
    BuildingObject,
    NPCChatRequest,
    PlanEntry,
    PlayerChatReplyRequest,
    PlayerChatRequest,
    PlayerImpactRequest,
    RelationshipData,
)
from backend.models.npc import NPCState


# --- Helper ---

def _get_period(hour: int) -> str:
    """Map hour to time-of-day label (matches npc_dialogue.gd)."""
    if 5 <= hour < 8:
        return "dawn"
    if 8 <= hour < 12:
        return "morning"
    if 12 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 21:
        return "evening"
    return "night"


def _mood_desc(mood: float) -> str:
    if mood < 20:
        return "miserable"
    if mood < 40:
        return "unhappy"
    if mood < 60:
        return "okay"
    if mood < 80:
        return "good"
    return "great"


def _need_tag(value: float, low_label: str, mid_label: str, threshold_low: float = 20.0, threshold_mid: float = 40.0) -> str:
    if value < threshold_low:
        return f"({low_label})"
    if value < threshold_mid:
        return f"({mid_label})"
    return "(fine)"


def _format_memory_age(mem: dict, current_game_time: int) -> str:
    """Human-readable age label (matches npc_dialogue.gd format_memory_age)."""
    mem_time = mem.get("timestamp", mem.get("game_time", 0))
    minutes_ago = max(current_game_time - mem_time, 0)
    hours_ago = minutes_ago // 60
    days_ago = minutes_ago // 1440
    if minutes_ago < 30:
        return "(just now)"
    if hours_ago < 1:
        return f"({minutes_ago} min ago)"
    if hours_ago < 6:
        return f"({hours_ago} hours ago)"
    if days_ago < 1:
        return "(today)"
    if days_ago < 2:
        return "(yesterday)"
    if days_ago < 7:
        return f"({days_ago} days ago)"
    return "(over a week ago)"


def _memory_prefix(mem_type: str) -> str:
    prefixes = {
        "reflection": "[Thought] ",
        "gossip": "[Heard] ",
        "environment": "[Noticed] ",
        "episode_summary": "[Summary] ",
        "period_summary": "[Summary] ",
    }
    return prefixes.get(mem_type, "")


# --- Player dialogue prompts (from npc_dialogue.gd) ---

def build_system_prompt(
    npc: NPCState,
    player_name: str,
    core_memory: dict,
    closest_friends: list[dict],
) -> str:
    """Port of npc_dialogue.gd _build_system_prompt()."""
    prompt = (
        f"You are {npc.npc_name}, a {npc.age}-year-old {npc.job} "
        f"in the town of DeepTown. {npc.personality}\n\n"
        f"Your speech style: {npc.speech_style}\n\n"
    )

    emotional_state = core_memory.get("emotional_state", "")
    if emotional_state:
        prompt += f"Current mood: {emotional_state}\n"

    player_summary = core_memory.get("player_summary", "")
    if player_summary and not player_summary.startswith("I haven't met"):
        prompt += f"What you know about {player_name}: {player_summary}\n"

    npc_summaries = core_memory.get("npc_summaries", {})
    for npc_n, summary in npc_summaries.items():
        prompt += f"About {npc_n}: {summary}\n"

    key_facts = core_memory.get("key_facts", [])
    if key_facts:
        prompt += f"Important things you know: {', '.join(key_facts)}\n"

    prompt += "\n"

    if closest_friends:
        rel_lines = [f"You {f['label']} {f['name']}" for f in closest_friends]
        prompt += f"Key relationships: {', '.join(rel_lines)}.\n\n"

    prompt += (
        f"There is a newcomer in town named {player_name}. "
        "They recently moved into House 11 on the south row. "
        "They seem curious about the town and its people.\n\n"
    )

    prompt += (
        "Rules:\n"
        "- Respond in character, first person, 1-3 sentences only\n"
        "- Never break character or mention being an AI\n"
        "- Let your personality shine through every word\n"
        "- Reference your memories naturally if relevant\n"
        "- Your mood and needs should affect how you talk\n"
        f"- You can ask {player_name} questions too — be curious about the newcomer\n"
        "- React to what they say, don't just give generic responses\n"
        "- If someone asks about past events, rely on your memories. "
        "If you don't remember, say so honestly — never make up events."
    )
    return prompt


def build_dialogue_context(
    req: PlayerChatRequest,
    core_memory: dict,
    retrieved_memories: list[dict],
    gossip_about_player: list[dict],
) -> str:
    """Port of npc_dialogue.gd _build_dialogue_context()."""
    npc = req.npc_state
    period = _get_period(req.game_time.hour)
    mood = (npc.needs.hunger + npc.needs.energy + npc.needs.social) / 3.0
    mood_d = _mood_desc(mood)
    activity_str = npc.current_activity or "standing around"
    time_str = req.time_string or f"{req.game_time.hour}:00"

    ctx = (
        f"Current situation: It is {time_str} ({period}). "
        f"You are at the {npc.current_destination}. "
        f"You are currently {activity_str}. "
        f"Your mood is {mood_d} ({int(mood)}/100).\n\n"
    )

    # Needs
    ctx += "Your needs:\n"
    ctx += f"- Hunger: {int(npc.needs.hunger)}/100 {_need_tag(npc.needs.hunger, 'starving!', 'hungry')}\n"
    ctx += f"- Energy: {int(npc.needs.energy)}/100 {_need_tag(npc.needs.energy, 'exhausted!', 'tired')}\n"
    ctx += f"- Social: {int(npc.needs.social)}/100 {_need_tag(npc.needs.social, 'lonely', 'could use company', 30.0, 50.0)}\n\n"

    # Relationship
    rel = req.relationship
    ctx += f"Your relationship with {req.player_name} (the person you're talking to):\n"
    ctx += f"- Trust: You {rel.trust_label} them\n"
    ctx += f"- Affection: You {rel.affection_label} them\n"
    ctx += f"- Respect: You {rel.respect_label} them\n"
    player_core_summary = core_memory.get("player_summary", "")
    if player_core_summary:
        ctx += f"- Your feelings: {player_core_summary}\n"
    ctx += (
        "\nRespond naturally based on these feelings. "
        "Low trust = guarded. High affection = warm. "
        "Negative respect = dismissive. Never mention numbers.\n\n"
    )

    # Building objects
    active_objects = [
        f"the {o.tile_type} is {o.state}"
        for o in req.building_objects
        if o.state != "idle"
    ]
    if active_objects:
        ctx += f"Around you: {', '.join(active_objects)}.\n\n"

    # Retrieved memories
    if retrieved_memories:
        ctx += "Your relevant memories:\n"
        for mem in retrieved_memories:
            age_label = _format_memory_age(mem, req.game_time.total_minutes)
            prefix = _memory_prefix(mem.get("type", ""))
            text = mem.get("text", mem.get("description", ""))
            ctx += f"- {prefix}{text} {age_label}\n"
        ctx += "\n"

    # Gossip about player
    if gossip_about_player:
        ctx += "You've heard things about this person from others:\n"
        for pg in gossip_about_player[:3]:
            ctx += f"- {pg.get('description', pg.get('text', ''))}\n"
        ctx += "\n"

    # Plans
    upcoming = [
        p for p in req.plans
        if req.game_time.hour < p.end_hour
    ]
    if upcoming:
        ctx += "Your plans for today:\n"
        for p in upcoming:
            ctx += f"- {p.start_hour}:00-{p.end_hour}:00 — {p.activity} at the {p.location}\n"
        ctx += "\n"

    # Schedule pressure
    if req.schedule_destination and req.schedule_destination != npc.current_destination:
        ctx += (
            f"Note: You should be heading to the {req.schedule_destination} soon, "
            f"but you're talking to {req.player_name}. "
            "You might mention needing to leave if the conversation drags on.\n\n"
        )

    ctx += (
        f"{req.player_name} is standing in front of you and wants to talk. "
        "They recently moved to DeepTown and live in House 11. Respond naturally."
    )
    return ctx


def build_reply_context(
    req: PlayerChatReplyRequest,
    core_memory: dict,
    retrieved_memories: list[dict],
    gossip_about_player: list[dict],
) -> str:
    """Port of npc_dialogue.gd _build_dialogue_context_for_reply()."""
    npc = req.npc_state
    period = _get_period(req.game_time.hour)
    mood = (npc.needs.hunger + npc.needs.energy + npc.needs.social) / 3.0
    mood_d = _mood_desc(mood)
    activity_str = npc.current_activity or "standing around"
    time_str = req.time_string or f"{req.game_time.hour}:00"

    ctx = (
        f"Current situation: It is {time_str} ({period}). "
        f"You are at the {npc.current_destination}. "
        f"You are currently {activity_str}. "
        f"Your mood is {mood_d} ({int(mood)}/100).\n\n"
    )

    # Needs
    ctx += "Your needs:\n"
    ctx += f"- Hunger: {int(npc.needs.hunger)}/100 {_need_tag(npc.needs.hunger, 'starving!', 'hungry')}\n"
    ctx += f"- Energy: {int(npc.needs.energy)}/100 {_need_tag(npc.needs.energy, 'exhausted!', 'tired')}\n"
    ctx += f"- Social: {int(npc.needs.social)}/100 {_need_tag(npc.needs.social, 'lonely', 'could use company', 30.0, 50.0)}\n\n"

    # Relationship
    rel = req.relationship
    ctx += f"Your relationship with {req.player_name} (the person you're talking to):\n"
    ctx += f"- Trust: You {rel.trust_label} them\n"
    ctx += f"- Affection: You {rel.affection_label} them\n"
    ctx += f"- Respect: You {rel.respect_label} them\n"
    player_core_summary = core_memory.get("player_summary", "")
    if player_core_summary:
        ctx += f"- Your feelings: {player_core_summary}\n"
    ctx += (
        "\nRespond naturally based on these feelings. "
        "Low trust = guarded. High affection = warm. "
        "Negative respect = dismissive. Never mention numbers.\n\n"
    )

    # Building objects
    active_objects = [
        f"the {o.tile_type} is {o.state}"
        for o in req.building_objects
        if o.state != "idle"
    ]
    if active_objects:
        ctx += f"Around you: {', '.join(active_objects)}.\n\n"

    # Retrieved memories (using player_message as query)
    if retrieved_memories:
        ctx += "Your relevant memories:\n"
        for mem in retrieved_memories:
            age_label = _format_memory_age(mem, req.game_time.total_minutes)
            prefix = _memory_prefix(mem.get("type", ""))
            text = mem.get("text", mem.get("description", ""))
            ctx += f"- {prefix}{text} {age_label}\n"
        ctx += "\n"

    # Gossip about player
    if gossip_about_player:
        ctx += "You've heard things about this person from others:\n"
        for pg in gossip_about_player[:3]:
            ctx += f"- {pg.get('description', pg.get('text', ''))}\n"
        ctx += "\n"

    # Plans
    upcoming = [
        p for p in req.plans
        if req.game_time.hour < p.end_hour
    ]
    if upcoming:
        ctx += "Your plans for today:\n"
        for p in upcoming:
            ctx += f"- {p.start_hour}:00-{p.end_hour}:00 — {p.activity} at the {p.location}\n"
        ctx += "\n"

    # Schedule pressure
    if req.schedule_destination and req.schedule_destination != npc.current_destination:
        ctx += (
            f"Note: You should be heading to the {req.schedule_destination} soon, "
            f"but you're talking to {req.player_name}. "
            "You might mention needing to leave if the conversation drags on.\n\n"
        )

    ctx += f"{req.player_name} is talking to you right now."
    return ctx


def build_reply_with_history(
    req: PlayerChatReplyRequest,
    core_memory: dict,
    retrieved_memories: list[dict],
    gossip_about_player: list[dict],
) -> str:
    """Build full reply context including conversation history window.

    Matches npc_dialogue.gd get_conversation_reply_async() context assembly.
    """
    ctx = build_reply_context(req, core_memory, retrieved_memories, gossip_about_player)

    # Working memory — last 6 turns
    ctx += "\nConversation so far:\n"
    window_start = max(len(req.history) - 6, 0)
    for msg in req.history[window_start:]:
        ctx += f'{msg.speaker}: "{msg.text}"\n'
    ctx += f'\n{req.player_name} just said: "{req.player_message}"\n'
    ctx += (
        f"\nRespond naturally in character. 1-3 sentences. "
        f"Continue the conversation based on what {req.player_name} said."
    )
    return ctx


# --- Impact analysis prompts ---

def build_player_impact_prompt(req: PlayerImpactRequest) -> str:
    """Port of npc_dialogue.gd _analyze_player_conversation_impact() prompt."""
    npc = req.npc_state
    rel = req.relationship
    identity_text = npc.personality[:150]
    # Core memory player_summary is fetched server-side
    old_summary = "No prior impression"  # will be overridden if available

    return (
        f"You are analyzing a conversation between {req.npc_name} and "
        f"{req.player_name} in a small fantasy town.\n\n"
        f"{req.npc_name}'s personality: {identity_text}\n"
        f"{req.npc_name}'s current feelings about {req.player_name}: {old_summary}\n"
        f"Current relationship — Trust: {rel.trust}, Affection: {rel.affection}, "
        f"Respect: {rel.respect}\n\n"
        f"The conversation:\n"
        f'{req.player_name} said: "{req.player_message[:200]}"\n'
        f'{req.npc_name} replied: "{req.npc_response[:200]}"\n\n'
        f"Based on what {req.player_name} said, how should "
        f"{req.npc_name}'s feelings change?\n\n"
        "Respond ONLY with this exact JSON, no other text:\n"
        '{"trust_change": 0, "affection_change": 0, "respect_change": 0, '
        f'"emotional_state": "how {req.npc_name} feels now", '
        f'"player_summary_update": "updated 1-2 sentence summary of what '
        f'{req.npc_name} thinks about {req.player_name}", '
        '"key_fact": "new fact learned, or empty string"}\n\n'
        "Scoring rules:\n"
        "- Values between -5 and +5\n"
        "- 0 = neutral small talk\n"
        "- +1 to +2 = friendly, positive, helpful\n"
        "- +3 to +5 = deeply meaningful, vulnerable, generous\n"
        "- -1 to -2 = rude, dismissive\n"
        "- -3 to -5 = threatening, insulting, betrayal\n"
        "- Trust: honesty/promises (+) vs lying/sketchy (-)\n"
        "- Affection: warmth/humor/compliments (+) vs coldness/insults (-)\n"
        "- Respect: competence/bravery/wisdom (+) vs cowardice/disrespect (-)"
    )


def build_player_impact_prompt_with_summary(
    req: PlayerImpactRequest,
    old_summary: str,
) -> str:
    """Same as build_player_impact_prompt but with actual core memory summary."""
    npc = req.npc_state
    rel = req.relationship
    identity_text = npc.personality[:150]
    summary_or_default = old_summary if old_summary else "No prior impression"

    return (
        f"You are analyzing a conversation between {req.npc_name} and "
        f"{req.player_name} in a small fantasy town.\n\n"
        f"{req.npc_name}'s personality: {identity_text}\n"
        f"{req.npc_name}'s current feelings about {req.player_name}: "
        f"{summary_or_default}\n"
        f"Current relationship — Trust: {rel.trust}, Affection: {rel.affection}, "
        f"Respect: {rel.respect}\n\n"
        f"The conversation:\n"
        f'{req.player_name} said: "{req.player_message[:200]}"\n'
        f'{req.npc_name} replied: "{req.npc_response[:200]}"\n\n'
        f"Based on what {req.player_name} said, how should "
        f"{req.npc_name}'s feelings change?\n\n"
        "Respond ONLY with this exact JSON, no other text:\n"
        '{"trust_change": 0, "affection_change": 0, "respect_change": 0, '
        f'"emotional_state": "how {req.npc_name} feels now", '
        f'"player_summary_update": "updated 1-2 sentence summary of what '
        f'{req.npc_name} thinks about {req.player_name}", '
        '"key_fact": "new fact learned, or empty string"}\n\n'
        "Scoring rules:\n"
        "- Values between -5 and +5\n"
        "- 0 = neutral small talk\n"
        "- +1 to +2 = friendly, positive, helpful\n"
        "- +3 to +5 = deeply meaningful, vulnerable, generous\n"
        "- -1 to -2 = rude, dismissive\n"
        "- -3 to -5 = threatening, insulting, betrayal\n"
        "- Trust: honesty/promises (+) vs lying/sketchy (-)\n"
        "- Affection: warmth/humor/compliments (+) vs coldness/insults (-)\n"
        "- Respect: competence/bravery/wisdom (+) vs cowardice/disrespect (-)"
    )


def build_conversation_summary_prompt(
    npc_name: str,
    player_name: str,
    history: list[dict],
) -> tuple[str, str]:
    """Port of npc_dialogue.gd _summarize_player_conversation(). Returns (system, user)."""
    transcript = ""
    for msg in history:
        text = str(msg.get("text", ""))[:80]
        transcript += f'{msg.get("speaker", "")}: "{text}"\n'

    system = (
        f"You summarize conversations for {npc_name}. "
        f"Write in first person as {npc_name}."
    )
    user = (
        f"Summarize this conversation between {npc_name} and {player_name} "
        f"in 2-3 sentences from {npc_name}'s perspective (first person).\n"
        "Focus on: what was discussed, any promises made, emotional tone, "
        "anything important learned.\n\n"
        f"Conversation:\n{transcript}\n"
        "Write ONLY the summary, nothing else."
    )
    return system, user


# --- NPC-to-NPC prompts (from npc_conversation.gd) ---

def build_npc_chat_system_prompt(npc: NPCState) -> str:
    """Port of npc_conversation.gd _build_npc_chat_system_prompt()."""
    return (
        f"You are {npc.npc_name}, age {npc.age}, {npc.job} in DeepTown. "
        f"{npc.personality}\n"
        f"Speech style: {npc.speech_style}\n\n"
        "Rules:\n"
        "- Say ONE sentence only, in character, first person\n"
        "- This is casual chat with a fellow townsperson, not a formal speech\n"
        "- Be natural — greetings, complaints, observations, jokes, gossip\n"
        "- Reference your current mood or needs if relevant\n"
        "- NEVER break character or mention being an AI"
    )


def build_npc_chat_context_for_turn(
    req: NPCChatRequest,
    core_memory: dict,
    retrieved_memories: list[dict],
) -> str:
    """Port of npc_conversation.gd _build_npc_chat_context_for_turn()."""
    speaker = req.speaker_state
    listener = req.listener_state
    period = _get_period(req.game_time.hour)
    rel = req.relationship

    ctx = f"It's {period} at the {speaker.current_destination}. "

    if speaker.current_activity and not speaker.current_activity.startswith("talking with"):
        ctx += f"You were {speaker.current_activity} before this conversation. "
    if listener.current_activity and not listener.current_activity.startswith("talking with"):
        ctx += f"{req.listener_name} was {listener.current_activity}. "

    ctx += (
        f"You {rel.trust_label} {req.listener_name}, "
        f"{rel.affection_label} them, and {rel.respect_label} them. "
    )

    # NPC summary for partner
    npc_summaries = core_memory.get("npc_summaries", {})
    partner_summary = npc_summaries.get(req.listener_name, "")
    if partner_summary:
        ctx += f"What you know about {req.listener_name}: {partner_summary} "

    # Retrieved memories
    if retrieved_memories:
        ctx += "Relevant memories: "
        for mem in retrieved_memories:
            text = mem.get("text", mem.get("description", ""))
            age_label = _format_memory_age(mem, req.game_time.total_minutes)
            ctx += f"{text} {age_label}. "

    # History
    if req.history:
        history_text = ""
        for msg in req.history:
            history_text += f'{msg.speaker}: "{msg.text}"\n'
        ctx += f"\n\nConversation so far:\n{history_text}"

    # Instruction
    if req.turn == 0:
        ctx += (
            f"\nYou're chatting with {req.listener_name} about {req.topic}. "
            "Say ONE line (max 1-2 sentences)."
        )
    else:
        ctx += (
            f"\nContinue the conversation with {req.listener_name}. "
            "Say ONE line (max 1-2 sentences). "
            "If the conversation has reached a natural end, you can say goodbye."
        )

    return ctx


def build_npc_impact_prompt(
    speaker_name: str,
    listener_name: str,
    speaker_line: str,
    listener_line: str,
    relationship: dict,
) -> str:
    """Port of npc_conversation.gd _analyze_npc_conversation_impact() prompt."""
    return (
        f"Conversation between {speaker_name} and {listener_name}:\n"
        f'{speaker_name}: "{speaker_line[:120]}"\n'
        f'{listener_name}: "{listener_line[:120]}"\n\n'
        f"Current relationship: Trust:{relationship.get('trust', 0)} "
        f"Affection:{relationship.get('affection', 0)} "
        f"Respect:{relationship.get('respect', 0)}\n\n"
        "For EACH person, rate how feelings change. JSON only:\n"
        '{"a_to_b": {"trust": 0, "affection": 0, "respect": 0}, '
        '"b_to_a": {"trust": 0, "affection": 0, "respect": 0}}\n'
        "Values -3 to +3. 0 for casual chat."
    )


def build_npc_summary_update_prompt(
    npc_name: str,
    other_name: str,
    my_line: str,
    their_line: str,
    old_summary: str,
) -> tuple[str, str]:
    """Port of npc_conversation.gd _update_npc_summary_async(). Returns (system, user)."""
    system = (
        f"You are {npc_name}. Write a brief 1-2 sentence impression of {other_name}."
    )
    user = (
        f'{npc_name} had this exchange with {other_name}: '
        f'"{my_line[:100]}" / "{their_line[:100]}"\n'
        f'Previous impression of {other_name}: "{old_summary}"\n'
        "Write a 1-2 sentence updated impression:"
    )
    return system, user
