extends CharacterBody2D
## Controls a single NPC: schedule-driven movement between buildings via navigation.

const SPEED: float = 80.0

var npc_name: String = ""
var job: String = ""
var home_building: String = ""
var workplace_building: String = ""
var sprite_path: String = ""

var _current_destination: String = ""
var _is_navigating: bool = false
var _building_positions: Dictionary = {}
var _nav_retry_timer: float = 0.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var name_label: Label = $NameLabel


func initialize(data: Dictionary, building_positions: Dictionary) -> void:
	## Call BEFORE adding to scene tree. Sets NPC identity and building targets.
	npc_name = data.get("name", "NPC")
	job = data.get("job", "")
	home_building = data.get("home", "")
	workplace_building = data.get("workplace", "")
	sprite_path = data.get("sprite", "")

	_building_positions = building_positions


func _ready() -> void:
	if sprite_path != "":
		var tex: Texture2D = load(sprite_path)
		if tex:
			sprite.texture = tex
	name_label.text = npc_name

	nav_agent.path_desired_distance = 8.0
	nav_agent.target_desired_distance = 16.0
	nav_agent.navigation_finished.connect(_on_navigation_finished)

	EventBus.time_hour_changed.connect(_on_hour_changed)

	# NavigationServer needs multiple frames to build navmesh from TileMapLayer
	for i: int in range(3):
		await get_tree().physics_frame
	_update_destination(GameClock.hour)


func _physics_process(delta: float) -> void:
	# Retry navigation if path wasn't found on first attempt
	if _nav_retry_timer > 0.0:
		_nav_retry_timer -= delta
		if _nav_retry_timer <= 0.0:
			_current_destination = ""  # force re-evaluation
			_update_destination(GameClock.hour)
		return

	if not _is_navigating:
		return

	if nav_agent.is_navigation_finished():
		_is_navigating = false
		velocity = Vector2.ZERO
		return

	var next_pos: Vector2 = nav_agent.get_next_path_position()
	var direction: Vector2 = global_position.direction_to(next_pos)
	velocity = direction * SPEED
	move_and_slide()

	# Flip sprite based on movement direction
	if velocity.x < -1.0:
		sprite.flip_h = true
	elif velocity.x > 1.0:
		sprite.flip_h = false


func _on_navigation_finished() -> void:
	_is_navigating = false
	velocity = Vector2.ZERO


func _on_hour_changed(hour: int) -> void:
	_update_destination(hour)


func _update_destination(hour: int) -> void:
	var dest: String = _get_schedule_destination(hour)
	if dest == _current_destination:
		return

	_current_destination = dest
	var target: Vector2 = _building_positions.get(dest, Vector2.ZERO)
	if target == Vector2.ZERO:
		push_warning("%s: no position found for building '%s'" % [npc_name, dest])
		return

	nav_agent.target_position = target
	_is_navigating = true

	# If nav agent can't find a path, retry in 2 seconds
	await get_tree().physics_frame
	await get_tree().physics_frame
	if nav_agent.is_navigation_finished() and global_position.distance_to(target) > nav_agent.target_desired_distance:
		_is_navigating = false
		_nav_retry_timer = 2.0


func _get_schedule_destination(hour: int) -> String:
	## 22-06: sleep at home | 06-17: work | 17-22: tavern
	if hour >= 22 or hour < 6:
		return home_building
	elif hour >= 6 and hour < 17:
		return workplace_building
	else:
		return "Tavern"
