# Devlog 042 — Fix API Errors, Priority Player Dialogue, Events Dashboard

## API Fixes

- **MAX_CONCURRENT**: 8 → 4 (fixes connection errors, result:4)
- **download_chunk_size**: 64KB → 1MB (fixes body size limit, result:13)
- **timeout**: 5s → 10s (prevents premature timeouts during bursts)
- **Removed thinkingConfig** from all requests (was wasting tokens with budget:0)

## Priority Player Dialogue

Added `generate_priority()` method to GeminiClient with a **dedicated HTTPRequest node** that bypasses the queue entirely. When player presses E to talk:
- Request goes directly to the player HTTP node (not queued)
- If player node is busy, request jumps to FRONT of queue
- Result: <3s response even during 61-NPC planning burst

Only two callers switched to priority: opening dialogue + conversation reply.

## Events Dashboard

Added "Events" tab to the web inspector with two components:

### Global Event Feed
Aggregates notable events from all 61 NPCs into a unified timeline:
- Conversations, gossip, reflections, plan changes
- Deduplicated (same conversation only shown once)
- Last 2 game hours, newest first

### Town Chronicle (Gemini 2.5 Pro)
Every 10 game minutes, sends recent events to **Gemini 2.5 Pro** which generates a 2-3 sentence narrative summary:
- "Maria and Thomas are deep in conversation at the General Store, while Celeste and Wren work quietly at the Tailor Shop..."
- Appears as highlighted italic entries in the Events tab

## Files Changed

| File | Change |
|------|--------|
| `scripts/llm/gemini_client.gd` | 4 concurrent, 1MB chunk, 10s timeout, `generate_priority()`, `MODEL_PRO`, dedicated player HTTP |
| `scripts/npc/npc_dialogue.gd` | Player dialogue calls → `generate_priority()` |
| `scripts/ui/inspector_export.gd` | Global events aggregation + chronicle via Gemini Pro |
| `tools/inspector_server.py` | Events tab with chronicle + raw events |
