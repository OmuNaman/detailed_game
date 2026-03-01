extends Node
## Tracks game time. 1 real second = 1 game minute.
## Emits signals via EventBus when hour, day, or season changes.

enum Season { SPRING, SUMMER, AUTUMN, WINTER }

const MINUTES_PER_HOUR: int = 60
const HOURS_PER_DAY: int = 24
const DAYS_PER_SEASON: int = 28
const SEASON_NAMES: PackedStringArray = ["Spring", "Summer", "Autumn", "Winter"]

# 1 real second = 1 game minute
const REAL_SECONDS_PER_GAME_MINUTE: float = 1.0

var minute: int = 0
var hour: int = 6  # Start at 6 AM
var day: int = 1
var season: Season = Season.SPRING
var is_paused: bool = false

var _elapsed: float = 0.0
# Total minutes since game start — useful for memory timestamps
var total_minutes: int = 0


func _ready() -> void:
	# Initialize total_minutes from starting time
	total_minutes = hour * MINUTES_PER_HOUR + minute


func _process(delta: float) -> void:
	if is_paused:
		return

	_elapsed += delta
	while _elapsed >= REAL_SECONDS_PER_GAME_MINUTE:
		_elapsed -= REAL_SECONDS_PER_GAME_MINUTE
		_advance_minute()


func _advance_minute() -> void:
	minute += 1
	total_minutes += 1
	EventBus.time_tick.emit(total_minutes)

	if minute >= MINUTES_PER_HOUR:
		minute = 0
		_advance_hour()


func _advance_hour() -> void:
	var old_hour: int = hour
	hour += 1
	if hour >= HOURS_PER_DAY:
		hour = 0
		_advance_day()

	if hour != old_hour:
		EventBus.time_hour_changed.emit(hour)


func _advance_day() -> void:
	day += 1
	EventBus.time_day_changed.emit(day)

	if day > DAYS_PER_SEASON:
		day = 1
		_advance_season()


func _advance_season() -> void:
	season = (season + 1) % Season.size() as Season
	EventBus.time_season_changed.emit(get_season_name())


func get_season_name() -> String:
	return SEASON_NAMES[season]


func get_time_string() -> String:
	return "%02d:%02d" % [hour, minute]


func get_display_string() -> String:
	return "Day %d - %s" % [day, get_time_string()]


func get_full_display_string() -> String:
	return "%s, Day %d - %s" % [get_season_name(), day, get_time_string()]


func get_hour_fraction() -> float:
	## Returns current time as a fraction of the day (0.0 = midnight, 0.5 = noon)
	return (hour + minute / 60.0) / 24.0


func get_state() -> Dictionary:
	return {
		"minute": minute,
		"hour": hour,
		"day": day,
		"season": season,
		"total_minutes": total_minutes,
	}


func load_state(state: Dictionary) -> void:
	minute = state.get("minute", 0)
	hour = state.get("hour", 6)
	day = state.get("day", 1)
	season = state.get("season", Season.SPRING) as Season
	total_minutes = state.get("total_minutes", hour * MINUTES_PER_HOUR + minute)
