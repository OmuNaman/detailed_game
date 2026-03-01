extends Node
## Global signal bus for decoupled communication between systems.

# Time signals
signal time_tick(game_minute: int)
signal time_hour_changed(hour: int)
signal time_day_changed(day: int)
signal time_season_changed(season: String)

# NPC signals (for future use)
signal crime_committed(crime_data: Dictionary)
signal npc_observed_event(observer_id: String, event_data: Dictionary)
signal reputation_changed(target_id: String, amount: float)
signal gossip_spread(from_id: String, to_id: String, memory: Dictionary)
