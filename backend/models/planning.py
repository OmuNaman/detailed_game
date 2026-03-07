"""Pydantic models for planning and reflection endpoints.

Matches GDScript data shapes from npc_planner.gd and npc_reflection.gd.
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from backend.models.memory import EpisodicMemory
from backend.models.npc import GameTimeInfo, NPCState


# --- Planning ---

class PlanBlock(BaseModel):
    """Level 1 plan block — a multi-hour activity."""

    start_hour: int
    end_hour: int
    location: str
    activity: str
    decomposed: bool = False


class L2Step(BaseModel):
    """Level 2 step — hourly breakdown of an L1 block."""

    hour: int
    end_hour: int
    activity: str


class L3Step(BaseModel):
    """Level 3 step — 5-20 minute granular action within an L2 hour."""

    start_min: int
    end_min: int
    activity: str


class PlanRequest(BaseModel):
    """Request to generate a daily plan."""

    npc_name: str
    npc_state: NPCState
    game_time: GameTimeInfo
    reflections: list[str] = Field(default_factory=list)
    relationships: dict[str, str] = Field(default_factory=dict)
    gossip: list[str] = Field(default_factory=list)
    recent_events: list[str] = Field(default_factory=list)
    npc_summaries: dict[str, str] = Field(default_factory=dict)
    player_name: str = ""
    player_summary: str = ""
    world_description: str = ""


class PlanResponse(BaseModel):
    """Response with generated daily plan."""

    plan_level1: list[PlanBlock] = Field(default_factory=list)
    success: bool = True


class DecomposeL2Request(BaseModel):
    """Request to decompose an L1 block into hourly steps."""

    npc_name: str
    npc_state: NPCState
    block: PlanBlock
    game_time: GameTimeInfo


class DecomposeL2Response(BaseModel):
    """Response with hourly decomposition."""

    steps: list[L2Step] = Field(default_factory=list)
    success: bool = True


class DecomposeL3Request(BaseModel):
    """Request to decompose an L2 step into minute-level actions."""

    npc_name: str
    npc_state: NPCState
    hour: int
    location: str
    activity: str
    game_time: GameTimeInfo


class DecomposeL3Response(BaseModel):
    """Response with minute-level decomposition."""

    steps: list[L3Step] = Field(default_factory=list)
    success: bool = True


class ReactionRequest(BaseModel):
    """Request to evaluate whether an NPC should react to an event."""

    npc_name: str
    npc_state: NPCState
    observation: str
    importance: float
    current_activity: str
    current_destination: str
    game_time: GameTimeInfo


class ReactionResponse(BaseModel):
    """Response from reaction evaluation."""

    action: str = "CONTINUE"  # "CONTINUE" or "REACT"
    new_location: str = ""
    new_activity: str = ""
    success: bool = True


# --- Reflection ---

class ReflectRequest(BaseModel):
    """Request to trigger NPC reflection."""

    npc_name: str
    npc_state: NPCState
    game_time: GameTimeInfo


class ReflectResponse(BaseModel):
    """Response from reflection process."""

    insights: list[str] = Field(default_factory=list)
    questions_generated: int = 0
    success: bool = True


# --- Gossip ---

class GossipPickRequest(BaseModel):
    """Request to select a gossip memory to share."""

    npc_name: str
    other_npc_name: str
    trust_score: float
    game_time: int


class GossipPickResponse(BaseModel):
    """Response with selected gossip memory (or null)."""

    memory: EpisodicMemory | None = None
    should_share: bool = False


class GossipShareRequest(BaseModel):
    """Request to share gossip between NPCs."""

    sharer_name: str
    receiver_name: str
    memory_text: str
    memory_importance: float
    memory_valence: float
    memory_actor: str = ""
    gossip_hops: int = 0
    game_time: int


class GossipShareResponse(BaseModel):
    """Response from gossip sharing."""

    success: bool = True


class GossipDetectRequest(BaseModel):
    """Request to detect third-party mentions in dialogue."""

    speaker_name: str
    line_text: str
    listener_name: str
    all_npc_names: list[str] = Field(default_factory=list)
    player_name: str = ""
    game_time: int


class GossipDetectResponse(BaseModel):
    """Response with detected mentions."""

    mentions: list[dict] = Field(default_factory=list)
