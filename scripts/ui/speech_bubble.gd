extends Node2D
## Temporary floating text above an NPC's head. Fades after a few seconds.

var _label: Label
var _timer: float = 0.0
var _duration: float = 3.0


func show_text(text: String, duration: float = 3.0) -> void:
	_duration = duration
	_timer = 0.0

	_label = Label.new()
	_label.text = text
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-80, -50)
	_label.custom_minimum_size = Vector2(160, 0)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# Style: small white text with dark outline
	_label.add_theme_font_size_override("font_size", 10)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 3)

	add_child(_label)


func _process(delta: float) -> void:
	if not _label:
		return
	_timer += delta

	# Float upward slowly
	_label.position.y -= 5.0 * delta

	# Fade out in the last second
	if _timer > _duration - 1.0:
		_label.modulate.a = maxf(0.0, 1.0 - (_timer - (_duration - 1.0)))

	if _timer >= _duration:
		queue_free()
