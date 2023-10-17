extends CharacterBody3D

@export var MOVE_SPEED: float = 100.0
@export var JUMP_SPEED: float = 2.0
@export var first_person: bool = false : 
	set(value):
		first_person = value
		if first_person:
			$CameraManager/Arm.spring_length = 0.0
		else:
			$CameraManager/Arm.spring_length = 4.0

@export var gravity_enabled: bool = true :
	set(value):
		gravity_enabled = value
		if not gravity_enabled:
			velocity.y = 0
			
@export var collision_enabled: bool = true :
	set(value):
		collision_enabled = value
		$CollisionShapeBody.disabled = ! collision_enabled
		$CollisionShapeRay.disabled = ! collision_enabled


func _physics_process(delta) -> void:
	var direction: Vector3 = get_camera_relative_input()
	var h_veloc: Vector2 = Vector2(direction.x, direction.z) * MOVE_SPEED
	if Input.is_action_pressed("sprint"):
		h_veloc *= 2
	velocity.x = h_veloc.x
	velocity.z = h_veloc.y
	if gravity_enabled:
		velocity.y -= 40 * delta
	move_and_slide()


# Returns the input vector relative to the camera. Forward is always the direction the camera is facing
func get_camera_relative_input() -> Vector3:
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
		velocity.y += JUMP_SPEED + MOVE_SPEED*.016
	if Input.is_action_pressed("down"):
		velocity.y -= JUMP_SPEED + MOVE_SPEED*.016
	if Input.is_key_pressed(KEY_KP_ADD) or Input.is_key_pressed(KEY_EQUAL):
		MOVE_SPEED = clamp(MOVE_SPEED + .5, 0, 9999)
	if Input.is_key_pressed(KEY_KP_SUBTRACT) or Input.is_key_pressed(KEY_MINUS):
		MOVE_SPEED = clamp(MOVE_SPEED - .5, 0, 9999)
	return input_dir		


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			MOVE_SPEED = clamp(MOVE_SPEED + 5, 0, 9999)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			MOVE_SPEED = clamp(MOVE_SPEED - 5, 0, 9999)
	
	elif event is InputEventKey:
		if event.pressed and event.keycode == KEY_V:
			first_person = ! first_person
		if event.pressed and event.keycode == KEY_G:
			gravity_enabled = ! gravity_enabled
		if event.pressed and event.keycode == KEY_C:
			collision_enabled = ! collision_enabled

		elif event.is_action_released("down") or event.is_action_released("up"):
			velocity.y = 0
