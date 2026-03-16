extends CanvasLayer
## Admin/God Mode Panel — inject memories, directives, moods into NPCs.
## Toggle with F9. Inspired by Stanford Generative Agents researcher interface.

var _visible: bool = false
var _panel: PanelContainer
var _npc_selector: OptionButton
var _selected_npc: CharacterBody2D = null

# Memory injection
var _memory_text: LineEdit
var _importance_slider: HSlider
var _importance_label: Label
var _valence_slider: HSlider
var _valence_label: Label

# Directive
var _directive_text: LineEdit
var _location_selector: OptionButton
var _hour_start: SpinBox
var _hour_end: SpinBox

# Mood
var _emotion_text: LineEdit
var _hunger_slider: HSlider
var _energy_slider: HSlider
var _social_slider: HSlider

# Seed Event
var _seed_event_text: LineEdit
var _seed_location: OptionButton
var _seed_hour: SpinBox
var _seed_also_coworkers: CheckBox

# Status
var _status_label: RichTextLabel

const BUILDINGS: Array[String] = [
	"Bakery", "General Store", "Tavern", "Church", "Sheriff Office",
	"Courthouse", "Blacksmith", "Library", "Inn", "Market",
	"Carpenter Workshop", "Tailor Shop", "Stables", "Clinic", "School",
]


func _ready() -> void:
	layer = 31
	_build_ui()
	_panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F9:
			_toggle()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _visible:
			_toggle()
			get_viewport().set_input_as_handled()


func _toggle() -> void:
	_visible = not _visible
	_panel.visible = _visible
	if _visible:
		_refresh_npc_list()
		_update_sliders_from_npc()
	# Pause/resume player
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		player.set_process(not _visible)
		player.set_physics_process(not _visible)


func _refresh_npc_list() -> void:
	_npc_selector.clear()
	var npcs: Array[Node] = []
	npcs.assign(get_tree().get_nodes_in_group("npcs"))
	npcs.sort_custom(func(a: Node, b: Node) -> bool:
		return (a as CharacterBody2D).npc_name < (b as CharacterBody2D).npc_name)
	for npc_node: Node in npcs:
		var npc: CharacterBody2D = npc_node as CharacterBody2D
		_npc_selector.add_item(npc.npc_name)
	if _npc_selector.item_count > 0:
		_on_npc_selected(0)


func _on_npc_selected(index: int) -> void:
	var name: String = _npc_selector.get_item_text(index)
	for npc_node: Node in get_tree().get_nodes_in_group("npcs"):
		var npc: CharacterBody2D = npc_node as CharacterBody2D
		if npc.npc_name == name:
			_selected_npc = npc
			_update_sliders_from_npc()
			return


func _update_sliders_from_npc() -> void:
	if _selected_npc == null:
		return
	_hunger_slider.value = _selected_npc.hunger
	_energy_slider.value = _selected_npc.energy
	_social_slider.value = _selected_npc.social
	var emotion: String = _selected_npc.memory.core_memory.get("emotional_state", "")
	_emotion_text.text = emotion
	_set_status("[color=#aaa]Selected: %s (%s at %s)[/color]" % [
		_selected_npc.npc_name, _selected_npc.job, _selected_npc._current_destination])


# --- Actions ---

func _inject_memory() -> void:
	if _selected_npc == null or _memory_text.text.strip_edges() == "":
		_set_status("[color=#f88]No NPC selected or empty text[/color]")
		return
	var text: String = _memory_text.text.strip_edges()
	var importance: float = _importance_slider.value
	var valence: float = _valence_slider.value
	_selected_npc._add_memory_with_embedding(
		text, "observation", "Admin",
		[_selected_npc.npc_name] as Array[String],
		_selected_npc._current_destination, _selected_npc._current_destination,
		importance, valence)
	_memory_text.text = ""
	_set_status("[color=#8f8]Injected memory into %s (imp=%.1f, val=%.1f)[/color]" % [
		_selected_npc.npc_name, importance, valence])
	print("[Admin] Injected memory into %s: \"%s\"" % [_selected_npc.npc_name, text.left(60)])


func _seed_event() -> void:
	## Stanford-style event injection. Injects observation into selected NPC (+ optional coworkers).
	## Importance 7.0 triggers reaction evaluation, gossip handles propagation.
	if _selected_npc == null or _seed_event_text.text.strip_edges() == "":
		_set_status("[color=#f88]No NPC selected or empty event text[/color]")
		return
	var event_desc: String = _seed_event_text.text.strip_edges()
	var location: String = _seed_location.get_item_text(_seed_location.selected)
	var hour: int = int(_seed_hour.value)

	# Build natural observation text
	var obs_text: String = "%s heard that %s at the %s at %d:00 today. Everyone in town is welcome." % [
		_selected_npc.npc_name, event_desc, location, hour]

	# Inject into primary NPC
	var seeded: Array[String] = [_selected_npc.npc_name]
	_selected_npc._add_memory_with_embedding(
		obs_text, "observation", "townsfolk",
		[_selected_npc.npc_name] as Array[String],
		_selected_npc._current_destination, location, 7.0, 0.6)

	# Optionally inject into 2 coworkers (same workplace)
	if _seed_also_coworkers.button_pressed:
		var count: int = 0
		for npc_node: Node in get_tree().get_nodes_in_group("npcs"):
			var npc: CharacterBody2D = npc_node as CharacterBody2D
			if npc == _selected_npc:
				continue
			if npc.workplace_building == _selected_npc.workplace_building:
				var coworker_obs: String = "%s heard from %s that %s at the %s at %d:00 today." % [
					npc.npc_name, _selected_npc.npc_name, event_desc, location, hour]
				npc._add_memory_with_embedding(
					coworker_obs, "gossip", _selected_npc.npc_name,
					[npc.npc_name, _selected_npc.npc_name] as Array[String],
					npc._current_destination, location, 6.0, 0.5)
				seeded.append(npc.npc_name)
				count += 1
				if count >= 2:
					break

	# Trigger reaction evaluation — handles both immediate and future events via _process_reaction_result()
	_selected_npc.planner.evaluate_reaction(obs_text, 7.0)

	_seed_event_text.text = ""
	_set_status("[color=#8f8]Seeded event into %s! Watch gossip propagate.[/color]" % ", ".join(seeded))
	print("[Seed Event] Injected into %s: \"%s\" at %s hour %d" % [
		", ".join(seeded), event_desc, location, hour])


func _give_directive() -> void:
	if _selected_npc == null or _directive_text.text.strip_edges() == "":
		_set_status("[color=#f88]No NPC selected or empty directive[/color]")
		return
	var activity: String = _directive_text.text.strip_edges()
	var location: String = _location_selector.get_item_text(_location_selector.selected)
	var start: int = int(_hour_start.value)
	var end: int = int(_hour_end.value)
	if end <= start:
		_set_status("[color=#f88]End hour must be after start hour[/color]")
		return

	# Build new L1 block and merge into plan
	var new_block: Dictionary = {
		"start_hour": start, "end_hour": end,
		"location": location, "activity": activity, "decomposed": false
	}
	# Remove overlapping blocks
	var filtered: Array[Dictionary] = []
	for block: Dictionary in _selected_npc.planner._plan_level1:
		if block["end_hour"] <= start or block["start_hour"] >= end:
			filtered.append(block)
	filtered.append(new_block)
	filtered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["start_hour"] < b["start_hour"])
	_selected_npc.planner._plan_level1 = filtered
	_selected_npc.planner.clear_decomposed_plans()
	_selected_npc._update_destination(GameClock.hour)
	_directive_text.text = ""
	_set_status("[color=#8f8]Directive set: %s → %s (%d:00-%d:00)[/color]" % [
		_selected_npc.npc_name, location, start, end])
	print("[Admin] Directive for %s: \"%s\" at %s (%d-%d)" % [
		_selected_npc.npc_name, activity, location, start, end])


func _apply_mood() -> void:
	if _selected_npc == null:
		return
	_selected_npc.hunger = _hunger_slider.value
	_selected_npc.energy = _energy_slider.value
	_selected_npc.social = _social_slider.value
	if _emotion_text.text.strip_edges() != "":
		_selected_npc.memory.update_emotional_state(_emotion_text.text.strip_edges())
	_set_status("[color=#8f8]Updated %s mood (H:%.0f E:%.0f S:%.0f)[/color]" % [
		_selected_npc.npc_name, _hunger_slider.value, _energy_slider.value, _social_slider.value])


func _trigger_reflection() -> void:
	if _selected_npc == null:
		return
	_selected_npc.reflection.enhanced_reflect()
	_set_status("[color=#8f8]Triggered reflection for %s[/color]" % _selected_npc.npc_name)


func _skip_to_hour() -> void:
	var target: int = int(_hour_start.value)
	GameClock.hour = target
	GameClock.minute = 0
	GameClock.total_minutes = GameClock.total_minutes - (GameClock.total_minutes % 1440) + target * 60
	EventBus.time_hour_changed.emit(target)
	_set_status("[color=#8f8]Skipped to hour %d:00[/color]" % target)


func _save_all() -> void:
	var town: Node = get_tree().get_first_node_in_group("town_root")
	if town and town.has_method("_save_all_memories"):
		town._save_all_memories()
	else:
		# Fallback: iterate NPCs and save directly
		for npc_node: Node in get_tree().get_nodes_in_group("npcs"):
			var npc: CharacterBody2D = npc_node as CharacterBody2D
			npc.memory.save_all()
		Relationships.save_relationships()
	_set_status("[color=#8f8]Saved all NPC data[/color]")


func _set_status(bbcode: String) -> void:
	_status_label.text = bbcode


# --- UI Construction ---

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.1
	_panel.anchor_right = 0.9
	_panel.anchor_top = 0.05
	_panel.anchor_bottom = 0.95
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	# Header
	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "Admin Panel (F9)"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)
	header.add_child(_spacer())
	_npc_selector = OptionButton.new()
	_npc_selector.custom_minimum_size.x = 200
	_npc_selector.item_selected.connect(_on_npc_selected)
	header.add_child(_npc_selector)

	vbox.add_child(HSeparator.new())

	# === INJECT MEMORY ===
	vbox.add_child(_section_label("Inject Memory"))
	_memory_text = LineEdit.new()
	_memory_text.placeholder_text = "Memory text (e.g., 'There will be a festival at the Tavern tonight')"
	vbox.add_child(_memory_text)

	var imp_row := HBoxContainer.new()
	vbox.add_child(imp_row)
	imp_row.add_child(_label("Importance:"))
	_importance_slider = HSlider.new()
	_importance_slider.min_value = 1.0
	_importance_slider.max_value = 10.0
	_importance_slider.value = 5.0
	_importance_slider.step = 0.5
	_importance_slider.custom_minimum_size.x = 120
	_importance_slider.value_changed.connect(func(v: float) -> void: _importance_label.text = "%.1f" % v)
	imp_row.add_child(_importance_slider)
	_importance_label = _label("5.0")
	imp_row.add_child(_importance_label)
	imp_row.add_child(_spacer())
	imp_row.add_child(_label("Valence:"))
	_valence_slider = HSlider.new()
	_valence_slider.min_value = -1.0
	_valence_slider.max_value = 1.0
	_valence_slider.value = 0.0
	_valence_slider.step = 0.1
	_valence_slider.custom_minimum_size.x = 120
	_valence_slider.value_changed.connect(func(v: float) -> void: _valence_label.text = "%.1f" % v)
	imp_row.add_child(_valence_slider)
	_valence_label = _label("0.0")
	imp_row.add_child(_valence_label)

	var inject_btn := Button.new()
	inject_btn.text = "Inject Memory"
	inject_btn.pressed.connect(_inject_memory)
	vbox.add_child(inject_btn)

	vbox.add_child(HSeparator.new())

	# === SEED EVENT (Stanford-style) ===
	vbox.add_child(_section_label("Seed Event (Stanford Party Planning)"))
	_seed_event_text = LineEdit.new()
	_seed_event_text.placeholder_text = "Event (e.g., 'Grand festival with music and food')"
	vbox.add_child(_seed_event_text)
	var seed_row := HBoxContainer.new()
	vbox.add_child(seed_row)
	seed_row.add_child(_label("Location:"))
	_seed_location = OptionButton.new()
	_seed_location.custom_minimum_size.x = 140
	for bld: String in BUILDINGS:
		_seed_location.add_item(bld)
	seed_row.add_child(_seed_location)
	seed_row.add_child(_spacer())
	seed_row.add_child(_label("Hour:"))
	_seed_hour = SpinBox.new()
	_seed_hour.min_value = 6
	_seed_hour.max_value = 21
	_seed_hour.value = 18
	seed_row.add_child(_seed_hour)
	seed_row.add_child(_spacer())
	_seed_also_coworkers = CheckBox.new()
	_seed_also_coworkers.text = "Also seed 2 coworkers"
	_seed_also_coworkers.button_pressed = true
	seed_row.add_child(_seed_also_coworkers)
	var seed_btn := Button.new()
	seed_btn.text = "Seed Event (inject + let gossip propagate)"
	seed_btn.pressed.connect(_seed_event)
	vbox.add_child(seed_btn)

	vbox.add_child(HSeparator.new())

	# === GIVE DIRECTIVE ===
	vbox.add_child(_section_label("Give Directive (Plan Override)"))
	_directive_text = LineEdit.new()
	_directive_text.placeholder_text = "Task (e.g., 'Organize a party', 'Go talk to Maria about the festival')"
	vbox.add_child(_directive_text)

	var dir_row := HBoxContainer.new()
	vbox.add_child(dir_row)
	dir_row.add_child(_label("Location:"))
	_location_selector = OptionButton.new()
	_location_selector.custom_minimum_size.x = 160
	for bld: String in BUILDINGS:
		_location_selector.add_item(bld)
	dir_row.add_child(_location_selector)
	dir_row.add_child(_spacer())
	dir_row.add_child(_label("Hours:"))
	_hour_start = SpinBox.new()
	_hour_start.min_value = 5
	_hour_start.max_value = 22
	_hour_start.value = GameClock.hour
	dir_row.add_child(_hour_start)
	dir_row.add_child(_label("to"))
	_hour_end = SpinBox.new()
	_hour_end.min_value = 6
	_hour_end.max_value = 23
	_hour_end.value = mini(GameClock.hour + 2, 22)
	dir_row.add_child(_hour_end)

	var dir_btn := Button.new()
	dir_btn.text = "Override Current Plan"
	dir_btn.pressed.connect(_give_directive)
	vbox.add_child(dir_btn)

	vbox.add_child(HSeparator.new())

	# === MODIFY STATE ===
	vbox.add_child(_section_label("Modify State"))
	var emo_row := HBoxContainer.new()
	vbox.add_child(emo_row)
	emo_row.add_child(_label("Emotional State:"))
	_emotion_text = LineEdit.new()
	_emotion_text.placeholder_text = "e.g., 'Feeling excited about the upcoming festival'"
	_emotion_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	emo_row.add_child(_emotion_text)

	var needs_row := HBoxContainer.new()
	vbox.add_child(needs_row)
	needs_row.add_child(_label("Hunger:"))
	_hunger_slider = _need_slider()
	needs_row.add_child(_hunger_slider)
	needs_row.add_child(_label("Energy:"))
	_energy_slider = _need_slider()
	needs_row.add_child(_energy_slider)
	needs_row.add_child(_label("Social:"))
	_social_slider = _need_slider()
	needs_row.add_child(_social_slider)

	var mood_btn := Button.new()
	mood_btn.text = "Apply Mood Changes"
	mood_btn.pressed.connect(_apply_mood)
	vbox.add_child(mood_btn)

	vbox.add_child(HSeparator.new())

	# === QUICK ACTIONS ===
	vbox.add_child(_section_label("Quick Actions"))
	var action_row := HBoxContainer.new()
	vbox.add_child(action_row)
	var ref_btn := Button.new()
	ref_btn.text = "Trigger Reflection"
	ref_btn.pressed.connect(_trigger_reflection)
	action_row.add_child(ref_btn)
	var skip_btn := Button.new()
	skip_btn.text = "Skip to Hour (use Start hour above)"
	skip_btn.pressed.connect(_skip_to_hour)
	action_row.add_child(skip_btn)
	var save_btn := Button.new()
	save_btn.text = "Save All"
	save_btn.pressed.connect(_save_all)
	action_row.add_child(save_btn)

	vbox.add_child(HSeparator.new())

	# Status
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.text = "[color=#aaa]Ready. Select an NPC above.[/color]"
	vbox.add_child(_status_label)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	return l


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	return l


func _spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _need_slider() -> HSlider:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 100.0
	s.value = 80.0
	s.step = 5.0
	s.custom_minimum_size.x = 80
	return s
