# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Plugin for Terrain3D
@tool
extends EditorPlugin


# Includes
const UI: Script = preload("res://addons/terrain_3d/src/ui.gd")
const RegionGizmo: Script = preload("res://addons/terrain_3d/src/region_gizmo.gd")
const ASSET_DOCK: String = "res://addons/terrain_3d/src/asset_dock.tscn"

var modifier_ctrl: bool
var modifier_alt: bool
var modifier_shift: bool
var _last_modifiers: int = 0
var _input_mode: int = 0 # -1: camera move, 0: none, 1: operating
var _use_meta: bool = false

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
	if OS.get_name() == "macOS":
		_use_meta = true
	
	# Get the Godot Editor window. Structure is root:Window/EditorNode/Base Control
	godot_editor_window = EditorInterface.get_base_control().get_parent().get_parent()
	godot_editor_window.focus_entered.connect(_on_godot_focus_entered)

	
func _enter_tree() -> void:
	editor = Terrain3DEditor.new()
	setup_editor_settings()
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
	godot_editor_window.focus_entered.disconnect(_on_godot_focus_entered)


func _on_godot_focus_entered() -> void:
	_read_input()
	ui.update_decal()


## EditorPlugin selection function call chain isn't consistent. Here's the map of calls:
## Assume we handle Terrain3D and NavigationRegion3D  
# Click Terrain3D: 					_handles(Terrain3D), _make_visible(true), _edit(Terrain3D)
# Deselect:							_make_visible(false), _edit(null)
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
		terrain.set_plugin(self)
		terrain.set_editor(editor)
		editor.set_terrain(terrain)
		region_gizmo.set_node_3d(terrain)
		terrain.add_gizmo(region_gizmo)
		ui.set_visible(true)
		terrain.set_meta("_edit_lock_", true)

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

	_read_input(p_event)
	ui.update_decal()
	
	## Setup active camera & viewport
	# Always update this for all inputs, as the mouse position can move without
	# necessarily being a InputEventMouseMotion object. get_intersection() also
	# returns the last frame position, and should be updated more frequently.
	
	# Snap terrain to current camera 
	terrain.set_camera(p_viewport_camera)

	# Detect if viewport is set to half_resolution
	# Structure is: Node3DEditorViewportContainer/Node3DEditorViewport(4)/SubViewportContainer/SubViewport/Camera3D
	var editor_vpc: SubViewportContainer = p_viewport_camera.get_parent().get_parent()
	var full_resolution: bool = false if editor_vpc.stretch_shrink == 2 else true

	## Get mouse location on terrain
	# Project 2D mouse position to 3D position and direction
	var vp_mouse_pos: Vector2 = editor_vpc.get_local_mouse_position()
	var mouse_pos: Vector2 = vp_mouse_pos if full_resolution else vp_mouse_pos / 2
	var camera_pos: Vector3 = p_viewport_camera.project_ray_origin(mouse_pos)
	var camera_dir: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)

	# If region tool, grab mouse position without considering height
	if editor.get_tool() == Terrain3DEditor.REGION:
		var t = -Vector3(0, 1, 0).dot(camera_pos) / Vector3(0, 1, 0).dot(camera_dir)
		mouse_global_position = (camera_pos + t * camera_dir)
	else:
	#Else look for intersection with terrain
		var intersection_point: Vector3 = terrain.get_intersection(camera_pos, camera_dir, true)
		if intersection_point.z > 3.4e38 or is_nan(intersection_point.y): # max double or nan
			return AFTER_GUI_INPUT_PASS
		mouse_global_position = intersection_point
	
	## Handle mouse movement
	if p_event is InputEventMouseMotion:

		if _input_mode != -1: # Not cam rotation
			## Update region highlight
			var region_position: Vector2 = ( Vector2(mouse_global_position.x, mouse_global_position.z) \
				/ (terrain.get_region_size() * terrain.get_vertex_spacing()) ).floor()
			if current_region_position != region_position:
				current_region_position = region_position
				update_region_grid()

			if _input_mode > 0 and editor.is_operating():
				# Inject pressure - Relies on C++ set_brush_data() using same dictionary instance
				ui.brush_data["mouse_pressure"] = p_event.pressure

				editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
				return AFTER_GUI_INPUT_STOP
			
		return AFTER_GUI_INPUT_PASS

	if p_event is InputEventMouseButton and _input_mode > 0:
		if p_event.is_pressed():
			# If picking
			if ui.is_picking():
				ui.pick(mouse_global_position)
				if not ui.operation_builder or not ui.operation_builder.is_ready():
					return AFTER_GUI_INPUT_STOP
			
			if modifier_ctrl and editor.get_tool() == Terrain3DEditor.HEIGHT:
				var height: float = terrain.data.get_height(mouse_global_position)
				ui.brush_data["height"] = height
				ui.tool_settings.set_setting("height", height)
				
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
		
		# _input_apply released, save undo data
		elif editor.is_operating():
			editor.stop_operation()
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


func _read_input(p_event: InputEvent = null) -> void:
	## Determine if user is moving camera or applying
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or \
		p_event is InputEventMouseButton and p_event.is_released() and \
		p_event.get_button_index() == MOUSE_BUTTON_LEFT:
			_input_mode = 1 
	else:
			_input_mode = 0
	
	match get_setting("editors/3d/navigation/navigation_scheme", 0):
		2, 1: # Modo, Maya
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or \
	 			( Input.is_key_pressed(KEY_ALT) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) ):
					_input_mode = -1 
			if p_event is InputEventMouseButton and p_event.is_released() and \
				( p_event.get_button_index() == MOUSE_BUTTON_RIGHT or \
				( Input.is_key_pressed(KEY_ALT) and p_event.get_button_index() == MOUSE_BUTTON_LEFT )):
					ui.last_rmb_time = Time.get_ticks_msec()
		0, _: # Godot
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or \
				Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
					_input_mode = -1 
			if p_event is InputEventMouseButton and p_event.is_released() and \
				( p_event.get_button_index() == MOUSE_BUTTON_RIGHT or \
				p_event.get_button_index() == MOUSE_BUTTON_MIDDLE ):
					ui.last_rmb_time = Time.get_ticks_msec()
	if _input_mode < 0:
		return

	## Determine modifiers pressed
	modifier_shift = Input.is_key_pressed(KEY_SHIFT)
	modifier_ctrl = Input.is_key_pressed(KEY_META) if _use_meta else Input.is_key_pressed(KEY_CTRL)
	# Keybind enum: Alt,Space,Meta,Capslock
	var alt_key: int
	match get_setting("terrain3d/config/alt_key_bind", 0):
		3: alt_key = KEY_CAPSLOCK
		2: alt_key = KEY_META
		1: alt_key = KEY_SPACE
		0, _: alt_key = KEY_ALT
	modifier_alt = Input.is_key_pressed(alt_key)

	# Return if modifiers haven't changed AND brush_data has them;
	# modifiers disappear from brush_data when clicking asset_dock (Why?)
	var current_mods: int = int(modifier_shift) | int(modifier_ctrl) << 1 | int(modifier_alt) << 2
	if _last_modifiers == current_mods and ui.brush_data.has("modifier_shift"):
		return
	
	_last_modifiers = current_mods
	ui.brush_data["modifier_shift"] = modifier_shift
	ui.brush_data["modifier_ctrl"] = modifier_ctrl
	ui.brush_data["modifier_alt"] = modifier_alt
	ui.update_modifiers()


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
	var selected: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for node in selected:
		if ( is_instance_valid(_last_terrain) and node.get_instance_id() == _last_terrain.get_instance_id() ) or \
			node is Terrain3D:
				return true
	return false	


func select_terrain() -> void:
	if is_instance_valid(_last_terrain) and is_terrain_valid(_last_terrain) and not is_selected():
		var es: EditorSelection = EditorInterface.get_selection()
		es.clear()
		es.add_node(_last_terrain)


## Editor Settings


func setup_editor_settings() -> void:
	editor_settings = EditorInterface.get_editor_settings()
	if not editor_settings.has_setting("terrain3d/config/alt_key_bind"):
		editor_settings.set("terrain3d/config/alt_key_bind", 0)
	var property_info = {
		"name": "terrain3d/config/alt_key_bind",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Alt,Space,Meta,Capslock"
	}
	editor_settings.add_property_info(property_info)
	

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
