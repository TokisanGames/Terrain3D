extends Node3D


@export var generate_terrain: bool = false 


func _ready():
	if generate_terrain:
		var terrain := Terrain3D.new()
		terrain.storage = Terrain3DStorage.new()
		terrain.storage.noise_enabled = true
		terrain.storage.noise_height = 0.5
		terrain.storage.add_region(Vector3(0, 0, 0))
		terrain.storage.add_region(Vector3(2048, 0, -2048))
		terrain.storage.add_region(Vector3(-2048, 0, 2048))
		terrain.storage.add_region(Vector3(-3172, 0, -3172))
		terrain.storage.add_region(Vector3(3172, 0, 3172))
		terrain.storage.add_region(Vector3(-1024, 0, -1024))
		terrain.name = "Terrain3D"
		add_child(terrain, true)
		
		# Retreive 512x512 region blur map from RenderingServer
		var rbmap_rid: RID = terrain.storage.get_region_blend_map()
		var img = RenderingServer.texture_2d_get(rbmap_rid)
		$UI/TextureRect.texture = ImageTexture.create_from_image(img)
		
		return
		

#################
## Game demo

func _init() -> void:
	RenderingServer.set_debug_generate_wireframes(true)


func _process(delta) -> void:
	$UI/Label.text = "FPS: %s\n" % str(Engine.get_frames_per_second())
	$UI/Label.text += "Move Speed: %.1f\n" % $Player.MOVE_SPEED
	$UI/Label.text += "Position: %.1v\n" % $Player.global_position
	

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F10:
				var vp = get_viewport()
				vp.debug_draw = (vp.debug_draw + 1 ) % 4
				get_viewport().set_input_as_handled()
			KEY_F11:
				toggle_fullscreen()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				else:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				get_viewport().set_input_as_handled()
		
		
func toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN or \
		DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2(1280, 720))
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)

