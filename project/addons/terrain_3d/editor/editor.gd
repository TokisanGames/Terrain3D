@tool
extends EditorPlugin
#class_name Terrain3DEditorPlugin Cannot be named until Godot #75388


# Includes
const UI: Script = preload("res://addons/terrain_3d/editor/components/ui.gd")
const RegionGizmo: Script = preload("res://addons/terrain_3d/editor/components/region_gizmo.gd")
const SurfaceList: Script = preload("res://addons/terrain_3d/editor/components/surface_list.gd")

var terrain: Terrain3D

var mouse_is_pressed: bool = false

var pending_undo: bool = false
var editor: Terrain3DEditor
var ui: Node # Terrain3DUI see Godot #75388
var surface_list: SurfaceList
var surface_list_container: CustomControlContainer = CONTAINER_INSPECTOR_BOTTOM

var region_gizmo: RegionGizmo
var current_region_position: Vector2
var mouse_global_position: Vector3 = Vector3.ZERO


func _enter_tree() -> void:
	editor = Terrain3DEditor.new()
	ui = UI.new()
	ui.plugin = self
	add_child(ui)

	surface_list = SurfaceList.new()
	surface_list.hide()
	surface_list.connect("resource_changed", _on_surface_list_resource_changed)
	surface_list.connect("resource_inspected", _on_surface_list_resource_selected)
	surface_list.connect("resource_selected", ui._on_setting_changed)
	
	region_gizmo = RegionGizmo.new()
	
	add_control_to_container(surface_list_container, surface_list)
	surface_list.get_parent().connect("visibility_changed", _on_surface_list_visibility_changed)


func _exit_tree() -> void:
	remove_control_from_container(surface_list_container, surface_list)
	surface_list.queue_free()
	ui.queue_free()
	editor.free()

	
func _handles(object: Object) -> bool:
	return object is Terrain3D


func _edit(object: Object) -> void:
	if !object:
		_clear()
		
	if object is Terrain3D:
		if object == terrain:
			return
		terrain = object
		editor.set_terrain(terrain)
		region_gizmo.set_node_3d(terrain)
		terrain.add_gizmo(region_gizmo)
		terrain.set_plugin(self)
		
		if not terrain.is_connected("storage_changed", _load_storage):
			terrain.connect("storage_changed", _load_storage)
		_load_storage()

		
func _make_visible(visible: bool) -> void:
	ui.set_visible(visible)
	surface_list.set_visible(visible)
	update_grid()
	region_gizmo.set_hidden(!visible)

	
func _clear() -> void:
	if is_terrain_valid():
		terrain.disconnect("storage_changed", _load_storage)
		
		terrain.clear_gizmos()
		terrain = null
		editor.set_terrain(null)
		
	region_gizmo.clear()


func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> int:
	if not is_terrain_valid():
		return AFTER_GUI_INPUT_PASS
	
	# Track mouse position
	if p_event is InputEventMouseMotion:
		var mouse_pos: Vector2 = p_event.position
		var camera_pos: Vector3 = p_viewport_camera.global_position
		var camera_dir: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)
		
		# If mouse intersected terrain within 3000 units (3.4e38 is Double max val)
		var intersection_point: Vector3 = terrain.get_intersection(camera_pos, camera_dir)
		if intersection_point.x < 3.4e38:
			mouse_global_position = intersection_point
		else:
			# Else, grab mouse position without considering height
			var t = -Vector3(0, 1, 0).dot(camera_pos) / Vector3(0, 1, 0).dot(camera_dir)
			mouse_global_position = (camera_pos + t * camera_dir)
		ui.decal.global_position = mouse_global_position

		# Update region highlight
		var region_size = terrain.get_storage().get_region_size()
		var region_position: Vector2 = (Vector2(mouse_global_position.x, mouse_global_position.z) / region_size + Vector2(0.5, 0.5)).floor()
		if current_region_position != region_position:	
			current_region_position = region_position
			update_grid()

	elif p_event is InputEventMouseButton:
		if p_event.get_button_index() == MOUSE_BUTTON_LEFT:
			# Update mouse pressed state
			if mouse_is_pressed != p_event.is_pressed():
				mouse_is_pressed = p_event.is_pressed()

			if mouse_is_pressed:
				var tool: Terrain3DEditor.Tool = editor.get_tool() 
				
				if ui.picking != Terrain3DEditor.TOOL_MAX: 
					var color: Color
					match ui.picking:
						Terrain3DEditor.HEIGHT:
							color = terrain.get_storage().get_pixel(Terrain3DStorage.TYPE_HEIGHT, mouse_global_position)
						Terrain3DEditor.ROUGHNESS:
							color = terrain.get_storage().get_pixel(Terrain3DStorage.TYPE_COLOR, mouse_global_position)
						Terrain3DEditor.COLOR:
							color = terrain.get_storage().get_color(mouse_global_position)
						_:
							push_error("Unsupported picking type: ", ui.picking)
							return AFTER_GUI_INPUT_STOP
					ui.picking_callback.call(ui.picking, color)
					ui.picking = Terrain3DEditor.TOOL_MAX
					mouse_is_pressed = false
					return AFTER_GUI_INPUT_STOP

				elif editor.get_tool() == Terrain3DEditor.REGION:
					# Skip regions that already exist or don't
					var has_region: bool = terrain.get_storage().has_region(mouse_global_position)
					var op: int = editor.get_operation()
					if	( has_region and op == Terrain3DEditor.ADD) or \
						( not has_region and op == Terrain3DEditor.SUBTRACT ):
						return AFTER_GUI_INPUT_STOP

				# Mouse clicked, copy undo data 
				editor.setup_undo()
				pending_undo = true
				
			# Mouse released, store pending undo data in History
			else:
				if pending_undo:
					editor.store_undo()
				pending_undo = false
		
		ui.update_decal()
	
	if mouse_is_pressed:
		var continuous: bool = editor.get_tool() != Terrain3DEditor.REGION
		editor.operate(mouse_global_position, p_viewport_camera.rotation.y, continuous)
		return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS

		
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
				
			if surface_count < 32: # Limit of 5 bits in control map
				surface_list.add_item()
				
		update_grid()
			
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
