@tool
extends Node

@onready var terrain: Terrain3D = find_child("Terrain3D")
@export var nb_test_instance_rows:int = 100:
	set(value):
		nb_test_instance_rows = value
		if Engine.is_editor_hint():		
			spawn_instances(nb_test_instance_rows)
			
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
		
	spawn_instances(nb_test_instance_rows)
		
func spawn_instances(width: int = 10, pitch:float = 20.0):
	terrain.instancer.clear_by_mesh(2)
		# Instance foliage
	var xforms: Array[Transform3D]
	
	var step: int = 1
	for x in range(0, width, step):
		for z in range(0, width, step):
			var pos: Vector3 = $Player.global_position + Vector3(x*pitch, 0, z*pitch) - Vector3(width, 0, width) * .5
			pos.y = terrain.data.get_height(pos)
			xforms.push_back(Transform3D(Basis(), pos))
	terrain.instancer.add_transforms(2, xforms)
