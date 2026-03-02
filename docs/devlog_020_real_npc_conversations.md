# Devlog 020 — Real NPC-to-NPC Conversations

## Date: 2026-03-03

## Overview
NPC-to-NPC conversations now use Gemini to generate real dialogue instead of fake topic labels. When two NPCs meet, the initiator says one line and the other replies — both stored as actual dialogue text in their memories. Speech bubbles float above NPCs during conversations.

---

## Before vs After

**Before:** Two NPCs near each other → memory says "Had a conversation with Rose about town gossip". No actual words spoken.

**After:** Two NPCs near each other → Gemini generates real lines:
- Maria: "Have you tried the fresh bread this morning, Rose?"
- Rose: "Not yet, but it smells wonderful from here!"

Both memories now store the actual dialogue text, searchable and referenceable in future conversations.

## Conversation Flow

1. Two NPCs within 2 tiles, both stationary, cooldown expired
2. Both face each other, get +5 social boost
3. Topic selected via existing `_pick_conversation_topic()` (time/needs/job/memory-aware)
4. **Gemini Call 1:** Initiator generates opening line (ONE sentence)
5. **Gemini Call 2:** Other NPC generates reply (ONE sentence)
6. Both lines stored in both NPCs' memories with actual dialogue text
7. Speech bubbles appear: initiator immediately, responder 2 seconds later
8. Bubbles float upward and fade out after 4 seconds

## Memory Format

**Initiator's memory:**
```
I said to Rose: "Any good ale tonight?" — Rose replied: "Always, dear! Pull up a chair." (at the Tavern)
```

**Responder's memory:**
```
Maria said to me: "Any good ale tonight?" — I replied: "Always, dear! Pull up a chair." (at the Tavern)
```

Importance: 4.0 (up from 3.0 for fake conversations), type: "dialogue"

## System Prompt (NPC-to-NPC)

Shorter than player dialogue prompts to save tokens:
- Name, age, job, personality, speech style
- Rules: ONE sentence only, casual chat, in character, natural
- No AI acknowledgment

## Context Building

Each NPC's context includes:
- Time period + current location
- Needs state (hungry/exhausted/great mood)
- Top 3 recent memories
- Either "Start a chat about {topic}" or "{Name} said: '{line}', reply naturally"

## Fallback System

Three fallback layers:
1. **No API key:** Falls back to old topic-label system (`_fake_npc_conversation()`)
2. **Queue overflow (>10 pending):** Falls back to fake system (cost control)
3. **Gemini fails mid-conversation:** Uses generic fallback one-liners (`_get_npc_chat_fallback()`)

## Speech Bubbles

New `scripts/ui/speech_bubble.gd` component:
- White text with black outline (10pt, outline size 3)
- 160px wide, word-wrapped
- Floats upward at 5px/s
- Fades out in the last second
- Self-destructs after duration (default 4s)

Attached as child of the speaking NPC. Only one bubble per NPC at a time.

## Cost Analysis

- 2 Gemini calls per conversation (1 per NPC)
- Short system prompt (~100 tokens) + short context (~150 tokens) = ~250 input tokens per call
- Output capped at 1 sentence (~30 tokens)
- With 11 NPCs, 2-hour cooldown per pair, 15-minute check interval: ~5-6 conversations per game hour
- Queue overflow protection prevents runaway costs

---

## Files Modified (1) + Created (2)

| File | Changes |
|------|---------|
| `scripts/npc/npc_controller.gd` | `_try_npc_conversation()` rewritten with Gemini integration, `_fake_npc_conversation()` extracted, `_real_npc_conversation()` new, 3 helper methods, `_show_speech_bubble()` |
| `scripts/ui/speech_bubble.gd` | **NEW** — floating text bubble component |
| `docs/devlog_020_real_npc_conversations.md` | **NEW** — this file |

## Notes
- Player dialogue system completely untouched
- NPC movement, pathfinding, needs, and memory internals unchanged
- GeminiClient queue logic unchanged — just uses existing `generate()` method
- `_pick_conversation_topic()` unchanged — still provides context-aware topics
- Map, buildings, roads, furniture all untouched
