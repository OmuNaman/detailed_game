extends CanvasLayer
## Debug overlay toggled with F3. Shows NPC needs, destination, and observation count.

var _visible: bool = false

@onready var _panel: PanelContainer = $PanelContainer
@onready var _container: VBoxContainer = $PanelContainer/MarginContainer/VBoxContainer
@onready var _update_timer: Timer = $UpdateTimer


func _ready() -> void:
	_panel.visible = false
	_update_timer.timeout.connect(_refresh)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F3:
			_visible = not _visible
			_panel.visible = _visible
			if _visible:
				_refresh()


func _refresh() -> void:
	if not _visible:
		return

	# Clear old entries
	for child: Node in _container.get_children():
		child.queue_free()

	var npcs: Array[Node] = get_tree().get_nodes_in_group("npcs")
	for npc: Node in npcs:
		var entry: RichTextLabel = RichTextLabel.new()
		entry.bbcode_enabled = true
		entry.fit_content = true
		entry.custom_minimum_size = Vector2(240, 0)
		entry.scroll_active = false

		var hunger_bar: String = _make_bar(npc.hunger, "E8A040")
		var energy_bar: String = _make_bar(npc.energy, "4080E8")
		var social_bar: String = _make_bar(npc.social, "40C840")
		var mood_val: float = npc.get_mood()

		entry.text = "[b]%s[/b] (%s) → %s\nH:%s E:%s S:%s  Mood:%.0f  Obs:%d" % [
			npc.npc_name, npc.job, npc._current_destination,
			hunger_bar, energy_bar, social_bar,
			mood_val, npc.observations.size()
		]
		_container.add_child(entry)


func _make_bar(value: float, color: String) -> String:
	var filled: int = roundi(value / 10.0)
	var empty: int = 10 - filled
	return "[color=#%s]%s[/color][color=#333]%s[/color]" % [
		color, "█".repeat(filled), "█".repeat(empty)
	]
