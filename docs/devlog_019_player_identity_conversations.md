# Devlog 019 — Player Identity & Conversation Overhaul

## Date: 2026-03-03

## Overview
The player is no longer a nameless "Player" — they now enter their name on first launch, which is saved permanently and used throughout all systems. The one-shot dialogue system (press E, NPC talks once, press E to close) has been replaced with a full back-and-forth conversation window where the player can type replies.

---

## Part 1: Player Identity

### Name Entry Screen
On first launch, a centered panel appears over the paused game:
- "Welcome to DeepTown" title, "What is your name?" subtitle
- LineEdit (max 20 chars), "Begin" button (disabled until 2+ chars)
- Enter key or button click confirms
- Game unpauses automatically after name is set

Subsequent launches skip this — name is loaded from `user://player_profile.json`.

### PlayerProfile Autoload
New singleton `PlayerProfile` accessible everywhere:
- `player_name` — the player's chosen name (default: "Newcomer")
- `player_home` — "House 11"
- `is_name_set` — whether the profile has been saved
- Loaded in `_ready()`, saved via `set_name()`

### "Player" → Actual Name Everywhere
All hardcoded `"Player"` strings replaced with `PlayerProfile.player_name`:
- **Perception:** NPCs observe "Saw Aman near the Bakery" instead of "Saw Player near the Bakery"
- **Dialogue memory:** "Talked with Aman at the Tavern" instead of "Talked with Player"
- **System prompt:** NPCs know about the newcomer by name and that they live in House 11
- **Template responses:** Memory lookups use the actual name (with backward compat for old "Player" memories)
- **NPC-to-NPC topics:** "the newcomer Aman" instead of "the stranger they saw in town"

### Player's Home: House 11
House 11 (south row, gx:36 gy:33) is the player's home. The building label displays "{Name}'s House" on the map once the name is set.

---

## Part 2: Conversation Overhaul

### Before vs After

**Before:** Press E → NPC says one line → Press E to close. No way to reply.

**After:** Press E → conversation window opens → NPC gives opening line → player types reply → NPC responds to what you said → up to 5 exchanges → ESC to close.

### Dialogue Box Redesign
The bottom-of-screen panel now has:
- **Header:** NPC name (gold) + "[ESC] Close" hint
- **Scroll area:** Full conversation history with colored speaker names
  - NPC text in gold (#ffcc44)
  - Player text in blue (#7799ff)
  - System messages in gray italic
- **Input row:** LineEdit for typing + Send button
- Enter key or Send button submits
- ESC closes the conversation

### Conversation Flow
1. Player presses E near NPC → `start_conversation(npc)` called
2. Player movement disabled during conversation
3. NPC generates opening line via `get_dialogue_response_async()` (same as before)
4. Player types reply → shown in chat → stored as NPC memory (importance 5.0)
5. NPC generates contextual reply via new `get_conversation_reply_async()`
6. Full conversation history sent to Gemini for contextual responses
7. After 5 exchanges → system message: "conversation has naturally wound down"
8. ESC → close and re-enable player movement

### `get_conversation_reply_async()`
New method on `npc_controller.gd` that builds on the existing `get_dialogue_response_async()`:
- Takes player's message + full conversation history
- Sends system prompt + dialogue context + entire conversation transcript to Gemini
- NPC responds based on what the player actually said, not generic greeting
- Falls back to template if no API key or Gemini fails
- Stores exchange summary in NPC memory

### Enhanced System Prompt
NPCs now know about the player:
- "There is a newcomer named {name} who recently moved into House 11"
- Rule: "You can ask {name} questions too — be curious about the newcomer"
- Rule: "React to what they say, don't just give generic responses"

### Memory Impact
Each player message → NPC memory (importance 5.0):
```
Aman said to me: "Got any good bread?" at the Bakery
```
Each NPC reply → NPC memory (importance 5.0):
```
Talked with Aman at the Bakery. They said: "Got any good bread?" and I replied: "The sourdough is fresh!"
```

---

## Files Created (3) + Modified (5)

| File | Changes |
|------|---------|
| `scripts/core/player_profile.gd` | **NEW** — PlayerProfile autoload (name, home, save/load) |
| `scripts/ui/name_entry.gd` | **NEW** — Name entry screen on first launch |
| `scenes/ui/name_entry.tscn` | **NEW** — Name entry scene layout |
| `scripts/ui/dialogue_box.gd` | **REWRITE** — Full conversation UI (26→148 lines) |
| `scenes/ui/dialogue_box.tscn` | **REWRITE** — Conversation layout (scroll + input) |
| `scripts/npc/npc_controller.gd` | `get_conversation_reply_async()` new, `_build_system_prompt()` enhanced, 6 "Player" refs updated |
| `scripts/player/player_controller.gd` | `_handle_interact()` uses `start_conversation()`, removed `_waiting_for_dialogue` |
| `scripts/world/town.gd` | Name entry trigger on first launch |
| `scripts/world/town_generator.gd` | House 11 label shows player name |
| `project.godot` | PlayerProfile autoload registered |

## Notes
- NPC-to-NPC conversation system completely untouched
- NPC movement, pathfinding, needs, and memory internals unchanged
- Map, buildings, roads, furniture all untouched
- GeminiClient and EmbeddingClient internals unchanged
- Template fallback still works without API key
- Backward compatible with old "Player" memories in saved data
