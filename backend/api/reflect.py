"""Reflection endpoint — Stanford two-step reflection (questions then insights).

Faithful port of npc_reflection.gd enhanced_reflect().
"""

from __future__ import annotations

import logging

from fastapi import APIRouter

from backend.llm import client as llm_client
from backend.memory import chroma_store
from backend.memory.scoring import compute_stability
from backend.models.planning import ReflectRequest, ReflectResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/reflect", tags=["reflect"])

# Stop-words for keyword extraction (matches npc_reflection.gd)
_STOP_WORDS = frozenset({
    "what", "does", "have", "this", "that", "been", "with", "from",
    "they", "their", "about", "which", "there", "would", "could", "should",
})


def _extract_keywords(question: str) -> list[str]:
    """Extract keywords from a question for keyword-based retrieval."""
    keywords = []
    for w in question.split():
        lower = w.lower().strip()
        if len(lower) > 3 and lower not in _STOP_WORDS:
            keywords.append(lower)
    return keywords[:8]


def _parse_numbered_lines(text: str, max_count: int = 5, min_length: int = 10) -> list[str]:
    """Parse numbered lines from LLM output, stripping numbering."""
    results: list[str] = []
    for line in text.split("\n"):
        cleaned = line.strip()
        if not cleaned:
            continue
        stripped = cleaned
        if len(cleaned) > 2:
            if cleaned[0].isdigit() and cleaned[1] in ".):" :
                stripped = cleaned[2:].strip()
            elif len(cleaned) > 3 and cleaned[0].isdigit() and cleaned[1].isdigit():
                dot_pos = cleaned.find(".")
                if 0 < dot_pos < 4:
                    stripped = cleaned[dot_pos + 1:].strip()
        if len(stripped) >= min_length:
            results.append(stripped)
    return results[:max_count]


@router.post("", response_model=ReflectResponse)
async def reflect(req: ReflectRequest) -> ReflectResponse:
    """Run Stanford two-step reflection for an NPC.

    1. Gather 100 recent non-reflection memories
    2. Generate 5 salient questions
    3. For each question, retrieve relevant memories and generate insights
    4. Store insights as reflection memories, update core memory

    Port of npc_reflection.gd enhanced_reflect().
    """
    npc = req.npc_state

    # Gather recent non-reflection memories
    all_mems = chroma_store.get_all_memories(req.npc_name)
    recent = [
        m for m in all_mems
        if m.get("type", "") != "reflection" and not m.get("superseded", False)
    ]
    recent.sort(key=lambda m: m.get("timestamp", 0), reverse=True)
    recent = recent[:100]

    if len(recent) < 10:
        return ReflectResponse(success=True, questions_generated=0)

    # Build memory list text
    memories_text = ""
    for mem in recent:
        memories_text += f"- {mem.get('text', mem.get('description', ''))}\n"

    # Step 1: Generate 5 questions
    q_system = (
        f"You are analyzing the experiences of {req.npc_name}, "
        f"a {npc.age}-year-old {npc.job} in DeepTown. "
        f"{npc.personality[:200]}"
    )
    q_prompt = (
        f"Given these recent experiences of {req.npc_name}, "
        f"what are the 5 most salient high-level questions we can answer "
        f"about the subjects in the statements?\n\n"
        f"Recent experiences:\n{memories_text}\n"
        f"Focus on: patterns in relationships, changes in feelings, things learned "
        f"about others, personal growth, unresolved tensions, emerging goals, "
        f"and what relationships are forming or changing.\n\n"
        f"Respond with exactly 5 questions, one per line, nothing else."
    )

    q_text, q_success = await llm_client.generate(q_system, q_prompt)
    if not q_success or not q_text:
        return ReflectResponse(success=False, questions_generated=0)

    questions = _parse_numbered_lines(q_text, max_count=5)
    if not questions:
        return ReflectResponse(success=True, questions_generated=0)

    # Step 2: For each question, generate insights
    core = await chroma_store.get_core_memory(req.npc_name)
    identity = core.get("identity", npc.personality)
    all_insights: list[str] = []
    current_location = npc.current_destination or npc.home_building

    for question in questions:
        # Keyword retrieval
        keywords = _extract_keywords(question)
        relevant_mems = [
            m for m in all_mems
            if not m.get("superseded", False) and any(
                kw in m.get("text", m.get("description", "")).lower()
                for kw in keywords
            )
        ]
        # Sort by recency, take top 10
        relevant_mems.sort(key=lambda m: m.get("timestamp", 0), reverse=True)
        relevant_mems = relevant_mems[:10]

        if not relevant_mems:
            continue

        relevant_text = ""
        for mem in relevant_mems:
            day = mem.get("game_day", 0)
            text = mem.get("text", mem.get("description", ""))
            relevant_text += f"- [Day {day}] {text}\n"

        i_system = f"You are {req.npc_name}. Write personal reflections — genuine internal thoughts, not reports."
        i_prompt = (
            f"You are {req.npc_name} reflecting on your experiences.\n\n"
            f"Question: {question}\n\n"
            f"Relevant memories:\n{relevant_text}\n"
            f"Your personality: {identity[:300]}\n\n"
            f"What 5 high-level insights can you infer from the above statements? "
            f"Write each as a 1-2 sentence personal reflection in first person as {req.npc_name}. "
            f"Be genuine and specific — reference actual events and people. "
            f"Each should feel like an internal thought, not a report.\n\n"
            f"Format: One insight per line, numbered 1-5.\n"
            f"Write ONLY the insights, nothing else."
        )

        i_text, i_success = await llm_client.generate(i_system, i_prompt)
        if not i_success or not i_text:
            continue

        insights = _parse_numbered_lines(i_text, max_count=5)
        for insight in insights:
            # Strip citation if present
            paren_idx = insight.rfind("(because")
            clean = insight[:paren_idx].strip() if paren_idx > 0 else insight
            if len(clean) < 10:
                continue

            # Store as reflection memory
            collection = chroma_store.get_collection(req.npc_name)
            ref_mem = {
                "id": f"mem_{collection.count():04d}",
                "text": clean,
                "description": clean,
                "type": "reflection",
                "importance": 7.0,
                "emotional_valence": 0.0,
                "entities": [req.npc_name],
                "participants": [req.npc_name],
                "location": current_location,
                "observer_location": current_location,
                "observed_near": current_location,
                "timestamp": req.game_time.total_minutes,
                "game_time": req.game_time.total_minutes,
                "game_day": req.game_time.day,
                "game_hour": req.game_time.hour,
                "last_accessed": req.game_time.total_minutes,
                "access_count": 0,
                "observation_count": 1,
                "stability": compute_stability("reflection", 0.0),
                "protected": True,
                "superseded": False,
                "summary_level": 0,
                "actor": req.npc_name,
            }
            await chroma_store.add_memory(req.npc_name, ref_mem)
            all_insights.append(clean)

            # If insight mentions a player-like name, update player summary
            # (Godot will pass player_name separately if needed)

    # Update emotional state from last insight
    if all_insights:
        core["emotional_state"] = all_insights[-1][:150]
        await chroma_store.save_core_memory(req.npc_name, core)

    return ReflectResponse(
        insights=all_insights,
        questions_generated=len(questions),
        success=True,
    )
