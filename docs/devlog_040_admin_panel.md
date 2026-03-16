# Devlog 040 — Admin Panel (F9) + Gemini API Optimization

## What Changed

### Admin Panel (F9)
Stanford Generative Agents-inspired researcher interface. Press F9 to open a god-mode panel that lets you:

- **Inject Memory** — Type any observation and inject it into an NPC's memory with configurable importance (1-10) and valence (-1 to +1). High importance (8+) memories are protected and persist forever.
- **Give Directive** — Override an NPC's daily plan with a specific task, location, and time range. NPC immediately pathfinds to the new location.
- **Modify State** — Change hunger/energy/social sliders and emotional state text. Affects mood, dialogue, and behavior immediately.
- **Quick Actions** — Trigger reflection on demand, skip to a specific hour, or save all NPC data.

Use cases: seed events ("There's a festival at the Tavern tonight"), give tasks ("Go talk to Maria about the missing bread"), create emergent scenarios.

### Gemini API Optimization
- **Concurrency:** MAX_CONCURRENT 3 → 8 (Tier 1 paid key supports high RPM)
- **Flash Lite for compression:** Episode and period memory compression now use Flash Lite (3-4x cheaper, faster)
- **Raised queue thresholds:** All thresholds increased for 8-concurrent pool
  - Conversation → template: >40 (was >25)
  - Turn limit: >25 (was >15)
  - Impact skip: >35 (was >20)
  - Decomposition skip: >50 (was >30)

## Files Changed

| File | Change |
|------|--------|
| `scripts/ui/admin_panel.gd` | NEW — Full admin panel (300+ lines, built in code) |
| `scenes/world/town.tscn` | Add AdminPanel node |
| `scripts/llm/gemini_client.gd` | MAX_CONCURRENT 3→8 |
| `scripts/npc/npc_reflection.gd` | Flash Lite for episode + period compression |
| `scripts/npc/npc_conversation.gd` | Raised queue thresholds |
| `scripts/npc/npc_planner.gd` | Raised decomposition thresholds to >50 |
