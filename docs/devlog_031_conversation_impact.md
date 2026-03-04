# Devlog 031 — Conversation Impact on Relationships (Prompt J)

## What Changed
Replaced flat +1 Trust / +1 Affection conversation bumps with content-aware analysis. What you say now matters — insults drop trust, kindness raises affection, wisdom earns respect. Core Memory updates after significant interactions.

### Part 1: Player Conversation Impact
After every player dialogue reply, a Flash Lite analysis call evaluates:
- `trust_change`, `affection_change`, `respect_change` (-5 to +5)
- `emotional_state` update for the NPC
- `player_summary_update` — NPC's evolving understanding of the player
- `key_fact` — new facts learned from conversation

Replaces both the old flat +1/+1 bump AND the separate `_update_player_summary_async()` call — one Flash Lite call instead of two separate calls. Opening greetings (before the player says anything) no longer produce relationship changes.

### Part 2: NPC-to-NPC Conversation Impact
After Gemini-powered NPC conversations, a Flash Lite call evaluates bidirectional impact:
- `a_to_b` and `b_to_a` each with trust/affection/respect (-3 to +3)
- If all values are zero, minimal +1 trust applied (you showed up)
- NPC summary updates triggered every 3rd conversation OR when total magnitude ≥ 3

Fake conversations (template fallback when Gemini is down) still use flat +1/+1.

### Part 3: Gossip Impact Refinement
Replaced threshold-based gossip impact with proportional formula:
- `impact = clamp(valence * 2.0, -3, 3)` applied to trust only
- Previously: -0.2 threshold → fixed -2/-1/-1, +0.2 → fixed +1/+1/0
- Now: proportional to emotional valence, trust-only (gossip affects how much you trust someone, not how much you like them)

### Part 4: Relationship-Aware Dialogue
Replaced raw numeric relationship display in prompts with per-dimension descriptions:
- Trust: "deeply distrust" / "are suspicious of" / "feel neutral about" / "trust somewhat" / "trust deeply"
- Affection: "are cold toward" / "are indifferent to" / "feel neutral about" / "are fond of" / "deeply care about"
- Respect: "look down on" / "have little respect for" / "feel neutral about" / "respect" / "deeply respect and admire"

Player dialogue context now includes: "Respond naturally based on these feelings. Low trust = guarded. High affection = warm. Negative respect = dismissive. Never mention numbers."

### Part 5: GeminiClient Enhancements
- Added `MODEL_LITE` constant (`gemini-2.0-flash-lite`) for cheaper analysis calls
- Added optional `model_override` parameter to `generate()` — backward compatible
- Added `parse_json_response()` static utility that strips markdown code fences before parsing

## Files Changed
- **MODIFIED** `scripts/llm/gemini_client.gd` — MODEL_LITE constant, model parameter, parse_json_response()
- **MODIFIED** `scripts/core/relationships.gd` — get_trust_label(), get_affection_label(), get_respect_label()
- **MODIFIED** `scripts/npc/npc_controller.gd` — Impact analysis system:
  - Deleted: `_update_player_summary_async()` (replaced by combined impact analysis)
  - New vars: `_npc_conv_totals`
  - New methods: `_analyze_player_conversation_impact()`, `_apply_player_impact()`, `_analyze_npc_conversation_impact()`, `_apply_npc_impact()`, `_update_npc_summary_async()`
  - Modified: `get_dialogue_response_async()` (no bump on greeting), `get_conversation_reply_async()` (analysis instead of flat), `_real_npc_conversation()` (analysis instead of flat), `_share_gossip_with()` (proportional formula), `_build_dialogue_context()` (per-dimension labels), `_build_npc_chat_context()` (per-dimension labels)

## Cost Impact
- Player reply: 1 Flash Lite call (replaces 1 Flash call for summary → net cheaper)
- NPC-NPC conversation: 1 Flash Lite call (new, ~$0.60/month)
- NPC summary update: 1 Flash Lite call every 3rd conversation or on big impact
- Gossip: no extra API calls (formula-based)

## Testing Checklist
- [ ] Player says something kind → console: `[Impact] Maria→Player: T:+2 A:+3 R:+1`
- [ ] Player insults NPC → trust/affection drop: `[Impact] Maria→Player: T:-3 A:-4 R:-2`
- [ ] Neutral small talk → minimal bump: `T:+1 A:0 R:0`
- [ ] Core memory updates: `[Memory] Maria updated player summary: ...`
- [ ] NPC-NPC chat → bidirectional: `[NPC Impact] Maria→Thomas: T:+1 A:+1 R:0 | Thomas→Maria: T:+1 A:+2 R:0`
- [ ] NPC summaries update every 3rd conversation or on big impact
- [ ] Gossip with valence -0.8 → `[Gossip Impact] Finn heard about Bram → Trust -1`
- [ ] Dialogue context shows per-dimension labels (not raw numbers)
- [ ] No API key → all falls back to flat +1 trust (no crashes)
- [ ] Gemini queue > 8 → NPC-NPC skips analysis, uses flat bump
- [ ] Opening NPC greeting produces NO relationship change
- [ ] `_update_player_summary_async()` is gone — no duplicate Gemini calls
