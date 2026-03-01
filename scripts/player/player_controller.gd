extends CharacterBody2D

const SPEED: float = 120.0

var _facing_direction: Vector2 = Vector2.DOWN
var _is_moving: bool = false

@onready var sprite: Sprite2D = $Sprite2D


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


func get_facing_direction() -> Vector2:
	return _facing_direction
