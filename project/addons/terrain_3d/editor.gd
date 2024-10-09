@tool
extends EditorPlugin
#class_name Terrain3DEditorPlugin Cannot be named until Godot #75388


# Includes
const UI: Script = preload("res://addons/terrain_3d/src/ui.gd")
const RegionGizmo: Script = preload("res://addons/terrain_3d/src/region_gizmo.gd")
const ASSET_DOCK: String = "res://addons/terrain_3d/src/asset_dock.tscn"

var terrain: Terrain3D
var _last_terrain: Terrain3D
var nav_region: NavigationRegion3D

var editor: Terrain3DEditor
var editor_settings: EditorSettings
var ui: Node # Terrain3DUI see Godot #75388
var asset_dock: PanelContainer
var region_gizmo: RegionGizmo
var current_region_position: Vector2
var mouse_global_position: Vector3 = Vector3.ZERO
var godot_editor_window: Window # The Godot Editor window


func _init() -> void:
	# Get the Godot Editor window. Structure is root:Window/EditorNode/Base Control
	godot_editor_window = get_editor_interface().get_base_control().get_parent().get_parent()

	
func _enter_tree() -> void:
	editor = Terrain3DEditor.new()
	editor_settings = EditorInterface.get_editor_settings()
	ui = UI.new()
	ui.plugin = self
	add_child(ui)

	region_gizmo = RegionGizmo.new()

	scene_changed.connect(_on_scene_changed)

	asset_dock = load(ASSET_DOCK).instantiate()
	asset_dock.initialize(self)


func _exit_tree() -> void:
	asset_dock.remove_dock(true)
	asset_dock.queue_free()
	ui.queue_free()
	editor.free()

	scene_changed.disconnect(_on_scene_changed)


## EditorPlugin selection function chain isn't consistent. Here's the map of calls:
## Assume we handle Terrain3D and NavigationRegion3D  
# Click Terrain3D: 					_handles(Terrain3D), _make_visible(true), _edit(Terrain3D)
# Delect:							_make_visible(false), _edit(null)
# Click other node:					_handles(OtherNode)
# Click NavRegion3D:				_handles(NavReg3D), _make_visible(true), _edit(NavReg3D)
# Click NavRegion3D, Terrain3D:		_handles(Terrain3D), _edit(Terrain3D)
# Click Terrain3D, NavRegion3D:		_handles(NavReg3D), _edit(NavReg3D)
func _handles(p_object: Object) -> bool:
	if p_object is Terrain3D:
		return true
	elif p_object is NavigationRegion3D and is_instance_valid(_last_terrain):
		return true
	
	# Terrain3DObjects requires access to EditorUndoRedoManager. The only way to make sure it
	# always has it, is to pass it in here. _edit is NOT called if the node is cut and pasted.
	elif p_object is Terrain3DObjects:
		p_object.editor_setup(self)
	elif p_object is Node3D and p_object.get_parent() is Terrain3DObjects:
		p_object.get_parent().editor_setup(self)
	
	return false


func _make_visible(p_visible: bool, p_redraw: bool = false) -> void:
	if p_visible and is_selected():
		ui.set_visible(true)
		asset_dock.update_dock()
	else:
		ui.set_visible(false)


func _edit(p_object: Object) -> void:
	if !p_object:
		_clear()

	if p_object is Terrain3D:
		if p_object == terrain:
			return
		terrain = p_object
		_last_terrain = terrain
		editor.set_terrain(terrain)
		region_gizmo.set_node_3d(terrain)
		terrain.add_gizmo(region_gizmo)
		terrain.set_plugin(self)
		terrain.set_editor(editor)
		ui.set_visible(true)
		terrain.set_meta("_edit_lock_", true)

		if terrain.storage:
			ui.terrain_menu.directory_setup.directory_setup_popup()
		
		# Get alerted when a new asset list is loaded
		if not terrain.assets_changed.is_connected(asset_dock.update_assets):
			terrain.assets_changed.connect(asset_dock.update_assets)
		asset_dock.update_assets()
		# Get alerted when the region map changes
		if not terrain.data.region_map_changed.is_connected(update_region_grid):
			terrain.data.region_map_changed.connect(update_region_grid)
		update_region_grid()
	else:
		_clear()

	if is_terrain_valid(_last_terrain):
		if p_object is NavigationRegion3D:
			ui.set_visible(true, true)
			nav_region = p_object
		else:
			nav_region = null

	
func _clear() -> void:
	if is_terrain_valid():
		if terrain.data.region_map_changed.is_connected(update_region_grid):
			terrain.data.region_map_changed.disconnect(update_region_grid)
		
		terrain.clear_gizmos()
		terrain = null
		editor.set_terrain(null)
		
		ui.clear_picking()
		
	region_gizmo.clear()


func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> int:
	if not is_terrain_valid():
		return AFTER_GUI_INPUT_PASS
	
	ui.update_modifiers()
	
	## Handle mouse movement
	if p_event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			return AFTER_GUI_INPUT_PASS

		## Setup for active camera & viewport
		
		# Snap terrain to current camera 
		terrain.set_camera(p_viewport_camera)

		# Detect if viewport is set to half_resolution
		# Structure is: Node3DEditorViewportContainer/Node3DEditorViewport(4)/SubViewportContainer/SubViewport/Camera3D
		var editor_vpc: SubViewportContainer = p_viewport_camera.get_parent().get_parent()
		var full_resolution: bool = false if editor_vpc.stretch_shrink == 2 else true

		## Get mouse location on terrain
		
		# Project 2D mouse position to 3D position and direction
		var mouse_pos: Vector2 = p_event.position if full_resolution else p_event.position/2
		var camera_pos: Vector3 = p_viewport_camera.project_ray_origin(mouse_pos)
		var camera_dir: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)

		# If region tool, grab mouse position without considering height
		if editor.get_tool() == Terrain3DEditor.REGION:
			var t = -Vector3(0, 1, 0).dot(camera_pos) / Vector3(0, 1, 0).dot(camera_dir)
			mouse_global_position = (camera_pos + t * camera_dir)
		else:			
			# Else look for intersection with terrain
			var intersection_point: Vector3 = terrain.get_intersection(camera_pos, camera_dir)
			if intersection_point.z > 3.4e38 or is_nan(intersection_point.y): # max double or nan
				return AFTER_GUI_INPUT_STOP
			mouse_global_position = intersection_point

		## Update decal
		ui.decal.global_position = mouse_global_position
		ui.update_decal()

		## Update region highlight
		var region_position: Vector2 = ( Vector2(mouse_global_position.x, mouse_global_position.z) \
			/ (terrain.get_region_size() * terrain.get_vertex_spacing()) ).floor()
		if current_region_position != region_position:
			current_region_position = region_position
			update_region_grid()

		# Inject pressure - Relies on C++ set_brush_data() using same dictionary instance
		ui.brush_data["mouse_pressure"] = p_event.pressure

		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and editor.is_operating():
			editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
			return AFTER_GUI_INPUT_STOP

	elif p_event is InputEventMouseButton:
		if p_event.get_button_index() == MOUSE_BUTTON_RIGHT and p_event.is_released():
			ui.last_rmb_time = Time.get_ticks_msec()
		ui.update_decal()
			
		if p_event.get_button_index() == MOUSE_BUTTON_LEFT:
			if p_event.is_pressed():
				if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
					return AFTER_GUI_INPUT_STOP
					
				# If picking
				if ui.is_picking():
					ui.pick(mouse_global_position)
					if not ui.operation_builder or not ui.operation_builder.is_ready():
						return AFTER_GUI_INPUT_STOP
				
				# If adjusting regions
				if editor.get_tool() == Terrain3DEditor.REGION:
					# Skip regions that already exist or don't
					var has_region: bool = terrain.data.has_regionp(mouse_global_position)
					var op: int = editor.get_operation()
					if	( has_region and op == Terrain3DEditor.ADD) or \
						( not has_region and op == Terrain3DEditor.SUBTRACT ):
						return AFTER_GUI_INPUT_STOP
				
				# If an automatic operation is ready to go (e.g. gradient)
				if ui.operation_builder and ui.operation_builder.is_ready():
					ui.operation_builder.apply_operation(editor, mouse_global_position, p_viewport_camera.rotation.y)
					return AFTER_GUI_INPUT_STOP
				
				# Mouse clicked, start editing
				editor.start_operation(mouse_global_position)
				editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
				return AFTER_GUI_INPUT_STOP
			
			elif editor.is_operating():
				# Mouse released, save undo data
				editor.stop_operation()
				return AFTER_GUI_INPUT_STOP

	# Key presses
	ui.update_decal()
	return AFTER_GUI_INPUT_PASS


func update_region_grid() -> void:
	if not region_gizmo:
		return
	region_gizmo.set_hidden(not ui.visible)

	if is_terrain_valid():
		region_gizmo.show_rect = editor.get_tool() == Terrain3DEditor.REGION
		region_gizmo.use_secondary_color = editor.get_operation() == Terrain3DEditor.SUBTRACT
		region_gizmo.region_position = current_region_position
		region_gizmo.region_size = terrain.get_region_size() * terrain.get_vertex_spacing()
		region_gizmo.grid = terrain.get_data().get_region_locations()
		
		terrain.update_gizmos()
		return
		
	region_gizmo.show_rect = false
	region_gizmo.region_size = 1024
	region_gizmo.grid = [Vector2i.ZERO]


func _on_scene_changed(scene_root: Node) -> void:
	if not scene_root:
		return
		
	for node in scene_root.find_children("", "Terrain3DObjects"):
		node.editor_setup(self)

	asset_dock.update_assets()
	await get_tree().create_timer(2).timeout
	asset_dock.update_thumbnails()

		
func is_terrain_valid(p_terrain: Terrain3D = null) -> bool:
	var t: Terrain3D
	if p_terrain:
		t = p_terrain
	else:
		t = terrain
	if is_instance_valid(t) and t.is_inside_tree() and t.data:
		return true
	return false


func is_selected() -> bool:
	var selected: Array[Node] = get_editor_interface().get_selection().get_selected_nodes()
	for node in selected:
		if ( is_instance_valid(_last_terrain) and node.get_instance_id() == _last_terrain.get_instance_id() ) or \
			node is Terrain3D:
				return true
	return false	


func select_terrain() -> void:
	if is_instance_valid(_last_terrain) and is_terrain_valid(_last_terrain) and not is_selected():
		var es: EditorSelection = get_editor_interface().get_selection()
		es.clear()
		es.add_node(_last_terrain)


func set_setting(p_str: String, p_value: Variant) -> void:
	editor_settings.set_setting(p_str, p_value)


func get_setting(p_str: String, p_default: Variant) -> Variant:
	if editor_settings.has_setting(p_str):
		return editor_settings.get_setting(p_str)
	else:
		return p_default


func has_setting(p_str: String) -> bool:
	return editor_settings.has_setting(p_str)


func erase_setting(p_str: String) -> void:
	editor_settings.erase(p_str)
