class_name NavBakerPlugin
extends EditorInspectorPlugin


func _can_handle(object) -> bool:
	return object is ChunkBaker


func _parse_begin(object) -> void:
	var bake_button:Button = Button.new()
	bake_button.text = "Bake terrain navigation"
	bake_button.pressed.connect(func():
		(object as ChunkBaker).bake_terrain()
		)
	add_custom_control(bake_button)
	var stop_bake:Button = Button.new()
	stop_bake.text = "Stop bake"
	stop_bake.pressed.connect(func(): (object as ChunkBaker).stop_it = true)
	#(object as ChunkBaker).bake_started.connect(func(): stop_bake.disabled = false)
	#(object as ChunkBaker).bake_ended.connect(func(): stop_bake.disabled = true)
	#stop_bake.disabled = true
	add_custom_control(stop_bake)
