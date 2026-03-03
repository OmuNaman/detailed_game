# Devlog 024 — Reflection System (Memory Synthesis)

## What Changed
NPCs now reflect on their recent experiences and generate higher-level insights. This is the second pillar of the Stanford Generative Agents cognitive architecture — NPCs don't just remember events, they synthesize meaning from patterns. Reflections are stored as high-importance memories that naturally surface in future dialogue and decision-making.

## Reflection Process
1. NPC gathers 20 most recent memories
2. Builds a prompt with NPC identity + personality + timestamped memories
3. Gemini generates exactly 3 first-person insights
4. Insights parsed from numbered list, stored as type="reflection" with importance=8.0
5. High importance means reflections score well in retrieval and resist eviction

## Triggers
- **Nightly (primary):** At hour 22 (bedtime), once per game day. Uses monotonic day counter (`total_minutes / 1440`) to avoid season-reset issues with `GameClock.day`
- **Importance threshold (secondary):** Every 30 game-minutes, if accumulated importance since last reflection exceeds 100.0, NPC reflects early. Catches days with many significant events (multiple player conversations, witnessed crimes, etc.)
- `_reflection_cooldown` prevents double-triggers within the same reflection cycle

## Prompt Design
- **System prompt:** NPC identity, age, job, personality. Instructions: 3 insights, first person, synthesize meaning (not summaries), reference specific people/events
- **User message:** Timestamped recent memories with type labels. Previous reflections marked as `[previous reflection]` so NPCs build on their own insights over time
- **Output parsing:** Handles "1. ", "2) ", "1: " numbering formats. Minimum 10-char length filter. Capped at 3 insights

## Context Enrichment
- **Player dialogue:** `_build_dialogue_context()` now includes top 3 most recent reflections under "Your recent thoughts and realizations"
- **NPC-to-NPC chat:** `_build_npc_chat_context()` includes top 2 reflections as "You've been thinking: ..."
- Reflections also appear naturally in "recent memories" section since they're stored as regular memories with high importance

## Cost Control
- Max 1 Gemini call per NPC per day (nightly trigger)
- Importance threshold can trigger 1 additional call on exceptional days
- 11 NPCs × 1 call/day = ~11 Gemini calls per game day
- No API key → reflections silently skipped, no errors
- `_reflection_cooldown` serializes requests through Gemini's queue

## Example Output
```
[Reflection] Maria generated 3 insights
  - I've been enjoying the conversations with the newcomer — they seem genuinely interested in our town.
  - Gideon has been working extra hard at the smithy. I wonder if something is bothering him.
  - The Tavern gets livelier in the evenings. I should visit more often after closing the Bakery.
```

## Files Changed
| File | Action |
|------|--------|
| `scripts/npc/npc_controller.gd` | MODIFY — `_try_reflect()`, `_build_reflection_system_prompt()`, `_build_reflection_context()`, `_parse_reflections()`, `_get_current_day()`, bedtime + importance triggers, reflection context in dialogue + NPC chat |
