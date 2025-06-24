# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# UI for Terrain3D
extends Node


# Includes
const TerrainMenu: Script = preload("res://addons/terrain_3d/menu/terrain_menu.gd")
const Toolbar: Script = preload("res://addons/terrain_3d/src/toolbar.gd")
const ToolSettings: Script = preload("res://addons/terrain_3d/src/tool_settings.gd")
const OperationBuilder: Script = preload("res://addons/terrain_3d/src/operation_builder.gd")
const GradientOperationBuilder: Script = preload("res://addons/terrain_3d/src/gradient_operation_builder.gd")
const COLOR_RAISE := Color.WHITE
const COLOR_LOWER := Color.BLACK
const COLOR_SMOOTH := Color(0.5, 0, .2)
const COLOR_LIFT := Color.ORANGE
const COLOR_FLATTEN := Color.BLUE_VIOLET
const COLOR_HEIGHT := Color(0., 0.32, .4)
const COLOR_SLOPE := Color.YELLOW
const COLOR_PAINT := Color.DARK_GREEN
const COLOR_SPRAY := Color.PALE_GREEN
const COLOR_ROUGHNESS := Color.ROYAL_BLUE
const COLOR_AUTOSHADER := Color.DODGER_BLUE
const COLOR_HOLES := Color.BLACK
const COLOR_NAVIGATION := Color(.28, .0, .25)
const COLOR_INSTANCER := Color.CRIMSON
const COLOR_PICK_COLOR := Color.WHITE
const COLOR_PICK_HEIGHT := Color.DARK_RED
const COLOR_PICK_ROUGH := Color.ROYAL_BLUE

const OP_NONE: int = 0x0
const OP_POSITIVE_ONLY: int = 0x01
const OP_NEGATIVE_ONLY: int = 0x02

const RING1: String = "res://addons/terrain_3d/brushes/ring1.exr"
var ring_texture : ImageTexture
@onready var region_texture := ImageTexture.new() :
	set(value):
		var image: Image = Image.create_empty(1, 1, false, Image.FORMAT_R8)
		image.fill(Color.WHITE)
		value.create_from_image(image)
		region_texture = value
var plugin: EditorPlugin # Actually Terrain3DEditorPlugin, but Godot still has CRC errors
var toolbar: Toolbar
var tool_settings: ToolSettings
var terrain_menu: TerrainMenu
var setting_has_changed: bool = false
var visible: bool = false
var picking: int = Terrain3DEditor.TOOL_MAX
var picking_callback: Callable
var brush_data: Dictionary
var operation_builder: OperationBuilder
var active_tool: Terrain3DEditor.Tool
var _selected_tool: Terrain3DEditor.Tool
var active_operation: Terrain3DEditor.Operation
var _selected_operation: Terrain3DEditor.Operation
var inverted_input: bool = false

# Editor decals, indices; 0 = main brush, 1 = slope point A, 2 = slope point B
var mat_rid: RID
var editor_decal_position: Array[Vector2] = [Vector2(), Vector2(), Vector2()]
var editor_decal_rotation: Array[float] = [float(), float(), float()]
var editor_decal_size: Array[float] = [float(), float(), float()]
var editor_decal_color: Array[Color] = [Color(), Color(), Color()]
var editor_decal_visible: Array[bool] = [bool(), bool(), bool()]
var editor_brush_texture_rid: RID = RID()
var editor_decal_timer: Timer
var editor_decal_fade: float :
	set(value):
		editor_decal_fade = value
		if editor_decal_color.size() > 0:
			editor_decal_color[0].a = value
			if is_shader_valid():
				RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
				if value < 0.001:
					var r_map: PackedInt32Array = plugin.terrain.data.get_region_map()
					RenderingServer.material_set_param(mat_rid, "_region_map", r_map)
var editor_ring_texture_rid: RID


func _enter_tree() -> void:
	toolbar = Toolbar.new()
	toolbar.hide()
	toolbar.tool_changed.connect(_on_tool_changed)
	
	tool_settings = ToolSettings.new()
	tool_settings.setting_changed.connect(_on_setting_changed)
	tool_settings.picking.connect(_on_picking)
	tool_settings.plugin = plugin
	tool_settings.hide()

	terrain_menu = TerrainMenu.new()
	terrain_menu.plugin = plugin
	terrain_menu.hide()

	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, terrain_menu)

	_on_tool_changed(Terrain3DEditor.REGION, Terrain3DEditor.ADD)
	
	editor_decal_timer = Timer.new()
	editor_decal_timer.wait_time = .5
	editor_decal_timer.one_shot = true
	editor_decal_timer.timeout.connect(func():
		get_tree().create_tween().tween_property(self, "editor_decal_fade", 0.0, 0.15))
	add_child(editor_decal_timer)


func _ready() -> void:
	var img: Image = Image.load_from_file(RING1)
	img.convert(Image.FORMAT_R8)
	ring_texture = ImageTexture.create_from_image(img)
	editor_ring_texture_rid = ring_texture.get_rid()


func _exit_tree() -> void:
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	toolbar.queue_free()
	tool_settings.queue_free()
	terrain_menu.queue_free()
	editor_decal_timer.queue_free()


func set_visible(p_visible: bool, p_menu_only: bool = false) -> void:
	terrain_menu.set_visible(p_visible)

	if p_menu_only:
		toolbar.set_visible(false)
		tool_settings.set_visible(false)
	else:
		visible = p_visible
		toolbar.set_visible(p_visible)
		tool_settings.set_visible(p_visible)
		update_decal()

	if plugin.editor:
		if p_visible:
			await get_tree().create_timer(.01).timeout # Won't work, otherwise
			_on_tool_changed(_selected_tool, _selected_operation)
		else:
			plugin.editor.set_tool(Terrain3DEditor.TOOL_MAX)
			plugin.editor.set_operation(Terrain3DEditor.OP_MAX)

	
func set_menu_visibility(p_list: Control, p_visible: bool) -> void:
	if p_list:
		p_list.get_parent().get_parent().visible = p_visible
	

func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	_selected_tool = p_tool
	_selected_operation = p_operation
	clear_picking()
	set_menu_visibility(tool_settings.advanced_list, true)
	set_menu_visibility(tool_settings.scale_list, false)
	set_menu_visibility(tool_settings.rotation_list, false)
	set_menu_visibility(tool_settings.height_list, false)
	set_menu_visibility(tool_settings.color_list, false)

	# Select which settings to show. Options in tool_settings.gd:_ready
	var to_show: PackedStringArray = []
	
	match _selected_tool:
		Terrain3DEditor.REGION:
			to_show.push_back("instructions")
			to_show.push_back("invert")
			set_menu_visibility(tool_settings.advanced_list, false)

		Terrain3DEditor.SCULPT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			if _selected_operation in [Terrain3DEditor.ADD, Terrain3DEditor.SUBTRACT]:
					to_show.push_back("invert")
			elif _selected_operation == Terrain3DEditor.GRADIENT:
				to_show.push_back("gradient_points")
				to_show.push_back("drawable")

		Terrain3DEditor.HEIGHT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("height")
			to_show.push_back("height_picker")
			to_show.push_back("invert")

		Terrain3DEditor.TEXTURE:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("enable_texture")
			if _selected_operation == Terrain3DEditor.ADD:
				to_show.push_back("strength")
				to_show.push_back("invert")
			to_show.push_back("slope")
			to_show.push_back("enable_angle")
			to_show.push_back("angle")
			to_show.push_back("angle_picker")
			to_show.push_back("dynamic_angle")
			to_show.push_back("enable_scale")
			to_show.push_back("scale")
			to_show.push_back("scale_picker")

		Terrain3DEditor.COLOR:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("color")
			to_show.push_back("color_picker")
			to_show.push_back("slope")
			to_show.push_back("texture_filter")
			to_show.push_back("margin")
			to_show.push_back("invert")

		Terrain3DEditor.ROUGHNESS:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("roughness")
			to_show.push_back("roughness_picker")
			to_show.push_back("slope")
			to_show.push_back("texture_filter")
			to_show.push_back("margin")
			to_show.push_back("invert")

		Terrain3DEditor.AUTOSHADER, Terrain3DEditor.HOLES, Terrain3DEditor.NAVIGATION:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("invert")

		Terrain3DEditor.INSTANCER:
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("slope")
			set_menu_visibility(tool_settings.height_list, true)
			to_show.push_back("height_offset")
			to_show.push_back("random_height")
			set_menu_visibility(tool_settings.scale_list, true)
			to_show.push_back("fixed_scale")
			to_show.push_back("random_scale")
			set_menu_visibility(tool_settings.rotation_list, true)
			to_show.push_back("fixed_spin")
			to_show.push_back("random_spin")
			to_show.push_back("fixed_tilt")
			to_show.push_back("random_tilt")
			to_show.push_back("align_to_normal")
			set_menu_visibility(tool_settings.color_list, true)
			to_show.push_back("vertex_color")
			to_show.push_back("random_darken")
			to_show.push_back("random_hue")
			to_show.push_back("invert")

		_:
			pass

	# Advanced menu settings
	to_show.push_back("auto_regions")
	to_show.push_back("align_to_view")
	to_show.push_back("show_cursor_while_painting")
	to_show.push_back("gamma")
	to_show.push_back("jitter")
	to_show.push_back("crosshair_threshold")
	tool_settings.show_settings(to_show)

	operation_builder = null
	if _selected_operation == Terrain3DEditor.GRADIENT:
		operation_builder = GradientOperationBuilder.new()
		operation_builder.tool_settings = tool_settings

	_on_setting_changed()
	plugin.update_region_grid()


func _on_setting_changed(p_setting: Variant = null) -> void:
	if not plugin.asset_dock: # Skip function if not _ready()
		return
	brush_data = tool_settings.get_settings()
	brush_data["asset_id"] = plugin.asset_dock.get_current_list().get_selected_id()
	if plugin.editor:
		plugin.editor.set_brush_data(brush_data)
	inverted_input = brush_data.get("invert", false)
	if p_setting is CheckBox and p_setting.name == &"Invert":
		plugin._read_input() # Revalidate keyboard input for modifier_ctrl
	set_active_operation()
	update_decal()


# Change tool/operation based on modifiers. Called from:
# * editor_plugin.gd:_read_input() - when a modifier key is pressed
# * _on_tool_changed() via:
# * _on_setting_changed() eg. Touchscreen Invert
func set_active_operation() -> void:
	var inverted: bool = plugin.modifier_ctrl || inverted_input

	# Toggle toolbar buttons
	toolbar.show_add_buttons(not inverted)
	
	# If Shift, Smoothness 
	if plugin.modifier_shift and not inverted:
		active_tool = Terrain3DEditor.SCULPT
		active_operation = Terrain3DEditor.AVERAGE	
	
	# Else if Ctrl/Invert checked, opposite
	elif _selected_operation == Terrain3DEditor.ADD and inverted:
		active_tool = _selected_tool
		active_operation = Terrain3DEditor.SUBTRACT
	elif _selected_operation == Terrain3DEditor.SUBTRACT and not inverted:
		active_tool = _selected_tool
		active_operation = Terrain3DEditor.ADD

	# Else use default and set
	else:
		active_tool = _selected_tool
		active_operation = _selected_operation

	if plugin.editor:
		plugin.editor.set_tool(active_tool)
		plugin.editor.set_operation(active_operation)


func update_decal() -> void:
	if not plugin.terrain or brush_data.size() <= 3:
		return
	mat_rid = plugin.terrain.material.get_material_rid()
	editor_decal_timer.start()
	
	# If not a state that should show the decal, hide everything and return
	if not visible or \
		plugin._input_mode < 0 or \
		# After moving camera, wait for mouse cursor to update before revealing
		# See https://github.com/godotengine/godot/issues/70098
		Time.get_ticks_msec() - plugin.rmb_release_time <= 100 or \
		(plugin._input_mode > 0 and not brush_data["show_cursor_while_painting"]):
			hide_decal()
			return
	
	reset_decal_arrays()
	editor_decal_position[0] = Vector2(plugin.mouse_global_position.x, plugin.mouse_global_position.z)
	editor_decal_visible[0] = true
	# Set region size, and modify region map for none background mode.
	var r_map: PackedInt32Array = plugin.terrain.data.get_region_map()
	if plugin.editor.get_tool() == Terrain3DEditor.REGION:
		var r_size: float = float(plugin.terrain.get_region_size()) * plugin.terrain.get_vertex_spacing()
		var map_size: int = plugin.terrain.data.REGION_MAP_SIZE
		var half_r_size: float = r_size * 0.5
		var pos: Vector2 = (Vector2(plugin.mouse_global_position.x, plugin.mouse_global_position.z) +
			Vector2(half_r_size, half_r_size)).snappedf(r_size) - Vector2(half_r_size, half_r_size)
		editor_brush_texture_rid = region_texture.get_rid()
		editor_decal_position[0] = pos
		editor_decal_size[0] = r_size
		editor_decal_rotation[0] = 0.0
		
		var loc: Vector2i = plugin.terrain.data.get_region_location(plugin.mouse_global_position)
		loc += Vector2i(map_size / 2, map_size / 2)
		if !(loc.x < 0 or loc.x > map_size - 1 or loc.y < 0 or loc.y > map_size - 1):
			var index: int = clampi(loc.y * map_size + loc.x, 0, map_size * map_size - 1)
			if plugin.terrain.material.get_world_background() == Terrain3DMaterial.WorldBackground.NONE:
				if r_map[index] == 0 and active_operation == Terrain3DEditor.ADD:
					r_map[index] = -index - 1
				else:
					r_map[index] = r_map[index]
			
			match active_operation:
				Terrain3DEditor.ADD:
					if r_map[index] <= 0:
						editor_decal_color[0] = Color.WHITE
						editor_decal_color[0].a = 0.25
					else:
						hide_decal()
				
				Terrain3DEditor.SUBTRACT:
					if r_map[index] > 0:
						editor_decal_color[0] = Color.WHITE * .15
						editor_decal_color[0].a = 0.75
					else:
						hide_decal()
		else:
			hide_decal()
	# Set texture and color
	elif picking != Terrain3DEditor.TOOL_MAX:
		editor_brush_texture_rid = ring_texture.get_rid()
		editor_decal_size[0] = 10. * plugin.terrain.get_vertex_spacing()
		match picking:
			Terrain3DEditor.HEIGHT:
				editor_decal_color[0] = COLOR_PICK_HEIGHT
			Terrain3DEditor.COLOR:
				editor_decal_color[0] = COLOR_PICK_COLOR
			Terrain3DEditor.ROUGHNESS:
				editor_decal_color[0] = COLOR_PICK_ROUGH
		editor_decal_color[0].a = 1.0
	else:
		editor_brush_texture_rid = brush_data["brush"][1].get_rid()
		editor_decal_size[0] = maxf(brush_data["size"], .5)
		if brush_data["align_to_view"]:
			var cam: Camera3D = plugin.terrain.get_camera();
			if (cam):
				editor_decal_rotation[0] = cam.rotation.y
			else:
				editor_decal_rotation[0] = 0.
		match plugin.editor.get_tool():
			Terrain3DEditor.SCULPT:
				match active_operation:
					Terrain3DEditor.ADD:
						if plugin.modifier_alt:
							editor_decal_color[0] = COLOR_LIFT
							editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5)
						else:
							editor_decal_color[0] = COLOR_RAISE
							editor_decal_color[0].a = clamp(brush_data["strength"], .25, .5)
					Terrain3DEditor.SUBTRACT:
						if plugin.modifier_alt:
							editor_decal_color[0] = COLOR_FLATTEN
							editor_decal_color[0].a = clamp(brush_data["strength"], .25, .5) + .1
						else:
							editor_decal_color[0] = COLOR_LOWER
							editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
					Terrain3DEditor.AVERAGE:
						editor_decal_color[0] = COLOR_SMOOTH
						editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
					Terrain3DEditor.GRADIENT:
						editor_decal_color[0] = COLOR_SLOPE
						editor_decal_color[0].a = clamp(brush_data["strength"], .2, .4)
			Terrain3DEditor.HEIGHT:
				editor_decal_color[0] = COLOR_HEIGHT
				editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
			Terrain3DEditor.TEXTURE:
				match active_operation:
					Terrain3DEditor.REPLACE:
						editor_decal_color[0] = COLOR_PAINT
						editor_decal_color[0].a = .6
					Terrain3DEditor.SUBTRACT:
						editor_decal_color[0] = COLOR_PAINT
						editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .1
					Terrain3DEditor.ADD:
						editor_decal_color[0] = COLOR_SPRAY
						editor_decal_color[0].a = clamp(brush_data["strength"], .15, .4)
			Terrain3DEditor.COLOR:
				editor_decal_color[0] = brush_data["color"].srgb_to_linear()
				editor_decal_color[0].a *= clamp(brush_data["strength"], .2, .5)
			Terrain3DEditor.ROUGHNESS:
				editor_decal_color[0] = COLOR_ROUGHNESS
				editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .1
			Terrain3DEditor.AUTOSHADER:
				editor_decal_color[0] = COLOR_AUTOSHADER
				editor_decal_color[0].a = .6
			Terrain3DEditor.HOLES:
				editor_decal_color[0] = COLOR_HOLES
				editor_decal_color[0].a = .75
			Terrain3DEditor.NAVIGATION:
				editor_decal_color[0] = COLOR_NAVIGATION
				editor_decal_color[0].a = .80
			Terrain3DEditor.INSTANCER:
				editor_brush_texture_rid = ring_texture.get_rid()
				editor_decal_color[0] = COLOR_INSTANCER
				editor_decal_color[0].a = .75
	
	editor_decal_visible[1] = false
	editor_decal_visible[2] = false
	
	if active_operation == Terrain3DEditor.GRADIENT:
		var point1: Vector3 = brush_data["gradient_points"][0]
		if point1 != Vector3.ZERO:
			editor_decal_color[1] = COLOR_SLOPE
			editor_decal_size[1] = 10. * plugin.terrain.get_vertex_spacing()
			editor_decal_visible[1] = true
			editor_decal_position[1] = Vector2(point1.x, point1.z)
		var point2: Vector3 = brush_data["gradient_points"][1]
		if point2 != Vector3.ZERO:
			editor_decal_color[2] = COLOR_SLOPE
			editor_decal_size[2] = 10. * plugin.terrain.get_vertex_spacing()
			editor_decal_visible[2] = true
			editor_decal_position[2] = Vector2(point2.x, point2.z)
	
	if RenderingServer.get_current_rendering_method().contains("gl_compatibility"):
		for i in editor_decal_color.size():
			editor_decal_color[i].a = maxf(0.1, editor_decal_color[i].a - .25)
	
	editor_decal_fade = editor_decal_color[0].a
	# Update Shader params
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_brush_texture", editor_brush_texture_rid)
		RenderingServer.material_set_param(mat_rid, "_editor_ring_texture", editor_ring_texture_rid)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_position", editor_decal_position)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_size", editor_decal_size)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
		RenderingServer.material_set_param(mat_rid, "_editor_crosshair_threshold", brush_data["crosshair_threshold"] + 0.1)
		RenderingServer.material_set_param(mat_rid, "_region_map", r_map)


func is_shader_valid() -> bool:
	# As long as the compiled shader contains at least 1 uniform, we can use it to check
	# if the shader compilation has failed, as this will then return an empty dictionary.
	if not plugin.terrain:
		return false
	var params = RenderingServer.get_shader_parameter_list(plugin.terrain.material.get_shader_rid())
	if params.is_empty():
		return false
	else:
		return true


func hide_decal() -> void:
	editor_decal_visible = [false, false, false]
	if is_shader_valid():
		var r_map: PackedInt32Array = plugin.terrain.data.get_region_map()
		RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
		RenderingServer.material_set_param(mat_rid, "_region_map", r_map)


# These array sizes are reset to 0 when closing scenes for some unknown reason, so check and reset
func reset_decal_arrays() -> void:
	if editor_decal_color.size() < 3:
		editor_decal_position = [Vector2(), Vector2(), Vector2()]
		editor_decal_rotation = [float(), float(), float()]
		editor_decal_size = [float(), float(), float()]
		editor_decal_color = [Color(), Color(), Color()]
		editor_decal_visible = [false, false, false]
		editor_brush_texture_rid = RID()


func set_decal_rotation(p_rot: float) -> void:
	editor_decal_rotation[0] = p_rot
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)


func _on_picking(p_type: Terrain3DEditor.Tool, p_callback: Callable) -> void:
	picking = p_type
	picking_callback = p_callback
	update_decal()


func clear_picking() -> void:
	picking = Terrain3DEditor.TOOL_MAX


func is_picking() -> bool:
	if picking != Terrain3DEditor.TOOL_MAX:
		return true
	
	if operation_builder and operation_builder.is_picking():
		return true
	
	return false


func pick(p_global_position: Vector3) -> void:
	if picking != Terrain3DEditor.TOOL_MAX:
		var color: Color
		match picking:
			Terrain3DEditor.HEIGHT, Terrain3DEditor.SCULPT:
				color = Color(plugin.terrain.data.get_height(p_global_position), 0., 0., 1.)
			Terrain3DEditor.ROUGHNESS:
				color = plugin.terrain.data.get_pixel(Terrain3DRegion.TYPE_COLOR, p_global_position)
			Terrain3DEditor.COLOR:
				color = plugin.terrain.data.get_color(p_global_position)
			Terrain3DEditor.ANGLE:
				color = Color(plugin.terrain.data.get_control_angle(p_global_position), 0., 0., 1.)
			Terrain3DEditor.SCALE:
				color = Color(plugin.terrain.data.get_control_scale(p_global_position), 0., 0., 1.)
			_:
				push_error("Unsupported picking type: ", picking)
				return
		if picking_callback.is_valid():
			picking_callback.call(picking, color, p_global_position)
			picking_callback = Callable()
		picking = Terrain3DEditor.TOOL_MAX
	
	elif operation_builder and operation_builder.is_picking():
		operation_builder.pick(p_global_position, plugin.terrain)


func set_button_editor_icon(p_button: Button, p_icon_name: String) -> void:
	p_button.icon = EditorInterface.get_base_control().get_theme_icon(p_icon_name, "EditorIcons")
