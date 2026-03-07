"""Pydantic models for dialogue and conversation endpoints.

Matches GDScript data shapes from npc_dialogue.gd and npc_conversation.gd.
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from backend.models.npc import GameTimeInfo, NPCState


class ChatMessage(BaseModel):
    """Single message in a conversation history."""

    speaker: str
    text: str


class RelationshipData(BaseModel):
    """Relationship scores and labels between two characters."""

    trust: int = 0
    affection: int = 0
    respect: int = 0
    trust_label: str = "are neutral toward"
    affection_label: str = "feel nothing toward"
    respect_label: str = "have no opinion of"
    opinion_label: str = "are neutral toward"


class PlanEntry(BaseModel):
    """A single plan block from the NPC's daily plan."""

    start_hour: int = 0
    end_hour: int = 0
    activity: str = ""
    location: str = ""


class BuildingObject(BaseModel):
    """State of an interactive object in a building."""

    tile_type: str = ""
    state: str = "idle"
    user: str = ""


class PlayerChatRequest(BaseModel):
    """Request for initial NPC greeting when player approaches."""

    npc_name: str
    npc_state: NPCState
    player_name: str
    game_time: GameTimeInfo
    time_string: str = ""
    relationship: RelationshipData = Field(default_factory=RelationshipData)
    closest_friends: list[dict] = Field(default_factory=list)
    building_objects: list[BuildingObject] = Field(default_factory=list)
    plans: list[PlanEntry] = Field(default_factory=list)
    schedule_destination: str = ""


class PlayerChatReplyRequest(BaseModel):
    """Request for NPC reply in multi-turn player conversation."""

    npc_name: str
    npc_state: NPCState
    player_name: str
    player_message: str
    history: list[ChatMessage] = Field(default_factory=list)
    game_time: GameTimeInfo
    time_string: str = ""
    relationship: RelationshipData = Field(default_factory=RelationshipData)
    building_objects: list[BuildingObject] = Field(default_factory=list)
    plans: list[PlanEntry] = Field(default_factory=list)
    schedule_destination: str = ""


class ChatResponse(BaseModel):
    """Response from dialogue generation."""

    response_text: str = ""
    success: bool = True
    memory_created: bool = False


class ConversationEndRequest(BaseModel):
    """Request to summarize and store a completed conversation."""

    npc_name: str
    npc_state: NPCState
    player_name: str
    history: list[ChatMessage] = Field(default_factory=list)
    game_time: GameTimeInfo


class ConversationEndResponse(BaseModel):
    """Response from conversation end processing."""

    summary: str = ""
    success: bool = True


class NPCChatRequest(BaseModel):
    """Request for a single NPC-to-NPC conversation turn."""

    speaker_name: str
    speaker_state: NPCState
    listener_name: str
    listener_state: NPCState
    topic: str
    history: list[ChatMessage] = Field(default_factory=list)
    turn: int = 0
    max_turns: int = 6
    game_time: GameTimeInfo
    relationship: RelationshipData = Field(default_factory=RelationshipData)


class NPCChatResponse(BaseModel):
    """Response from NPC-to-NPC dialogue turn."""

    line: str = ""
    should_end: bool = False
    success: bool = True


class ImpactAnalysisResult(BaseModel):
    """Relationship change from a conversation exchange."""

    trust_change: int = Field(default=0, ge=-5, le=5)
    affection_change: int = Field(default=0, ge=-5, le=5)
    respect_change: int = Field(default=0, ge=-5, le=5)
    emotional_state: str = ""
    player_summary_update: str = ""
    key_fact: str = ""


class PlayerImpactRequest(BaseModel):
    """Request to analyze impact of player conversation on NPC."""

    npc_name: str
    npc_state: NPCState
    player_name: str
    player_message: str
    npc_response: str
    game_time: GameTimeInfo
    relationship: RelationshipData = Field(default_factory=RelationshipData)


class NPCImpactRequest(BaseModel):
    """Request to analyze bidirectional impact of NPC-NPC conversation."""

    speaker_name: str
    listener_name: str
    speaker_line: str
    listener_line: str
    current_relationship: dict = Field(default_factory=dict)
    game_time: GameTimeInfo


class NPCImpactResponse(BaseModel):
    """Bidirectional relationship changes from NPC-NPC conversation."""

    a_to_b: ImpactAnalysisResult = Field(default_factory=ImpactAnalysisResult)
    b_to_a: ImpactAnalysisResult = Field(default_factory=ImpactAnalysisResult)
