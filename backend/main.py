"""DeepTown Brain — FastAPI backend for NPC cognitive architecture."""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from backend.api.chat import router as chat_router
from backend.api.gossip import router as gossip_router
from backend.api.memory import router as memory_router
from backend.api.observe import router as observe_router
from backend.api.plan import router as plan_router
from backend.api.reflect import router as reflect_router
from backend.config import settings
from backend.memory.chroma_store import get_chroma_client


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup/shutdown lifecycle."""
    get_chroma_client()  # Initialize ChromaDB on startup
    print(f"[Brain] Starting with model={settings.llm_model}, "
          f"embedding={settings.embedding_model}")
    yield
    print("[Brain] Shutting down")


app = FastAPI(
    title="DeepTown Brain",
    description="Cognitive engine for NPC memory, dialogue, planning, and reflection.",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


app.include_router(chat_router)
app.include_router(gossip_router)
app.include_router(memory_router)
app.include_router(observe_router)
app.include_router(plan_router)
app.include_router(reflect_router)


@app.get("/health")
async def health_check():
    """Basic health check."""
    return {"status": "ok"}
