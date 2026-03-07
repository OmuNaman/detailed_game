"""Pydantic models for NPC state and game time.

Matches GDScript data shapes from npc_controller.gd.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class NPCNeeds(BaseModel):
    """NPC physiological needs — range 0-100 each."""

    hunger: float = Field(default=100.0, ge=0.0, le=100.0)
    energy: float = Field(default=100.0, ge=0.0, le=100.0)
    social: float = Field(default=100.0, ge=0.0, le=100.0)


class NPCState(BaseModel):
    """Full NPC state snapshot sent with every API request (stateless protocol)."""

    npc_name: str
    job: str = ""
    age: int = 0
    personality: str = ""
    speech_style: str = ""
    home_building: str = ""
    workplace_building: str = ""
    current_destination: str = ""
    current_activity: str = ""
    needs: NPCNeeds = Field(default_factory=NPCNeeds)
    game_time: int = 0  # GameClock.total_minutes
    game_hour: int = 0
    game_minute: int = 0
    game_day: int = 0
    game_season: str = "Spring"


class GameTimeInfo(BaseModel):
    """Game clock snapshot."""

    total_minutes: int = 0
    hour: int = 0
    minute: int = 0
    day: int = 1
    season: str = "Spring"


class ObserveRequest(BaseModel):
    """Request to process an NPC observation."""

    npc_id: str
    observation: str
    game_time: int = 0
    game_day: int = 0
    game_hour: int = 0


class ObserveResponse(BaseModel):
    """Response from observation processing."""

    status: str = "ok"
    importance: float = 5.0
    valence: float = 0.0
