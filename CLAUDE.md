# DeepTown — Context Engineering Bootcamp

Educational platform implementing Stanford Generative Agents via a **Brain/Body Split** architecture.

- **Brain** (Python FastAPI): Cognitive engine — memory (ChromaDB), planning, reflection, LLM orchestration, tool calling.
- **Body** (Godot 4): Thin client — rendering, pathfinding, UI. NPCs are stateless; they ask the Brain what to do.

## Project Structure

```
deeptown/
├── .env                         # API keys (gitignored)
├── data/
│   ├── npcs.json                # Lore definitions (tracked)
│   ├── player_profile.json      # Dynamic save (gitignored)
│   └── npc_data/                # Dynamic memories (gitignored)
├── backend/                     # Python context engine
│   ├── main.py                  # FastAPI entry point
│   ├── api/                     # Routers (/observe, /chat, /plan)
│   ├── memory/                  # ChromaDB interface
│   └── models/                  # Pydantic schemas
└── game/                        # Godot thin client
    ├── project.godot
    └── scripts/api_client.gd    # HTTP requests to localhost:8000
```

## Commands

```bash
# Backend
cd backend
pip install -r requirements.txt
uvicorn main:app --reload --port 8000

# Linting & types
ruff check .
mypy .

# Tests
pytest
pytest tests/test_memory.py -k "test_name"  # prefer single tests
```

## Architecture Rules

1. **Godot is dumb.** NPCs never make decisions locally. Every action originates from a Brain API response. If you're writing logic in GDScript that "decides" behavior, it belongs in Python instead.
2. **Context is king.** Every LLM prompt must inject: Tier 0 (core memory from `npcs.json`), Tier 1 (retrieved episodic memory from ChromaDB), and current state (needs, location, time).
3. **Tool calling for actions.** The LLM returns structured tool calls (e.g., `move_to("Tavern")`, `say("Hello")`) — Godot executes them. Never parse free-text for actions.
4. **Stateless API.** Each Brain endpoint receives full context in the request body. No server-side session state between calls.

## Data Storage

All dynamic data lives inside the project directory (`res://`), NOT in system AppData (`user://`). This keeps the project Git-friendly for students.

- `res://.env` — API keys
- `res://data/player_profile.json` — player save
- `res://data/npc_data/` — per-NPC memory files

IMPORTANT: `.env` and `data/` dynamic files are gitignored. Never commit API keys or save states.

## Code Style

### Python (Backend)
- Python 3.11+. Use type hints on all function signatures.
- Pydantic models for every API request/response — no raw dicts crossing API boundaries.
- Async endpoints in FastAPI. Use `async def` for all route handlers.
- Imports: standard lib → third-party → local, separated by blank lines.
- Docstrings on all public functions (one-liner is fine for simple ones).

### GDScript (Godot)
- snake_case for variables and functions, PascalCase for classes/nodes.
- All HTTP calls go through `api_client.gd` — no direct HTTP requests elsewhere.
- Signals for UI updates, never direct node references across scenes.

## LLM Integration

- Multi-model: OpenAI, Anthropic, Gemini via their Python SDKs.
- Model selection via `.env` config, not hardcoded.
- Embeddings: ChromaDB default or `text-embedding-3-small`.
- IMPORTANT: Always handle API errors gracefully with retries and fallback responses so the game doesn't freeze on LLM failures.

## Memory System (ChromaDB)

- One collection per NPC.
- Memories are timestamped and include importance scores (1–10).
- Retrieval uses recency + relevance + importance weighting.
- Reflection triggers after a threshold of accumulated importance.
- See `backend/memory/` for implementation details.

## When Working on This Project

- Before changing API contracts, check both `backend/models/` (Pydantic) AND `game/scripts/api_client.gd` — they must stay in sync.
- Run `pytest` after any backend change. Run `ruff check .` before committing.
- This is a teaching project. Prefer clarity over cleverness. Add comments explaining *why*, not *what*.
- Keep commits small and focused. One feature or fix per commit.