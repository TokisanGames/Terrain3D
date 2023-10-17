extends Control


var player: Node


func _init() -> void:
	RenderingServer.set_debug_generate_wireframes(true)


func _process(delta) -> void:
	$Label.text = "FPS: %s\n" % str(Engine.get_frames_per_second())
	$Label.text += "Move Speed: %.1f\n" % player.MOVE_SPEED if player else ""
	$Label.text += "Position: %.1v\n" % player.global_position if player else ""
	$Label.text += "Move: WASDEQ/Shift/Mouse\nMove speed: Wheel,+/-\nCamera View: V\n"
	$Label.text += "Gravity toggle: G\nCollision toggle: C\n"
	$Label.text += "Full screen: F11\nMouse toggle: Escape\nQuit: F8\n"


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F8:
				get_tree().quit()
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

