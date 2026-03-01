# PROJECT: DeepTown — A Dwarf Fortress-Depth 2D Town Simulation

## Vision
A top-down 2D pixel-art town simulation (GBA Pokemon aesthetic) with Dwarf Fortress-level depth. Every NPC has memory, relationships, schedules, opinions, and agency. The town has working law, crime, courts, economy, and reputation. LLMs power NPC dialogue and decision-making. Built in **Godot 4 (GDScript)**.

## Tech Stack
- **Engine:** Godot 4.x (GDScript only, no C#)
- **Art Style:** 16x16 or 32x32 pixel tiles, top-down GBA Pokemon style
- **LLM Integration:** Gemini API for NPC dialogue and dynamic decision-making
- **Target:** Desktop (Windows/Linux/Mac)

## Architecture Principles
- **Data-driven:** NPCs, items, buildings, laws, jobs defined in JSON/Resource files — NOT hardcoded
- **ECS-inspired:** Use Godot nodes as components. NPCs are scenes composed of: `AIBrain`, `Memory`, `Relationships`, `Needs`, `Schedule`, `Inventory`, `Reputation`
- **Simulation-first:** The world ticks forward even offscreen. NPCs act whether the player sees them or not
- **Memory is sacred:** Every NPC remembers every interaction, witnessed event, and rumor. Memory fades over time but never fully disappears. Use weighted memory with recency bias

## Project Structure
```
deeptown/
├── CLAUDE.md
├── project.godot
├── assets/
│   ├── sprites/          # Character spritesheets, tilesets
│   ├── audio/            # SFX, ambient
│   └── fonts/            # Pixel fonts
├── scenes/
│   ├── world/            # Town map, buildings, interiors
│   ├── npcs/             # NPC base scene + variants
│   ├── ui/               # HUD, dialogue, court UI, reputation screen
│   └── systems/          # Autoloads and system scenes
├── scripts/
│   ├── core/             # GameClock, EventBus, SaveManager
│   ├── npc/              # AIBrain, Memory, Relationships, Schedule, Needs
│   ├── systems/          # CrimeSystem, CourtSystem, EconomySystem, ReputationSystem
│   ├── world/            # BuildingManager, WeatherSystem, TileInteraction
│   ├── player/           # PlayerController, PlayerInventory, PlayerActions
│   └── llm/              # GeminiClient, PromptBuilder, ResponseParser
├── data/
│   ├── npcs.json         # NPC definitions (name, job, personality, relationships)
│   ├── buildings.json    # Building types, interiors, functions
│   ├── items.json        # All items in the game
│   ├── laws.json         # Town laws and penalties
│   ├── jobs.json         # Job definitions, schedules, pay
│   └── dialogue/         # Dialogue templates and prompt contexts
└── docs/
    ├── DESIGN.md          # Full game design document
    ├── SYSTEMS.md         # Deep dive into each simulation system
    └── ROADMAP.md         # Development phases and milestones
```

## Core Systems (Priority Order)

### 1. Game Clock & Time
- 1 real second = ~1 game minute (configurable)
- Day/night cycle affects NPC behavior, shop hours, crime rates
- Seasons affect mood, events, economy
- Time drives EVERYTHING — schedules, needs decay, memory fade, crop growth

### 2. NPC System (The Heart of the Game)

#### Inspired by: Stanford "Generative Agents" Paper (Park et al., 2023)
The NPCs use an architecture based on the Stanford Generative Agents research, where 25 AI agents in a 2D pixel world autonomously formed relationships, threw parties, and coordinated complex social behavior — all emergently from memory, reflection, and planning loops. Our system adapts this for a game context.

Each NPC has:
- **Identity:** Name, age, gender, job, personality traits (brave, greedy, kind, lazy, etc.), a 2-3 sentence core description ("Maria is the town baker. She is warm but gossips too much. She secretly resents the mayor for raising her rent.")
- **Needs:** Hunger, energy, social, happiness, safety — decay over time, drive behavior
- **Mood:** Computed from needs + recent memories + relationships + personality

#### NPC Cognitive Architecture (3 pillars):

**PILLAR 1 — Memory Stream (Observe → Store → Retrieve)**
The memory stream is the NPC's full record of experience. NOT a simple array — it's a scored retrieval system.

Each memory is a `MemoryRecord`:
```
{
  description: String,       # "Saw player steal bread from the bakery"
  type: "observation" | "reflection" | "plan" | "dialogue" | "rumor",
  participants: [npc_ids],
  location: String,
  game_time: int,            # When it happened
  importance: float,         # 1-10. Mundane=1, witnessed murder=10
  last_accessed: int,        # Last time this memory was retrieved
  emotional_valence: float,  # -1.0 (terrible) to +1.0 (wonderful)
  embedding_key: String      # For semantic search if using vector DB later
}
```

**Memory retrieval** uses three scores combined:
- **Recency:** More recent memories score higher. Exponential decay: `score = 0.99 ^ (hours_since_event)`
- **Importance:** How significant was the event? Eating breakfast = 1, witnessing a crime = 9, getting married = 10
- **Relevance:** How related is this memory to the current situation? Use keyword matching for v1, semantic similarity (via Gemini embeddings) for v2

Final retrieval score = `recency * w1 + importance * w2 + relevance * w3` (weights tunable, start with equal)

When an NPC needs to act or respond, retrieve top 5-10 memories by this score and feed them as context.

**PILLAR 2 — Reflection (Synthesize → Insight → Beliefs)**
Periodically (every ~50 observations, or when importance accumulates past a threshold), NPCs reflect on recent memories and generate higher-level insights:

- Raw memories: "John yelled at me Tuesday", "John ignored me at the tavern", "John spread a rumor about me"
- **Reflection output:** "I believe John dislikes me and is trying to damage my reputation" (importance: 8)
- Reflections are stored BACK into the memory stream as type "reflection" with high importance
- Reflections shape future behavior: an NPC who reflects "the sheriff is corrupt" may stop reporting crimes
- Use Gemini API to generate reflections. Prompt: "Given these recent memories, what 1-3 high-level insights would {NPC_name} draw? Consider their personality: {traits}"
- **Fallback without LLM:** Rule-based reflection — if 3+ negative memories about same person in 48h → generate "I don't trust {person}" reflection

**PILLAR 3 — Planning (Daily Plans → Hourly Actions → Reactive Replanning)**
Each morning (6 AM game time), NPCs generate a daily plan:

- **Input:** NPC identity + recent reflections + current needs + current relationships + yesterday's events
- **Output:** Ordered list of intended actions with times: "7am: eat breakfast, 8am: open bakery, 12pm: lunch break — visit Maria, 5pm: close shop, 6pm: go to tavern, 9pm: go home, 10pm: sleep"
- Plans are stored in memory stream as type "plan"
- **Reactive replanning:** When something unexpected happens (witness a crime, get into argument, player interaction), NPC can revise remaining plan
- Use Gemini API for rich planning. Fallback: template schedules per job type with personality-based variation

#### Observation System
NPCs don't know everything — they only know what they **perceive**:
- NPCs have a **perception radius** (~5 tiles). They observe events within this radius
- Observations become memories automatically: "Saw {actor} {action} at {location} at {time}"
- NPCs in buildings only observe events inside that building
- NPCs can overhear conversations if within 3 tiles
- What NPCs observe drives their gossip, opinions, crime reports, and relationship changes
- IMPORTANT: If no NPC observes an event, it effectively didn't happen socially. A crime with no witnesses = no investigation

#### Emergent Behavior (This is the magic)
With these 3 pillars, NPCs should EMERGENTLY:
- Organize social events (NPC reflects "I haven't socialized enough" → plans a gathering → invites friends)
- Form opinions about the player based on observed actions, not scripted triggers
- Spread information through gossip chains (NPC A tells NPC B what they saw → B forms opinion → B tells C)
- Change career paths (NPC reflects "I hate my job and my boss is mean" → plans to look for new work)
- Fall in love, get jealous, hold grudges, forgive — all from accumulated memories and reflections
- Coordinate complex behavior without explicit scripting

#### Relationships
- **Dictionary per NPC:** `npc_id -> {trust: float, affection: float, respect: float, history: []}`
- Updated by interactions and observations, NOT by script
- Gossip propagation: When NPC A gossips to NPC B about NPC C, B stores it as a "rumor" type memory with lower importance than firsthand observation
- Romantic relationships: crush → dating → engaged → married → (possibly divorced) — driven by affection scores and reflection insights
- Family ties: parents, children, siblings — affect loyalty, trust baseline, and behavior

### 3. Gossip & Information Propagation
Information in DeepTown is NOT global. It spreads like a real town:
- **Firsthand:** NPC saw it happen → stored as observation (high reliability)
- **Secondhand:** NPC was told by witness → stored as rumor (medium reliability)
- **Thirdhand+:** Telephone game — details may distort. Rumor reliability degrades each hop
- **Gossip triggers:** NPCs with high social need gossip more. NPCs gossip about high-importance memories
- **Gossip targets:** NPCs prefer gossiping to friends (high trust). They AVOID telling secrets to NPCs they distrust
- **Information decay:** After 3+ hops, rumors may become inaccurate ("player stole bread" → "player robbed the bakery" → "player is a dangerous criminal")
- **Social network mapping:** Track who told whom. This creates emergent factions and information bubbles
- This system means: commit a crime in front of one NPC, and within 2-3 game days the whole town may know — or may not, if the witness has no friends

### 4. Crime & Law System
- **Crimes:** Theft, assault, trespassing, vandalism, murder, fraud, public disturbance
- **Detection:** Crimes need witnesses or evidence. No omniscient police
- **Investigation:** Sheriff interviews witnesses, searches for evidence, can get it wrong
- **Arrest:** Sheriff confronts suspect. Suspect can comply, flee, or resist
- **Trial:** Town court with judge NPC. Witnesses testify. Verdict based on evidence quality, judge personality, town opinion. Wrongful convictions possible
- **Punishment:** Fine, jail time, community service, exile. Severity based on crime + criminal history
- **Player crimes:** Player is subject to the SAME system. Get caught stealing? Face trial
- NPCs can also be criminals. Thieves, con artists, even corrupt officials

### 5. Reputation System
- Town-wide reputation score (hidden, but effects are visible)
- Per-NPC opinion tracking (each NPC remembers YOUR actions independently)
- Reputation spreads via gossip — not everyone knows everything instantly
- Actions have reputation consequences: helping = +rep, stealing = -rep, but ONLY if witnessed/known
- High reputation: discounts, trust, information, elected positions
- Low reputation: price gouging, refused service, NPC hostility, arrest on suspicion

### 6. Economy
- NPCs earn wages from jobs, spend on needs (food, rent, entertainment)
- Shops have inventory that depletes and restocks
- Supply and demand — prices shift based on scarcity
- Player can trade, own a shop, hire NPCs, or steal
- Money circulates: NPC buys from shop → shop pays supplier → supplier pays workers

### 7. LLM Integration (Gemini API)
Gemini serves THREE distinct roles in the cognitive architecture:

**Role 1 — Dialogue Generation (most frequent)**
- When player talks to NPC: system prompt with NPC identity + top retrieved memories + current mood + relationship with player → generate natural response
- NPCs should reference their memories naturally: "Didn't I see you near the bakery yesterday?" (if they have that observation)
- Personality must shine through: a grumpy NPC and a cheerful NPC witnessing the same event respond differently

**Role 2 — Reflection Synthesis (periodic)**
- Every ~50 observations or when importance threshold is hit
- Prompt: "You are {name}, {description}. Based on these recent experiences: {memories}. What 1-3 high-level realizations or beliefs would you form?"
- Output stored back as reflection memories with high importance

**Role 3 — Daily Planning (once per game day per NPC)**
- Prompt: "You are {name}, {description}. Your recent reflections: {reflections}. Your needs: {needs}. Your relationships: {key_relationships}. What is your plan for today? List hour-by-hour."
- Parse into actionable schedule the game engine can execute

**Cost Management (CRITICAL with $200 budget):**
- **Batch reflections:** Don't reflect every NPC every cycle. Rotate: 3-4 NPCs reflect per game day
- **Cache dialogue:** If NPC mood/context hasn't changed much, reuse recent responses for similar prompts
- **Template fallback:** ALWAYS have rule-based fallbacks. LLM enhances but is not required
- **Tiered importance:** Only use LLM for player-facing dialogue + reflections. Use templates for NPC-to-NPC routine dialogue
- **Track spend:** Log every API call cost. Add a debug overlay showing daily/total API spend
- **Gemini Flash:** Use gemini-2.0-flash for routine dialogue (cheap), gemini-2.5-pro only for critical reflections and complex planning
- **Estimated budget:** ~15-20 NPCs × 1 plan/day + ~5 reflections/day + player dialogues = manageable if using Flash model

## Coding Conventions
- GDScript style: snake_case for variables/functions, PascalCase for classes/nodes
- Use signals for decoupled communication between systems
- Use Autoloads for global systems: `GameClock`, `EventBus`, `CrimeSystem`, `ReputationSystem`
- ALWAYS use typed GDScript: `var health: int = 100`, `func get_mood() -> float:`
- Comments on WHY, not WHAT. The code should be readable without comments
- Keep scripts under 300 lines. Split into components if growing
- Test simulation logic with print statements and a debug overlay

## Workflow Rules
- ALWAYS plan before coding. Write approach in a comment or SCRATCHPAD.md first
- Build systems incrementally: get the simplest version working, then add depth
- Commit after each working feature with descriptive messages
- When adding a new system, update SYSTEMS.md with its design
- When changing NPC data structure, update npcs.json schema in data/
- Run the game and verify visually after any significant change
- Use Godot's built-in debugger and print() liberally

## Current Phase: Phase 1 — Foundation
Build ONE small town (8-12 buildings, 15-20 NPCs) with:
- [x] Project setup
- [x] Tile map with buildings (homes, shop, tavern, sheriff office, courthouse, church)
- [x] Player movement (top-down, 4-directional, GBA Pokemon style)
- [x] Game clock with day/night cycle
- [x] NPC spawning with core descriptions and personality traits
- [x] NPC pathfinding (A* on tilemap)
- [ ] Basic needs system (hunger, energy, social)
- [ ] Memory Stream — NPCs observe and store MemoryRecords with importance scoring
- [ ] Memory Retrieval — recency + importance + relevance weighted retrieval
- [ ] Daily Planning — NPCs generate morning plans (template-based v1, LLM v2)
- [ ] Observation system — perception radius, NPCs only know what they see/hear
- [ ] Interaction system (talk to NPCs → retrieve memories → generate response)
- [ ] Gossip propagation — NPCs share observations during social time
- [ ] Reflection system — periodic insight generation (rule-based v1, LLM v2)
- [ ] Crime detection (witness-based, fed by observation system)
- [ ] Sheriff arrest mechanic
- [ ] Simple court trial
- [ ] Reputation tracking (per-NPC + town-wide, driven by memory/gossip)
- [ ] LLM integration (Gemini API for dialogue, reflection, planning)

## IMPORTANT Reminders
- This is a SIMULATION first, game second. Depth over polish
- NPCs are NOT quest dispensers. They are autonomous agents living their lives
- The player is just another entity in the simulation. No special treatment by the law
- Wrongful convictions, corrupt officials, NPC drama — these are FEATURES not bugs
- Every system should fail gracefully. If LLM is down, use templates. If pathfinding fails, NPC waits
- Performance matters: 20 NPCs ticking every frame needs optimization. Use process groups and LOD for offscreen NPCs
- Save system must capture ENTIRE world state: every NPC memory, relationship, reputation score, inventory item, time of day, pending court cases — EVERYTHING