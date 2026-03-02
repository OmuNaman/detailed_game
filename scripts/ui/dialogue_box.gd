extends CanvasLayer
## Simple dialogue box for NPC interaction. Shows name + text at screen bottom.

var is_showing: bool = false

@onready var _panel: PanelContainer = $PanelContainer
@onready var _name_label: Label = $PanelContainer/MarginContainer/VBoxContainer/NameLabel
@onready var _dialogue_label: Label = $PanelContainer/MarginContainer/VBoxContainer/DialogueLabel


func _ready() -> void:
	add_to_group("dialogue_box")
	_panel.visible = false


func show_dialogue(speaker_name: String, text: String) -> void:
	_name_label.text = speaker_name
	_dialogue_label.text = text
	_panel.visible = true
	is_showing = true


func hide_dialogue() -> void:
	_panel.visible = false
	is_showing = false
