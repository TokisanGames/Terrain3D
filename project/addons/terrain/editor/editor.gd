@tool
extends EditorPlugin

const ICON_TERRAIN = preload("res://addons/terrain/icons/icon_terrain3d.svg")
const ICON_TERRAIN_MATERIAL = preload("res://addons/terrain/icons/icon_terrain_material.svg")
const ICON_LAYER_MATERIAL = preload("res://addons/terrain/icons/icon_terrain_layer_material.svg")

var current_terrain: Terrain3D

var mouse_is_pressed: bool = false
var toolbar: TerrainEditorToolBar

func _enter_tree():
	toolbar = TerrainEditorToolBar.new()
#	var theme: Theme = get_editor_interface().get_base_control().get_theme()
#	theme.set_icon("Terrain3D", "EditorIcons", ICON_TERRAIN)
#	theme.set_icon("TerrainLayerMaterial3D", "EditorIcons", ICON_LAYER_MATERIAL)
#	theme.set_icon("TerrainMaterial3D", "EditorIcons", ICON_TERRAIN_MATERIAL)
	
func _exit_tree():
	toolbar.queue_free()
#	var theme: Theme = get_editor_interface().get_base_control().get_theme()
#	theme.set_icon("Terrain3D", "EditorIcons", null)
#	theme.set_icon("TerrainLayerMaterial3D", "EditorIcons", null)
#	theme.set_icon("TerrainMaterial3D", "EditorIcons", null)

func _handles(object: Variant):
	if object is Terrain3D:
		return true
	return false
	
func _edit(object: Variant):
	if object is Terrain3D:
		
		if object == current_terrain:
			return
			
		current_terrain = object

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent):
	
	if is_terrain_valid():
		if event is InputEventMouse:
			
			var mouse_pos: Vector2 = event.get_position()
			var camera_pos: Vector3 = viewport_camera.global_position
			
			var camera_from: Vector3 = viewport_camera.project_ray_origin(mouse_pos)
			var camera_to: Vector3 = viewport_camera.project_ray_normal(mouse_pos)
			var t = -Vector3(0, 1, 0).dot(camera_from) / Vector3(0, 1, 0).dot(camera_to)
			var intersection: Vector3 = (camera_from + t * camera_to)
			var global_position: Vector2 = Vector2(intersection.x, intersection.z)
			
			var uv_position = global_position / 1024.0
			
			var was_pressed: bool = mouse_is_pressed
			
			if event is InputEventMouseButton and event.get_button_index() == 1:
				mouse_is_pressed = event.is_pressed()
				
				if toolbar.tool == TerrainEditorToolBar.Tool.ADD_MAP:
					if !current_terrain.get_storage().has_map(global_position):
						current_terrain.get_storage().add_map(global_position)
						
				if toolbar.tool == TerrainEditorToolBar.Tool.REMOVE_MAP:
					if current_terrain.get_storage().has_map(global_position):
						current_terrain.get_storage().remove_map(global_position)
						
			if mouse_is_pressed:
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		
func is_terrain_valid():
	return is_instance_valid(current_terrain)

class TerrainEditorToolBar extends HBoxContainer:
	
	enum Tool {
		ADD_MAP,
		REMOVE_MAP,
		PAINT_HEIGHT,
		PAINT_TEXTURE,
	}
	
	enum Mode {
		
	}
	
	var tool: Tool = Tool.ADD_MAP
