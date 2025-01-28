@tool
extends Node

@onready var terrain: Terrain3D = find_child("Terrain3D")


func _ready():
	if not Engine.is_editor_hint() and has_node("UI"):
		$UI.player = $Player

	# Load Sky3D into the demo environment if enabled
	if Engine.is_editor_hint() and has_node("Environment") and \
		Engine.get_singleton(&"EditorInterface").is_plugin_enabled("sky_3d"):
			$Environment.queue_free()
			var sky3d = load("res://addons/sky_3d/src/Sky3D.gd").new()
			sky3d.name = "Sky3D"
			add_child(sky3d, true)
			move_child(sky3d, 1)
			sky3d.owner = self
			sky3d.current_time = 10
			sky3d.enable_editor_time = false
			
		
