extends Node
class_name Terrain3DUI


# Includes
const Toolbar: Script = preload("res://addons/terrain/editor/components/toolbar.gd")
const ToolSettings: Script = preload("res://addons/terrain/editor/components/tool_settings.gd")

var plugin: Terrain3DEditorPlugin
var toolbar: Toolbar
var toolbar_settings: ToolSettings
var setting_has_changed: bool = false
var visible: bool = false
var picking: int = Terrain3DEditor.TOOL_MAX
var picking_callback: Callable


func _enter_tree() -> void:
	toolbar = Toolbar.new()
	toolbar.hide()
	toolbar.connect("tool_changed", _on_tool_changed)
	
	toolbar_settings = ToolSettings.new()
	toolbar_settings.connect("setting_changed", _on_setting_changed)
	toolbar_settings.connect("picking", _on_picking)
	toolbar_settings.hide()

	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.add_control_to_bottom(toolbar_settings)


func _exit_tree() -> void:
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	toolbar_settings.get_parent().remove_child(toolbar_settings)
	toolbar.queue_free()
	toolbar_settings.queue_free()

	
func set_visible(p_visible: bool) -> void:
	visible = p_visible
	toolbar.set_visible(p_visible)
	
	if p_visible:
		p_visible = plugin.editor.get_tool() != Terrain3DEditor.REGION
	toolbar_settings.set_visible(p_visible)


func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	if not visible:
		return

	if plugin.editor:
		plugin.editor.set_tool(p_tool)
		plugin.editor.set_operation(p_operation)
		print_debug("Setting tool: %s, operation: %s" % [ p_tool, p_operation ])
	
	if p_tool != Terrain3DEditor.REGION:
		# Select which settings to hide. Options:
		# size, opactiy, height, slope, color, roughness, (height|color|roughness) picker
		var to_hide: PackedStringArray = []
		
		if p_tool == Terrain3DEditor.HEIGHT:
			to_hide.push_back("slope")
			to_hide.push_back("color")
			to_hide.push_back("color picker")
			to_hide.push_back("roughness")
			to_hide.push_back("roughness picker")

		elif p_tool == Terrain3DEditor.TEXTURE:
			to_hide.push_back("height")
			to_hide.push_back("height picker")
			to_hide.push_back("color")
			to_hide.push_back("color picker")
			to_hide.push_back("roughness")
			to_hide.push_back("roughness picker")

		elif p_tool == Terrain3DEditor.COLOR:
			to_hide.push_back("height")
			to_hide.push_back("height picker")
			to_hide.push_back("roughness")
			to_hide.push_back("roughness picker")

		elif p_tool == Terrain3DEditor.ROUGHNESS:
			to_hide.push_back("height")
			to_hide.push_back("height picker")
			to_hide.push_back("color")
			to_hide.push_back("color picker")
	
		toolbar_settings.hide_settings(to_hide)

	toolbar_settings.set_visible(p_tool != Terrain3DEditor.REGION)	
	_on_setting_changed()
	plugin.update_grid()


func _on_setting_changed() -> void:
	if not visible:
		return
	var brush_data: Dictionary = {
		"size": int(toolbar_settings.get_setting("size")),
		"opacity": toolbar_settings.get_setting("opacity") / 100.0,
		"color": toolbar_settings.get_setting("color"),
		"roughness": toolbar_settings.get_setting("roughness"),
		"gamma": toolbar_settings.get_setting("gamma"),
		"height": toolbar_settings.get_setting("height"),
		"jitter": toolbar_settings.get_setting("jitter"),
		"image": toolbar_settings.get_setting("brush"),
		"automatic_regions": toolbar_settings.get_setting("automatic_regions"),
		"align_with_view": toolbar_settings.get_setting("align_with_view"),
		"index": plugin.surface_list.get_selected_index(),
	}
	plugin.editor.set_brush_data(brush_data)


func _on_picking(type: int, callback: Callable) -> void:
	picking = type
	picking_callback = callback
