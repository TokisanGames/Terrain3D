class_name UnpackerPlugin
extends EditorInspectorPlugin


func _can_handle(object) -> bool:
	return object is NavmeshBundleUnpacker


func _parse_begin(object) -> void:
	var unpack_button:Button = Button.new()
	unpack_button.text = "Unpack"
	unpack_button.pressed.connect(func():
		(object as NavmeshBundleUnpacker).unpack()
		)
	add_custom_control(unpack_button)
