extends CanvasLayer
## Name entry screen shown on first launch. Pauses game until name is set.

@onready var _line_edit: LineEdit = $Panel/VBox/LineEdit
@onready var _begin_button: Button = $Panel/VBox/BeginButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_begin_button.disabled = true
	_line_edit.text_changed.connect(_on_text_changed)
	_line_edit.text_submitted.connect(_on_text_submitted)
	_begin_button.pressed.connect(_on_begin_pressed)
	_line_edit.grab_focus()


func _on_text_changed(new_text: String) -> void:
	_begin_button.disabled = new_text.strip_edges().length() < 2


func _on_text_submitted(_text: String) -> void:
	_confirm_name()


func _on_begin_pressed() -> void:
	_confirm_name()


func _confirm_name() -> void:
	var name_text: String = _line_edit.text.strip_edges()
	if name_text.length() < 2:
		return
	PlayerProfile.set_player_name(name_text)
	get_tree().paused = false
	queue_free()
