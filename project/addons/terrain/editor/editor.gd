@tool
extends EditorPlugin

const ICON_TERRAIN = preload("res://addons/terrain/icons/icon_terrain3d.svg")
const ICON_TERRAIN_MATERIAL = preload("res://addons/terrain/icons/icon_terrain_material.svg")
const ICON_LAYER_MATERIAL = preload("res://addons/terrain/icons/icon_terrain_layer_material.svg")

var current_terrain: Terrain3D

var mouse_is_pressed: bool = false
var toolbar: TerrainEditorToolBar
var layers: TerrainEditorLayers

var map_size: float = 1024
var map_gizmo: TerrainEditorMapGizmo
var current_map_position: Vector3

func _enter_tree():
	toolbar = TerrainEditorToolBar.new()
	toolbar.hide()
	toolbar.connect("tool_changed", _on_tool_changed)
	
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_RIGHT, toolbar)
	
	map_gizmo = TerrainEditorMapGizmo.new()
#	var theme: Theme = get_editor_interface().get_base_control().get_theme()
#	theme.set_icon("Terrain3D", "EditorIcons", ICON_TERRAIN)
#	theme.set_icon("TerrainLayerMaterial3D", "EditorIcons", ICON_LAYER_MATERIAL)
#	theme.set_icon("TerrainMaterial3D", "EditorIcons", ICON_TERRAIN_MATERIAL)
	
func _exit_tree():
	
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_RIGHT, toolbar)
	toolbar.queue_free()

#	var theme: Theme = get_editor_interface().get_base_control().get_theme()
#	theme.set_icon("Terrain3D", "EditorIcons", null)
#	theme.set_icon("TerrainLayerMaterial3D", "EditorIcons", null)
#	theme.set_icon("TerrainMaterial3D", "EditorIcons", null)

func _handles(object: Variant):
	return object is Terrain3D

func _edit(object: Variant):
	if object is Terrain3D:
		if object == current_terrain:
			return
		current_terrain = object
		
		map_gizmo.set_node_3d(current_terrain)
		current_terrain.add_gizmo(map_gizmo)
		
func _make_visible(visible: bool):
	toolbar.set_visible(visible)
	layers.set_visible(visible)
	
	map_gizmo.set_hidden(!visible)
	
func _clear():
	if is_terrain_valid():
		current_terrain.clear_gizmos()
		current_terrain = null
		
	map_gizmo.clear()

func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent):
	
	if is_terrain_valid():
		if p_event is InputEventMouse:
			var mouse_pos: Vector2 = p_event.get_position()
			var camera_pos: Vector3 = p_viewport_camera.get_global_position()
			
			var camera_from: Vector3 = p_viewport_camera.project_ray_origin(mouse_pos)
			var camera_to: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)
			var t = -Vector3(0, 1, 0).dot(camera_from) / Vector3(0, 1, 0).dot(camera_to)
			var intersection: Vector3 = (camera_from + t * camera_to)
			var uv_coord = Vector2(intersection.x, intersection.z) / map_size
			
			var was_pressed: bool = mouse_is_pressed
			
			if p_event is InputEventMouseButton and p_event.get_button_index() == 1:
				mouse_is_pressed = p_event.is_pressed()
			
			match toolbar.get_mode():
				TerrainEditorToolBar.Mode.MAP:
					var map_position: Vector3 = (intersection / map_size + Vector3(0.5, 0, 0.5)).floor() * map_size
					map_position.y = 0
					
					if current_map_position != map_position:
						map_gizmo.position = map_position
						map_gizmo.size = map_size
						map_gizmo.grid = current_terrain.storage.get_map_offsets()
						map_gizmo.use_secondary_color = toolbar.tool == TerrainEditorToolBar.Tool.MAP_REMOVE
						
						current_terrain.update_gizmos()
						current_map_position = map_position
						
					if mouse_is_pressed and !was_pressed:
						if toolbar.tool == TerrainEditorToolBar.Tool.MAP_ADD:
							if !current_terrain.get_storage().has_map(intersection):
								current_terrain.get_storage().add_map(intersection)
							
						if toolbar.tool == TerrainEditorToolBar.Tool.MAP_REMOVE:
							if current_terrain.get_storage().has_map(intersection):
								current_terrain.get_storage().remove_map(intersection)
						
				TerrainEditorToolBar.Mode.HEIGHT:
					pass
					
				TerrainEditorToolBar.Mode.TEXTURE:
					pass
					
			if mouse_is_pressed:
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		
func is_terrain_valid():
	var valid: bool = false
	if is_instance_valid(current_terrain):
		valid = true
		if current_terrain.storage == null:
			valid = false
	return valid
	
func _on_tool_changed():
	map_gizmo.set_hidden(toolbar.get_mode() != TerrainEditorToolBar.Mode.MAP)
	
class TerrainEditorMapGizmo extends EditorNode3DGizmo:
	
	var rect_material: StandardMaterial3D
	var grid_material: StandardMaterial3D
	var position: Vector3
	var size: float
	var grid: Array[Vector2]
	var use_secondary_color: bool = false
	
	var main_color: Color = Color.GREEN_YELLOW
	var secondary_color: Color = Color.RED
	
	func _init():
		rect_material = StandardMaterial3D.new()
		rect_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
		rect_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rect_material.render_priority = 1
		rect_material.albedo_color = main_color
		
		grid_material = StandardMaterial3D.new()
		grid_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
		grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		grid_material.albedo_color = Color.WHITE
	
	func _redraw():
		
		clear()
		rect_material.albedo_color = main_color if !use_secondary_color else secondary_color
		
		draw_rect(position, rect_material)
		for pos in grid:
			draw_rect(Vector3(pos.x, 0, pos.y) * size, grid_material)
		
	func draw_rect(pos: Vector3, material: StandardMaterial3D):
		var lines: PackedVector3Array = [
			Vector3(-1, 0, -1),
			Vector3(-1, 0, 1),
			Vector3(1, 0, 1),
			Vector3(1, 0, -1),
			Vector3(-1, 0, 1),
			Vector3(1, 0, 1),
			Vector3(1, 0, -1),
			Vector3(-1, 0, -1),
		]
		
		for i in lines.size():
			lines[i] = ((lines[i] / 2.0) * size) + pos
		
		add_lines(lines, material)
		

### Terrain Editor Tools
class TerrainEditorToolBar extends VBoxContainer:
	
	signal tool_changed()
	
	const ICON_MAP_ADD: Texture2D = preload("res://addons/terrain/icons/icon_map_add.svg")
	const ICON_MAP_REMOVE: Texture2D = preload("res://addons/terrain/icons/icon_map_remove.svg")
	const ICON_HEIGHT_ADD: Texture2D = preload("res://addons/terrain/icons/icon_height_add.svg")
	const ICON_HEIGHT_SUB: Texture2D = preload("res://addons/terrain/icons/icon_height_sub.svg")
	const ICON_HEIGHT_MUL: Texture2D = preload("res://addons/terrain/icons/icon_height_mul.svg")
	const ICON_HEIGHT_FLAT: Texture2D = preload("res://addons/terrain/icons/icon_height_flat.svg")
	
	enum Tool {
		MAP_ADD,
		MAP_REMOVE,
		HEIGHT_ADD,
		HEIGHT_SUB,
		HEIGHT_MUL,
		HEIGHT_FLAT,
	}
	
	enum Mode {
		MAP,
		HEIGHT,
		TEXTURE,
	}
	
	var tool: Tool = Tool.MAP_ADD
	var tool_group: ButtonGroup = ButtonGroup.new()
	
	func _init():
		tool_group.connect("pressed", _on_tool_selected)
		
		var map_add_button: Button = Button.new()
		var map_remove_button: Button = Button.new()
		
		map_add_button.set_meta("Tool", Tool.MAP_ADD)
		map_remove_button.set_meta("Tool", Tool.MAP_REMOVE)
		
		map_add_button.set_tooltip_text("Add Region")
		map_remove_button.set_tooltip_text("Delete Region")
		
		map_add_button.set_button_icon(ICON_MAP_ADD)
		map_remove_button.set_button_icon(ICON_MAP_REMOVE)
		map_add_button.set_button_group(tool_group)
		map_remove_button.set_button_group(tool_group)
		
		var height_add_button: Button = Button.new()
		var height_sub_button: Button = Button.new()
		var height_mul_button: Button = Button.new()
		var height_flat_button: Button = Button.new()
		
		height_add_button.set_meta("Tool", Tool.HEIGHT_ADD)
		height_sub_button.set_meta("Tool", Tool.HEIGHT_SUB)
		height_mul_button.set_meta("Tool", Tool.HEIGHT_MUL)
		height_flat_button.set_meta("Tool", Tool.HEIGHT_FLAT)
		
		height_add_button.set_tooltip_text("Increase")
		height_sub_button.set_tooltip_text("Decrease")
		height_mul_button.set_tooltip_text("Multiply")
		height_flat_button.set_tooltip_text("Flatten")
		
		height_add_button.set_button_icon(ICON_HEIGHT_ADD)
		height_sub_button.set_button_icon(ICON_HEIGHT_SUB)
		height_mul_button.set_button_icon(ICON_HEIGHT_MUL)
		height_flat_button.set_button_icon(ICON_HEIGHT_FLAT)
		
		height_add_button.set_button_group(tool_group)
		height_sub_button.set_button_group(tool_group)
		height_mul_button.set_button_group(tool_group)
		height_flat_button.set_button_group(tool_group)

		for button in tool_group.get_buttons():
			button.set_flat(true)
			button.set_toggle_mode(true)
			add_child(button)
			
		map_add_button.set_pressed(true)
			
	func _on_tool_selected(p_button: Button):
		var _tool: Tool = p_button.get_meta("Tool", -1)
		if _tool == -1: 
			return
		tool = _tool
		emit_signal("tool_changed")
		
	func get_mode():
		if tool == Tool.MAP_ADD or tool == Tool.MAP_REMOVE:
			return Mode.MAP
			
		if  tool == Tool.HEIGHT_ADD or tool == Tool.HEIGHT_FLAT or tool == Tool.HEIGHT_MUL or tool == Tool.HEIGHT_SUB:
			return Mode.HEIGHT
		return -1
		
### Layer Material List container
class TerrainEditorLayers extends HBoxContainer:
	
	func _init():
		custom_minimum_size.y = 100.0


