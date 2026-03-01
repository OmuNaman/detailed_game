extends CanvasModulate
## Tints the entire scene based on time of day.
## Bright white at noon, dark blue at midnight, orange at dawn/dusk.

# Color keyframes mapped to hour fractions (0.0 = midnight, 0.5 = noon)
# Format: [time_fraction, Color]
var _color_keys: Array[Array] = [
	[0.0,    Color(0.15, 0.15, 0.30)],  # 00:00 — deep night
	[0.20,   Color(0.15, 0.15, 0.30)],  # 04:48 — still dark
	[0.25,   Color(0.85, 0.55, 0.35)],  # 06:00 — dawn orange
	[0.30,   Color(0.95, 0.85, 0.70)],  # 07:12 — early morning warmth
	[0.35,   Color(1.0, 1.0, 1.0)],     # 08:24 — full daylight
	[0.50,   Color(1.0, 1.0, 1.0)],     # 12:00 — noon (brightest)
	[0.70,   Color(1.0, 1.0, 1.0)],     # 16:48 — still bright
	[0.75,   Color(0.95, 0.75, 0.50)],  # 18:00 — dusk golden
	[0.80,   Color(0.80, 0.45, 0.30)],  # 19:12 — sunset orange
	[0.85,   Color(0.35, 0.25, 0.45)],  # 20:24 — twilight
	[0.90,   Color(0.15, 0.15, 0.30)],  # 21:36 — night falls
	[1.0,    Color(0.15, 0.15, 0.30)],  # 24:00 — wraps to midnight
]


func _ready() -> void:
	EventBus.time_tick.connect(_on_time_tick)
	_update_tint()


func _on_time_tick(_total_minutes: int) -> void:
	_update_tint()


func _update_tint() -> void:
	var t: float = GameClock.get_hour_fraction()
	color = _sample_gradient(t)


func _sample_gradient(t: float) -> Color:
	# Find the two keyframes we're between
	for i: int in range(_color_keys.size() - 1):
		var t0: float = _color_keys[i][0]
		var t1: float = _color_keys[i + 1][0]
		if t >= t0 and t <= t1:
			var blend: float = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
			return _color_keys[i][1].lerp(_color_keys[i + 1][1], blend)

	return _color_keys[0][1]
