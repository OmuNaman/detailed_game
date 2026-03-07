"""Pydantic models for the three-tier memory system.

Matches GDScript data shapes from memory_system.gd exactly.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


# --- Tier 0: Core Memory ---

class CoreMemory(BaseModel):
    """Always-in-prompt identity and relationship context (~800 tokens)."""

    identity: str = ""
    emotional_state: str = "Feeling neutral, starting the day."
    player_summary: str = ""
    npc_summaries: dict[str, str] = Field(default_factory=dict)
    active_goals: list[str] = Field(default_factory=list)
    key_facts: list[str] = Field(default_factory=list, max_length=10)


# --- Tier 1: Episodic Memory ---

class EpisodicMemory(BaseModel):
    """Single memory record — matches memory_system.gd create_memory() output."""

    id: str = ""
    text: str = ""
    description: str = ""  # backward compat alias for text
    type: str = "observation"  # observation|environment|conversation|dialogue|reflection|plan|gossip|gossip_heard|gossip_shared|player_dialogue|episode_summary|period_summary
    importance: float = Field(default=5.0, ge=1.0, le=10.0)
    emotional_valence: float = Field(default=0.0, ge=-1.0, le=1.0)
    entities: list[str] = Field(default_factory=list)
    participants: list[str] = Field(default_factory=list)
    location: str = ""
    observer_location: str = ""
    observed_near: str = ""
    timestamp: int = 0  # game minutes (GameClock.total_minutes)
    game_time: int = 0  # backward compat
    game_day: int = 0
    game_hour: int = 0
    last_accessed: int = 0
    access_count: int = 0
    observation_count: int = 1
    stability: float = 12.0
    protected: bool = False
    superseded: bool = False
    shared_with: list[str] = Field(default_factory=list)
    source_memory_id: str = ""
    summary_level: int = 0  # 0=raw, 1=episode, 2=period
    actor: str = ""
    gossip_source: str | None = None
    gossip_hops: int | None = None
    original_description: str | None = None


# --- API Request/Response Models ---

class MemoryAddRequest(BaseModel):
    """Request to add a new memory for an NPC."""

    npc_name: str
    text: str
    type: str
    actor: str = ""
    participants: list[str] = Field(default_factory=list)
    observer_location: str = ""
    observed_near: str = ""
    importance: float = Field(ge=1.0, le=10.0)
    valence: float = Field(ge=-1.0, le=1.0)
    game_time: int  # current GameClock.total_minutes
    game_day: int = 0
    game_hour: int = 0
    extra_fields: dict = Field(default_factory=dict)


class MemoryAddResponse(BaseModel):
    """Response after adding a memory."""

    memory: EpisodicMemory
    deduplicated: bool = False


class MemoryRetrieveRequest(BaseModel):
    """Request to retrieve memories by semantic query."""

    npc_name: str
    query_text: str
    game_time: int
    count: int = 8
    type_filter: str = ""
    entity_filter: str = ""
    time_range_hours: float = -1


class MemoryRetrieveResponse(BaseModel):
    """Response with retrieved memories."""

    memories: list[EpisodicMemory]


class MemoryContextRequest(BaseModel):
    """Request for assembled memory context string."""

    npc_name: str
    query_text: str
    game_time: int
    count: int = 8


class MemoryContextResponse(BaseModel):
    """Response with formatted context for prompt injection."""

    context: str
    retrieved_count: int


class CoreMemoryUpdateRequest(BaseModel):
    """Partial update to core memory fields."""

    emotional_state: str | None = None
    player_summary: str | None = None
    npc_summaries: dict[str, str] | None = None
    active_goals: list[str] | None = None
    key_facts: list[str] | None = None


class MaintenanceRequest(BaseModel):
    """Request to run memory maintenance (forgetting + compression)."""

    game_time: int


class MaintenanceResponse(BaseModel):
    """Response from maintenance run."""

    forgotten_count: int = 0
    compressed_count: int = 0
    period_summaries_created: int = 0
