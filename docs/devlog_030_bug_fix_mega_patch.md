# Devlog 030 — Bug Fix Mega-Patch (Prompt K)

## What Changed
Fixed 11 bugs across NPC systems in a single pass. All fixes are in `npc_controller.gd`.

### Bug 1: EnvScan Sleep Check (CRITICAL)
Environment scans fired on sleeping NPCs, creating ~64 duplicate memories/day/NPC. Added `current_activity.begins_with("sleeping")` guard at the top of `_scan_environment()`.

### Bug 2: Block Conversations During Sleep (CRITICAL)
NPCs chatted while "sleeping in bed" — wasting Gemini calls and creating absurd midnight conversations. Added sleep check + night-hours block (22-5) at the start of `_try_npc_conversation()`, plus per-NPC sleep check in the loop.

### Bug 3: Gossip shared_with Tracking (HIGH)
Thomas told Finn the same gossip 3 times because there was no tracking of who already heard what. Added `shared_with` array check in `_pick_gossip_for()` and tracking in `_share_gossip_with()`.

### Bug 4: NPC-Workplace Mapping in Planning Prompt (HIGH)
Plans hallucinated names like "Sheriff Barnes" because Gemini didn't know who lived in town. Added full 11-NPC roster with jobs, workplaces, and homes to `_build_planning_system_prompt()`.

### Bug 5: Plan Activity at Wrong Location (MEDIUM)
NPC showed plan text while at home (hunger override sent them home, but activity still showed plan). Now only shows plan activity if `_current_destination == plan.destination`.

### Bug 6: Conversation Distance for Large Buildings (HIGH)
Rose + Silas at Tavern (8x6) and Aldric + Clara at Church never talked — 64px range too small. Now uses building-aware distance: 192px (6 tiles) if both NPCs are in the same building, 64px otherwise.

### Bug 7: Finn-Clara Conversation Spam (MEDIUM)
Finn and Clara shared a house, talked 8+ times/day, same gossip loop. Trust hit 100 in 3 days. Added:
- Daily cap: `MAX_CONV_PER_PAIR_PER_DAY = 3` with `_pair_key()` canonical naming
- Cohabiting cooldown: 4 game hours between conversations when in the same building
- Midnight reset of daily counts

### Bug 8: Day 1 Planning Not Triggering (MEDIUM)
Game loads NPCs at hour 6, planning triggers at hour 5. Day 1 had no plans. Added `_check_planning_on_load()` called via `call_deferred` in `_ready()` — generates plans if loaded after hour 5.

### Bug 9: Tavern Visits Too Brief (MEDIUM)
NPCs arrived at Tavern hour 17, immediately left because schedule said go home. Added:
- `_dest_arrival_time` tracking set in `_arrive()`
- `MIN_STAY_MINUTES = 60` enforced in `_on_time_tick()` destination re-evaluation (except emergencies/sleep)
- Evening threshold relaxed: only leave Tavern if `energy < 20` (was: `social > 80 and energy < 40`)

### Bug 10: Player Name Inconsistency (LOW)
Verified all observation/gossip text creation already uses `PlayerProfile.player_name`. The two remaining `"Player"` string references are backward-compat fallbacks for old save data. No changes needed.

### Bug 11: Thomas Routes to Church First (LOW)
At hour 6, the `_wants_to_visit("Church")` check came before the workplace return. With `_next_visit_check` starting at 0, the first check always passed and 10% of the time sent Thomas to Church. Fix: Church visits now only allowed after hour 8.

## Files Changed
- **MODIFIED** `scripts/npc/npc_controller.gd` — All 11 bug fixes
  - New vars: `_conv_counts_today`, `_dest_arrival_time`
  - New consts: `MAX_CONV_PER_PAIR_PER_DAY=3`, `COOLDOWN_COHABIT_MINUTES=240`, `MIN_STAY_MINUTES=60`
  - New methods: `_pair_key()`, `_check_planning_on_load()`
  - Modified: `_scan_environment()`, `_try_npc_conversation()`, `_pick_gossip_for()`, `_share_gossip_with()`, `_build_planning_system_prompt()`, `_update_activity()`, `_on_hour_changed()`, `_on_time_tick()`, `_arrive()`, `_get_schedule_destination()`, `_ready()`

## Testing Checklist
- [x] No EnvScan logs between hours 22-5
- [x] No NPC Chat logs between hours 22-5
- [x] Gossip never repeats same memory to same listener
- [x] Planning triggers Day 1 after load
- [x] No hallucinated NPC names in plans
- [x] Rose+Silas talk at Tavern (192px range)
- [x] Aldric+Clara talk at Church (192px range)
- [x] Finn-Clara capped at 3 conversations/day
- [x] NPCs stay at Tavern 1+ hours in evening
- [x] All logs use player name, not "Player"
- [x] Activity text matches NPC location (no plan text at wrong building)
- [x] Thomas goes to General Store at hour 6, not Church
