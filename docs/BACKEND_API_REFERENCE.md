# DeepTown Brain — Backend API Reference

> Comprehensive documentation for every route, model, algorithm, and configuration in the Python FastAPI backend.

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Architecture](#architecture)
4. [Configuration](#configuration)
5. [Data Models](#data-models)
6. [API Endpoints](#api-endpoints)
   - [Health Check](#health-check)
   - [Memory Endpoints](#memory-endpoints)
   - [Observe Endpoint](#observe-endpoint)
   - [Chat Endpoints](#chat-endpoints)
   - [Planning Endpoints](#planning-endpoints)
   - [Reflection Endpoint](#reflection-endpoint)
   - [Gossip Endpoints](#gossip-endpoints)
7. [Memory System (ChromaDB)](#memory-system-chromadb)
8. [LLM Integration](#llm-integration)
9. [Scoring & Retrieval Algorithms](#scoring--retrieval-algorithms)
10. [Memory Maintenance](#memory-maintenance)
11. [NPC Roster & World Data](#npc-roster--world-data)
12. [Error Handling & Fallbacks](#error-handling--fallbacks)
13. [File Structure](#file-structure)

---

## Overview

The DeepTown Brain is a **stateless FastAPI backend** that serves as the cognitive engine for NPC behavior in the DeepTown game. It implements the **Stanford Generative Agents** architecture:

- **Memory** — Three-tier memory system (Core, Episodic, Archival) stored in ChromaDB
- **Dialogue** — LLM-generated conversations between NPCs and with the player
- **Planning** — Three-level recursive daily planning (L1 day blocks, L2 hourly, L3 minute-level)
- **Reflection** — Two-step reflection process generating insights from accumulated experiences
- **Gossip** — Natural information diffusion between NPCs with hop tracking

**Key design principle:** Every API endpoint is **stateless**. The Godot client sends the full NPC state, game time, and context in every request. The backend never stores session state between calls.

**Total endpoints:** 27 routes across 6 routers + 1 root health check.

---

## Getting Started

### Prerequisites

- Python 3.11+
- A Gemini API key (set in `.env` at the project root)

### Installation

```bash
cd backend
pip install -r requirements.txt
```

### Running the Server

```bash
uvicorn backend.main:app --reload --port 8000
```

### Verifying

```bash
curl http://localhost:8000/health
# Returns: {"status": "ok"}

# Interactive API docs:
# http://localhost:8000/docs     (Swagger UI)
# http://localhost:8000/redoc    (ReDoc)
```

### Dependencies (`requirements.txt`)

| Package | Version | Purpose |
|---------|---------|---------|
| `fastapi` | >= 0.115.0 | Web framework |
| `uvicorn[standard]` | >= 0.32.0 | ASGI server |
| `pydantic` | >= 2.10.0 | Data validation |
| `pydantic-settings` | >= 2.7.0 | Settings from `.env` |
| `chromadb` | >= 0.6.0 | Vector database for memory |
| `python-dotenv` | >= 1.0.0 | Environment file loading |
| `google-generativeai` | >= 0.8.0 | Gemini SDK (unused — we use httpx directly) |
| `openai` | >= 1.60.0 | Future OpenAI support |
| `anthropic` | >= 0.40.0 | Future Anthropic support |
| `httpx` | >= 0.28.0 | HTTP client for Gemini API |
| `pytest` | >= 8.0.0 | Testing |
| `pytest-asyncio` | >= 0.25.0 | Async test support |
| `ruff` | >= 0.9.0 | Linting |

---

## Architecture

```
Godot Game (Body)                    Python Backend (Brain)
+------------------+                +-------------------------+
| ApiClient.gd     | -- HTTP/JSON --| FastAPI (main.py)       |
|                  |                |  /health                |
| npc_dialogue.gd  | --> /chat/*    |  /chat/greet            |
| npc_conversation |                |  /chat/reply            |
| npc_planner.gd   | --> /plan/*    |  /chat/end              |
| npc_reflection   | --> /reflect   |  /chat/npc-turn         |
| npc_gossip.gd    | --> /gossip/*  |  /chat/player-impact    |
| npc_perception   | --> /observe   |  /chat/npc-impact       |
| npc_controller   | --> /memory/*  |  /chat/npc-summary      |
+------------------+                |  /plan/daily            |
                                    |  /plan/decompose-l2     |
                                    |  /plan/decompose-l3     |
                                    |  /plan/react            |
                                    |  /reflect               |
                                    |  /gossip/pick           |
                                    |  /gossip/share          |
                                    |  /gossip/detect-mentions|
                                    |  /memory/{npc}/add      |
                                    |  /memory/{npc}/retrieve |
                                    |  /memory/{npc}/context  |
                                    |  /memory/{npc}/core     |
                                    |  /memory/{npc}/maintenance|
                                    |  /observe               |
                                    +-------------------------+
                                           |
                                    +------+------+
                                    | ChromaDB    |  (Vector DB)
                                    | data/       |  (JSON core memory)
                                    | Gemini API  |  (LLM + Embeddings)
                                    +-------------+
```

### Stateless Protocol

Every request includes the full context needed to generate a response:

- **`NPCState`** — NPC identity, job, personality, needs, location
- **`GameTimeInfo`** — Current game clock (total_minutes, hour, minute, day, season)
- **`RelationshipData`** — Trust/affection/respect scores and labels
- **Conversation history** — Array of `{speaker, text}` messages

The server reconstructs context from ChromaDB (memories, core memory) and the request body. It never caches NPC state between calls.

### CORS

All origins are allowed (`*`) since the Godot client connects from `localhost` during development.

### Startup Lifecycle

On startup (`lifespan` context manager):
1. Initializes persistent ChromaDB client at `data/chroma_db/`
2. Logs the configured LLM model and embedding model

---

## Configuration

**File:** `backend/config.py`

Settings are loaded from the `.env` file at the project root. Two formats are supported:

### Format 1: Standard KEY=VALUE
```env
GEMINI_API_KEY=AIzaSy...
```

### Format 2: Bare API Key (legacy GDScript format)
```
AIzaSy...
```

The `_load_api_key()` function detects the bare-key format and falls back to it when pydantic-settings doesn't find a `GEMINI_API_KEY=` entry.

### Settings Reference

| Setting | Default | Description |
|---------|---------|-------------|
| `gemini_api_key` | `""` | Gemini API key for LLM and embeddings |
| `llm_model` | `"gemini-2.5-flash"` | Primary LLM model for dialogue, planning, reflection |
| `llm_model_lite` | `"gemini-2.5-flash-lite"` | Cheaper model for impact analysis, decomposition |
| `llm_temperature` | `0.8` | LLM sampling temperature |
| `llm_max_tokens` | `256` | Max output tokens per generation |
| `embedding_model` | `"gemini-embedding-001"` | Embedding model for memory vectors |
| `embedding_dim` | `768` | Embedding vector dimensionality |
| `data_dir` | `"data"` | Base directory for all persistent data |
| `chroma_persist_dir` | `"data/chroma_db"` | ChromaDB persistence directory |

All settings can be overridden via environment variables (uppercase, e.g., `LLM_MODEL=gemini-2.0-flash`).

---

## Data Models

All request/response bodies use Pydantic models with strict validation. Models are defined in `backend/models/`.

### Shared Models

#### `NPCState` — Full NPC snapshot (`models/npc.py`)

Sent with every request to provide NPC identity context.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `npc_name` | `str` | required | NPC's display name (e.g., "Maria") |
| `job` | `str` | `""` | NPC's profession (e.g., "Baker") |
| `age` | `int` | `0` | NPC's age in years |
| `personality` | `str` | `""` | Multi-sentence personality description |
| `speech_style` | `str` | `""` | Speech mannerisms and vocabulary |
| `home_building` | `str` | `""` | NPC's home (e.g., "House 1") |
| `workplace_building` | `str` | `""` | NPC's workplace (e.g., "Bakery") |
| `current_destination` | `str` | `""` | Where the NPC is currently heading |
| `current_activity` | `str` | `""` | What the NPC is currently doing |
| `needs` | `NPCNeeds` | `{}` | Physiological needs (see below) |
| `game_time` | `int` | `0` | `GameClock.total_minutes` |
| `game_hour` | `int` | `0` | Current hour (0-23) |
| `game_minute` | `int` | `0` | Current minute (0-59) |
| `game_day` | `int` | `0` | Current day number |
| `game_season` | `str` | `"Spring"` | Current season |

#### `NPCNeeds` — Physiological needs

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| `hunger` | `float` | 0.0-100.0 | Food satisfaction (100 = full) |
| `energy` | `float` | 0.0-100.0 | Rest level (100 = rested) |
| `social` | `float` | 0.0-100.0 | Social fulfillment (100 = satisfied) |

#### `GameTimeInfo` — Game clock snapshot (`models/npc.py`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `total_minutes` | `int` | `0` | Absolute game minutes since start |
| `hour` | `int` | `0` | Current hour (0-23) |
| `minute` | `int` | `0` | Current minute (0-59) |
| `day` | `int` | `1` | Current day number |
| `season` | `str` | `"Spring"` | Current season |

#### `RelationshipData` — Relationship between two characters (`models/conversation.py`)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `trust` | `int` | `0` | Trust score (numeric) |
| `affection` | `int` | `0` | Affection score (numeric) |
| `respect` | `int` | `0` | Respect score (numeric) |
| `trust_label` | `str` | `"are neutral toward"` | Human-readable trust description |
| `affection_label` | `str` | `"feel nothing toward"` | Human-readable affection description |
| `respect_label` | `str` | `"have no opinion of"` | Human-readable respect description |
| `opinion_label` | `str` | `"are neutral toward"` | Overall opinion description |

#### `ChatMessage` — Single conversation message

| Field | Type | Description |
|-------|------|-------------|
| `speaker` | `str` | Who said it (NPC name or player name) |
| `text` | `str` | What was said |

### Memory Models (`models/memory.py`)

#### `CoreMemory` — Tier 0: Always-in-prompt context

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `identity` | `str` | `""` | NPC's self-description and core traits |
| `emotional_state` | `str` | `"Feeling neutral, starting the day."` | Current emotional state |
| `player_summary` | `str` | `""` | NPC's impression of the player |
| `npc_summaries` | `dict[str, str]` | `{}` | Impressions of other NPCs by name |
| `active_goals` | `list[str]` | `[]` | Current daily plan goals |
| `key_facts` | `list[str]` | `[]` | Important facts (max 10, FIFO) |

Stored as JSON at `data/npc_data/{npc_name}/core_memory.json`.

#### `EpisodicMemory` — Single memory record

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | `str` | `""` | Unique identifier (e.g., `"mem_0042"`) |
| `text` | `str` | `""` | Memory content |
| `description` | `str` | `""` | Backward-compat alias for `text` |
| `type` | `str` | `"observation"` | Memory type (see below) |
| `importance` | `float` | `5.0` | Importance score (1.0-10.0) |
| `emotional_valence` | `float` | `0.0` | Emotional charge (-1.0 to 1.0) |
| `entities` | `list[str]` | `[]` | People/things involved |
| `participants` | `list[str]` | `[]` | Direct participants |
| `location` | `str` | `""` | Where this happened |
| `observer_location` | `str` | `""` | Where the observer was |
| `observed_near` | `str` | `""` | What building was nearby |
| `timestamp` | `int` | `0` | Creation time (game minutes) |
| `game_time` | `int` | `0` | Same as timestamp (compat) |
| `game_day` | `int` | `0` | Day number when created |
| `game_hour` | `int` | `0` | Hour when created |
| `last_accessed` | `int` | `0` | Last retrieval time (game minutes) |
| `access_count` | `int` | `0` | Number of times retrieved |
| `observation_count` | `int` | `1` | Dedup counter |
| `stability` | `float` | `12.0` | Resistance to forgetting (hours) |
| `protected` | `bool` | `false` | Immune to forgetting curves |
| `superseded` | `bool` | `false` | Replaced by summary |
| `shared_with` | `list[str]` | `[]` | NPCs this was shared with as gossip |
| `source_memory_id` | `str` | `""` | Parent memory (for summaries) |
| `summary_level` | `int` | `0` | 0=raw, 1=episode summary, 2=period summary |
| `actor` | `str` | `""` | Primary actor in the memory |
| `gossip_source` | `str\|null` | `null` | Who shared this gossip |
| `gossip_hops` | `int\|null` | `null` | How many times relayed |
| `original_description` | `str\|null` | `null` | Original text before gossip |

**Memory types:** `observation`, `environment`, `conversation`, `dialogue`, `reflection`, `plan`, `gossip`, `gossip_heard`, `gossip_shared`, `player_dialogue`, `episode_summary`, `period_summary`

**Protected memories** (never decay): importance >= 8.0, `player_dialogue` type, `reflection` type, any summary.

### Planning Models (`models/planning.py`)

#### `PlanBlock` — Level 1 day block

| Field | Type | Description |
|-------|------|-------------|
| `start_hour` | `int` | Start hour (5-22) |
| `end_hour` | `int` | End hour (6-23) |
| `location` | `str` | Building name |
| `activity` | `str` | Activity description |
| `decomposed` | `bool` | Whether L2 decomposition exists |

#### `L2Step` — Level 2 hourly step

| Field | Type | Description |
|-------|------|-------------|
| `hour` | `int` | Hour (0-23) |
| `end_hour` | `int` | End hour |
| `activity` | `str` | Hourly activity |

#### `L3Step` — Level 3 minute-level action

| Field | Type | Description |
|-------|------|-------------|
| `start_min` | `int` | Start minute (0-59) |
| `end_min` | `int` | End minute (1-60) |
| `activity` | `str` | Specific action |

### Conversation Models (`models/conversation.py`)

#### `PlanEntry` — Plan context for dialogue prompts

| Field | Type | Description |
|-------|------|-------------|
| `start_hour` | `int` | Plan block start |
| `end_hour` | `int` | Plan block end |
| `activity` | `str` | Planned activity |
| `location` | `str` | Planned location |

#### `BuildingObject` — Interactive object state

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tile_type` | `str` | `""` | Object type (oven, counter, etc.) |
| `state` | `str` | `"idle"` | Current state |
| `user` | `str` | `""` | Who is using it |

#### `ImpactAnalysisResult` — Relationship change

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| `trust_change` | `int` | -5 to +5 | Trust delta |
| `affection_change` | `int` | -5 to +5 | Affection delta |
| `respect_change` | `int` | -5 to +5 | Respect delta |
| `emotional_state` | `str` | max 150 chars | New emotional state |
| `player_summary_update` | `str` | max 200 chars | Updated player impression |
| `key_fact` | `str` | max 100 chars | New key fact to remember |

---

## API Endpoints

### Health Check

#### `GET /health`

Basic health check. Always returns `200 OK`.

**Response:**
```json
{"status": "ok"}
```

---

### Memory Endpoints

**Router prefix:** `/memory`

#### `POST /memory/{npc_name}/add`

Add a new memory with automatic embedding generation.

**Path Parameters:**
| Param | Type | Description |
|-------|------|-------------|
| `npc_name` | `str` | NPC identifier (e.g., `"Maria"`) |

**Request Body (`MemoryAddRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC name (redundant with path, for compat) |
| `text` | `str` | yes | Memory text content |
| `type` | `str` | yes | Memory type (see types above) |
| `actor` | `str` | no | Primary actor |
| `participants` | `list[str]` | no | People involved |
| `observer_location` | `str` | no | Observer's location |
| `observed_near` | `str` | no | Nearby building |
| `importance` | `float` | yes | 1.0-10.0 importance score |
| `valence` | `float` | yes | -1.0 to 1.0 emotional valence |
| `game_time` | `int` | yes | Current `GameClock.total_minutes` |
| `game_day` | `int` | no | Day number (auto-calculated if 0) |
| `game_hour` | `int` | no | Hour (auto-calculated if 0) |
| `extra_fields` | `dict` | no | Additional metadata (gossip_source, gossip_hops, etc.) |

**Processing:**
1. Calculates `stability` from type + valence: `base_stability * (1.0 + abs(valence) * 3.0)`
2. Sets `protected = true` if importance >= 8.0 or type is `player_dialogue`/`reflection`
3. Generates embedding via Gemini Embedding API (768 dimensions)
4. Upserts into ChromaDB collection named after the NPC

**Response (`MemoryAddResponse`):**
```json
{
  "memory": { /* full EpisodicMemory object */ },
  "deduplicated": false
}
```

**Example:**
```bash
curl -X POST http://localhost:8000/memory/Maria/add \
  -H "Content-Type: application/json" \
  -d '{
    "npc_name": "Maria",
    "text": "Saw Thomas walking toward the General Store early this morning",
    "type": "observation",
    "actor": "Thomas",
    "participants": ["Thomas"],
    "observer_location": "Bakery",
    "observed_near": "General Store",
    "importance": 2.0,
    "valence": 0.0,
    "game_time": 360,
    "game_day": 1,
    "game_hour": 6
  }'
```

---

#### `POST /memory/{npc_name}/retrieve`

Retrieve memories by semantic query with hybrid re-ranking.

**Request Body (`MemoryRetrieveRequest`):**
| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `npc_name` | `str` | yes | — | NPC name |
| `query_text` | `str` | yes | — | Natural language query |
| `game_time` | `int` | yes | — | Current game time in minutes |
| `count` | `int` | no | `8` | Number of results to return |
| `type_filter` | `str` | no | `""` | Filter by memory type |
| `entity_filter` | `str` | no | `""` | Filter by entity (unused currently) |
| `time_range_hours` | `float` | no | `-1` | Only return memories from last N hours (-1 = no limit) |

**Processing:**
1. Embeds `query_text` via Gemini Embedding API
2. Queries ChromaDB for top 50 candidates (vector search, excluding `superseded=true`)
3. Re-ranks using **hybrid scoring formula** (see [Scoring & Retrieval Algorithms](#scoring--retrieval-algorithms))
4. Applies **testing effect** to retrieved memories (stability *= 1.1)
5. Updates `last_accessed` and `access_count` in ChromaDB

**Response (`MemoryRetrieveResponse`):**
```json
{
  "memories": [
    {
      "id": "mem_0042",
      "text": "Talked with the player about the harvest festival",
      "type": "dialogue",
      "importance": 6.0,
      ...
    }
  ]
}
```

---

#### `POST /memory/{npc_name}/context`

Assemble a formatted memory context string for prompt injection.

**Request Body (`MemoryContextRequest`):**
| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `npc_name` | `str` | yes | — | NPC name |
| `query_text` | `str` | yes | — | Retrieval query |
| `game_time` | `int` | yes | — | Current game time |
| `count` | `int` | no | `8` | Number of memories to include |

**Processing:**
1. Loads core memory from JSON
2. Retrieves episodic memories via semantic search
3. Formats as structured text:

```
=== WHO I AM ===
[identity text]
Current mood: [emotional_state]
What I know about the player: [player_summary]
About Thomas: [npc_summary]
Key things I know: [fact1, fact2, ...]

=== RELEVANT MEMORIES ===
[Day 3, Hour 14] Talked with Thomas about the new shipment
[Day 2, Hour 9] Saw Elena patrolling near the Bakery
```

**Response (`MemoryContextResponse`):**
```json
{
  "context": "=== WHO I AM ===\n...",
  "retrieved_count": 8
}
```

---

#### `GET /memory/{npc_name}/core`

Read the core memory (Tier 0) for an NPC.

**Response (`CoreMemory`):**
```json
{
  "identity": "I am Maria, the baker of DeepTown...",
  "emotional_state": "Feeling content after a productive morning",
  "player_summary": "A curious newcomer who seems friendly",
  "npc_summaries": {
    "Thomas": "My neighbor, reliable but quiet",
    "Rose": "Always cheerful, great to talk with"
  },
  "active_goals": [
    "Bake bread at Bakery (6:00-12:00)",
    "Visit Rose at Tavern (16:00-17:00)"
  ],
  "key_facts": [
    "Thomas mentioned a storm coming",
    "The player asked about Elena"
  ]
}
```

---

#### `PUT /memory/{npc_name}/core`

Update specific core memory fields. Only provided fields are updated; null fields are ignored.

**Request Body (`CoreMemoryUpdateRequest`):**
| Field | Type | Description |
|-------|------|-------------|
| `emotional_state` | `str\|null` | New emotional state |
| `player_summary` | `str\|null` | Updated player impression |
| `npc_summaries` | `dict\|null` | NPC impressions to merge (additive) |
| `active_goals` | `list[str]\|null` | Replace active goals |
| `key_facts` | `list[str]\|null` | Append new facts (max 10 total, FIFO) |

---

#### `POST /memory/{npc_name}/maintenance`

Run daily memory maintenance: forgetting curves + episode compression + period compression.

**Request Body (`MaintenanceRequest`):**
| Field | Type | Description |
|-------|------|-------------|
| `game_time` | `int` | Current game time in minutes |

**Processing:**
1. **Forgetting curves** — Decay stability for non-protected memories:
   - `observation`/`environment`: `stability *= 0.7` per day (if never accessed)
   - All other types: `stability *= 0.85` per day (if never accessed)
   - Protected memories are immune (importance >= 8, reflections, player_dialogue)
   - Memories with recency score < 0.05 are marked `effectively_forgotten`

2. **Episode compression** — If 10+ raw memories are candidates:
   - Takes oldest 30 non-protected, non-superseded, raw memories
   - Sends to LLM for 3-5 sentence summary
   - Creates `episode_summary` memory (summary_level=1, protected=true)
   - Deletes the original raw memories from ChromaDB

3. **Period compression** — If 10+ episode summaries exist:
   - Takes oldest 7 episode summaries
   - Sends to LLM for 2-3 sentence period summary
   - Creates `period_summary` memory (summary_level=2, protected=true)
   - Deletes the compressed episode summaries

**Response (`MaintenanceResponse`):**
```json
{
  "forgotten_count": 15,
  "compressed_count": 30,
  "period_summaries_created": 1
}
```

---

### Observe Endpoint

**Router:** root (no prefix)

#### `POST /observe`

Process an NPC observation and store it as a memory.

**Request Body (`ObserveRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_id` | `str` | yes | NPC identifier |
| `observation` | `str` | yes | What was observed |
| `game_time` | `int` | no | Current game time in minutes |
| `game_day` | `int` | no | Current day |
| `game_hour` | `int` | no | Current hour |

**Processing:**
1. Applies simple importance heuristics:
   - Default observation: importance = 2.0, valence = 0.0
   - Player-related: importance = 5.0, valence = 0.1
2. Calculates stability from type + valence
3. Generates embedding and stores in ChromaDB

**Response (`ObserveResponse`):**
```json
{
  "status": "ok",
  "importance": 2.0,
  "valence": 0.0
}
```

---

### Chat Endpoints

**Router prefix:** `/chat`

#### `POST /chat/greet`

Generate the NPC's initial greeting when the player approaches.

**Request Body (`PlayerChatRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC's name |
| `npc_state` | `NPCState` | yes | Full NPC state snapshot |
| `player_name` | `str` | yes | Player's name |
| `game_time` | `GameTimeInfo` | yes | Current game clock |
| `time_string` | `str` | no | Formatted time string |
| `relationship` | `RelationshipData` | no | Trust/affection/respect scores |
| `closest_friends` | `list[dict]` | no | NPC's closest friends with opinion labels |
| `building_objects` | `list[BuildingObject]` | no | Interactive objects in current building |
| `plans` | `list[PlanEntry]` | no | NPC's L1 daily plan |
| `schedule_destination` | `str` | no | Where NPC is scheduled to be |

**Processing:**
1. Loads core memory from JSON
2. Retrieves 8 memories using query: `"{npc_name} talking with {player_name} at the {destination}"`
3. Fetches up to 3 gossip memories about the player
4. Builds system prompt (NPC identity, personality, speech style, rules)
5. Builds user message (time, location, needs, relationship, memories, plans, building objects)
6. Generates response via Gemini API (main model, temp 0.8, max 256 tokens)
7. Stores dialogue memory: `"Talked with {player} at {location}. I said: {text[:80]}"` (importance=4.0)

**Response (`ChatResponse`):**
```json
{
  "response_text": "Good morning! Fresh bread just came out of the oven. What brings you by?",
  "success": true,
  "memory_created": true
}
```

---

#### `POST /chat/reply`

Generate NPC reply in a multi-turn player conversation.

**Request Body (`PlayerChatReplyRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC's name |
| `npc_state` | `NPCState` | yes | Full state snapshot |
| `player_name` | `str` | yes | Player's name |
| `player_message` | `str` | yes | What the player just said |
| `history` | `list[ChatMessage]` | no | Conversation so far |
| `game_time` | `GameTimeInfo` | yes | Current game clock |
| `time_string` | `str` | no | Formatted time |
| `relationship` | `RelationshipData` | no | Relationship scores |
| `building_objects` | `list[BuildingObject]` | no | Building objects |
| `plans` | `list[PlanEntry]` | no | NPC's daily plan |
| `schedule_destination` | `str` | no | Scheduled destination |

**Key difference from `/greet`:** Uses the player's actual message as the retrieval query for **targeted memory retrieval**, and includes conversation history in the prompt.

**Response (`ChatResponse`):**
```json
{
  "response_text": "Oh, Thomas? He mentioned something about a delivery yesterday...",
  "success": true,
  "memory_created": true
}
```

---

#### `POST /chat/end`

Summarize and store a completed player conversation.

**Request Body (`ConversationEndRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC's name |
| `npc_state` | `NPCState` | yes | Full state |
| `player_name` | `str` | yes | Player's name |
| `history` | `list[ChatMessage]` | no | Full conversation history |
| `game_time` | `GameTimeInfo` | yes | Current time |

**Processing:**
- **Short conversations (<=4 messages):** Simple concatenation of speaker/text pairs
- **Long conversations (>4 messages):** LLM-generated summary via Gemini

The summary is stored as a `dialogue` memory with importance=8.0 (protected).

**Response (`ConversationEndResponse`):**
```json
{
  "summary": "Had a warm conversation with the player about the upcoming festival. They asked about Thomas and I shared what I knew.",
  "success": true
}
```

---

#### `POST /chat/npc-turn`

Generate a single turn in an NPC-to-NPC autonomous conversation.

**Request Body (`NPCChatRequest`):**
| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `speaker_name` | `str` | yes | — | Who is speaking this turn |
| `speaker_state` | `NPCState` | yes | — | Speaker's full state |
| `listener_name` | `str` | yes | — | Who is listening |
| `listener_state` | `NPCState` | yes | — | Listener's full state |
| `topic` | `str` | yes | — | Conversation topic |
| `history` | `list[ChatMessage]` | no | `[]` | Prior turns |
| `turn` | `int` | no | `0` | Current turn number (0-indexed) |
| `max_turns` | `int` | no | `6` | Maximum turns before forced end |
| `game_time` | `GameTimeInfo` | yes | — | Current time |
| `relationship` | `RelationshipData` | no | `{}` | Speaker's relationship to listener |

**Processing:**
1. Loads speaker's core memory
2. Retrieves 3 memories using last conversation line (or topic if first turn)
3. Builds NPC-specific system prompt and context
4. Generates single line of dialogue (max 120 chars, quotes stripped)
5. Detects farewell keywords: "goodbye", "see you", "take care", "farewell"
6. Returns `should_end=true` if max turns reached or farewell detected (after minimum 2 turns)

**Response (`NPCChatResponse`):**
```json
{
  "line": "I heard the player was asking about the old mine. Interesting, right?",
  "should_end": false,
  "success": true
}
```

---

#### `POST /chat/player-impact`

Analyze how a player conversation exchange affects the NPC's feelings.

**Request Body (`PlayerImpactRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC's name |
| `npc_state` | `NPCState` | yes | Full state |
| `player_name` | `str` | yes | Player's name |
| `player_message` | `str` | yes | What the player said |
| `npc_response` | `str` | yes | What the NPC replied |
| `game_time` | `GameTimeInfo` | yes | Current time |
| `relationship` | `RelationshipData` | no | Current relationship |

**Processing:**
1. Sends exchange to Flash Lite model with structured JSON output prompt
2. Parses trust/affection/respect changes (clamped to -5 to +5)
3. Extracts emotional state, player summary update, and key fact
4. **Updates core memory server-side:** emotional state, player summary, key facts
5. Returns changes for Godot to apply to the Relationships system

**Response (`ImpactAnalysisResult`):**
```json
{
  "trust_change": 2,
  "affection_change": 1,
  "respect_change": 0,
  "emotional_state": "Feeling appreciated after the kind words",
  "player_summary_update": "A friendly newcomer who cares about the town",
  "key_fact": "The player is interested in the harvest festival"
}
```

**On failure:** Returns `{"trust_change": 1, "affection_change": 1}` (small positive bias).

---

#### `POST /chat/npc-impact`

Analyze bidirectional relationship impact of an NPC-NPC conversation.

**Request Body (`NPCImpactRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `speaker_name` | `str` | yes | Speaker name |
| `listener_name` | `str` | yes | Listener name |
| `speaker_line` | `str` | yes | What speaker said |
| `listener_line` | `str` | yes | What listener replied |
| `current_relationship` | `dict` | no | Current relationship data |
| `game_time` | `GameTimeInfo` | yes | Current time |

**Response (`NPCImpactResponse`):**
```json
{
  "a_to_b": {
    "trust_change": 1,
    "affection_change": 2,
    "respect_change": 0
  },
  "b_to_a": {
    "trust_change": 1,
    "affection_change": 1,
    "respect_change": 1
  }
}
```

Changes are clamped to -3 to +3 for NPC-NPC interactions (smaller range than player).

---

#### `POST /chat/npc-summary`

Update one NPC's impression of another after conversation.

**Query Parameters:**
| Param | Type | Description |
|-------|------|-------------|
| `npc_name` | `str` | The NPC updating their impression |
| `other_name` | `str` | The NPC they're forming an impression of |
| `my_line` | `str` | What I said |
| `their_line` | `str` | What they said |

**Processing:**
1. Loads existing impression from core memory's `npc_summaries`
2. Sends old impression + new exchange to Flash Lite
3. Updates `npc_summaries[other_name]` in core memory
4. Saves core memory

**Response (`ChatResponse`):**
```json
{
  "response_text": "Thomas seems more worried than usual lately, but still dependable",
  "success": true
}
```

---

### Planning Endpoints

**Router prefix:** `/plan`

#### `POST /plan/daily`

Generate a Level 1 daily plan (5-8 activity blocks covering hours 5-22).

**Request Body (`PlanRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC name |
| `npc_state` | `NPCState` | yes | Full NPC state |
| `game_time` | `GameTimeInfo` | yes | Current game time |
| `reflections` | `list[str]` | no | Up to 3 recent reflection texts |
| `relationships` | `dict[str, str]` | no | `{name: opinion_label}` |
| `gossip` | `list[str]` | no | Up to 3 recent gossip texts |
| `recent_events` | `list[str]` | no | Up to 5 recent memory texts |
| `npc_summaries` | `dict[str, str]` | no | Impressions of other NPCs |
| `player_name` | `str` | no | Player's name |
| `player_summary` | `str` | no | NPC's impression of player |
| `world_description` | `str` | no | Known buildings/areas |

**Processing:**
1. Builds system prompt with NPC identity, personality, workplace, home, building list, NPC roster
2. Builds user message with reflections, relationships, gossip, events, summaries, world knowledge
3. Generates plan via Gemini main model
4. Parses `START-END|LOCATION|ACTIVITY` format lines
5. Validates building names via fuzzy matching against 18 valid buildings
6. Caps at 8 blocks, sorts by start hour
7. Stores plan as memory (importance=4.0)
8. Updates `active_goals` in core memory

**LLM output format expected:**
```
5-6|House 1|Wake up, have breakfast
6-12|Bakery|Morning work baking bread
12-13|House 1|Lunch break at home
13-16|Bakery|Afternoon baking and customers
16-17|Tavern|Visit Rose for a drink
17-20|Tavern|Evening socializing
20-22|House 1|Dinner and winding down
```

**Fuzzy building matching:** `"the bakery"` matches `"Bakery"`, `"gen store"` matches `"General Store"`, etc.

**Response (`PlanResponse`):**
```json
{
  "plan_level1": [
    {"start_hour": 5, "end_hour": 6, "location": "House 1", "activity": "Wake up, have breakfast", "decomposed": false},
    {"start_hour": 6, "end_hour": 12, "location": "Bakery", "activity": "Morning baking", "decomposed": false}
  ],
  "success": true
}
```

---

#### `POST /plan/decompose-l2`

Decompose a Level 1 block into hourly Level 2 steps.

**Request Body (`DecomposeL2Request`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC name |
| `npc_state` | `NPCState` | yes | Full NPC state |
| `block` | `PlanBlock` | yes | The L1 block to decompose |
| `game_time` | `GameTimeInfo` | yes | Current time |

**Processing:**
- **Single-hour blocks:** Returns the block as-is (no decomposition needed)
- **Multi-hour blocks:** Sends to Flash Lite model with format `HOUR|ACTIVITY`
- **Fallback:** One entry per hour with the L1 activity repeated

**Example prompt:** "You are Maria, a Baker (cheerful, early riser). Break this 6-hour activity block into hourly steps."

**Response (`DecomposeL2Response`):**
```json
{
  "steps": [
    {"hour": 6, "end_hour": 7, "activity": "Open the bakery and light the ovens"},
    {"hour": 7, "end_hour": 8, "activity": "Knead dough for the day's bread"},
    {"hour": 8, "end_hour": 9, "activity": "Shape loaves and put them in the oven"}
  ],
  "success": true
}
```

---

#### `POST /plan/decompose-l3`

Decompose an hourly L2 step into 5-20 minute Level 3 actions.

**Request Body (`DecomposeL3Request`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC name |
| `npc_state` | `NPCState` | yes | Full NPC state |
| `hour` | `int` | yes | The hour being decomposed |
| `location` | `str` | yes | Building name |
| `activity` | `str` | yes | L2 activity text |
| `game_time` | `GameTimeInfo` | yes | Current time |

**Processing:**
- Sends to Flash Lite with format `START_MIN-END_MIN|ACTION`
- Caps at 6 actions, sorts by start minute
- **Fallback:** Single entry `0-60|{activity}`

**Response (`DecomposeL3Response`):**
```json
{
  "steps": [
    {"start_min": 0, "end_min": 10, "activity": "Unlock the bakery door"},
    {"start_min": 10, "end_min": 30, "activity": "Prepare the dough"},
    {"start_min": 30, "end_min": 50, "activity": "Shape individual loaves"},
    {"start_min": 50, "end_min": 60, "activity": "Clean up the workspace"}
  ],
  "success": true
}
```

---

#### `POST /plan/react`

Evaluate whether an NPC should abandon their current plan to react to an observation.

**Request Body (`ReactionRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC name |
| `npc_state` | `NPCState` | yes | Full state |
| `observation` | `str` | yes | What was observed |
| `importance` | `float` | yes | Observation importance (1-10) |
| `current_activity` | `str` | yes | What NPC is currently doing |
| `current_destination` | `str` | yes | Where NPC currently is |
| `game_time` | `GameTimeInfo` | yes | Current time |

**Processing:**
1. Sends to Flash Lite with `CONTINUE` or `REACT|LOCATION|NEW_ACTIVITY` format
2. Parses response, fuzzy-matches location
3. If `REACT`: stores reaction memory (importance=4.0) and returns new location/activity
4. If `CONTINUE`: returns action="CONTINUE"

**Response (`ReactionResponse`):**
```json
{
  "action": "REACT",
  "new_location": "Tavern",
  "new_activity": "Rush to check on the commotion",
  "success": true
}
```

or:
```json
{
  "action": "CONTINUE",
  "new_location": "",
  "new_activity": "",
  "success": true
}
```

---

### Reflection Endpoint

**Router prefix:** `/reflect`

#### `POST /reflect`

Run Stanford two-step reflection for an NPC. This is the most computationally expensive endpoint — it makes 1 + N LLM calls (where N is the number of questions generated, typically 5).

**Request Body (`ReflectRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC name |
| `npc_state` | `NPCState` | yes | Full state |
| `game_time` | `GameTimeInfo` | yes | Current time |

**Processing (Two-Step Stanford Reflection):**

**Step 1: Question Generation**
1. Gathers 100 most recent non-reflection, non-superseded memories from ChromaDB
2. Requires minimum 10 memories to proceed
3. Sends full memory list to Gemini with prompt:
   > "Given these recent experiences of {name}, what are the 5 most salient high-level questions we can answer about the subjects in the statements?"
4. Parses 5 numbered questions

**Step 2: Insight Generation (per question)**
1. Extracts keywords from question (filtering stop words)
2. Retrieves up to 10 relevant memories via keyword matching
3. Sends question + relevant memories to Gemini:
   > "What 5 high-level insights can you infer? Write each as a 1-2 sentence personal reflection in first person as {name}."
4. Parses up to 5 insights per question
5. Strips citation markers like `(because of 1, 3, 5)`
6. Stores each insight as a `reflection` memory (importance=7.0, protected=true)
7. Generates embedding for each reflection

**Post-processing:**
- Updates `emotional_state` in core memory to the last generated insight (max 150 chars)
- Saves core memory

**Response (`ReflectResponse`):**
```json
{
  "insights": [
    "I've been spending more time with Thomas lately. I think our friendship is growing stronger.",
    "The player's questions about the old mine make me wonder if they know something we don't.",
    "Rose always brightens my day. I should visit the Tavern more often."
  ],
  "questions_generated": 5,
  "success": true
}
```

**Typical LLM calls:** 6 total (1 question generation + 5 insight generations)

---

### Gossip Endpoints

**Router prefix:** `/gossip`

#### `POST /gossip/pick`

Select an interesting memory to share as gossip with another NPC.

**Request Body (`GossipPickRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `npc_name` | `str` | yes | NPC who might share gossip |
| `other_npc_name` | `str` | yes | NPC they'd share with |
| `trust_score` | `float` | yes | Trust toward the other NPC |
| `game_time` | `int` | yes | Current game time in minutes |

**Processing:**
1. **Trust gate:** Returns `should_share=false` if trust < 15.0
2. **Random chance:** 20% chance of sharing (returns false 80% of the time)
3. **Candidate filtering:** Searches all memories for:
   - Recent enough: < 48 hours old
   - Important enough: importance >= 3.0
   - About a third party: actor is neither self nor the other NPC
   - Not already shared with this NPC
   - Not gossip originally from this NPC
   - Other NPC is not a participant
   - Type is one of: observation, dialogue, environment, reflection, gossip
4. **Ranking:** Sorts by `importance * 0.98^hours_ago` (juiciest recent memory first)

**Response (`GossipPickResponse`):**
```json
{
  "memory": {
    "id": "mem_0023",
    "text": "Saw Thomas arguing with Elena near the Sheriff Office",
    "importance": 6.0,
    "actor": "Thomas",
    ...
  },
  "should_share": true
}
```

or:
```json
{
  "memory": null,
  "should_share": false
}
```

---

#### `POST /gossip/share`

Execute the gossip sharing between two NPCs. Creates memories for both parties.

**Request Body (`GossipShareRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sharer_name` | `str` | yes | NPC sharing the gossip |
| `receiver_name` | `str` | yes | NPC receiving the gossip |
| `memory_text` | `str` | yes | Original memory text being shared |
| `memory_importance` | `float` | yes | Original importance |
| `memory_valence` | `float` | yes | Original emotional valence |
| `memory_actor` | `str` | no | Who the gossip is about |
| `gossip_hops` | `int` | no | Current hop count (0 = first-hand) |
| `game_time` | `int` | yes | Current game time |

**Processing:**
1. **Hop check:** Blocks if `gossip_hops + 1 > 3` (max 3 hops)
2. **Formats gossip description:**
   - First-hand (hop 1): `"{sharer} told me: {text}"`
   - Second-hand+ (hop 2+): `"{sharer} mentioned that they heard: {text}"`
3. **Importance decay:** `max(importance - (hops * 1.0), 2.0)` — gossip loses 1.0 importance per hop (minimum 2.0)
4. **Creates receiver memory:** Type `gossip`, with `gossip_source` and `gossip_hops` metadata
5. **Creates sharer memory:** Type `gossip_shared`, `"Told {receiver} about {text[:60]}"` (importance=2.0)
6. **Marks shared:** Updates `shared_with` array in sharer's original memory

**Gossip constants:**

| Constant | Value | Description |
|----------|-------|-------------|
| `GOSSIP_TRUST_THRESHOLD` | 15.0 | Minimum trust to gossip |
| `GOSSIP_CHANCE` | 0.2 | 20% chance per conversation |
| `GOSSIP_MIN_IMPORTANCE` | 3.0 | Minimum importance to share |
| `GOSSIP_MAX_AGE_HOURS` | 48 | Max age of shareable memories |
| `GOSSIP_MAX_HOPS` | 3 | Max propagation depth |

**Response (`GossipShareResponse`):**
```json
{"success": true}
```

---

#### `POST /gossip/detect-mentions`

Scan dialogue text for mentions of third-party NPCs or the player. Creates gossip memories for the listener.

**Request Body (`GossipDetectRequest`):**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `speaker_name` | `str` | yes | Who is speaking |
| `line_text` | `str` | yes | The dialogue text to scan |
| `listener_name` | `str` | yes | Who is listening |
| `all_npc_names` | `list[str]` | no | All NPC names in the game |
| `player_name` | `str` | no | Player's name |
| `game_time` | `int` | yes | Current game time |

**Processing:**
1. Filters out speaker and listener from names to check
2. Case-insensitive scan of `line_text` for each name
3. For each mention found:
   - Creates `gossip` memory for listener: `"{speaker} mentioned {name}: "{line}""` (max 200 chars)
   - Importance: 4.0 for player mentions, 3.0 for NPC mentions
   - Sets `gossip_source = speaker_name`, `gossip_hops = 1`

**Response (`GossipDetectResponse`):**
```json
{
  "mentions": [
    {
      "mentioned_name": "Thomas",
      "importance": 3.0,
      "description": "Maria mentioned Thomas: \"I saw Thomas near the mine earlier\""
    }
  ]
}
```

---

## Memory System (ChromaDB)

**File:** `backend/memory/chroma_store.py`

### Storage Structure

- **Persistence directory:** `data/chroma_db/`
- **One collection per NPC:** Collection name is lowercase NPC name with spaces replaced by underscores (e.g., `"old_silas"`)
- **Distance metric:** L2 (Euclidean) via `hnsw:space = "l2"`
- **Core memory:** Stored as JSON files at `data/npc_data/{npc_name}/core_memory.json`

### ChromaDB Metadata

ChromaDB only stores flat scalar values. Complex fields are serialized:

| Field | Storage | Notes |
|-------|---------|-------|
| `entities` | JSON string | `'["Maria", "Thomas"]'` |
| `participants` | JSON string | Same format |
| `shared_with` | JSON string | Same format |
| All others | Native types | int, float, str, bool |

### Embedding Generation

- **Model:** `gemini-embedding-001`
- **Dimensions:** 768
- **API:** Direct HTTP to `generativelanguage.googleapis.com/v1beta/`
- **Timeout:** 10 seconds per single embed, 30 seconds per batch
- **Fallback:** If embedding fails, memory is stored without vector (keyword-only search)

### Deduplication

Text similarity is checked via word overlap (Jaccard index):
```python
intersection / union >= 0.85  # 85% word overlap = duplicate
```

---

## LLM Integration

**File:** `backend/llm/client.py`

### Models Used

| Model | Config Key | Use Cases |
|-------|-----------|-----------|
| `gemini-2.5-flash` | `llm_model` | Dialogue, planning (L1), reflection |
| `gemini-2.5-flash-lite` | `llm_model_lite` | Impact analysis, decomposition (L2/L3), reaction evaluation |

### Generation Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Temperature | 0.8 | Configurable via `llm_temperature` |
| Max tokens | 256 | Configurable via `llm_max_tokens` |
| Thinking budget | 0 | Disabled for main model (`thinkingConfig.thinkingBudget = 0`) |

### API Integration

- **Direct HTTP** via `httpx.AsyncClient` (not the google-generativeai SDK)
- **Timeout:** 15 seconds per generation request
- **Retry:** None currently (single attempt)
- **Error handling:** Returns `("", False)` on any failure — never raises exceptions

### Functions

| Function | Model | Description |
|----------|-------|-------------|
| `generate(system, user, model?, max_tokens?, temp?)` | Configurable | Main generation, returns `(text, success)` |
| `generate_lite(system, user, max_tokens?)` | Flash Lite | Wrapper for cheaper model |
| `embed_text(text)` | Embedding model | Single text -> 768-dim vector |
| `embed_batch(texts)` | Embedding model | Batch embed multiple texts |
| `parse_json_response(text)` | — | Strip markdown fences, parse JSON |

### Prompt Templates

**File:** `backend/llm/prompts.py`

All prompts are faithful ports of the original GDScript templates. Key prompt builders:

| Function | Used By | Description |
|----------|---------|-------------|
| `build_system_prompt()` | `/chat/greet`, `/chat/reply` | NPC identity, personality, speech rules |
| `build_dialogue_context()` | `/chat/greet` | Time, location, needs, relationships, memories |
| `build_reply_with_history()` | `/chat/reply` | Same + conversation history + player message |
| `build_player_impact_prompt_with_summary()` | `/chat/player-impact` | Trust/affection/respect JSON analysis |
| `build_conversation_summary_prompt()` | `/chat/end` | Summarize full conversation |
| `build_npc_chat_system_prompt()` | `/chat/npc-turn` | NPC-NPC system prompt |
| `build_npc_chat_context_for_turn()` | `/chat/npc-turn` | Per-turn context with history |
| `build_npc_impact_prompt()` | `/chat/npc-impact` | Bidirectional relationship JSON |
| `build_npc_summary_update_prompt()` | `/chat/npc-summary` | Update NPC impression |

---

## Scoring & Retrieval Algorithms

**File:** `backend/memory/scoring.py`

### Hybrid Scoring Formula

Every memory retrieval uses this formula:

```
score = 0.5 * relevance + 0.3 * recency + 0.2 * importance
```

| Component | Weight | Range | Calculation |
|-----------|--------|-------|-------------|
| Relevance | 0.5 | [0, 1] | Cosine similarity normalized: `(cos_sim + 1) / 2` |
| Recency | 0.3 | [0, 1] | Power-law decay: `(1 + 0.234 * hours / stability)^(-0.5)` |
| Importance | 0.2 | [0, 1] | `importance / 10.0` |

**Archival boost:** Summaries (summary_level > 0) get a 1.1x multiplier on the final score.

### ChromaDB Distance to Similarity

ChromaDB returns L2 distance. Conversion to cosine similarity:
```
cos_sim = 1.0 - (distance^2) / 2.0    # For normalized embeddings
relevance = (cos_sim + 1.0) / 2.0      # Normalize to [0, 1]
```

### Recency Decay

Power-law decay based on stability (in hours):
```
recency = (1 + 0.234 * hours_elapsed / stability)^(-0.5)
```

Higher stability = slower decay. Examples:
- Observation (stability=6h): 50% recency after ~25 hours
- Reflection (stability=72h): 50% recency after ~300 hours
- Period summary (stability=336h): 50% recency after ~1400 hours

### Stability by Memory Type

| Type | Base Stability (hours) | Description |
|------|----------------------|-------------|
| `observation` | 6 | Quick sensory observations |
| `environment` | 6 | Environmental state changes |
| `conversation` | 24 | Overheard conversation |
| `dialogue` | 24 | Direct conversation |
| `reflection` | 72 | Generated insight |
| `plan` | 12 | Daily plan |
| `gossip` | 18 | Heard gossip |
| `gossip_shared` | 12 | Shared gossip |
| `player_dialogue` | 48 | Conversation with player |
| `episode_summary` | 168 | Compressed episode (1 week) |
| `period_summary` | 336 | Compressed period (2 weeks) |

**Emotional amplification:** `final_stability = base * (1.0 + abs(valence) * 3.0)`, capped at 500.

### Testing Effect

Retrieved memories get stronger: `stability *= 1.1` (capped at 500).

### Keyword Fallback

When embedding fails, a keyword-based scoring fallback is used:
```
relevance = matching_keywords / total_keywords
```

The rest of the formula is identical.

---

## Memory Maintenance

**File:** `backend/memory/forgetting.py`, `backend/memory/compression.py`

### Daily Forgetting Curves

Applied via `/memory/{npc}/maintenance`:

| Memory Type | Decay Rate | Condition |
|-------------|-----------|-----------|
| observation, environment | 0.7 per day | Only if `access_count == 0` |
| All others | 0.85 per day | Only if `access_count == 0` |
| Protected (importance >= 8, reflections, player_dialogue) | No decay | Always immune |

Minimum stability: 1.0 (never goes to zero).

**Effectively forgotten:** When `recency < 0.05`, the memory is marked `effectively_forgotten = true`.

### Episode Compression

Triggered when 10+ non-protected raw memories accumulate:

1. Takes oldest 30 candidates (non-protected, non-superseded, summary_level=0)
2. LLM prompt: "Summarize these memories into a dense 3-5 sentence paragraph. PRESERVE relationship changes, emotional peaks, promises. COMPRESS AWAY routine activities."
3. Creates `episode_summary` (summary_level=1, protected=true)
4. Deletes original memories from ChromaDB

### Period Compression

Triggered when 10+ episode summaries accumulate:

1. Takes oldest 7 episode summaries
2. LLM prompt: "Compress into a single 2-3 sentence period summary"
3. Creates `period_summary` (summary_level=2, protected=true)
4. Deletes compressed episodes

---

## NPC Roster & World Data

### NPC Roster (hardcoded in `backend/api/plan.py`)

Used in planning prompts to prevent the LLM from hallucinating names:

| Name | Job | Workplace | Home |
|------|-----|-----------|------|
| Maria | Baker | Bakery | House 1 |
| Thomas | Shopkeeper | General Store | House 2 |
| Elena | Sheriff | Sheriff Office | House 3 |
| Gideon | Blacksmith | Blacksmith | House 4 |
| Rose | Barmaid | Tavern | House 5 |
| Lyra | Clerk | Courthouse | House 6 |
| Finn | Farmer/laborer | General Store | House 7 |
| Clara | Churchgoer | Church | House 7 |
| Bram | Apprentice | Blacksmith | House 8 |
| Old Silas | Retired storyteller | Tavern | House 9 |
| Father Aldric | Priest | Church | House 10 |

### Valid Buildings

Used for fuzzy matching in plan parsing and reaction evaluation:

```
Bakery, General Store, Tavern, Church, Sheriff Office, Courthouse, Blacksmith,
House 1, House 2, House 3, House 4, House 5, House 6, House 7, House 8,
House 9, House 10, House 11
```

---

## Error Handling & Fallbacks

### LLM Failure

Every LLM call returns `(text, success)`. On failure (`success=False`):

| Endpoint | Fallback |
|----------|----------|
| `/chat/greet` | Returns `{"success": false}` — Godot shows template response |
| `/chat/reply` | Returns `{"success": false}` — Godot shows template response |
| `/chat/end` | Uses simple concatenation summary |
| `/chat/npc-turn` | Returns `"Interesting weather we're having."` |
| `/chat/player-impact` | Returns `{"trust_change": 1, "affection_change": 1}` (small positive) |
| `/chat/npc-impact` | Returns small positive changes for both directions |
| `/plan/daily` | Returns `{"success": false}` — Godot generates fallback plan |
| `/plan/decompose-l2` | Returns one entry per hour with L1 activity |
| `/plan/decompose-l3` | Returns single `0-60` entry with L2 activity |
| `/plan/react` | Returns `"CONTINUE"` |
| `/reflect` | Returns `{"success": false}` |

### Embedding Failure

If the Gemini Embedding API fails:
- Memory is still stored in ChromaDB (without embedding vector)
- Retrieval falls back to keyword-based scoring

### Backend Unavailable

The Godot client (`scripts/core/api_client.gd`) checks `ApiClient.is_available()` before every call. If the backend is unreachable, all GDScript files fall back to local GeminiClient calls (direct Gemini API from GDScript).

---

## File Structure

```
backend/
├── __init__.py
├── main.py                  # FastAPI app, CORS, lifespan, router registration
├── config.py                # Settings from .env (pydantic-settings)
├── requirements.txt         # Python dependencies
│
├── api/                     # Route handlers
│   ├── __init__.py
│   ├── chat.py              # 7 endpoints: greet, reply, end, npc-turn, player-impact, npc-impact, npc-summary
│   ├── gossip.py            # 3 endpoints: pick, share, detect-mentions
│   ├── memory.py            # 5 endpoints: add, retrieve, context, core (GET/PUT), maintenance
│   ├── observe.py           # 1 endpoint: observe
│   ├── plan.py              # 4 endpoints: daily, decompose-l2, decompose-l3, react
│   └── reflect.py           # 1 endpoint: reflect
│
├── llm/                     # LLM integration
│   ├── __init__.py
│   ├── client.py            # Gemini API wrapper (generate, embed, parse JSON)
│   └── prompts.py           # All prompt templates (faithful GDScript port)
│
├── memory/                  # Memory subsystem
│   ├── __init__.py
│   ├── chroma_store.py      # ChromaDB operations (add, retrieve, context assembly, core memory I/O)
│   ├── scoring.py           # Hybrid scoring formula, stability, testing effect, keywords
│   ├── forgetting.py        # Daily forgetting curves
│   └── compression.py       # Episode/period compression prompts and helpers
│
└── models/                  # Pydantic schemas
    ├── __init__.py
    ├── memory.py            # CoreMemory, EpisodicMemory, Memory API request/response
    ├── npc.py               # NPCState, NPCNeeds, GameTimeInfo, ObserveRequest/Response
    ├── conversation.py      # Chat messages, relationship data, all chat request/response models
    └── planning.py          # Plan blocks, L2/L3 steps, reflection, gossip request/response models
```

### Data Directory (gitignored)

```
data/
├── chroma_db/               # ChromaDB persistence (auto-created)
│   ├── maria/               # One collection per NPC
│   ├── thomas/
│   └── ...
├── npc_data/
│   ├── Maria/
│   │   └── core_memory.json # Tier 0 core memory
│   ├── Thomas/
│   │   └── core_memory.json
│   └── ...
├── player_profile.json      # Player save data
└── relationships.json       # Relationship scores
```
