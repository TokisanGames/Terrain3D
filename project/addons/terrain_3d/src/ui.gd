extends Node
#class_name Terrain3DUI Cannot be named until Godot #75388


# Includes
const Toolbar: Script = preload("res://addons/terrain_3d/src/toolbar.gd")
const ToolSettings: Script = preload("res://addons/terrain_3d/src/tool_settings.gd")
const TerrainMenu: Script = preload("res://addons/terrain_3d/src/terrain_menu.gd")
const OperationBuilder: Script = preload("res://addons/terrain_3d/src/operation_builder.gd")
const GradientOperationBuilder: Script = preload("res://addons/terrain_3d/src/gradient_operation_builder.gd")
const COLOR_RAISE := Color.WHITE
const COLOR_LOWER := Color(.02, .02, .02)
const COLOR_SMOOTH := Color(0.5, 0, .1)
const COLOR_LIFT := Color.ORANGE
const COLOR_FLATTEN := Color.BLUE_VIOLET
const COLOR_HEIGHT := Color(0., 0.32, .4)
const COLOR_SLOPE := Color.YELLOW
const COLOR_PAINT := Color.FOREST_GREEN
const COLOR_SPRAY := Color.SEA_GREEN
const COLOR_ROUGHNESS := Color.ROYAL_BLUE
const COLOR_AUTOSHADER := Color.DODGER_BLUE
const COLOR_HOLES := Color.BLACK
const COLOR_NAVIGATION := Color(.15, .0, .255)
const COLOR_INSTANCER := Color.CRIMSON
const COLOR_PICK_COLOR := Color.WHITE
const COLOR_PICK_HEIGHT := Color.DARK_RED
const COLOR_PICK_ROUGH := Color.ROYAL_BLUE

const MODIFIER_KEYS := [KEY_SHIFT, KEY_CTRL, KEY_ALT]
const M_SHIFT: int = 0x1
const M_CTRL: int = 0x2
const M_ALT: int = 0x4
const OP_NONE: int = 0x0
const OP_POSITIVE_ONLY: int = 0x01
const OP_NEGATIVE_ONLY: int = 0x02

const RING1: String = "res://addons/terrain_3d/brushes/ring1.exr"
@onready var ring_texture := ImageTexture.create_from_image(Terrain3DUtil.black_to_alpha(Image.load_from_file(RING1)))

var plugin: EditorPlugin # Actually Terrain3DEditorPlugin, but Godot still has CRC errors
var toolbar: Toolbar
var tool_settings: ToolSettings
var terrain_menu: TerrainMenu
var setting_has_changed: bool = false
var visible: bool = false
var picking: int = Terrain3DEditor.TOOL_MAX
var picking_callback: Callable
var decal: Decal
var decal_timer: Timer
var gradient_decals: Array[Decal]
var brush_data: Dictionary
var operation_builder: OperationBuilder
var modifiers: int = 0
var modifier_ctrl: bool
var modifier_alt: bool
var modifier_shift: bool
var last_tool: Terrain3DEditor.Tool
var last_operation: Terrain3DEditor.Operation
var last_rmb_time: int = 0

# Compatibility decals, indices; 0 = main brush, 1 = slope point A, 2 = slope point B
var editor_decal_position: Array[Vector2]
var editor_decal_rotation: Array[float]
var editor_decal_size: Array[float]
var editor_decal_color: Array[Color]
var editor_decal_visible: Array[bool]


func _enter_tree() -> void:
	toolbar = Toolbar.new()
	toolbar.hide()
	toolbar.connect("tool_changed", _on_tool_changed)
	
	tool_settings = ToolSettings.new()
	tool_settings.connect("setting_changed", _on_setting_changed)
	tool_settings.connect("picking", _on_picking)
	tool_settings.plugin = plugin
	tool_settings.hide()

	terrain_menu = TerrainMenu.new()
	terrain_menu.plugin = plugin
	terrain_menu.hide()

	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, terrain_menu)

	_on_tool_changed(Terrain3DEditor.REGION, Terrain3DEditor.ADD)
	
	decal = Decal.new()
	add_child(decal)
	decal_timer = Timer.new()
	decal_timer.wait_time = .5
	decal_timer.one_shot = true
	decal_timer.timeout.connect(Callable(func(node):
		if node:
			get_tree().create_tween().tween_property(node, "albedo_mix", 0.0, 0.15)).bind(decal))
	add_child(decal_timer)
	plugin.godot_editor_window.focus_entered.connect(_on_godot_focus_entered)


func _exit_tree() -> void:
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	toolbar.queue_free()
	tool_settings.queue_free()
	terrain_menu.queue_free()
	decal.queue_free()
	decal_timer.queue_free()
	for gradient_decal in gradient_decals:
		gradient_decal.queue_free()
	gradient_decals.clear()
	plugin.godot_editor_window.focus_entered.disconnect(_on_godot_focus_entered)


func _on_godot_focus_entered() -> void:
	update_modifiers()
	update_decal()


func set_visible(p_visible: bool, p_menu_only: bool = false) -> void:
	if(plugin.editor):
		if(p_visible):
			await get_tree().create_timer(.01).timeout # Won't work, otherwise.
			_on_tool_changed(last_tool, last_operation)
		else:
			plugin.editor.set_tool(Terrain3DEditor.TOOL_MAX)
			plugin.editor.set_operation(Terrain3DEditor.OP_MAX)
	
	terrain_menu.set_visible(p_visible)

	if p_menu_only:
		toolbar.set_visible(false)
		tool_settings.set_visible(false)
	else:
		visible = p_visible
		toolbar.set_visible(p_visible)
		tool_settings.set_visible(p_visible)
		update_decal()


func set_menu_visibility(p_list: Control, p_visible: bool) -> void:
	if p_list:
		p_list.get_parent().get_parent().visible = p_visible
	

func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	clear_picking()
	set_menu_visibility(tool_settings.advanced_list, true)
	set_menu_visibility(tool_settings.scale_list, false)
	set_menu_visibility(tool_settings.rotation_list, false)
	set_menu_visibility(tool_settings.height_list, false)
	set_menu_visibility(tool_settings.color_list, false)

	# Select which settings to show. Options in tool_settings.gd:_ready
	var to_show: PackedStringArray = []
	
	match p_tool:
		Terrain3DEditor.REGION:
			to_show.push_back("instructions")
			to_show.push_back("remove")
			set_menu_visibility(tool_settings.advanced_list, false)

		Terrain3DEditor.SCULPT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			if p_operation in [Terrain3DEditor.ADD, Terrain3DEditor.SUBTRACT]:
					to_show.push_back("remove")
			elif p_operation == Terrain3DEditor.GRADIENT:
				to_show.push_back("gradient_points")
				to_show.push_back("drawable")

		Terrain3DEditor.HEIGHT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("height")
			to_show.push_back("height_picker")

		Terrain3DEditor.TEXTURE:	
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("enable_texture")
			if p_operation == Terrain3DEditor.ADD:
				to_show.push_back("strength")
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
			to_show.push_back("enable_texture")
			to_show.push_back("margin")
			to_show.push_back("remove")

		Terrain3DEditor.ROUGHNESS:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("roughness")
			to_show.push_back("roughness_picker")
			to_show.push_back("slope")
			to_show.push_back("enable_texture")
			to_show.push_back("margin")
			to_show.push_back("remove")

		Terrain3DEditor.AUTOSHADER, Terrain3DEditor.HOLES, Terrain3DEditor.NAVIGATION:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("remove")

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
			to_show.push_back("fixed_angle")
			to_show.push_back("random_angle")
			to_show.push_back("align_to_normal")
			set_menu_visibility(tool_settings.color_list, true)
			to_show.push_back("vertex_color")
			to_show.push_back("random_darken")
			to_show.push_back("random_hue")
			to_show.push_back("remove")

		_:
			pass

	# Advanced menu settings
	to_show.push_back("auto_regions")
	to_show.push_back("align_to_view")
	to_show.push_back("show_cursor_while_painting")
	to_show.push_back("gamma")
	to_show.push_back("jitter")
	tool_settings.show_settings(to_show)

	operation_builder = null
	if p_operation == Terrain3DEditor.GRADIENT:
		operation_builder = GradientOperationBuilder.new()
		operation_builder.tool_settings = tool_settings

	if plugin.editor:
		plugin.editor.set_tool(p_tool)
		plugin.editor.set_operation(_modify_operation(p_operation))
		last_tool = p_tool
		last_operation = p_operation

	_on_setting_changed()
	plugin.update_region_grid()


func _on_setting_changed() -> void:
	if not plugin.asset_dock:
		return
	brush_data = tool_settings.get_settings()
	brush_data["asset_id"] = plugin.asset_dock.get_current_list().get_selected_id()
	update_decal()
	plugin.editor.set_brush_data(brush_data)
	plugin.editor.set_operation(_modify_operation(plugin.editor.get_operation()))


func update_decal() -> void:
	var mouse_buttons: int = Input.get_mouse_button_mask()

	# If not a state that should show the decal, hide everything and return
	if not visible or \
			not plugin.terrain or \
			# Wait for cursor to recenter after right-click before revealing
			# See https://github.com/godotengine/godot/issues/70098
			Time.get_ticks_msec() - last_rmb_time <= 10 or \
			brush_data.is_empty() or \
			mouse_buttons & MOUSE_BUTTON_RIGHT or \
			(mouse_buttons & MOUSE_BUTTON_LEFT and not brush_data["show_cursor_while_painting"]) or \
			plugin.editor.get_tool() == Terrain3DEditor.REGION:
		decal.visible = false
		for gradient_decal in gradient_decals:
			gradient_decal.visible = false
		return

	decal.visible = true
	decal.size = Vector3.ONE * brush_data["size"]
	if brush_data["align_to_view"]:
		var cam: Camera3D = plugin.terrain.get_camera();
		if (cam):
			decal.rotation.y = cam.rotation.y
	else:
		decal.rotation.y = 0

	# Set texture and color
	if picking != Terrain3DEditor.TOOL_MAX:
		decal.texture_albedo = ring_texture
		decal.size = Vector3.ONE * 10. * plugin.terrain.get_vertex_spacing()
		match picking:
			Terrain3DEditor.HEIGHT:
				decal.modulate = COLOR_PICK_HEIGHT
			Terrain3DEditor.COLOR:
				decal.modulate = COLOR_PICK_COLOR
			Terrain3DEditor.ROUGHNESS:
				decal.modulate = COLOR_PICK_ROUGH
		decal.modulate.a = 1.0
	else:
		decal.texture_albedo = brush_data["brush"][1]
		match plugin.editor.get_tool():
			Terrain3DEditor.SCULPT:
				match plugin.editor.get_operation():
					Terrain3DEditor.ADD:
						if modifier_alt:
							decal.modulate = COLOR_LIFT
							decal.modulate.a = clamp(brush_data["strength"], .2, .5)
						else:
							decal.modulate = COLOR_RAISE
							decal.modulate.a = clamp(brush_data["strength"], .2, .5)
					Terrain3DEditor.SUBTRACT:
						if modifier_alt:
							decal.modulate = COLOR_FLATTEN
							decal.modulate.a = clamp(brush_data["strength"], .2, .5)
						else:
							decal.modulate = COLOR_LOWER
							decal.modulate.a = clamp(brush_data["strength"], .2, .5) + .5
					Terrain3DEditor.AVERAGE:
						decal.modulate = COLOR_SMOOTH
						decal.modulate.a = clamp(brush_data["strength"], .2, .5) + .2
					Terrain3DEditor.GRADIENT:
						decal.modulate = COLOR_SLOPE
						decal.modulate.a = clamp(brush_data["strength"], .2, .5)
			Terrain3DEditor.HEIGHT:
				decal.modulate = COLOR_HEIGHT
				decal.modulate.a = clamp(brush_data["strength"], .2, .5)
			Terrain3DEditor.TEXTURE:
				match plugin.editor.get_operation():
					Terrain3DEditor.REPLACE:
						decal.modulate = COLOR_PAINT
						decal.modulate.a = .7
					Terrain3DEditor.ADD:
						decal.modulate = COLOR_SPRAY
						decal.modulate.a = clamp(brush_data["strength"], .2, .5)
			Terrain3DEditor.COLOR:
				decal.modulate = brush_data["color"].srgb_to_linear()
				decal.modulate.a *= clamp(brush_data["strength"], .2, .5)
			Terrain3DEditor.ROUGHNESS:
				decal.modulate = COLOR_ROUGHNESS
				decal.modulate.a = clamp(brush_data["strength"], .2, .5)
			Terrain3DEditor.AUTOSHADER:
				decal.modulate = COLOR_AUTOSHADER
				decal.modulate.a = .7
			Terrain3DEditor.HOLES:
				decal.modulate = COLOR_HOLES
				decal.modulate.a = .85
			Terrain3DEditor.NAVIGATION:
				decal.modulate = COLOR_NAVIGATION
				decal.modulate.a = .85
			Terrain3DEditor.INSTANCER:
				decal.texture_albedo = ring_texture
				decal.modulate = COLOR_INSTANCER
				decal.modulate.a = 1.0
	decal.size.y = max(1000, decal.size.y)
	decal.albedo_mix = 1.0
	decal.cull_mask = 1 << ( plugin.terrain.get_mouse_layer() - 1 )
	decal_timer.start()

	for gradient_decal in gradient_decals:
		gradient_decal.visible = false
	
	if plugin.editor.get_operation() == Terrain3DEditor.GRADIENT:
		var index := 0
		for point in brush_data["gradient_points"]:
			if point != Vector3.ZERO:
				var point_decal: Decal = _get_gradient_decal(index)
				point_decal.visible = true
				point_decal.position = point
				index += 1

	update_compatibility_decal()


func _get_gradient_decal(index: int) -> Decal:
	if gradient_decals.size() > index:
		return gradient_decals[index]
	
	var gradient_decal := Decal.new()
	gradient_decal = Decal.new()
	gradient_decal.texture_albedo = ring_texture
	gradient_decal.modulate = COLOR_SLOPE
	gradient_decal.size = Vector3.ONE * 10. * plugin.terrain.get_vertex_spacing()
	gradient_decal.size.y = 1000.
	gradient_decal.cull_mask = decal.cull_mask
	add_child(gradient_decal)
	
	gradient_decals.push_back(gradient_decal)
	return gradient_decal


func update_compatibility_decal() -> void:
	if not plugin.terrain.is_compatibility_mode():
		return

	# Verify setup
	if editor_decal_position.size() != 3:
		editor_decal_position.resize(3)
		editor_decal_rotation.resize(3)
		editor_decal_size.resize(3)
		editor_decal_color.resize(3)
		editor_decal_visible.resize(3)
		decal_timer.timeout.connect(func():
			var mat_rid: RID = plugin.terrain.material.get_material_rid()
			editor_decal_visible[0] = false
			RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
			)

	# Update compatibility decal
	var mat_rid: RID = plugin.terrain.material.get_material_rid()
	if decal.visible:
		editor_decal_position[0] = Vector2(decal.global_position.x, decal.global_position.z)
		editor_decal_rotation[0] = decal.rotation.y
		editor_decal_size[0] = brush_data.get("size")
		editor_decal_color[0] = decal.modulate
		editor_decal_visible[0] = decal.visible
		RenderingServer.material_set_param(
			mat_rid, "_editor_decal_0", decal.texture_albedo.get_rid()
			)
	if gradient_decals.size() >= 1:
		editor_decal_position[1] = Vector2(gradient_decals[0].global_position.x,
			gradient_decals[0].global_position.z)
		editor_decal_rotation[1] = gradient_decals[0].rotation.y
		editor_decal_size[1] = 10.0
		editor_decal_color[1] = gradient_decals[0].modulate
		editor_decal_visible[1] = gradient_decals[0].visible
		RenderingServer.material_set_param(
			mat_rid, "_editor_decal_1", gradient_decals[0].texture_albedo.get_rid()
			)
	if gradient_decals.size() >= 2:
		editor_decal_position[2] = Vector2(gradient_decals[1].global_position.x,
			gradient_decals[1].global_position.z)
		editor_decal_rotation[2] = gradient_decals[1].rotation.y
		editor_decal_size[2] = 10.0
		editor_decal_color[2] = gradient_decals[1].modulate
		editor_decal_visible[2] = gradient_decals[1].visible
		RenderingServer.material_set_param(
			mat_rid, "_editor_decal_2", gradient_decals[1].texture_albedo.get_rid()
			)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_position", editor_decal_position)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_size", editor_decal_size)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
	RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)


func set_decal_rotation(p_rot: float) -> void:
	decal.rotation.y = p_rot


func _on_picking(p_type: int, p_callback: Callable) -> void:
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
				color = plugin.terrain.data.get_pixel(Terrain3DRegion.TYPE_HEIGHT, p_global_position)
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
		picking_callback.call(picking, color, p_global_position)
		picking = Terrain3DEditor.TOOL_MAX
	
	elif operation_builder and operation_builder.is_picking():
		operation_builder.pick(p_global_position, plugin.terrain)


func update_modifiers() -> void:
	# Return if modifiers haven't changed; modifiers disappear when clicking asset_dock
	var current_mods: int = 0
	for i in MODIFIER_KEYS.size():
		if Input.is_key_pressed(MODIFIER_KEYS[i]):
			current_mods |= 1 << i
	if modifiers == current_mods and brush_data.has("modifier_shift"):
		return
	
	modifier_shift = bool(current_mods & M_SHIFT)
	brush_data["modifier_shift"] = modifier_shift

	modifier_ctrl = bool(current_mods & M_CTRL)
	brush_data["modifier_ctrl"] = modifier_ctrl
	toolbar.show_add_buttons(!modifier_ctrl)

	modifier_alt = bool(current_mods & M_ALT)
	brush_data["modifier_alt"] = modifier_alt

	if modifier_shift and not modifier_ctrl:
		plugin.editor.set_tool(Terrain3DEditor.SCULPT)
		plugin.editor.set_operation(Terrain3DEditor.AVERAGE)
	else:
		plugin.editor.set_tool(last_tool)
		if modifier_ctrl:
			plugin.editor.set_operation(_modify_operation(last_operation))
		else:
			plugin.editor.set_operation(last_operation)
	
	modifiers = current_mods


func _modify_operation(p_operation: Terrain3DEditor.Operation) -> Terrain3DEditor.Operation:
	var remove_checked: bool = false
	if DisplayServer.is_touchscreen_available():
		var removable_tools := [Terrain3DEditor.REGION, Terrain3DEditor.SCULPT, Terrain3DEditor.HEIGHT, Terrain3DEditor.AUTOSHADER,
			Terrain3DEditor.HOLES, Terrain3DEditor.INSTANCER, Terrain3DEditor.NAVIGATION, 
			Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS]
		remove_checked = brush_data.get("remove", false) && plugin.editor.get_tool() in removable_tools
		
	if modifier_ctrl or remove_checked:
		return _invert_operation(p_operation, OP_NEGATIVE_ONLY)
	return _invert_operation(p_operation, OP_POSITIVE_ONLY)


func _invert_operation(p_operation: Terrain3DEditor.Operation, flags: int = OP_NONE) -> Terrain3DEditor.Operation:
	if p_operation == Terrain3DEditor.ADD and ! (flags & OP_POSITIVE_ONLY):
		return Terrain3DEditor.SUBTRACT
	elif p_operation == Terrain3DEditor.SUBTRACT and ! (flags & OP_NEGATIVE_ONLY):
		return Terrain3DEditor.ADD
	return p_operation


func set_button_editor_icon(p_button: Button, p_icon_name: String) -> void:
	p_button.icon = EditorInterface.get_base_control().get_theme_icon(p_icon_name, "EditorIcons")
