@tool
extends EditorPlugin

# Includes
const Toolbar: Script = preload("res://addons/terrain/editor/components/toolbar.gd")
const ToolSettings: Script = preload("res://addons/terrain/editor/components/tool_settings.gd")
const RegionGizmo: Script = preload("res://addons/terrain/editor/components/region_gizmo.gd")
const SurfaceList: Script = preload("res://addons/terrain/editor/components/surface_list.gd")

var terrain: Terrain3D

var mouse_is_pressed: bool = false
var setting_has_changed: bool = false
var editor: Terrain3DEditor
var toolbar: Toolbar
var toolbar_settings: ToolSettings
var surface_list: SurfaceList
var surface_list_container: CustomControlContainer = CONTAINER_INSPECTOR_BOTTOM

var region_gizmo: RegionGizmo
var current_region_position: Vector2
var current_global_position: Vector3
var start_global_position: Vector3
var end_global_position: Vector3

func _enter_tree() -> void:
	editor = Terrain3DEditor.new()
	
	toolbar_settings = ToolSettings.new()
	toolbar_settings.connect("setting_changed", _on_setting_changed)
	toolbar_settings.hide()
	
	toolbar = Toolbar.new()
	toolbar.hide()
	toolbar.connect("tool_changed", _on_tool_changed)
	
	surface_list = SurfaceList.new()
	surface_list.hide()
	surface_list.connect("resource_changed", _on_surface_list_resource_changed)
	surface_list.connect("resource_inspected", _on_surface_list_resource_selected)
	surface_list.connect("resource_selected", _on_setting_changed)
	
	region_gizmo = RegionGizmo.new()
	
	add_control_to_container(surface_list_container, surface_list)
	surface_list.get_parent().connect("visibility_changed", _on_surface_list_visibility_changed)
	
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	add_control_to_bottom(toolbar_settings)
	
func _exit_tree() -> void:
	remove_control_from_container(surface_list_container, surface_list)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	toolbar_settings.get_parent().remove_child(toolbar_settings)
	toolbar.queue_free()
	toolbar_settings.queue_free()
	surface_list.queue_free()
	editor.free()
	
func _handles(object: Variant) -> bool:
	return object is Terrain3D

func _edit(object: Variant) -> void:
	if object is Terrain3D:
		if object == terrain:
			return
			
		terrain = object
		# If 'terrain' is passed to editor instead of 'object', Godot crashes.
		editor.set_terrain(object)
		region_gizmo.set_node_3d(object)
		terrain.add_gizmo(region_gizmo)
		
		terrain.connect("storage_changed", _load_storage)
		_load_storage()
		
func _make_visible(visible: bool) -> void:
	toolbar.set_visible(visible)
	surface_list.set_visible(visible)
	update_grid()
	region_gizmo.set_hidden(!visible)
	
	if visible:
		visible = editor.get_tool() != Terrain3DEditor.REGION
	toolbar_settings.set_visible(visible)
	
func _clear() -> void:
	if is_terrain_valid():
		terrain.disconnect("storage_changed", _load_storage)
		
		terrain.clear_gizmos()
		terrain = null
		editor.set_terrain(null)
		
	region_gizmo.clear()

func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> int:
	if is_terrain_valid():
		if p_event is InputEventMouse:
			var mouse_pos: Vector2 = p_event.get_position()
			var camera_pos: Vector3 = p_viewport_camera.get_global_position()
			var camera_from: Vector3 = p_viewport_camera.project_ray_origin(mouse_pos)
			var camera_to: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)
			var t = -Vector3(0, 1, 0).dot(camera_from) / Vector3(0, 1, 0).dot(camera_to)
			var global_position: Vector3 = (camera_from + t * camera_to)
			end_global_position = global_position
			
			var region_size = terrain.get_storage().get_region_size()
			var region_position: Vector2 = (Vector2(global_position.x, global_position.z) / region_size + Vector2(0.5, 0.5)).floor()

			if current_region_position != region_position:	
				current_region_position = region_position
				update_grid()
			
			if setting_has_changed:
				var brush_data: Dictionary = {
					"size": int(toolbar_settings.get_setting("size")),
					"opacity": toolbar_settings.get_setting("opacity") / 100.0,
					"gamma": toolbar_settings.get_setting("gamma"),
					"height": toolbar_settings.get_setting("height"),
					"jitter": toolbar_settings.get_setting("jitter"),
					"image": toolbar_settings.get_setting("shape"),
					"automatic_regions": toolbar_settings.get_setting("automatic_regions"),
					"align_with_view": toolbar_settings.get_setting("align_with_view"),
					"index": surface_list.get_selected_index(),
				}
				editor.set_brush_data(brush_data)
				setting_has_changed = false
				
			var was_pressed: bool = mouse_is_pressed
			
			if p_event is InputEventMouseButton and p_event.get_button_index() == 1:
				if mouse_is_pressed != p_event.is_pressed():
					mouse_is_pressed = p_event.is_pressed()
					start_global_position = end_global_position
				
			if mouse_is_pressed:
				editor.operate(global_position, p_viewport_camera.rotation.y, was_pressed)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
				
	return EditorPlugin.AFTER_GUI_INPUT_PASS
		
func is_terrain_valid() -> bool:
	var valid: bool = false
	if is_instance_valid(terrain):
		valid = terrain.get_storage() != null
	return valid
	
func update_grid() -> void:
	if !region_gizmo.get_node_3d():
		return
		
	if is_terrain_valid():
		region_gizmo.show_rect = editor.get_tool() == Terrain3DEditor.REGION
		region_gizmo.use_secondary_color = editor.get_operation() == Terrain3DEditor.SUBTRACT
		region_gizmo.region_position = current_region_position
		region_gizmo.region_size = terrain.get_storage().get_region_size()
		region_gizmo.grid = terrain.get_storage().get_region_offsets()
		
		terrain.update_gizmos()
		return
		
	region_gizmo.show_rect = false
	region_gizmo.region_size = 1024
	region_gizmo.grid = [Vector2i.ZERO]
	
func add_control_to_bottom(control: Control) -> void:
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, control)
	var container = control.get_parent().get_parent().get_parent().get_parent()
	control.get_parent().remove_child(control)
	container.add_child(control)
	container.move_child(control, 2)

# Signal handlers

func _load_storage() -> void:
	if terrain:
		surface_list.clear()
		
		if is_terrain_valid():
			var surface_count: int = terrain.get_storage().get_surfaces().size()
			for i in surface_count:
				var surface: Terrain3DSurface = terrain.get_storage().get_surface(i)
				surface_list.add_item(surface)
				
			if surface_count < 256:
				surface_list.add_item()
			
func _on_surface_list_resource_changed(surface, index: int) -> void:
	if is_terrain_valid():
		terrain.get_storage().set_surface(surface, index)
		call_deferred("_load_storage")
		
func _on_surface_list_resource_selected(surface) -> void:
	get_editor_interface().inspect_object(surface, "", true)
	
func _on_surface_list_visibility_changed() -> void:
	if surface_list.get_parent() != null:
		remove_control_from_container(surface_list_container, surface_list)
	
	if surface_list.get_parent() == null:
		surface_list_container = CONTAINER_INSPECTOR_BOTTOM
		if get_editor_interface().is_distraction_free_mode_enabled():
			surface_list_container = CONTAINER_SPATIAL_EDITOR_SIDE_RIGHT
		add_control_to_container(surface_list_container, surface_list)

func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	if editor:
		editor.set_tool(p_tool)
		editor.set_operation(p_operation)
	
	var settings: PackedStringArray = []
	
	if p_operation == Terrain3DEditor.REPLACE:
		settings.push_back("opacity")
		
	if p_tool == Terrain3DEditor.TEXTURE or p_tool == Terrain3DEditor.COLOR:
		settings.push_back("height")
		
	if p_tool == Terrain3DEditor.HEIGHT:
		settings.push_back("slope")
		
	toolbar_settings.set_visible(p_tool != Terrain3DEditor.REGION)
		
	toolbar_settings.hide_settings(settings)
	update_grid()
	
func _on_setting_changed() -> void:
	setting_has_changed = true
