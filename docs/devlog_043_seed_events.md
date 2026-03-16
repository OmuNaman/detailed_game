# Devlog 043 — Seed Event System (Stanford Party Planning)

## What Changed

Implemented the Stanford Generative Agents paper's event injection mechanism. Inject an observation into ONE NPC and watch it propagate naturally through the town via gossip, conversations, and autonomous plan re-evaluation.

### How It Works

1. **Seed**: Inject "Festival at the Tavern at 6pm" into Maria (importance 7.0)
2. **React**: Maria's planner evaluates → REACT → redirects to Tavern to prepare
3. **Gossip**: Maria mentions it during conversations → listeners get gossip memories
4. **Plan**: Other NPCs see the gossip during planning → add Tavern visit to their schedule
5. **Emerge**: By hour 18, multiple NPCs show up autonomously. No forced attendance.

### Two Ways to Seed Events

**In-Game (F9 Admin Panel):**
- New "Seed Event" section with event text, location, hour
- "Also seed 2 coworkers" checkbox for faster initial spread
- Button injects observation + triggers reaction evaluation

**Web Dashboard (localhost:8080 → Events tab):**
- Seed Event form at the top of Events tab
- NPC selector, location dropdown, hour picker
- POSTs to `/api/seed_event` → writes `seed_event.json`
- Godot polls the file every 5s, injects when found, deletes file

### Key Design Decisions

- **Importance 7.0** = triggers reaction (threshold 5.0) but NOT protected (< 8.0)
- **Actor = "townsfolk"** not "Admin" — more natural for gossip propagation
- **Coworker seeding** creates "gossip" type memories (hop 1) from the primary NPC
- **No mass injection** — the gossip system handles propagation (max 3 hops)

## Files Changed

| File | Change |
|------|--------|
| `scripts/ui/admin_panel.gd` | Seed Event section + `_seed_event()` function |
| `tools/inspector_server.py` | Seed Event form in Events tab + POST /api/seed_event endpoint |
| `scripts/ui/inspector_export.gd` | `_check_seed_event()` polls for seed_event.json from web |
