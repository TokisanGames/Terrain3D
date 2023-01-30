@tool
extends EditorPlugin

const ICON_TERRAIN: Texture2D = preload("res://addons/terrain/icons/icon_terrain3d.svg")
const ICON_TERRAIN_MATERIAL: Texture2D = preload("res://addons/terrain/icons/icon_terrain_material.svg")

const BRUSH: Image = preload("res://addons/terrain/editor/brush/brush_default.exr")

var current_terrain: Terrain3D

var mouse_is_pressed: bool = false
var editor: Terrain3DEditor
var toolbar: Toolbar
var toolbar_settings: ToolSettings

var region_gizmo: RegionGizmo
var current_region_position: Vector2

func _enter_tree():
	editor = Terrain3DEditor.new()
	
	toolbar = Toolbar.new()
	toolbar.hide()
	toolbar.connect("tool_changed", _on_tool_changed)
	
	toolbar_settings = ToolSettings.new()
	toolbar_settings.hide()
	
	region_gizmo = RegionGizmo.new()
	
	add_control_to_top(toolbar_settings)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	
#	var theme: Theme = get_editor_interface().get_base_control().get_theme()
#	theme.set_icon("Terrain3D", "EditorIcons", ICON_TERRAIN)
#	theme.set_icon("TerrainMaterial3D", "EditorIcons", ICON_TERRAIN_MATERIAL)
	
func _exit_tree():

	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	toolbar.queue_free()
	remove_control_from_top(toolbar_settings)
	toolbar_settings.queue_free()
	
	editor.free()
	
#	var theme: Theme = get_editor_interface().get_base_control().get_theme()
#	theme.set_icon("Terrain3D", "EditorIcons", null)
#	theme.set_icon("TerrainMaterial3D", "EditorIcons", null)

func add_control_to_top(control: Control):
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, control)
	var container = control.get_parent().get_parent().get_parent().get_parent()
	control.get_parent().remove_child(control)
	container.add_child(control)
	container.move_child(control, 1)
	
func remove_control_from_top(control: Control):
	control.get_parent().remove_child(control)

func _handles(object: Variant):
	return object is Terrain3D

func _edit(object: Variant):
	if object is Terrain3D:
		if object == current_terrain:
			return
			
		current_terrain = object
		editor.set_terrain(object)
		
		region_gizmo.set_node_3d(current_terrain)
		current_terrain.add_gizmo(region_gizmo)
		
func _make_visible(visible: bool):
	toolbar.set_visible(visible)
	toolbar_settings.set_visible(visible)
	
	update_grid()
	region_gizmo.set_hidden(!visible)
	
func _clear():
	if is_terrain_valid():
		current_terrain.clear_gizmos()
		current_terrain = null
		editor.set_terrain(null)
		
	region_gizmo.clear()

func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent):
	
	if is_terrain_valid():
		if p_event is InputEventMouse:
			var mouse_pos: Vector2 = p_event.get_position()
			var camera_pos: Vector3 = p_viewport_camera.get_global_position()
			
			var camera_from: Vector3 = p_viewport_camera.project_ray_origin(mouse_pos)
			var camera_to: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)
			var t = -Vector3(0, 1, 0).dot(camera_from) / Vector3(0, 1, 0).dot(camera_to)
			var global_position: Vector3 = (camera_from + t * camera_to)
			
			var region_size = current_terrain.get_storage().get_region_size()
			var region_position: Vector2 = (Vector2(global_position.x, global_position.z) / region_size + Vector2(0.5, 0.5)).floor()
			
			if current_region_position != region_position:
				current_region_position = region_position
				update_grid()

			var was_pressed: bool = mouse_is_pressed
			
			if p_event is InputEventMouseButton and p_event.get_button_index() == 1:
				mouse_is_pressed = p_event.is_pressed()
				
			if toolbar_settings.is_dirty():
				var brush_data: Dictionary = {
					"size": toolbar_settings.get_setting(ToolSettings.SIZE),
					"opacity": toolbar_settings.get_setting(ToolSettings.OPACITY) / 100.0,
					"flow": toolbar_settings.get_setting(ToolSettings.FLOW) / 100.0,
					"image": BRUSH
				}
				editor.set_brush_data(brush_data)
				toolbar_settings.clean()
			
			if mouse_is_pressed:
				editor.operate(global_position, was_pressed)
				
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		
func is_terrain_valid():
	var valid: bool = false
	if is_instance_valid(current_terrain):
		valid = current_terrain.storage != null
	return valid
	
func update_grid():
	
	if is_terrain_valid():
		region_gizmo.show_rect = editor.get_tool() == Terrain3DEditor.REGION
		region_gizmo.use_secondary_color = editor.get_operation() == Terrain3DEditor.SUBTRACT
		region_gizmo.position = current_region_position * current_terrain.get_storage().get_region_size()
		region_gizmo.grid = current_terrain.get_storage().get_region_offsets()
		
		current_terrain.update_gizmos()
		return
	
	region_gizmo.show_rect = false
	region_gizmo.size = 1024
	region_gizmo.grid = [Vector2.ZERO]
	
func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation):
	if editor:
		editor.set_tool(p_tool)
		editor.set_operation(p_operation)
	update_grid()

## Gizmo/Grid
class RegionGizmo extends EditorNode3DGizmo:
	
	var rect_material: StandardMaterial3D
	var grid_material: StandardMaterial3D
	var position: Vector2
	var size: float
	var grid: Array[Vector2]
	var use_secondary_color: bool = false
	var show_rect: bool = true
	
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
		
		if show_rect:
			rect_material.albedo_color = main_color if !use_secondary_color else secondary_color
			draw_rect(position, rect_material)
		
		for pos in grid:
			draw_rect(pos * size, grid_material)
		
	func draw_rect(pos: Vector2, material: StandardMaterial3D):
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
			lines[i] = ((lines[i] / 2.0) * size) + Vector3(pos.x, 0, pos.y)
		
		add_lines(lines, material)
		
## Settings 
class ToolSettings extends PanelContainer:
	
	enum ControlType {
		LABEL,
		SLIDER,
		SPINBOX
	}
	
	enum {
		SIZE,
		OPACITY,
		FLOW
	}
	
	var list: HBoxContainer
	var dirty: bool = true
	
	func _init():
		list = HBoxContainer.new()
		add_child(list)
	
	func _ready():
		add_setting("Size: ", "m", 0, 500, 50)
		add_setting("Opacity: ", "%", 0, 100, 50)
		add_setting("Flow: ", "%", 0, 100, 50)
		
		set("theme_override_styles/panel", get_theme_stylebox("panel", "Panel"))
		
	func add_setting(p_name: StringName, p_suffix: String, min_value: int, max_value: int, value: int):
		var container: HBoxContainer = HBoxContainer.new()
		var label: Label = Label.new()
		var slider: HSlider = HSlider.new()
		var spinbox: EditorSpinSlider = EditorSpinSlider.new()
		
		label.set_vertical_alignment(VERTICAL_ALIGNMENT_CENTER)
		label.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
		label.set_custom_minimum_size(Vector2(32, 0))
		slider.set_custom_minimum_size(Vector2(110, 0))
		slider.set_v_size_flags(SIZE_SHRINK_CENTER)
		spinbox.set_custom_minimum_size(Vector2(50, 0))
		spinbox.set_flat(true)
		spinbox.set_hide_slider(true)
	
		container.add_child(label)
		container.add_child(slider)
		container.add_child(spinbox)
		list.add_child(container)
		
		slider.share(spinbox)
		slider.connect("value_changed", _on_setting_changed)

		slider.set_max(max_value)
		slider.set_min(min_value)
		spinbox.set_max(max_value)
		spinbox.set_min(min_value)
		spinbox.set_suffix(p_suffix)
		
		slider.set_value(value)
		label.set_text(p_name)
	
	func get_setting(setting: int):
		return list.get_child(setting).get_child(ControlType.SPINBOX).get_value()
		
	func is_dirty():
		return dirty
		
	func clean():
		dirty = false
		
	func _on_setting_changed(data: Variant):
		dirty = true
	
### Tools
class Toolbar extends VBoxContainer:
	
	signal tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation)
	
	const ICON_REGION_ADD: Texture2D = preload("res://addons/terrain/icons/icon_map_add.svg")
	const ICON_REGION_REMOVE: Texture2D = preload("res://addons/terrain/icons/icon_map_remove.svg")
	const ICON_HEIGHT_ADD: Texture2D = preload("res://addons/terrain/icons/icon_height_add.svg")
	const ICON_HEIGHT_SUB: Texture2D = preload("res://addons/terrain/icons/icon_height_sub.svg")
	const ICON_HEIGHT_MUL: Texture2D = preload("res://addons/terrain/icons/icon_height_mul.svg")
	const ICON_HEIGHT_FLAT: Texture2D = preload("res://addons/terrain/icons/icon_height_flat.svg")
	
	var tool_group: ButtonGroup = ButtonGroup.new()
	
	func _init():
		set_custom_minimum_size(Vector2(32, 0))
	
	func _ready():
		tool_group.connect("pressed", _on_tool_selected)
		
		add_tool_button(Terrain3DEditor.REGION, Terrain3DEditor.ADD, "Add Region", ICON_REGION_ADD, tool_group)
		add_tool_button(Terrain3DEditor.REGION, Terrain3DEditor.SUBTRACT, "Delete Region", ICON_REGION_REMOVE, tool_group)
		
		add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.ADD, "Increase", ICON_HEIGHT_ADD, tool_group)
		add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.SUBTRACT, "Decrease", ICON_HEIGHT_SUB, tool_group)
		add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.MULTIPLY, "Multiply", ICON_HEIGHT_MUL, tool_group)
		add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.REPLACE, "Flatten", ICON_HEIGHT_FLAT, tool_group)
	
		var buttons: Array[BaseButton] = tool_group.get_buttons()

		for i in buttons.size():
			if i < buttons.size() - 1:
				var button: BaseButton = buttons[i]
				var next_button: BaseButton = buttons[i+1]
				
				if button.get_meta("Tool") != next_button.get_meta("Tool"):
					var s: HSeparator = HSeparator.new()
					add_child(s)
					move_child(s, i+1)
			
		buttons[0].set_pressed(true)
		
	func add_tool_button(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation, p_tip: String, p_icon: Texture2D, p_group: ButtonGroup):
		var button: Button = Button.new()
		button.set_meta("Tool", p_tool)
		button.set_meta("Operation", p_operation)
		button.set_tooltip_text(p_tip)
		button.set_button_icon(p_icon)
		button.set_button_group(p_group)
		button.set_flat(true)
		button.set_toggle_mode(true)
		button.set_h_size_flags(SIZE_SHRINK_END)
		add_child(button)
			
	func _on_tool_selected(p_button: BaseButton):
		emit_signal("tool_changed", p_button.get_meta("Tool", -1), p_button.get_meta("Operation", -1))
		

class MaterialList extends HBoxContainer:
	
	func _init():
		custom_minimum_size.y = 100.0


