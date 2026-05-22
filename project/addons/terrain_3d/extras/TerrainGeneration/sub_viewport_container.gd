@tool
extends SubViewportContainer

var orbit_capture: bool = false

@onready var camera_pivot_yaw: Node3D = $SubViewport/CameraPivotYaw
@onready var camera_pivot_pitch: Node3D = $SubViewport/CameraPivotYaw/CameraPivotPitch
@onready var preview_camera_3d: Camera3D = %PreviewCamera3D


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			orbit_capture = !orbit_capture
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			preview_camera_3d.fov -= 10
			preview_camera_3d.fov = clamp(preview_camera_3d.fov, 1, 179)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			preview_camera_3d.fov += 10
			preview_camera_3d.fov = clamp(preview_camera_3d.fov, 1, 179)
			
	if event is InputEventMouseMotion:
		if orbit_capture:
			preview_camera_3d.rotation = Vector3.ZERO
			camera_pivot_yaw.rotate_y(event.relative.x * 0.01)
			camera_pivot_pitch.rotate_x(-event.relative.y * 0.01)
		
