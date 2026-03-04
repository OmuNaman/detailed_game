# Devlog 033 — Memory-Aware Dialogue Integration (Prompt M)

## What Changed
Rewired ALL Gemini dialogue calls to use relevance-ranked memory retrieval instead of flat `get_recent(5)` + `get_by_type()` lookups. NPCs now reference past events, remember what the player told them, and bring up relevant history. Also added conversation summaries, working memory, and emotional state decay.

### Part 1: Retrieval-Based Memory for All Dialogue

**New method: `retrieve_by_query_text()`** in MemorySystem — convenience wrapper that:
- Extracts keywords from free text (removes stop words, punctuation)
- Searches BOTH `episodic_memories` AND `archival_summaries` (unlike `retrieve_by_keywords` which only searches episodic)
- Scores with hybrid formula: 0.5×relevance + 0.3×recency + 0.2×importance
- Applies 1.1× boost to archival summaries (same as embedding-based retrieval)
- Returns top-k results with testing effect applied

**REPLACES** in `_build_dialogue_context()`:
- `get_recent(5)` → single `retrieve_by_query_text()` call
- `get_by_type("reflection")` → handled by retrieval scoring
- `get_by_type("environment")` → handled by retrieval scoring
- `get_by_type("gossip")` → handled by retrieval scoring

All 4 separate calls collapsed into ONE retrieval call with 8 results.

### Part 2: Targeted Retrieval for Conversation Replies

New `_build_dialogue_context_for_reply(player_message)` uses the player's actual message as the retrieval query. When the player says "remember when we first met?", retrieval surfaces earliest conversation memories instead of generic recent ones.

Working memory: last 6 conversation turns kept in context (was unbounded before).

### Part 3: NPC-to-NPC Dialogue — Memory Integration

`_build_npc_chat_context()` memory section rewritten: 4 separate type lookups → single `retrieve_by_query_text()` call with conversation partner as query. Added `npc_summaries` from core memory for conversation partner context.

### Part 4: Reflection-Aware Planning

`_build_planning_context()` now includes:
- Core memory `npc_summaries` (what NPC knows about specific people)
- Core memory `player_summary` (if player has been met)

### Part 5: Past Event Recall

Added honest recall instruction to `_build_system_prompt()`:
> "If someone asks about past events, rely on your memories. If you don't remember, say so honestly — never make up events."

### Part 6: Memory Age Labels

New `_format_memory_age()` helper produces human-readable timestamps:
- "(just now)", "(30 min ago)", "(2 hours ago)", "(today)", "(yesterday)", "(3 days ago)", "(over a week ago)"

Memory type prefixes in dialogue context:
- `[Thought]` for reflections
- `[Heard]` for gossip
- `[Noticed]` for environment observations
- `[Summary]` for episode/period summaries

### Part 7: Conversation Summary Memory

When player closes dialogue (ESC), `on_player_conversation_ended()` fires:
- Short conversations (≤4 turns): simple concatenation summary
- Longer conversations (5+ turns): Gemini Flash summarization
- Stored as type="player_dialogue", importance=8.0 (auto-protected)
- No API key: falls back to simple "Had a conversation with X at Y"

### Part 8: Emotional State Decay

- Every hour, checks if 3+ quiet hours have passed since last significant event
- If so, emotional state decays to "Feeling neutral, going about the day."
- Significant events that reset the timer: player conversation impact, reflection insights, receiving gossip

## Files Changed
- **MODIFIED** `scripts/npc/memory_system.gd` — `retrieve_by_query_text()` method
- **MODIFIED** `scripts/npc/npc_controller.gd` — Major dialogue rewrite:
  - New vars: `_player_conv_history`, `_last_significant_event_time`
  - New methods: `_format_memory_age()`, `_build_dialogue_context_for_reply()`, `on_player_conversation_ended()`, `_summarize_player_conversation()`
  - Modified: `_build_dialogue_context()` (retrieval-based), `_build_npc_chat_context()` (retrieval-based), `_build_planning_context()` (core memory), `_build_system_prompt()` (honest recall), `get_conversation_reply_async()` (targeted retrieval + working memory), `get_dialogue_response_async()` (init working memory), `_on_hour_changed()` (emotional decay), `_apply_player_impact()` (significant event), `_enhanced_reflect()` (significant event), `_share_gossip_with()` (significant event for receiver)
- **MODIFIED** `scripts/ui/dialogue_box.gd` — `hide_dialogue()` calls `on_player_conversation_ended()`

## Cost Impact
- Conversation summary: 1 Gemini Flash call per ended conversation (5+ turns only)
- No additional API calls for retrieval (keyword-based, synchronous)
- Slightly reduced token usage in dialogue prompts (8 relevant memories vs previous unbounded type lookups)

## Testing Checklist
- [ ] Player says "remember when we first met?" → retrieval surfaces earliest player_dialogue memory
- [ ] Player insults NPC → trust drops, emotional_state updates, next conversation is guarded
- [ ] NPC-to-NPC chat context includes npc_summaries entry for partner
- [ ] Planning context includes core memory npc_summaries + player_summary
- [ ] After ESC: `[ConvSummary] Maria: "Conversation with Player about..."` (protected, importance 8.0)
- [ ] After 3+ quiet hours: emotional state decays to neutral
- [ ] Retrieved memories show age labels: "(today)", "(yesterday)", "(3 days ago)"
- [ ] Memory section shows type prefixes: [Thought], [Heard], [Noticed], [Summary]
- [ ] No API key → all falls back gracefully, no crashes
- [ ] Old `get_recent(5)` + 4× `get_by_type()` pattern replaced in both player + NPC dialogue
