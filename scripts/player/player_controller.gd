extends CharacterBody2D

const SPEED: float = 120.0

var _facing_direction: Vector2 = Vector2.DOWN
var _is_moving: bool = false
var _dialogue_box: Node = null

@onready var sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	add_to_group("player")


func _physics_process(_delta: float) -> void:
	var input_dir: Vector2 = Vector2.ZERO
	input_dir.x = Input.get_axis("move_left", "move_right")
	input_dir.y = Input.get_axis("move_up", "move_down")

	# GBA Pokemon style: snap to cardinal directions, no diagonal
	if input_dir != Vector2.ZERO:
		if abs(input_dir.x) >= abs(input_dir.y):
			input_dir = Vector2(sign(input_dir.x), 0)
		else:
			input_dir = Vector2(0, sign(input_dir.y))
		_facing_direction = input_dir
		_is_moving = true
	else:
		_is_moving = false

	velocity = input_dir * SPEED
	move_and_slide()

	_update_sprite()


func _update_sprite() -> void:
	if not sprite:
		return
	# Flip sprite horizontally based on facing direction
	if _facing_direction.x < 0:
		sprite.flip_h = true
	elif _facing_direction.x > 0:
		sprite.flip_h = false

	# Modulate slightly when moving for visual feedback
	if _is_moving:
		sprite.modulate.a = 1.0
	else:
		sprite.modulate.a = 0.85


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		_handle_interact()


func _handle_interact() -> void:
	if _dialogue_box == null:
		_dialogue_box = get_tree().get_first_node_in_group("dialogue_box")
	if _dialogue_box == null:
		return

	# Toggle off if already showing
	if _dialogue_box.is_showing:
		_dialogue_box.hide_dialogue()
		return

	# Find nearest NPC within 1.5 tiles (48px)
	var nearest_npc: Node = null
	var nearest_dist: float = 48.0
	for npc: Node in get_tree().get_nodes_in_group("npcs"):
		var dist: float = global_position.distance_to(npc.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_npc = npc

	if nearest_npc == null:
		return

	var response: String = nearest_npc.get_dialogue_response()
	_dialogue_box.show_dialogue(nearest_npc.npc_name, response)


func get_facing_direction() -> Vector2:
	return _facing_direction
