extends CharacterBody3D

@export var MOVE_SPEED: float = 5.0
@export var gravity_enabled: bool = false
@export var collision_enabled: bool = false :
	set(value):
		collision_enabled = value
		$CollisionShape3D.disabled = ! collision_enabled


func _ready():
	pass


func _physics_process(delta):
	var direction: Vector3 = get_camera_relative_input(true)
	if gravity_enabled:
		velocity.y -= 90.81 * delta
	position += direction * MOVE_SPEED
	move_and_slide()
	
		
# Returns the input vector relative to the camera. Forward is always the direction the camera is facing
func get_camera_relative_input(flat: bool = true) -> Vector3:
	var input_dir: Vector3 = Vector3.ZERO
	if Input.is_action_pressed("left"):
		input_dir -= %Camera3D.global_transform.basis.x
	if Input.is_action_pressed("right"):
		input_dir += %Camera3D.global_transform.basis.x
	if Input.is_action_pressed("forward"):
		input_dir -= %Camera3D.global_transform.basis.z
	if Input.is_action_pressed("backward"):
		input_dir += %Camera3D.global_transform.basis.z
	if Input.is_action_pressed("up"):
		if flat:
			input_dir += Vector3.UP
		else:
			input_dir += %Camera3D.global_transform.basis.y
	if Input.is_action_pressed("down"):
		if flat:
			input_dir -= Vector3.UP
		else:
			input_dir -= %Camera3D.global_transform.basis.y
	if Input.is_key_pressed(KEY_KP_ADD) or Input.is_key_pressed(KEY_EQUAL):
		MOVE_SPEED += .05
	if Input.is_key_pressed(KEY_KP_SUBTRACT) or Input.is_key_pressed(KEY_MINUS):
		MOVE_SPEED -= .05
	return input_dir		


func _input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			MOVE_SPEED += .1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			MOVE_SPEED -= .1
	
