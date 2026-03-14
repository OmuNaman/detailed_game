"""Chat endpoints — player dialogue, NPC-NPC conversation, impact analysis."""

from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel

from backend.llm import client as llm_client
from backend.llm.prompts import (
    build_conversation_summary_prompt,
    build_dialogue_context,
    build_npc_chat_context_for_turn,
    build_npc_chat_system_prompt,
    build_npc_impact_prompt,
    build_npc_summary_update_prompt,
    build_player_impact_prompt_with_summary,
    build_reply_with_history,
    build_system_prompt,
)
from backend.memory import chroma_store
from backend.memory.scoring import compute_stability
from backend.models.conversation import (
    ChatResponse,
    ConversationEndRequest,
    ConversationEndResponse,
    ImpactAnalysisResult,
    NPCChatRequest,
    NPCChatResponse,
    NPCImpactRequest,
    NPCImpactResponse,
    PlayerChatReplyRequest,
    PlayerChatRequest,
    PlayerImpactRequest,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/chat", tags=["chat"])

NPC_CONV_MIN_TURNS = 2


# --- Helpers ---

async def _get_gossip_about_player(npc_name: str, player_name: str) -> list[dict]:
    """Fetch gossip memories about the player."""
    gossip_mems = chroma_store.get_memories_by_type(npc_name, "gossip")
    return sorted(
        [g for g in gossip_mems if g.get("actor", "") == player_name],
        key=lambda g: g.get("game_time", 0),
        reverse=True,
    )[:3]


async def _store_dialogue_memory(
    npc_name: str,
    text: str,
    actor: str,
    participants: list[str],
    location: str,
    game_time: int,
    importance: float,
    valence: float,
) -> None:
    """Helper to store a dialogue memory in ChromaDB."""
    collection = chroma_store.get_collection(npc_name)
    stability = compute_stability("dialogue", valence)
    memory = {
        "id": f"mem_{collection.count():04d}",
        "text": text,
        "description": text,
        "type": "dialogue",
        "importance": importance,
        "emotional_valence": valence,
        "entities": participants,
        "participants": participants,
        "location": location,
        "observer_location": location,
        "observed_near": location,
        "timestamp": game_time,
        "game_time": game_time,
        "game_day": game_time // 1440,
        "game_hour": (game_time % 1440) // 60,
        "last_accessed": game_time,
        "access_count": 0,
        "observation_count": 1,
        "stability": stability,
        "protected": importance >= 8.0,
        "superseded": False,
        "summary_level": 0,
        "actor": actor,
    }
    await chroma_store.add_memory(npc_name, memory)


# --- Player dialogue endpoints ---

@router.post("/greet", response_model=ChatResponse)
async def greet_player(req: PlayerChatRequest) -> ChatResponse:
    """Generate NPC greeting when player approaches.

    Port of npc_dialogue.gd get_dialogue_response_async().
    """
    npc = req.npc_state
    core = await chroma_store.get_core_memory(req.npc_name)

    # Retrieval query for greeting context
    retrieval_query = (
        f"{req.npc_name} talking with {req.player_name} "
        f"at the {npc.current_destination}"
    )
    retrieved = await chroma_store.retrieve_memories(
        req.npc_name, retrieval_query,
        req.game_time.total_minutes, count=8,
    )
    gossip = await _get_gossip_about_player(req.npc_name, req.player_name)

    system_prompt = build_system_prompt(
        npc, req.player_name, core, req.closest_friends,
    )
    user_message = build_dialogue_context(req, core, retrieved, gossip)

    text, success = await llm_client.generate(system_prompt, user_message)

    if success and text:
        # Store greeting memory
        await _store_dialogue_memory(
            req.npc_name,
            f"Talked with {req.player_name} at the {npc.current_destination}. "
            f"I said: {text[:80]}",
            req.player_name,
            [req.npc_name, req.player_name],
            npc.current_destination,
            req.game_time.total_minutes,
            importance=4.0, valence=0.2,
        )
        return ChatResponse(response_text=text, success=True, memory_created=True)

    return ChatResponse(response_text="", success=False)


@router.post("/reply", response_model=ChatResponse)
async def reply_to_player(req: PlayerChatReplyRequest) -> ChatResponse:
    """Generate NPC reply in multi-turn player conversation.

    Port of npc_dialogue.gd get_conversation_reply_async().
    """
    npc = req.npc_state
    core = await chroma_store.get_core_memory(req.npc_name)

    # Targeted retrieval using player's actual message
    retrieved = await chroma_store.retrieve_memories(
        req.npc_name, req.player_message,
        req.game_time.total_minutes, count=8,
    )
    gossip = await _get_gossip_about_player(req.npc_name, req.player_name)

    system_prompt = build_system_prompt(
        npc, req.player_name, core, [],
    )
    user_message = build_reply_with_history(req, core, retrieved, gossip)

    text, success = await llm_client.generate(system_prompt, user_message)

    if success and text:
        await _store_dialogue_memory(
            req.npc_name,
            f'Talked with {req.player_name} at the {npc.current_destination}. '
            f'They said: "{req.player_message[:40]}" and I replied: "{text[:40]}"',
            req.player_name,
            [req.npc_name, req.player_name],
            npc.current_destination,
            req.game_time.total_minutes,
            importance=5.0, valence=0.3,
        )
        return ChatResponse(response_text=text, success=True, memory_created=True)

    return ChatResponse(response_text="", success=False)


@router.post("/end", response_model=ConversationEndResponse)
async def end_conversation(req: ConversationEndRequest) -> ConversationEndResponse:
    """Summarize and store a completed player conversation.

    Port of npc_dialogue.gd on_player_conversation_ended().
    """
    npc = req.npc_state
    history = [{"speaker": m.speaker, "text": m.text} for m in req.history]

    if not history:
        return ConversationEndResponse(summary="", success=True)

    # Short conversation: simple concatenation
    if len(history) <= 4:
        parts = [
            f'{m["speaker"]}: "{str(m["text"])[:50]}"'
            for m in history
        ]
        summary = (
            f"Conversation with {req.player_name} at the "
            f"{npc.current_destination}. {'. '.join(parts)}"
        )[:200]
        await _store_dialogue_memory(
            req.npc_name, summary, req.player_name,
            [req.npc_name, req.player_name],
            npc.current_destination, req.game_time.total_minutes,
            importance=8.0, valence=0.3,
        )
        return ConversationEndResponse(summary=summary, success=True)

    # Longer conversation: LLM summary
    system, user = build_conversation_summary_prompt(
        req.npc_name, req.player_name, history,
    )
    text, success = await llm_client.generate(system, user)

    if success and text:
        summary = text.strip()[:300]
    else:
        summary = (
            f"Had a long conversation with {req.player_name} "
            f"at the {npc.current_destination} about various topics"
        )

    await _store_dialogue_memory(
        req.npc_name, summary, req.player_name,
        [req.npc_name, req.player_name],
        npc.current_destination, req.game_time.total_minutes,
        importance=8.0, valence=0.3,
    )
    return ConversationEndResponse(summary=summary, success=True)


# --- NPC-to-NPC conversation ---

@router.post("/npc-turn", response_model=NPCChatResponse)
async def npc_conversation_turn(req: NPCChatRequest) -> NPCChatResponse:
    """Generate a single NPC-to-NPC conversation turn.

    Port of npc_conversation.gd _run_conversation_turn().
    """
    core = await chroma_store.get_core_memory(req.speaker_name)

    # Per-turn retrieval: use last line or topic as query
    retrieval_query = req.topic
    if req.history:
        last_line = req.history[-1].text
        if len(last_line) > 5:
            retrieval_query = last_line

    retrieved = await chroma_store.retrieve_memories(
        req.speaker_name, retrieval_query,
        req.game_time.total_minutes, count=3,
    )

    system_prompt = build_npc_chat_system_prompt(req.speaker_state)
    context = build_npc_chat_context_for_turn(req, core, retrieved)

    line, success = await llm_client.generate(system_prompt, context)

    if not success or not line.strip():
        # Fallback
        line = "Interesting weather we're having."

    line = line.strip().replace('"', '').replace("'", "'")[:120]

    # Should conversation end?
    should_end = False
    next_turn = req.turn + 1
    if next_turn >= req.max_turns:
        should_end = True
    elif next_turn >= NPC_CONV_MIN_TURNS:
        # Farewell detection
        line_lower = line.lower()
        if any(w in line_lower for w in ("goodbye", "see you", "take care", "farewell")):
            should_end = True

    return NPCChatResponse(line=line, should_end=should_end, success=True)


# --- Impact analysis ---

@router.post("/player-impact", response_model=ImpactAnalysisResult)
async def analyze_player_impact(req: PlayerImpactRequest) -> ImpactAnalysisResult:
    """Analyze conversation impact on NPC-player relationship.

    Port of npc_dialogue.gd _analyze_player_conversation_impact().
    """
    core = await chroma_store.get_core_memory(req.npc_name)
    old_summary = core.get("player_summary", "")

    prompt = build_player_impact_prompt_with_summary(req, old_summary)

    text, success = await llm_client.generate_lite(
        "You analyze conversation impact on relationships. Return ONLY valid JSON.",
        prompt,
    )

    if not success or not text:
        return ImpactAnalysisResult(trust_change=1, affection_change=1)

    data = llm_client.parse_json_response(text)
    if not data or not isinstance(data, dict):
        return ImpactAnalysisResult(trust_change=1, affection_change=1)

    result = ImpactAnalysisResult(
        trust_change=max(-5, min(5, int(data.get("trust_change", 0)))),
        affection_change=max(-5, min(5, int(data.get("affection_change", 0)))),
        respect_change=max(-5, min(5, int(data.get("respect_change", 0)))),
        emotional_state=str(data.get("emotional_state", ""))[:150],
        player_summary_update=str(data.get("player_summary_update", ""))[:200],
        key_fact=str(data.get("key_fact", ""))[:100],
    )

    # Update core memory with new emotional state and player summary
    if result.emotional_state:
        core["emotional_state"] = result.emotional_state
    if result.player_summary_update:
        core["player_summary"] = result.player_summary_update
    if result.key_fact and len(result.key_fact) > 3:
        facts = core.get("key_facts", [])
        if result.key_fact not in facts:
            facts.append(result.key_fact)
        core["key_facts"] = facts[-10:]
    await chroma_store.save_core_memory(req.npc_name, core)

    return result


@router.post("/npc-impact", response_model=NPCImpactResponse)
async def analyze_npc_impact(req: NPCImpactRequest) -> NPCImpactResponse:
    """Analyze bidirectional impact of NPC-NPC conversation.

    Port of npc_conversation.gd _analyze_npc_conversation_impact().
    """
    prompt = build_npc_impact_prompt(
        req.speaker_name, req.listener_name,
        req.speaker_line, req.listener_line,
        req.current_relationship,
    )

    text, success = await llm_client.generate_lite(
        "Analyze conversation impact. Return ONLY valid JSON.",
        prompt,
    )

    if not success or not text:
        return NPCImpactResponse(
            a_to_b=ImpactAnalysisResult(trust_change=1, affection_change=1),
            b_to_a=ImpactAnalysisResult(trust_change=1, affection_change=1),
        )

    data = llm_client.parse_json_response(text)
    if not data or not isinstance(data, dict):
        return NPCImpactResponse(
            a_to_b=ImpactAnalysisResult(trust_change=1, affection_change=1),
            b_to_a=ImpactAnalysisResult(trust_change=1, affection_change=1),
        )

    a2b = data.get("a_to_b", {})
    b2a = data.get("b_to_a", {})

    return NPCImpactResponse(
        a_to_b=ImpactAnalysisResult(
            trust_change=max(-3, min(3, int(a2b.get("trust", 0)))),
            affection_change=max(-3, min(3, int(a2b.get("affection", 0)))),
            respect_change=max(-3, min(3, int(a2b.get("respect", 0)))),
        ),
        b_to_a=ImpactAnalysisResult(
            trust_change=max(-3, min(3, int(b2a.get("trust", 0)))),
            affection_change=max(-3, min(3, int(b2a.get("affection", 0)))),
            respect_change=max(-3, min(3, int(b2a.get("respect", 0)))),
        ),
    )


class NPCSummaryRequest(BaseModel):
    """Request body for NPC summary update."""

    npc_name: str
    other_name: str
    my_line: str
    their_line: str


@router.post("/npc-summary", response_model=ChatResponse)
async def update_npc_summary(req: NPCSummaryRequest) -> ChatResponse:
    """Update NPC's impression of another NPC after conversation.

    Port of npc_conversation.gd _update_npc_summary_async().
    """
    npc_name = req.npc_name
    other_name = req.other_name
    my_line = req.my_line
    their_line = req.their_line
    core = await chroma_store.get_core_memory(npc_name)
    old_summary = core.get("npc_summaries", {}).get(other_name, "No prior impression")

    system, user = build_npc_summary_update_prompt(
        npc_name, other_name, my_line, their_line, old_summary,
    )
    text, success = await llm_client.generate_lite(system, user)

    if success and text:
        summary = text.strip()[:200]
        npc_summaries = core.get("npc_summaries", {})
        npc_summaries[other_name] = summary
        core["npc_summaries"] = npc_summaries
        await chroma_store.save_core_memory(npc_name, core)
        return ChatResponse(response_text=summary, success=True)

    return ChatResponse(response_text="", success=False)
