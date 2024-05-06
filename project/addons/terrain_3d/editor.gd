@tool
extends EditorPlugin
#class_name Terrain3DEditorPlugin Cannot be named until Godot #75388


# Includes
const UI: Script = preload("res://addons/terrain_3d/src/ui.gd")
const RegionGizmo: Script = preload("res://addons/terrain_3d/src/region_gizmo.gd")
const ASSET_DOCK: String = "res://addons/terrain_3d/src/asset_dock.tscn"
const PS_DOCK_POSITION: String = "terrain3d/config/dock_position"
const PS_DOCK_PINNED: String = "terrain3d/config/dock_pinned"

var terrain: Terrain3D
var nav_region: NavigationRegion3D

var editor: Terrain3DEditor
var ui: Node # Terrain3DUI see Godot #75388
var region_gizmo: RegionGizmo
var visible: bool
var current_region_position: Vector2
var mouse_global_position: Vector3 = Vector3.ZERO

enum DOCK_STATE {
	HIDDEN = -1,
	SIDEBAR = 0,
	BOTTOM = 1,
}
var asset_dock: Control
var dock_state: DOCK_STATE = -1
var dock_position: DockSlot = DOCK_SLOT_RIGHT_BL

# Track negative input (CTRL)
var _negative_input: bool = false
# Track state prior to pressing CTRL: -1 not tracked, 0 false, 1 true
var _prev_enable_state: int = -1


func _enter_tree() -> void:
	editor = Terrain3DEditor.new()
	ui = UI.new()
	ui.plugin = self
	add_child(ui)

	region_gizmo = RegionGizmo.new()

	scene_changed.connect(_on_scene_changed)

	if ProjectSettings.has_setting(PS_DOCK_POSITION):
		dock_position = ProjectSettings.get_setting(PS_DOCK_POSITION)
	asset_dock = load(ASSET_DOCK).instantiate()
	await asset_dock.ready
	if ProjectSettings.has_setting(PS_DOCK_PINNED):
		asset_dock.placement_pin.button_pressed = ProjectSettings.get_setting(PS_DOCK_PINNED)
	asset_dock.placement_pin.toggled.connect(_on_asset_dock_pin_changed)
	asset_dock.placement_option.selected = dock_position
	asset_dock.placement_changed.connect(_on_asset_dock_placement_changed)
	asset_dock.resource_changed.connect(_on_asset_dock_resource_changed)
	asset_dock.resource_inspected.connect(_on_asset_dock_resource_inspected)
	asset_dock.resource_selected.connect(_on_asset_dock_resource_selected)
	

func _exit_tree() -> void:
	asset_dock.queue_free()
	ui.queue_free()
	editor.free()

	scene_changed.disconnect(_on_scene_changed)


func _handles(p_object: Object) -> bool:
	if p_object is Terrain3D or p_object is NavigationRegion3D:
		return true
	if p_object is Terrain3DObjects or (p_object is Node3D and p_object.get_parent() is Terrain3DObjects):
		return true
	return false


func _edit(p_object: Object) -> void:
	if !p_object:
		_clear()

	if p_object is Terrain3D:
		if p_object == terrain:
			return
		terrain = p_object
		editor.set_terrain(terrain)
		region_gizmo.set_node_3d(terrain)
		terrain.add_gizmo(region_gizmo)
		terrain.set_plugin(self)
		
		if not terrain.texture_list_changed.is_connected(_load_textures):
			terrain.texture_list_changed.connect(_load_textures)
		_load_textures()
		if not terrain.storage_changed.is_connected(_load_storage):
			terrain.storage_changed.connect(_load_storage)
		_load_storage()
	else:
		terrain = null
	
	if p_object is NavigationRegion3D:
		nav_region = p_object
	else:
		nav_region = null

	if p_object is Terrain3DObjects:
		p_object.editor_setup(self)
	elif p_object is Node3D and p_object.get_parent() is Terrain3DObjects:
		p_object.get_parent().editor_setup(self)
	
		
func _make_visible(p_visible: bool, p_redraw: bool = false) -> void:
	visible = p_visible
	ui.set_visible(visible)
	update_region_grid()

	# Manage Asset Dock position and visibility
	if visible and dock_state == DOCK_STATE.HIDDEN:
		if dock_position < DOCK_SLOT_MAX:
			add_control_to_dock(dock_position, asset_dock)
			dock_state = DOCK_STATE.SIDEBAR
			asset_dock.move_slider(true)
		else:
			add_control_to_bottom_panel(asset_dock, "Terrain3D")
			make_bottom_panel_item_visible(asset_dock)
			dock_state = DOCK_STATE.BOTTOM
			asset_dock.move_slider(false)
	elif not visible and dock_state != DOCK_STATE.HIDDEN:
		var pinned: bool = false
		if p_redraw or ( asset_dock.placement_pin and not asset_dock.placement_pin.button_pressed):
			if dock_state == DOCK_STATE.SIDEBAR:
				remove_control_from_docks(asset_dock)
			else:
				remove_control_from_bottom_panel(asset_dock)
			dock_state = DOCK_STATE.HIDDEN


func _clear() -> void:
	if is_terrain_valid():
		terrain.storage_changed.disconnect(_load_storage)
		
		terrain.clear_gizmos()
		terrain = null
		editor.set_terrain(null)
		
		ui.clear_picking()
		
	region_gizmo.clear()


func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> int:
	if not is_terrain_valid():
		return AFTER_GUI_INPUT_PASS
	
	## Track negative input (CTRL)
	if p_event is InputEventKey and not p_event.echo and p_event.keycode == KEY_CTRL:
		if p_event.is_pressed():
			_negative_input = true
			_prev_enable_state = int(ui.toolbar_settings.get_setting("enable"))
			ui.toolbar_settings.set_setting("enable", false)
		else:
			_negative_input = false
			ui.toolbar_settings.set_setting("enable", bool(_prev_enable_state))
			_prev_enable_state = -1
	
	## Handle mouse movement
	if p_event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			return AFTER_GUI_INPUT_PASS

		if _prev_enable_state >= 0 and not Input.is_key_pressed(KEY_CTRL):
			_negative_input = false
			ui.toolbar_settings.set_setting("enable", bool(_prev_enable_state))
			_prev_enable_state = -1

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
			if intersection_point.z > 3.4e38: # double max
				return AFTER_GUI_INPUT_STOP
			mouse_global_position = intersection_point
		
		## Update decal
		ui.decal.global_position = mouse_global_position
		ui.decal.albedo_mix = 1.0
		if ui.decal_timer.is_stopped():
			ui.update_decal()
		else:
			ui.decal_timer.start()

		## Update region highlight
		var region_size = terrain.get_storage().get_region_size()
		var region_position: Vector2 = ( Vector2(mouse_global_position.x, mouse_global_position.z) \
			/ (region_size * terrain.get_mesh_vertex_spacing()) ).floor()
		if current_region_position != region_position:
			current_region_position = region_position
			update_region_grid()
			
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and editor.is_operating():
			editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
			return AFTER_GUI_INPUT_STOP

	elif p_event is InputEventMouseButton:
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
					var has_region: bool = terrain.get_storage().has_region(mouse_global_position)
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
	
	return AFTER_GUI_INPUT_PASS

		
func is_terrain_valid() -> bool:
	if is_instance_valid(terrain) and terrain.get_storage():
		return true
	return false

	
func _load_storage() -> void:
	if terrain:
		update_region_grid()


func update_region_grid() -> void:
	if not region_gizmo:
		return

	region_gizmo.set_hidden(not visible)
	
	if is_terrain_valid():
		region_gizmo.show_rect = editor.get_tool() == Terrain3DEditor.REGION
		region_gizmo.use_secondary_color = editor.get_operation() == Terrain3DEditor.SUBTRACT
		region_gizmo.region_position = current_region_position
		region_gizmo.region_size = terrain.get_storage().get_region_size() * terrain.get_mesh_vertex_spacing()
		region_gizmo.grid = terrain.get_storage().get_region_offsets()
		
		terrain.update_gizmos()
		return
		
	region_gizmo.show_rect = false
	region_gizmo.region_size = 1024
	region_gizmo.grid = [Vector2i.ZERO]


func _load_textures() -> void:
	if terrain and terrain.texture_list:
		if not terrain.texture_list.textures_changed.is_connected(update_asset_dock):
			terrain.texture_list.textures_changed.connect(update_asset_dock)
		update_asset_dock()				


func update_asset_dock(p_texture_list: Terrain3DTextureList = null) -> void:
	asset_dock.clear()
	
	if is_terrain_valid() and terrain.texture_list:
		var texture_count: int = terrain.texture_list.get_texture_count()
		for i in texture_count:
			var texture: Terrain3DTexture = terrain.texture_list.get_texture(i)
			asset_dock.add_item(texture)
			
		if texture_count < Terrain3DTextureList.MAX_TEXTURES:
			asset_dock.add_item()


func _on_asset_dock_pin_changed(toggled: bool) -> void:
	ProjectSettings.set_setting(PS_DOCK_PINNED, toggled)
	ProjectSettings.save()

	
func _on_asset_dock_placement_changed(index: int) -> void:
	dock_position = clamp(index, 0, DOCK_SLOT_MAX)
	ProjectSettings.set_setting(PS_DOCK_POSITION, dock_position)
	ProjectSettings.save()
	_make_visible(false, true) # Hide to redraw
	_make_visible(true)


func _on_asset_dock_resource_changed(p_texture: Resource, p_index: int) -> void:
	if is_terrain_valid():
		# If removing last entry and its selected, clear inspector
		if not p_texture and p_index == asset_dock.get_selected_index() and \
				asset_dock.get_selected_index() == asset_dock.entries.size() - 2:
			get_editor_interface().inspect_object(null)			
		terrain.get_texture_list().set_texture(p_index, p_texture)


func _on_asset_dock_resource_selected() -> void:
	# If not on a texture painting tool, then switch to Paint
	if editor.get_tool() != Terrain3DEditor.TEXTURE:
		var paint_btn: Button = ui.toolbar.get_node_or_null("PaintBaseTexture")
		if paint_btn:
			paint_btn.set_pressed(true)
			ui._on_tool_changed(Terrain3DEditor.TEXTURE, Terrain3DEditor.REPLACE)
	ui._on_setting_changed()


func _on_asset_dock_resource_inspected(texture: Resource) -> void:
	get_editor_interface().inspect_object(texture, "", true)


func _on_scene_changed(scene_root: Node) -> void:
	if scene_root:
		for node in scene_root.find_children("", "Terrain3DObjects"):
			node.editor_setup(self)
