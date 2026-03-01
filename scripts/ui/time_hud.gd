extends CanvasLayer
## Displays current game time in the top-left corner.

@onready var time_label: Label = $MarginContainer/TimeLabel


func _ready() -> void:
	EventBus.time_tick.connect(_on_time_tick)
	_update_display()


func _on_time_tick(_total_minutes: int) -> void:
	_update_display()


func _update_display() -> void:
	if time_label:
		time_label.text = GameClock.get_full_display_string()
