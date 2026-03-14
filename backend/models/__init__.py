"""Pydantic models for the DeepTown Brain API."""

from backend.models.memory import (
    CoreMemory,
    CoreMemoryUpdateRequest,
    EpisodicMemory,
    MaintenanceRequest,
    MaintenanceResponse,
    MemoryAddRequest,
    MemoryAddResponse,
    MemoryContextRequest,
    MemoryContextResponse,
    MemoryRetrieveRequest,
    MemoryRetrieveResponse,
    MemorySnapshotResponse,
)
from backend.models.npc import (
    GameTimeInfo,
    NPCNeeds,
    NPCState,
    ObserveRequest,
    ObserveResponse,
)

__all__ = [
    "CoreMemory",
    "CoreMemoryUpdateRequest",
    "EpisodicMemory",
    "GameTimeInfo",
    "MaintenanceRequest",
    "MaintenanceResponse",
    "MemoryAddRequest",
    "MemoryAddResponse",
    "MemoryContextRequest",
    "MemoryContextResponse",
    "MemoryRetrieveRequest",
    "MemoryRetrieveResponse",
    "MemorySnapshotResponse",
    "NPCNeeds",
    "NPCState",
    "ObserveRequest",
    "ObserveResponse",
]
