# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# UI for Pasture3D
extends Node


# Includes
const TerrainMenu: Script = preload("res://addons/pasture_3d/menu/terrain_menu.gd")
const TerrainToolbar: Script = preload("res://addons/pasture_3d/src/toolbar.gd")
const TerrainToolSettings: Script = preload("res://addons/pasture_3d/src/tool_settings.gd")
const OperationBuilder: Script = preload("res://addons/pasture_3d/src/operation_builder.gd")
const GradientOperationBuilder: Script = preload("res://addons/pasture_3d/src/gradient_operation_builder.gd")

# Decal colors
const COLOR_RAISE := Color(1., 1., 1.) # White
const COLOR_LOWER := Color(0.2, 0.2, 0.2) # Dark gray
const COLOR_SMOOTH := Color(0.5, 0.0, 0.2) # Dark Red
const COLOR_AVERAGE := Color(0.6, 0.1, 0.3) # Neutral purple
const COLOR_LIFT := Color(1.0, 0.6, 0.0) # Bright orange
const COLOR_FLATTEN := Color(0.0, 0.6, 1.0) # Cyan
const COLOR_HEIGHT := Color(0.0, 0.8, 0.8) # Brighter cyan
const COLOR_SLOPE := Color(1.0, 1.0, 0.0) # Bright yellow
const COLOR_ERASE := Color(1.0, 0.42, 0.7) # Pink (eraser theme)
const COLOR_PAINT := Color(0.0, 0.5, 0.0) # Dark green
const COLOR_SPRAY := Color(0.4, 0.8, 0.4) # Lighter green
const COLOR_UNSPRAY := Color(0.5, 0.2, 0.5) # Neutral purple
const COLOR_WET := Color(0.4, 0.6, 1.0) # Light blue
const COLOR_DRY := Color(0.6, 0.4, 0.0) # Warm brown
const COLOR_AUTOSHADER := Color(0.36, 0.2, 0.09) # Chocolate
const COLOR_HOLES := Color(0.1, 0.1, 0.1) # Near-black
const COLOR_NAVIGATION := Color(0.5, 0.2, 0.5) # Purple
const COLOR_INSTANCE := Color(0.863, 0.08, 0.235) # Crimson
const COLOR_UNINSTANCE := Color(0.2, 0.9, 0.6) # Cyan-green
const COLOR_PICK := Color.WHITE

const OP_NONE: int = 0x0
const OP_POSITIVE_ONLY: int = 0x01
const OP_NEGATIVE_ONLY: int = 0x02

@onready var region_texture := ImageTexture.new() :
	set(value):
		var image: Image = Image.create_empty(1, 1, false, Image.FORMAT_R8)
		image.fill(Color.WHITE)
		value.create_from_image(image)
		region_texture = value
var plugin: EditorPlugin # Actually Pasture3DEditorPlugin, but Godot still has CRC errors
var toolbar: TerrainToolbar
var tool_settings: TerrainToolSettings
var terrain_menu: TerrainMenu
var setting_has_changed: bool = false
var visible: bool = false
var picking: int = Pasture3DEditor.TOOL_MAX
var picking_callback: Callable
var brush_data: Dictionary
var operation_builder: OperationBuilder
var active_tool: Pasture3DEditor.Tool = Pasture3DEditor.TOOL_MAX
var _selected_tool: Pasture3DEditor.Tool = Pasture3DEditor.TOOL_MAX
var active_operation: Pasture3DEditor.Operation = Pasture3DEditor.OP_MAX
var _selected_operation: Pasture3DEditor.Operation = Pasture3DEditor.OP_MAX
var inverted_input: bool = false

# 3 Editor decals: 0 = cursor, 1 = slope point1, 2 = slope point2
var mat_rid: RID
var editor_brush_texture_rid: RID = RID()
var editor_decal_position: Array[Vector2] = [Vector2(), Vector2(), Vector2()]
var editor_decal_rotation: Array[float] = [0., 0., 0.]
var editor_decal_size: Array[float] = [0., 0., 0.]
var editor_decal_color: Array[Color] = [Color(), Color(), Color()]
var editor_decal_visible: Array[bool] = [false, false, false]
var editor_decal_part: Array[bool] = [true, true] # Decal[0] cursor components: brush, reticle
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


func _enter_tree() -> void:
	if plugin.debug:
		print("Pasture3DUI: _enter_tree()")

	toolbar = TerrainToolbar.new()
	toolbar.plugin = plugin
	toolbar.hide()
	toolbar.tool_changed.connect(_on_tool_changed)
	toolbar.placement_toggled.connect(_on_placement_toggled)
	toolbar.selection_toggled.connect(_on_selection_toggled)

	tool_settings = TerrainToolSettings.new()
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

	# Bottom-bar landscape-brush type picker (shown only while the Place Brush tool is active).
	tool_settings.build_placement_selector(toolbar.PLACEABLE_BRUSHES)
	tool_settings.placement_type_changed.connect(_on_placement_type_changed)
	tool_settings.placement_offset_changed.connect(_on_placement_offset_changed)

	_on_tool_changed(Pasture3DEditor.REGION, Pasture3DEditor.ADD)
	
	editor_decal_timer = Timer.new()
	editor_decal_timer.wait_time = .5
	editor_decal_timer.one_shot = true
	editor_decal_timer.timeout.connect(func():
		get_tree().create_tween().tween_property(self, "editor_decal_fade", 0.0, 0.15))
	add_child(editor_decal_timer)


func _exit_tree() -> void:
	if plugin.debug:
		print("Pasture3DUI: _exit_tree()")
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	toolbar.queue_free()
	tool_settings.queue_free()
	terrain_menu.queue_free()
	editor_decal_timer.queue_free()


func set_visible(p_visible: bool, p_menu_only: bool = false) -> void:
	if plugin.debug:
		print("Pasture3DUI: set_visible(%s, %s)" % [ p_visible, p_menu_only ])

	terrain_menu.set_visible(p_visible)

	if p_menu_only:
		toolbar.set_visible(false)
		tool_settings.set_visible(false)
	else:
		visible = p_visible
		toolbar.set_visible(p_visible)
		tool_settings.set_visible(p_visible)

	if plugin.editor and plugin.terrain and p_visible:
			await get_tree().process_frame # Won't work, otherwise
			if plugin.debug:
				print("Pasture3DUI: set_visible: calling _on_tool_changed()")
			_on_tool_changed(_selected_tool, _selected_operation)
			if _selected_tool in [ Pasture3DEditor.REGION, Pasture3DEditor.NAVIGATION ]:
				plugin.terrain.material.update(Pasture3DMaterial.FULL_REBUILD)

	
func set_menu_visibility(p_list: Control, p_visible: bool) -> void:
	if p_list:
		p_list.get_parent().get_parent().visible = p_visible
	

func _on_tool_changed(p_tool: Pasture3DEditor.Tool, p_operation: Pasture3DEditor.Operation) -> void:
	if plugin.debug:
		print("Pasture3DUI: _on_tool_changed: ", p_tool, ", ", p_operation)
	if active_tool == p_tool and active_operation == p_operation:
		return
	_selected_tool = p_tool
	_selected_operation = p_operation
	clear_picking()
	set_menu_visibility(tool_settings.advanced_list, true)
	set_menu_visibility(tool_settings.scale_list, false)
	set_menu_visibility(tool_settings.rotation_list, false)
	set_menu_visibility(tool_settings.height_list, false)
	set_menu_visibility(tool_settings.color_list, false)
	set_menu_visibility(tool_settings.collision_list, false)

	# Select which settings to show. Options in tool_settings.gd:_ready
	var to_show: PackedStringArray = []
	
	match _selected_tool:
		Pasture3DEditor.REGION:
			to_show.push_back("instructions")
			to_show.push_back("invert")
			set_menu_visibility(tool_settings.advanced_list, false)

		Pasture3DEditor.SCULPT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			if _selected_operation in [Pasture3DEditor.ADD, Pasture3DEditor.SUBTRACT]:
					to_show.push_back("invert")
			elif _selected_operation == Pasture3DEditor.GRADIENT:
				to_show.push_back("gradient_points")
				to_show.push_back("drawable")

		Pasture3DEditor.HEIGHT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("height")
			to_show.push_back("height_picker")
			to_show.push_back("invert")

		Pasture3DEditor.TEXTURE:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("enable_texture")
			to_show.push_back("texture_picker")
			if _selected_operation == Pasture3DEditor.ADD:
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

		Pasture3DEditor.COLOR:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("color")
			to_show.push_back("color_picker")
			to_show.push_back("slope")
			to_show.push_back("texture_filter")
			to_show.push_back("margin")
			to_show.push_back("invert")

		Pasture3DEditor.ROUGHNESS:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("roughness")
			to_show.push_back("roughness_picker")
			to_show.push_back("slope")
			to_show.push_back("texture_filter")
			to_show.push_back("margin")
			to_show.push_back("invert")

		Pasture3DEditor.AUTOSHADER, Pasture3DEditor.HOLES, Pasture3DEditor.NAVIGATION:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("invert")

		Pasture3DEditor.INSTANCER:
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("slope")
			to_show.push_back("mesh_picker")
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
			set_menu_visibility(tool_settings.collision_list, true)
			to_show.push_back("on_collision")
			to_show.push_back("raycast_height")
			to_show.push_back("invert")

		_:
			pass

	# Advanced menu settings
	to_show.push_back("auto_regions")
	to_show.push_back("align_to_view")
	to_show.push_back("show_brush_texture")
	to_show.push_back("gamma")
	to_show.push_back("brush_spin_speed")
	tool_settings.show_settings(to_show)

	if plugin.debug:
		print("Pasture3DUI: _on_tool_changed: calling _on_setting_changed()")
	_on_setting_changed()


## Place-Brush tool toggled on/off (see toolbar.gd). While on, the native editor is parked on a no-op
## tool so a click can never sculpt, and the bottom-bar brush-type picker is shown. Toggling off restores
## the sculpt tool that's still selected in the radio.
func _on_placement_toggled(p_enabled: bool) -> void:
	plugin.placement_mode = p_enabled
	if p_enabled:
		plugin.selection_mode = false
		_enter_landscape_mode()
		tool_settings.show_placement_selector(true)
	else:
		tool_settings.show_placement_selector(false)
		_exit_landscape_mode_if_idle()


## Select-Brush tool toggled on/off. Same parking as placement, but no type picker (it selects, not adds).
func _on_selection_toggled(p_enabled: bool) -> void:
	plugin.selection_mode = p_enabled
	if p_enabled:
		plugin.placement_mode = false
		tool_settings.show_placement_selector(false)
		_enter_landscape_mode()
	else:
		_exit_landscape_mode_if_idle()


## Shared setup when a landscape pseudo-tool turns on: drop picking and hide the standard tool rows. No
## need to park the C++ editor tool — placement/selection are intercepted ahead of the sculpt path and
## ahead of update_decal in _forward_3d_gui_input, so a click can never sculpt and the old brush decal
## isn't refreshed (it just fades out).
func _enter_landscape_mode() -> void:
	clear_picking()
	tool_settings.show_settings(PackedStringArray())


## Leaving a landscape pseudo-tool: only when NEITHER is active (switching Place↔Select fires a stray
## toggled(false) on the deselected button — don't let it tear down the mode we're entering). Rebuilds
## the previously-selected sculpt tool's rows + restores its C++ tool/op. Force the guard open first
## (active_tool may equal _selected_tool again after a set_active_operation), else the rebuild no-ops.
func _exit_landscape_mode_if_idle() -> void:
	if not plugin.placement_mode and not plugin.selection_mode:
		active_tool = Pasture3DEditor.TOOL_MAX
		active_operation = Pasture3DEditor.OP_MAX
		_on_tool_changed(_selected_tool, _selected_operation)


func _on_placement_type_changed(p_script: String, p_label: String, p_icon: String) -> void:
	plugin.placement_brush_script = p_script
	plugin.placement_brush_label = p_label
	if toolbar and toolbar.placement_button:
		toolbar.placement_button.set_button_icon(load(p_icon))


func _on_placement_offset_changed(p_offset: float) -> void:
	plugin.placement_y_offset = p_offset


func _on_setting_changed(p_setting: Variant = null) -> void:
	if plugin.debug:
		print("Pasture3DUI: _on_setting_changed: ", p_setting if p_setting else "update all")
	if not plugin.asset_dock: # Skip function if not _ready()
		return
	brush_data = tool_settings.get_settings()
	brush_data["asset_id"] = plugin.asset_dock.current_list.get_selected_asset_id()
	if plugin.debug:
		print("Pasture3DUI: _on_setting_changed: selected resource ID: ", brush_data["asset_id"])
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
		match _selected_tool:
			Pasture3DEditor.SCULPT, Pasture3DEditor.HEIGHT, Pasture3DEditor.HOLES, \
			Pasture3DEditor.INSTANCER:
				active_tool = Pasture3DEditor.SCULPT
				active_operation = Pasture3DEditor.AVERAGE
			Pasture3DEditor.TEXTURE:
				active_tool = Pasture3DEditor.TEXTURE
				active_operation = Pasture3DEditor.AVERAGE
			Pasture3DEditor.COLOR:
				active_tool = Pasture3DEditor.COLOR
				active_operation = Pasture3DEditor.AVERAGE
			Pasture3DEditor.ROUGHNESS:
				active_tool = Pasture3DEditor.ROUGHNESS
				active_operation = Pasture3DEditor.AVERAGE
	
	# Else if Ctrl/Invert checked, opposite
	elif _selected_operation == Pasture3DEditor.ADD and inverted:
		active_tool = _selected_tool
		active_operation = Pasture3DEditor.SUBTRACT
	elif _selected_operation == Pasture3DEditor.SUBTRACT and not inverted:
		active_tool = _selected_tool
		active_operation = Pasture3DEditor.ADD

	# Else use default and set
	else:
		active_tool = _selected_tool
		active_operation = _selected_operation

	# Initiate Multipoint operation
	operation_builder = null
	if active_operation == Pasture3DEditor.GRADIENT:
		operation_builder = GradientOperationBuilder.new()
		operation_builder.tool_settings = tool_settings

	if plugin.editor:
		plugin.editor.set_tool(active_tool)
		plugin.editor.set_operation(active_operation)


func update_decal() -> void:
	if not plugin.terrain or not plugin.viewport or brush_data.size() <= 3:
		return
	
	# If not a state that should show the decal, hide everything and return
	mat_rid = plugin.terrain.material.get_material_rid() # Used in hide_decal() and below
	if not visible or \
		plugin._input_mode == -1 or \
		# After moving camera, wait for mouse cursor to update before revealing
		# See https://github.com/godotengine/godot/issues/70098
		Time.get_ticks_msec() - plugin.rmb_release_time <= 100:
			hide_decal()
			return
	
	# Only show decal if in viewport or toolbars
	var main: Control = EditorInterface.get_editor_main_screen()
	var main_rect := Rect2(main.position, main.size)
	main_rect.size.y += tool_settings.size.y
	if not ( main_rect.has_point(plugin.viewport.get_mouse_position()) && plugin.mouse_in_main ):
		return
	
	reset_decal_arrays()
	editor_decal_position[0] = Vector2(plugin.mouse_global_position.x, plugin.mouse_global_position.z)
	editor_decal_visible = [true, false, false] # Show cursor by default
	editor_decal_part = [true, true] # Show brush and reticle by default
	editor_decal_timer.start()
	
	## Region Operations
	var r_map: PackedInt32Array = plugin.terrain.data.get_region_map()
	if plugin.editor.get_tool() == Pasture3DEditor.REGION:
		var r_size: float = float(plugin.terrain.get_region_size()) * plugin.terrain.get_vertex_spacing()
		var map_size: int = plugin.terrain.data.REGION_MAP_SIZE
		var half_r_size: float = r_size * 0.5
		var pos: Vector2 = (Vector2(plugin.mouse_global_position.x, plugin.mouse_global_position.z) +
			Vector2(half_r_size, half_r_size)).snappedf(r_size) - Vector2(half_r_size, half_r_size)
		editor_brush_texture_rid = region_texture.get_rid()
		editor_decal_position[0] = pos
		editor_decal_size[0] = r_size
		editor_decal_rotation[0] = 0.0
		editor_decal_part[1] = false # Disable reticle
		
		var loc: Vector2i = plugin.terrain.data.get_region_location(plugin.mouse_global_position)
		loc += Vector2i(map_size / 2, map_size / 2)
		if !(loc.x < 0 or loc.x > map_size - 1 or loc.y < 0 or loc.y > map_size - 1):
			var index: int = clampi(loc.y * map_size + loc.x, 0, map_size * map_size - 1)
			if plugin.terrain.material.get_world_background() == Pasture3DMaterial.WorldBackground.NONE:
				if r_map[index] == 0 and active_operation == Pasture3DEditor.ADD:
					r_map[index] = -index - 1
				else:
					r_map[index] = r_map[index]
			
			match active_operation:
				Pasture3DEditor.ADD:
					if r_map[index] <= 0:
						editor_decal_color[0] = Color.WHITE
						editor_decal_color[0].a = 0.25
					else:
						hide_decal()
				
				Pasture3DEditor.SUBTRACT:
					if r_map[index] > 0:
						editor_decal_color[0] = Color.WHITE * .15
						editor_decal_color[0].a = 0.75
					else:
						hide_decal()
		else:
			hide_decal()

	## Picking
	elif picking != Pasture3DEditor.TOOL_MAX:
		editor_decal_part[0] = false # Hide brush
		editor_decal_size[0] = plugin.terrain.get_vertex_spacing()
		editor_decal_color[0] = COLOR_PICK
		editor_decal_color[0].a = 1.0

	## Brushing Operations
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
			Pasture3DEditor.SCULPT:
				match active_operation:
					Pasture3DEditor.ADD:
						if plugin.modifier_alt:
							editor_decal_color[0] = COLOR_LIFT
							editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5)
						else:
							editor_decal_color[0] = COLOR_RAISE
							editor_decal_color[0].a = clamp(brush_data["strength"], .25, .5)
					Pasture3DEditor.SUBTRACT:
						if plugin.modifier_alt:
							editor_decal_color[0] = COLOR_FLATTEN
							editor_decal_color[0].a = clamp(brush_data["strength"], .25, .5) + .1
						else:
							editor_decal_color[0] = COLOR_LOWER
							editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
					Pasture3DEditor.AVERAGE:
						editor_decal_color[0] = COLOR_SMOOTH
						editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
					Pasture3DEditor.GRADIENT:
						editor_decal_color[0] = COLOR_SLOPE
						editor_decal_color[0].a = clamp(brush_data["strength"], .2, .4)
					Pasture3DEditor.ERASE:
						editor_decal_color[0] = COLOR_ERASE
						editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
			Pasture3DEditor.HEIGHT:
				editor_decal_color[0] = COLOR_HEIGHT
				editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
			Pasture3DEditor.TEXTURE:
				if plugin._input_mode == 1:
					editor_decal_part[0] = false # Hide brush
				if plugin.modifier_shift:
					editor_decal_color[0] = COLOR_AVERAGE
					editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
				else:
					match active_operation:
						Pasture3DEditor.REPLACE:
							editor_decal_color[0] = COLOR_PAINT
							editor_decal_color[0].a = .6
						Pasture3DEditor.SUBTRACT:
							editor_decal_color[0] = COLOR_UNSPRAY
							editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .1
						Pasture3DEditor.ADD:
							editor_decal_color[0] = COLOR_SPRAY
							editor_decal_color[0].a = clamp(brush_data["strength"], .15, .4)
			Pasture3DEditor.COLOR:
				if plugin.modifier_shift:
					editor_decal_color[0] = COLOR_AVERAGE
					editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
				elif plugin.modifier_ctrl:
					editor_decal_color[0] = Color.WHITE
					editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5)
				else:
					editor_decal_color[0] = brush_data["color"].srgb_to_linear()
					editor_decal_color[0].a *= clamp(brush_data["strength"], .3, .5)
			Pasture3DEditor.ROUGHNESS:
				if plugin._input_mode == 1:
					editor_decal_part[0] = false # Hide brush
				if plugin.modifier_shift:
					editor_decal_color[0] = COLOR_AVERAGE
					editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .25
				elif plugin.modifier_ctrl:
					editor_decal_color[0] = COLOR_DRY
					editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .1
				else:
					editor_decal_color[0] = COLOR_WET
					editor_decal_color[0].a = clamp(brush_data["strength"], .2, .5) + .1
			Pasture3DEditor.AUTOSHADER:
				editor_decal_color[0] = COLOR_AUTOSHADER
				editor_decal_color[0].a = .6
			Pasture3DEditor.HOLES:
				editor_decal_color[0] = COLOR_HOLES
				editor_decal_color[0].a = .75
			Pasture3DEditor.NAVIGATION:
				editor_decal_color[0] = COLOR_NAVIGATION
				editor_decal_color[0].a = .80
			Pasture3DEditor.INSTANCER:
				editor_decal_part[0] = false # Hide brush
				if plugin.modifier_ctrl:
					editor_decal_color[0] = COLOR_UNINSTANCE
					editor_decal_color[0].a = .75
				else:
					editor_decal_color[0] = COLOR_INSTANCE
					editor_decal_color[0].a = .75
	
	if plugin.editor.get_tool() != Pasture3DEditor.REGION and not brush_data["show_brush_texture"]:
		editor_decal_part[0] = false # Hide brush
	
	if active_operation == Pasture3DEditor.GRADIENT:
		var point1: Vector3 = brush_data["gradient_points"][0]
		if point1 != Vector3.ZERO:
			editor_decal_color[1] = COLOR_SLOPE
			editor_decal_size[1] = 0.25
			editor_decal_visible[1] = true
			editor_decal_position[1] = Vector2(point1.x, point1.z)
		var point2: Vector3 = brush_data["gradient_points"][1]
		if point2 != Vector3.ZERO:
			editor_decal_color[2] = COLOR_SLOPE
			editor_decal_size[2] = 0.25
			editor_decal_visible[2] = true
			editor_decal_position[2] = Vector2(point2.x, point2.z)
	
	if RenderingServer.get_current_rendering_method().contains("gl_compatibility"):
		for i in editor_decal_color.size():
			editor_decal_color[i].a = maxf(0.1, editor_decal_color[i].a - .25)
	
	editor_decal_fade = editor_decal_color[0].a
	# Update Shader params
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_brush_texture", editor_brush_texture_rid)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_position", editor_decal_position)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_size", editor_decal_size)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_part", editor_decal_part)
		RenderingServer.material_set_param(mat_rid, "_region_map", r_map)


## Crosshair under the cursor for the Place Brush tool. Shows just the cursor reticle (no brush circle)
## at `world_pos`, mirroring how the picking decal is drawn — placement skips the normal update_decal()
## path, so it pushes the shader params itself.
func show_placement_decal(world_pos: Vector3) -> void:
	if not plugin.terrain or not visible:
		return
	mat_rid = plugin.terrain.material.get_material_rid()
	if not is_shader_valid():
		return
	reset_decal_arrays()
	editor_brush_texture_rid = RID()
	editor_decal_position[0] = Vector2(world_pos.x, world_pos.z)
	editor_decal_rotation[0] = 0.0
	editor_decal_size[0] = maxf(plugin.terrain.get_vertex_spacing() * 4.0, 2.0)
	editor_decal_color[0] = COLOR_PICK
	editor_decal_color[0].a = 1.0
	editor_decal_visible = [true, false, false]
	editor_decal_part = [false, true] # reticle only (crosshair), no brush texture
	editor_decal_timer.start()
	var r_map: PackedInt32Array = plugin.terrain.data.get_region_map()
	RenderingServer.material_set_param(mat_rid, "_editor_brush_texture", editor_brush_texture_rid)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_position", editor_decal_position)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_size", editor_decal_size)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_part", editor_decal_part)
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
		editor_brush_texture_rid = RID()
		editor_decal_position = [Vector2(), Vector2(), Vector2()]
		editor_decal_rotation = [0., 0., 0.]
		editor_decal_size = [0., 0., 0.]
		editor_decal_color = [Color(), Color(), Color()]
		editor_decal_visible = [false, false, false]
		editor_decal_part = [true, true]


func set_decal_rotation(p_rot: float) -> void:
	editor_decal_rotation[0] = p_rot
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)


func _on_picking(p_type: Pasture3DEditor.Tool, p_callback: Callable) -> void:
	picking = p_type
	picking_callback = p_callback
	# Only the instancer picker has anything to highlight; the rest read a pixel.
	if picking == Pasture3DEditor.Tool.INSTANCER:
		if not get_tree().process_frame.is_connected(_update_picker_highlight):
			get_tree().process_frame.connect(_update_picker_highlight)
	elif get_tree().process_frame.is_connected(_update_picker_highlight):
		get_tree().process_frame.disconnect(_update_picker_highlight)


## Tints the mesh asset currently under the cursor while the instancer picker is armed, so it is
## clear which one a click would take. Runs every frame, which is affordable because
## set_highlighted() early-outs when the flag is unchanged -- only a change reaches the dock.
func _update_picker_highlight() -> void:
	var assets: Pasture3DAssets = _picker_assets()
	if assets == null:
		return
	var mesh_asset_id: int = -1
	if plugin.terrain.data.has_regionp(plugin.mouse_global_position):
		mesh_asset_id = plugin.terrain.instancer.get_closest_mesh_id(plugin.mouse_global_position)
	for i: int in assets.get_mesh_count():
		var ma: Pasture3DMeshAsset = assets.get_mesh_asset(i)
		if ma:
			ma.set_highlighted(i == mesh_asset_id)


func clear_picking() -> void:
	picking = Pasture3DEditor.TOOL_MAX
	if not get_tree().process_frame.is_connected(_update_picker_highlight):
		return
	get_tree().process_frame.disconnect(_update_picker_highlight)
	var assets: Pasture3DAssets = _picker_assets()
	if assets == null:
		return
	for i: int in assets.get_mesh_count():
		var ma: Pasture3DMeshAsset = assets.get_mesh_asset(i)
		if ma:
			ma.set_highlighted(false)
	if plugin.asset_dock:
		plugin.asset_dock.update_dock()


## The highlight path runs from a frame signal and from teardown, so it can fire after the
## terrain has gone away -- when the plugin is disabled mid-pick, or the node is deleted while
## the picker is armed. Upstream reaches straight through this chain.
func _picker_assets() -> Pasture3DAssets:
	if plugin == null or not is_instance_valid(plugin.terrain):
		return null
	return plugin.terrain.assets


func is_picking() -> bool:
	if picking != Pasture3DEditor.TOOL_MAX:
		return true
	
	if operation_builder and operation_builder.is_picking():
		return true
	
	return false


func pick(p_global_position: Vector3) -> void:
	if picking != Pasture3DEditor.TOOL_MAX:
		var color: Color
		match picking:
			Pasture3DEditor.HEIGHT, Pasture3DEditor.SCULPT:
				color = Color(plugin.terrain.data.get_height(p_global_position), 0., 0., 1.)
			Pasture3DEditor.ROUGHNESS:
				color = plugin.terrain.data.get_pixel(Pasture3DRegion.TYPE_COLOR, p_global_position)
			Pasture3DEditor.COLOR:
				color = plugin.terrain.data.get_color(p_global_position)
			Pasture3DEditor.ANGLE:
				color = Color(plugin.terrain.data.get_control_angle(p_global_position), 0., 0., 1.)
			Pasture3DEditor.SCALE:
				color = Color(plugin.terrain.data.get_control_scale(p_global_position), 0., 0., 1.)
			Pasture3DEditor.INSTANCER:
				var mesh_asset_id: int = plugin.terrain.instancer.get_closest_mesh_id(p_global_position)
				color = Color(mesh_asset_id, 0., 0., 1.)
			Pasture3DEditor.TEXTURE:
				var texture_blend_data: Vector3 = plugin.terrain.data.get_texture_id(p_global_position)
				if not texture_blend_data.is_finite():
					return
				if texture_blend_data.z < 0.65:
					color = Color(texture_blend_data.x, 0., 0., 1.)
				else:
					color = Color(texture_blend_data.y, 0., 0., 1.)
			_:
				push_error("Unsupported picking type: ", picking)
				return
		if picking_callback.is_valid():
			picking_callback.call(picking, color, p_global_position)
			picking_callback = Callable()
		clear_picking()

	elif operation_builder and operation_builder.is_picking():
		operation_builder.pick(p_global_position, plugin.terrain)


func set_button_editor_icon(p_button: Button, p_icon_name: String) -> void:
	p_button.icon = EditorInterface.get_base_control().get_theme_icon(p_icon_name, "EditorIcons")
