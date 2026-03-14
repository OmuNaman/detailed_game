extends CanvasLayer
## Debug overlay toggled with F3. Shows NPC needs, destination, memories, and API cost.

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
		entry.custom_minimum_size = Vector2(280, 0)
		entry.scroll_active = false

		var hunger_bar: String = _make_bar(npc.hunger, "E8A040")
		var energy_bar: String = _make_bar(npc.energy, "4080E8")
		var social_bar: String = _make_bar(npc.social, "40C840")
		var mood_val: float = npc.get_mood()
		var mem_count: int = npc.memory.memories.size()
		var conv_count: int = npc.memory.get_by_type("dialogue").size()

		var activity: String = npc.current_activity if npc.current_activity != "" else "idle"
		if activity.length() > 30:
			activity = activity.substr(0, 27) + "..."

		var text: String = "[b]%s[/b] (%s, %d) → %s\n[color=#ADF]%s[/color]\nH:%s E:%s S:%s  Mood:%.0f  Mem:%d  Conv:%d" % [
			npc.npc_name, npc.job, npc.age, npc._current_destination,
			activity,
			hunger_bar, energy_bar, social_bar,
			mood_val, mem_count, conv_count
		]

		# Show top 2 most recent memories (truncated)
		var recent: Array[Dictionary] = npc.memory.get_recent(2)
		for mem: Dictionary in recent:
			var desc: String = mem.get("description", "")
			if desc.length() > 45:
				desc = desc.substr(0, 42) + "..."
			text += "\n  [color=#888]%s[/color]" % desc

		# Show top 2 relationships
		var friends: Array[String] = Relationships.get_closest_friends(npc.npc_name, 2)
		if not friends.is_empty():
			var rel_parts: Array[String] = []
			for friend: String in friends:
				var op: float = Relationships.get_opinion(npc.npc_name, friend)
				rel_parts.append("%s:%+d" % [friend.left(6), int(op)])
			text += "\n  [color=#DAB]Rels: %s[/color]" % " ".join(rel_parts)

		entry.text = text
		_container.add_child(entry)

	# Backend status at the bottom
	var status_entry: RichTextLabel = RichTextLabel.new()
	status_entry.bbcode_enabled = true
	status_entry.fit_content = true
	status_entry.custom_minimum_size = Vector2(280, 0)
	status_entry.scroll_active = false
	var backend_status: String = "[color=#4C4]Backend: connected[/color]" if ApiClient.is_available() else "[color=#C44]Backend: offline[/color]"
	status_entry.text = "\n" + backend_status
	_container.add_child(status_entry)


func _make_bar(value: float, color: String) -> String:
	var filled: int = roundi(value / 10.0)
	var empty: int = 10 - filled
	return "[color=#%s]%s[/color][color=#333]%s[/color]" % [
		color, "█".repeat(filled), "█".repeat(empty)
	]
