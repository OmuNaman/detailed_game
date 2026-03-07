"""Planning endpoints — daily plan, L2/L3 decomposition, reaction evaluation.

Faithful port of npc_planner.gd Stanford 3-level recursive planning.
"""

from __future__ import annotations

import logging
import re

from fastapi import APIRouter

from backend.llm import client as llm_client
from backend.memory import chroma_store
from backend.models.planning import (
    DecomposeL2Request,
    DecomposeL2Response,
    DecomposeL3Request,
    DecomposeL3Response,
    L2Step,
    L3Step,
    PlanBlock,
    PlanRequest,
    PlanResponse,
    ReactionRequest,
    ReactionResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/plan", tags=["plan"])

# Valid building names for fuzzy matching (matches npc_planner.gd)
VALID_BUILDINGS: list[str] = [
    "Bakery", "General Store", "Tavern", "Church",
    "Sheriff Office", "Courthouse", "Blacksmith",
] + [f"House {i}" for i in range(1, 12)]

# NPC roster text (matches npc_planner.gd _get_npc_roster_text())
NPC_ROSTER_TEXT = """People who live and work in this town:
- Maria: Baker, works at Bakery, lives at House 1
- Thomas: Shopkeeper, works at General Store, lives at House 2
- Elena: Sheriff, works at Sheriff Office, lives at House 3
- Gideon: Blacksmith, works at Blacksmith, lives at House 4
- Rose: Barmaid, works at Tavern, lives at House 5
- Lyra: Clerk, works at Courthouse, lives at House 6
- Finn: Farmer/laborer, delivers to General Store, lives at House 7 (married to Clara)
- Clara: Devout churchgoer, helps at Church, lives at House 7 (married to Finn)
- Bram: Apprentice blacksmith, works at Blacksmith with Gideon, lives at House 8
- Old Silas: Retired storyteller, spends time at Tavern, lives at House 9
- Father Aldric: Priest, works at Church, lives at House 10

IMPORTANT: Only reference people from this list. Do NOT invent names.
"""


def _match_building_name(name: str, valid: list[str]) -> str:
    """Fuzzy match building name. Port of npc_planner.gd _match_building_name()."""
    lower = name.lower()
    for v in valid:
        if lower == v.lower():
            return v
        if v.lower() in lower or lower in v.lower():
            return v
    return ""


def _build_level1_prompt(npc: object) -> str:
    """System prompt for Level 1 planning. Port of npc_planner.gd _build_level1_prompt()."""
    prompt = f"You are {npc.npc_name}, a {npc.age}-year-old {npc.job} in DeepTown. {npc.personality}\n\n"
    prompt += "Plan your FULL day from waking (hour 5) to sleeping (hour 22). "
    prompt += "Generate 5-8 activity blocks covering every hour of your day.\n\n"
    prompt += f"Your workplace: {npc.workplace_building} (you typically work there from 6-15)\n"
    prompt += f"Your home: {npc.home_building}\n\n"
    prompt += "Available buildings: Bakery, General Store, Tavern, Church, Sheriff Office, Courthouse, Blacksmith\n\n"
    prompt += NPC_ROSTER_TEXT
    prompt += f"\nFormat each block as: START-END|LOCATION|ACTIVITY (one per line)\n"
    prompt += "Example:\n"
    prompt += f"5-6|{npc.home_building}|Wake up, have breakfast\n"
    prompt += f"6-12|{npc.workplace_building}|Morning work at the {npc.workplace_building}\n"
    prompt += f"12-13|{npc.home_building}|Lunch break at home\n"
    prompt += f"13-16|{npc.workplace_building}|Afternoon work\n"
    prompt += "16-17|Tavern|Visit Rose for a drink and catch up\n"
    prompt += "17-20|Tavern|Evening socializing\n"
    prompt += f"20-22|{npc.home_building}|Dinner and winding down\n\n"
    prompt += "Rules:\n"
    prompt += "- Cover hours 5-22 with NO gaps\n"
    prompt += "- Include meals at home around hours 7, 12, 19\n"
    prompt += "- Be specific about WHO and WHY for social visits\n"
    prompt += "- Make today different based on your feelings and relationships\n"
    prompt += "- Include at least one social visit outside your workplace\n"
    prompt += "- Do NOT plan past hour 22"
    return prompt


def _build_planning_context(req: PlanRequest) -> str:
    """User message with planning context. Port of npc_planner.gd _build_planning_context()."""
    context = ""

    if req.reflections:
        context += "Your recent thoughts:\n"
        for ref in req.reflections[:3]:
            context += f"- {ref}\n"
        context += "\n"

    if req.relationships:
        context += "Your relationships:\n"
        for target, label in req.relationships.items():
            context += f"- You {label} {target}\n"
        context += "\n"

    if req.gossip:
        context += "Things you've heard recently:\n"
        for g in req.gossip[:3]:
            context += f"- {g}\n"
        context += "\n"

    if req.recent_events:
        context += "Recent events:\n"
        for evt in req.recent_events[:5]:
            context += f"- {evt}\n"
        context += "\n"

    if req.npc_summaries:
        context += "What you know about people:\n"
        for name, summary in req.npc_summaries.items():
            context += f"- {name}: {summary}\n"
        context += "\n"

    if req.player_summary and not req.player_summary.startswith("I haven't met"):
        context += f"About {req.player_name}: {req.player_summary}\n\n"

    if req.world_description:
        context += f"{req.world_description}\n\n"

    context += "Plan your full day (5-8 blocks from hour 5 to 22). Format: START-END|LOCATION|ACTIVITY"
    return context


def _parse_level1_plan(text: str) -> list[PlanBlock]:
    """Parse START-END|LOCATION|ACTIVITY lines. Port of npc_planner.gd _parse_level1_plan()."""
    plans: list[PlanBlock] = []

    for line in text.split("\n"):
        cleaned = line.strip()
        if not cleaned:
            continue

        # Remove leading numbering or bullets
        if len(cleaned) > 2 and cleaned[0].isdigit() and cleaned[1] in ".):":
            if cleaned[1] not in "-|":
                cleaned = cleaned[2:].strip()

        parts = cleaned.split("|")
        if len(parts) < 3:
            continue

        time_part = parts[0].strip()
        location = parts[1].strip()
        activity = parts[2].strip()

        time_parts = time_part.split("-")
        if len(time_parts) != 2:
            continue

        try:
            start_h = int(time_parts[0].strip())
            end_h = int(time_parts[1].strip())
        except ValueError:
            continue

        if start_h < 5 or end_h > 23 or start_h >= end_h:
            continue

        matched = _match_building_name(location, VALID_BUILDINGS)
        if not matched:
            continue

        plans.append(PlanBlock(
            start_hour=start_h,
            end_hour=end_h,
            location=matched,
            activity=activity,
        ))

    plans.sort(key=lambda p: p.start_hour)
    return plans[:8]


def _parse_level2_steps(text: str, block_start: int, block_end: int) -> list[L2Step]:
    """Parse HOUR|ACTIVITY format. Port of npc_planner.gd _parse_level2_steps()."""
    steps: list[L2Step] = []
    for line in text.strip().split("\n"):
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", maxsplit=2)
        if len(parts) < 2:
            continue
        hour_str = parts[0].strip()
        activity = parts[1].strip()
        try:
            h = int(hour_str)
        except ValueError:
            continue
        if h < block_start or h >= block_end:
            continue
        steps.append(L2Step(hour=h, end_hour=h + 1, activity=activity))

    steps.sort(key=lambda s: s.hour)
    max_steps = block_end - block_start
    return steps[:max_steps]


def _parse_level3_steps(text: str) -> list[L3Step]:
    """Parse START_MIN-END_MIN|ACTION format. Port of npc_planner.gd _parse_level3_steps()."""
    steps: list[L3Step] = []
    for line in text.strip().split("\n"):
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", maxsplit=2)
        if len(parts) < 2:
            continue
        time_part = parts[0].strip()
        activity = parts[1].strip()
        if "-" not in time_part:
            continue
        time_parts = time_part.split("-")
        if len(time_parts) < 2:
            continue
        try:
            start_m = int(time_parts[0].strip())
            end_m = int(time_parts[1].strip())
        except ValueError:
            continue
        if start_m < 0 or end_m > 60 or start_m >= end_m:
            continue
        steps.append(L3Step(start_min=start_m, end_min=end_m, activity=activity))

    steps.sort(key=lambda s: s.start_min)
    return steps[:6]


# --- Endpoints ---

@router.post("/daily", response_model=PlanResponse)
async def generate_daily_plan(req: PlanRequest) -> PlanResponse:
    """Generate Level 1 daily plan (5-8 activity blocks).

    Port of npc_planner.gd generate_daily_plan().
    """
    system_prompt = _build_level1_prompt(req.npc_state)
    user_message = _build_planning_context(req)

    text, success = await llm_client.generate(system_prompt, user_message)

    if not success or not text:
        return PlanResponse(plan_level1=[], success=False)

    plans = _parse_level1_plan(text)

    if plans:
        # Store plan as memory
        plan_parts = [
            f"{p.activity} at {p.location} ({p.start_hour}:00-{p.end_hour}:00)"
            for p in plans
        ]
        plan_desc = f"My plans for today: {', '.join(plan_parts)}"
        collection = chroma_store.get_collection(req.npc_name)
        plan_mem = {
            "id": f"mem_{collection.count():04d}",
            "text": plan_desc,
            "description": plan_desc,
            "type": "plan",
            "importance": 4.0,
            "emotional_valence": 0.1,
            "entities": [req.npc_name],
            "participants": [req.npc_name],
            "location": req.npc_state.home_building,
            "observer_location": req.npc_state.home_building,
            "observed_near": req.npc_state.home_building,
            "timestamp": req.game_time.total_minutes,
            "game_time": req.game_time.total_minutes,
            "game_day": req.game_time.day,
            "game_hour": req.game_time.hour,
            "last_accessed": req.game_time.total_minutes,
            "access_count": 0,
            "observation_count": 1,
            "stability": 12.0,
            "protected": False,
            "superseded": False,
            "summary_level": 0,
            "actor": req.npc_name,
        }
        await chroma_store.add_memory(req.npc_name, plan_mem)

        # Update active goals in core memory
        core = await chroma_store.get_core_memory(req.npc_name)
        core["active_goals"] = plan_parts
        await chroma_store.save_core_memory(req.npc_name, core)

    return PlanResponse(plan_level1=plans, success=True)


@router.post("/decompose-l2", response_model=DecomposeL2Response)
async def decompose_to_level2(req: DecomposeL2Request) -> DecomposeL2Response:
    """Decompose an L1 block into hourly steps via Flash Lite.

    Port of npc_planner.gd _decompose_to_level2().
    """
    duration = req.block.end_hour - req.block.start_hour

    # Single-hour blocks don't need decomposition
    if duration <= 1:
        return DecomposeL2Response(steps=[
            L2Step(hour=req.block.start_hour, end_hour=req.block.end_hour, activity=req.block.activity),
        ])

    system_prompt = (
        f"You are {req.npc_name}, a {req.npc_state.job} ({req.npc_state.personality}). "
        f"Break this {duration}-hour activity block into hourly steps."
    )
    user_msg = (
        f"Activity: '{req.block.activity}' at {req.block.location} "
        f"from {req.block.start_hour}:00 to {req.block.end_hour}:00.\n"
        f"Break this into hourly steps. One line per hour.\n"
        f"Format: HOUR|ACTIVITY\n"
        f"Example:\n6|Open the shop and arrange shelves\n7|Greet early customers and restock\n"
        f"Only output the lines, nothing else."
    )

    text, success = await llm_client.generate_lite(system_prompt, user_msg)

    if success and text.strip():
        steps = _parse_level2_steps(text, req.block.start_hour, req.block.end_hour)
        if steps:
            return DecomposeL2Response(steps=steps)

    # Fallback: one entry per hour
    fallback = [
        L2Step(hour=h, end_hour=h + 1, activity=req.block.activity)
        for h in range(req.block.start_hour, req.block.end_hour)
    ]
    return DecomposeL2Response(steps=fallback)


@router.post("/decompose-l3", response_model=DecomposeL3Response)
async def decompose_to_level3(req: DecomposeL3Request) -> DecomposeL3Response:
    """Decompose an L2 hourly step into 5-20 minute actions via Flash Lite.

    Port of npc_planner.gd _decompose_to_level3().
    """
    system_prompt = (
        f"You are {req.npc_name}, a {req.npc_state.job}. "
        f"Break this 1-hour activity into 3-6 specific actions (5-20 min each)."
    )
    user_msg = (
        f"Hour {req.hour}:00 at {req.location}: '{req.activity}'\n"
        f"Format: START_MIN-END_MIN|ACTION\n"
        f"Example:\n0-10|Unlock the front door and light the stove\n"
        f"10-30|Knead bread dough for today's loaves\n"
        f"30-50|Shape loaves and place in oven\n50-60|Clean up workspace\n"
        f"Minutes must be 0-60, covering the full hour. Only output lines."
    )

    text, success = await llm_client.generate_lite(system_prompt, user_msg)

    if success and text.strip():
        steps = _parse_level3_steps(text)
        if steps:
            return DecomposeL3Response(steps=steps)

    # Fallback: single entry
    return DecomposeL3Response(steps=[
        L3Step(start_min=0, end_min=60, activity=req.activity),
    ])


@router.post("/react", response_model=ReactionResponse)
async def evaluate_reaction(req: ReactionRequest) -> ReactionResponse:
    """Evaluate whether NPC should react to observation by replanning.

    Port of npc_planner.gd evaluate_reaction().
    """
    system_prompt = (
        f"You are {req.npc_name}, a {req.npc_state.job} in DeepTown. "
        f"Decide if this observation warrants changing your current plans."
    )
    user_msg = (
        f"You are currently: {req.current_activity} at the {req.current_destination}.\n"
        f"New observation (importance {req.importance:.1f}): {req.observation}\n\n"
        f"Should you CONTINUE your current activity or REACT by changing plans?\n"
        f"If CONTINUE, just write: CONTINUE\n"
        f"If REACT, write: REACT|LOCATION|NEW_ACTIVITY\n"
        f"Example: REACT|Tavern|Rush to check on the commotion\n"
        f"Only react if this is truly important enough to disrupt your plans."
    )

    text, success = await llm_client.generate_lite(system_prompt, user_msg)

    if not success or not text.strip():
        return ReactionResponse(action="CONTINUE")

    first_line = text.strip().split("\n")[0].strip()
    upper = first_line.upper()

    if upper.startswith("CONTINUE"):
        return ReactionResponse(action="CONTINUE")

    if not upper.startswith("REACT"):
        return ReactionResponse(action="CONTINUE")

    parts = first_line.split("|")
    if len(parts) < 3:
        return ReactionResponse(action="CONTINUE")

    location_raw = parts[1].strip()
    activity_raw = parts[2].strip()

    matched = _match_building_name(location_raw, VALID_BUILDINGS)
    if not matched:
        matched = req.current_destination

    # Store reaction memory
    react_desc = f"Decided to react to: {req.observation} — going to {matched} to {activity_raw}"
    collection = chroma_store.get_collection(req.npc_name)
    react_mem = {
        "id": f"mem_{collection.count():04d}",
        "text": react_desc,
        "description": react_desc,
        "type": "plan",
        "importance": 4.0,
        "emotional_valence": 0.0,
        "entities": [req.npc_name],
        "participants": [req.npc_name],
        "location": req.current_destination,
        "observer_location": req.current_destination,
        "observed_near": matched,
        "timestamp": req.game_time.total_minutes,
        "game_time": req.game_time.total_minutes,
        "game_day": req.game_time.day,
        "game_hour": req.game_time.hour,
        "last_accessed": req.game_time.total_minutes,
        "access_count": 0,
        "observation_count": 1,
        "stability": 12.0,
        "protected": False,
        "superseded": False,
        "summary_level": 0,
        "actor": req.npc_name,
    }
    await chroma_store.add_memory(req.npc_name, react_mem)

    return ReactionResponse(
        action="REACT",
        new_location=matched,
        new_activity=activity_raw or "reacting to event",
    )
