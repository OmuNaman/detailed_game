extends CanvasLayer
## Full conversation UI for player-NPC dialogue. Supports multi-turn back-and-forth.

var is_showing: bool = false
var _current_npc: CharacterBody2D = null
var _conversation_history: Array[Dictionary] = []  # {speaker: String, text: String}
var _exchange_count: int = 0
const MAX_EXCHANGES: int = 5

@onready var _panel: PanelContainer = $PanelContainer
@onready var _name_label: Label = $PanelContainer/VBox/Header/NameLabel
@onready var _scroll: ScrollContainer = $PanelContainer/VBox/ScrollContainer
@onready var _messages_container: VBoxContainer = $PanelContainer/VBox/ScrollContainer/Messages
@onready var _input_field: LineEdit = $PanelContainer/VBox/InputRow/LineEdit
@onready var _send_button: Button = $PanelContainer/VBox/InputRow/SendButton


func _ready() -> void:
	add_to_group("dialogue_box")
	_panel.visible = false
	_send_button.pressed.connect(_on_send_pressed)
	_input_field.text_submitted.connect(_on_text_submitted)


func _unhandled_input(event: InputEvent) -> void:
	if not is_showing:
		return
	if event.is_action_pressed("ui_cancel"):
		hide_dialogue()
		get_viewport().set_input_as_handled()


func start_conversation(npc: CharacterBody2D) -> void:
	## Begin a new conversation with an NPC.
	_current_npc = npc
	_conversation_history.clear()
	_exchange_count = 0
	_name_label.text = npc.npc_name
	_clear_messages()
	_panel.visible = true
	is_showing = true

	# Disable player movement while in conversation
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		player.set_process(false)
		player.set_physics_process(false)

	# Get NPC's opening line
	_add_message(npc.npc_name, "...", true)
	npc.get_dialogue_response_async(func(response: String) -> void:
		_remove_last_message()
		_add_message(npc.npc_name, response, false)
		_conversation_history.append({"speaker": npc.npc_name, "text": response})
		_exchange_count += 1
		_focus_input()
	)


func hide_dialogue() -> void:
	_panel.visible = false
	is_showing = false

	# Notify NPC to create conversation summary memory
	if _current_npc and _current_npc.has_method("on_player_conversation_ended"):
		_current_npc.on_player_conversation_ended()
	_current_npc = null

	# Re-enable player movement
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		player.set_process(true)
		player.set_physics_process(true)

	_input_field.text = ""
	_input_field.release_focus()


func _on_send_pressed() -> void:
	_submit_reply()


func _on_text_submitted(_text: String) -> void:
	_submit_reply()


func _submit_reply() -> void:
	if not _current_npc or not is_showing:
		return

	var player_text: String = _input_field.text.strip_edges()
	if player_text == "":
		return

	if _exchange_count >= MAX_EXCHANGES:
		_add_system_message("(The conversation has naturally wound down. Press ESC to leave.)")
		return

	# Show player's message
	_add_message(PlayerProfile.player_name, player_text, false)
	_conversation_history.append({"speaker": PlayerProfile.player_name, "text": player_text})
	_input_field.text = ""

	# Store player's words as a memory for the NPC
	_current_npc._add_memory_with_embedding(
		"%s said to me: \"%s\" at the %s" % [PlayerProfile.player_name, player_text.left(60), _current_npc._current_destination],
		"dialogue", PlayerProfile.player_name,
		[_current_npc.npc_name, PlayerProfile.player_name] as Array[String],
		_current_npc._current_destination, _current_npc._current_destination, 5.0, 0.3
	)

	# Get NPC reply with conversation context
	_add_message(_current_npc.npc_name, "...", true)
	_current_npc.get_conversation_reply_async(player_text, _conversation_history, func(response: String) -> void:
		_remove_last_message()
		_add_message(_current_npc.npc_name, response, false)
		_conversation_history.append({"speaker": _current_npc.npc_name, "text": response})
		_exchange_count += 1

		if _exchange_count >= MAX_EXCHANGES:
			_add_system_message("(The conversation has naturally wound down. Press ESC to leave.)")
		else:
			_focus_input()
	)


func _add_message(speaker: String, text: String, is_typing: bool) -> void:
	var label := RichTextLabel.new()
	label.fit_content = true
	label.bbcode_enabled = true
	label.scroll_active = false
	label.custom_minimum_size.x = 500

	if is_typing:
		label.text = "[color=gray]%s: ...[/color]" % speaker
	elif speaker == PlayerProfile.player_name:
		label.text = "[color=#7799ff]%s:[/color] %s" % [speaker, text]
	else:
		label.text = "[color=#ffcc44]%s:[/color] %s" % [speaker, text]

	_messages_container.add_child(label)
	# Auto-scroll to bottom
	await get_tree().process_frame
	_scroll.scroll_vertical = _scroll.get_v_scroll_bar().max_value


func _add_system_message(text: String) -> void:
	var label := RichTextLabel.new()
	label.fit_content = true
	label.bbcode_enabled = true
	label.scroll_active = false
	label.text = "[color=gray][i]%s[/i][/color]" % text
	_messages_container.add_child(label)


func _remove_last_message() -> void:
	var count: int = _messages_container.get_child_count()
	if count > 0:
		_messages_container.get_child(count - 1).queue_free()


func _clear_messages() -> void:
	for child: Node in _messages_container.get_children():
		child.queue_free()


func _focus_input() -> void:
	_input_field.grab_focus()
