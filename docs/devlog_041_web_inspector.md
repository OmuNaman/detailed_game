# Devlog 041 — Web Inspector Dashboard

## What Changed

Real-time web dashboard for inspecting all 61 NPCs' cognitive state while the game runs.

### Architecture
- **Godot side**: `inspector_export.gd` dumps all NPC state to `user://inspector_state.json` every 5 real seconds
- **Web side**: `tools/inspector_server.py` serves a minimalist white dashboard at `http://localhost:8080`

### Dashboard Features
- **Sidebar**: Searchable NPC list with status dots (green=active, blue=moving, gray=sleeping, yellow=talking)
- **Overview tab**: Needs bars, emotional state, core memory (player summary, NPC summaries, key facts), personality, stats
- **Memories tab**: Color-coded by type (observation=blue, dialogue=green, reflection=purple, gossip=orange), importance stars, time labels
- **Relationships tab**: Trust/affection/respect bars centered at 0, green(positive)/red(negative), sorted by opinion score
- **Plan tab**: Today's schedule as timeline blocks with current hour highlighted in indigo
- **Reflections tab**: Stanford-style insight cards with italic quotes
- **Gossip tab**: Source tracking, hop count, timeline
- **Bottom bar**: Global stats (API requests, queue depth, active connections, token counts)

### How to Use
1. Start the Godot game
2. Run `python tools/inspector_server.py`
3. Open `http://localhost:8080` in your browser
4. Click any NPC to inspect — data auto-refreshes every 5 seconds

## Files
| File | Change |
|------|--------|
| `scripts/ui/inspector_export.gd` | NEW — State exporter (dumps 61 NPCs to JSON) |
| `tools/inspector_server.py` | NEW — Python HTTP server + embedded HTML dashboard |
| `scenes/world/town.tscn` | Add InspectorExport node |
