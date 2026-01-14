# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Tool settings bar for Terrain3D
extends PanelContainer

signal picking(type: Terrain3DEditor.Tool, callback: Callable)
signal setting_changed(setting: Variant)

enum Layout {
	HORIZONTAL,
	VERTICAL,
	GRID,
}

enum SettingType {
	CHECKBOX,
	COLOR_SELECT,
	DOUBLE_SLIDER,
	OPTION,
	PICKER,
	MULTI_PICKER,
	SLIDER,
	LABEL,
	TYPE_MAX,
}

const MultiPicker: Script = preload("res://addons/terrain_3d/src/multi_picker.gd")
const DEFAULT_BRUSH: String = "circle0.exr"
const BRUSH_PATH: String = "res://addons/terrain_3d/brushes"
const ES_TOOL_SETTINGS: String = "terrain3d/tool_settings/"
const LAYER_BLEND_LABELS := ["Add", "Subtract", "Replace"]
const MAP_TYPE_LABELS := {
	Terrain3DRegion.TYPE_HEIGHT: "Height",
	Terrain3DRegion.TYPE_CONTROL: "Control",
	Terrain3DRegion.TYPE_COLOR: "Color"
}

# Add settings flags
const NONE: int = 0x0
const ALLOW_LARGER: int = 0x1
const ALLOW_SMALLER: int = 0x2
const ALLOW_OUT_OF_BOUNDS: int = 0x3 # LARGER|SMALLER
const NO_LABEL: int = 0x4
const ADD_SEPARATOR: int = 0x8 # Add a vertical line before this entry
const ADD_SPACER: int = 0x10 # Add a space before this entry
const NO_SAVE: int = 0x20 # Don't save this in EditorSettings

var plugin: EditorPlugin # Actually Terrain3DEditorPlugin, but Godot still has CRC errors
var brush_preview_material: ShaderMaterial
var select_brush_button: Button
var selected_brush_imgs: Array
var main_list: HFlowContainer
var advanced_list: VBoxContainer
var height_list: VBoxContainer
var scale_list: VBoxContainer
var rotation_list: VBoxContainer
var color_list: VBoxContainer
var collision_list: VBoxContainer
var settings: Dictionary = {}
var layer_section: VBoxContainer
var layers_list: VBoxContainer
var layer_header_label: Label
var layer_refresh_button: Button
var layer_add_button: Button
var layer_locked_filter_button: CheckBox
var current_layer_region: Vector2i = Vector2i.ZERO
var current_layer_map_type: int = Terrain3DRegion.TYPE_MAX
var layer_selection_group: ButtonGroup
var _layer_entries: Array = [] ## Array[Dictionary] storing group_id, representative layer, and slice metadata
var _show_locked_layers: bool = false
var _selected_layer_groups: Dictionary = {}
var _layer_row_panels: Dictionary = {}
var _selected_row_style: StyleBoxFlat


func _ready() -> void:
	# Remove old editor settings, newer first so oldest can be removed
	for setting in ["jitter", "lift_floor", "flatten_peaks", "lift_flatten", "automatic_regions",
			"show_cursor_while_painting", "crosshair_threshold"]:
		plugin.erase_setting(ES_TOOL_SETTINGS + setting)

	# Setup buttons	
	main_list = HFlowContainer.new()
	add_child(main_list, true)
	
	add_brushes(main_list)

	add_setting({ "name":"instructions", "label":"Click the terrain to add a region. CTRL+Click to remove. Or select another tool on the left.",
		"type":SettingType.LABEL, "list":main_list, "flags":NO_LABEL|NO_SAVE })

	add_setting({ "name":"size", "type":SettingType.SLIDER, "list":main_list, "default":20, "unit":"m",
							"range":Vector3(0.1, 200, 1), "flags":ALLOW_LARGER|ADD_SPACER })
		
	add_setting({ "name":"strength", "type":SettingType.SLIDER, "list":main_list, "default":33, 
							"unit":"%", "range":Vector3(1, 100, 1), "flags":ALLOW_LARGER })

	add_setting({ "name":"height", "type":SettingType.SLIDER, "list":main_list, "default":20, 
							"unit":"m", "range":Vector3(-500, 500, 0.1), "flags":ALLOW_OUT_OF_BOUNDS })
	add_setting({ "name":"height_picker", "type":SettingType.PICKER, "list":main_list, "default":Terrain3DEditor.HEIGHT,
							"flags":NO_LABEL, "tooltip":"Pick Height from the terrain." })
	
	add_setting({ "name":"color", "type":SettingType.COLOR_SELECT, "list":main_list, 
							"default":Color.WHITE, "flags":ADD_SEPARATOR })
	add_setting({ "name":"color_picker", "type":SettingType.PICKER, "list":main_list, "default":Terrain3DEditor.COLOR,
							"flags":NO_LABEL, "tooltip":"Pick Color from the terrain." })

	add_setting({ "name":"roughness", "type":SettingType.SLIDER, "list":main_list, "default":-65,
							"unit":"%", "range":Vector3(-100, 100, 1), "flags":ADD_SEPARATOR })
	add_setting({ "name":"roughness_picker", "type":SettingType.PICKER, "list":main_list, "default":Terrain3DEditor.ROUGHNESS,
							"flags":NO_LABEL, "tooltip":"Pick Wetness from the terrain." })

	add_setting({ "name":"enable_texture", "label":"Texture", "type":SettingType.CHECKBOX, 
							"list":main_list, "default":true, "flags":ADD_SEPARATOR })

	add_setting({ "name":"texture_picker", "type":SettingType.PICKER, "list":main_list, "default":Terrain3DEditor.TEXTURE,
							"flags":NO_LABEL, "tooltip":"Pick Texture from the terrain." })

	add_setting({ "name":"texture_filter", "label":"Texture Filter", "type":SettingType.CHECKBOX, 
							"list":main_list, "default":false, "flags":ADD_SEPARATOR })

	add_setting({ "name":"margin", "type":SettingType.SLIDER, "list":main_list, "default":0, 
							"unit":"", "range":Vector3(-50, 50, 1), "flags":ALLOW_OUT_OF_BOUNDS })

	# Slope painting filter
	add_setting({ "name":"slope", "type":SettingType.DOUBLE_SLIDER, "list":main_list, "default":Vector2(0, 90),
							"unit":"°", "range":Vector3(0, 90, 1), "flags":ADD_SEPARATOR })
	
	add_setting({ "name":"enable_angle", "label":"Angle", "type":SettingType.CHECKBOX, 
							"list":main_list, "default":true, "flags":ADD_SEPARATOR })
	add_setting({ "name":"angle", "type":SettingType.SLIDER, "list":main_list, "default":0,
							"unit":"%", "range":Vector3(0, 337.5, 22.5), "flags":NO_LABEL })
	add_setting({ "name":"angle_picker", "type":SettingType.PICKER, "list":main_list, "default":Terrain3DEditor.ANGLE,
							"flags":NO_LABEL, "tooltip":"Pick Angle from the terrain." })
	add_setting({ "name":"dynamic_angle", "label":"Dynamic", "type":SettingType.CHECKBOX, 
							"list":main_list, "default":false, "flags":ADD_SPACER })
	
	add_setting({ "name":"enable_scale", "label":"Scale", "type":SettingType.CHECKBOX, 
							"list":main_list, "default":true, "flags":ADD_SEPARATOR })
	add_setting({ "name":"scale", "label":"±", "type":SettingType.SLIDER, "list":main_list, "default":0,
							"unit":"%", "range":Vector3(-60, 80, 20), "flags":NO_LABEL })
	add_setting({ "name":"scale_picker", "type":SettingType.PICKER, "list":main_list, "default":Terrain3DEditor.SCALE,
							"flags":NO_LABEL, "tooltip":"Pick Scale from the terrain." })

	## Slope sculpting brush
	add_setting({ "name":"gradient_points", "type":SettingType.MULTI_PICKER, "label":"Points", 
							"list":main_list, "default":Terrain3DEditor.SCULPT, "flags":ADD_SEPARATOR })
	add_setting({ "name":"drawable", "type":SettingType.CHECKBOX, "list":main_list, "default":false, 
							"flags":ADD_SEPARATOR })
	settings["drawable"].toggled.connect(_on_drawable_toggled)
	
	## Instancer
	add_setting({ "name":"mesh_picker", "type":SettingType.PICKER, "list":main_list,
							"default":Terrain3DEditor.INSTANCER, "flags":NO_LABEL|ADD_SEPARATOR,
							"tooltip":"Pick a Mesh asset from the terrain, within an instancer cell. (See overlays.)" })

	height_list = create_submenu(main_list, "Height", Layout.VERTICAL)
	add_setting({ "name":"height_offset", "type":SettingType.SLIDER, "list":height_list, "default":0, 
							"unit":"m", "range":Vector3(-10, 10, 0.05), "flags":ALLOW_OUT_OF_BOUNDS })
	add_setting({ "name":"random_height", "label":"Random Height ±", "type":SettingType.SLIDER, "list":height_list,
							"default":0, "unit":"m", "range":Vector3(0, 10, 0.05), "flags":ALLOW_OUT_OF_BOUNDS })

	scale_list = create_submenu(main_list, "Scale", Layout.VERTICAL)
	add_setting({ "name":"fixed_scale", "type":SettingType.SLIDER, "list":scale_list, "default":100, 
							"unit":"%", "range":Vector3(1, 1000, 1), "flags":ALLOW_OUT_OF_BOUNDS })
	add_setting({ "name":"random_scale", "label":"Random Scale ±", "type":SettingType.SLIDER, "list":scale_list, 
							"default":20, "unit":"%", "range":Vector3(0, 99, 1), "flags":ALLOW_OUT_OF_BOUNDS })

	rotation_list = create_submenu(main_list, "Rotation", Layout.VERTICAL)
	add_setting({ "name":"fixed_spin", "label":"Fixed Spin (Around Y)", "type":SettingType.SLIDER, "list":rotation_list, 
							"default":0, "unit":"°", "range":Vector3(0, 360, 1) })
	add_setting({ "name":"random_spin", "type":SettingType.SLIDER, "list":rotation_list, "default":360, 
							"unit":"°", "range":Vector3(0, 360, 1) })
	add_setting({ "name":"fixed_tilt", "label":"Fixed Tilt", "type":SettingType.SLIDER, "list":rotation_list, 
							"default":0, "unit":"°", "range":Vector3(-85, 85, 1), "flags":ALLOW_OUT_OF_BOUNDS })
	add_setting({ "name":"random_tilt", "label":"Random Tilt ±", "type":SettingType.SLIDER, "list":rotation_list, 
							"default":10, "unit":"°", "range":Vector3(0, 85, 1), "flags":ALLOW_OUT_OF_BOUNDS })
	add_setting({ "name":"align_to_normal", "type":SettingType.CHECKBOX, "list":rotation_list, "default":false })
	
	color_list = create_submenu(main_list, "Color", Layout.VERTICAL)
	add_setting({ "name":"vertex_color", "type":SettingType.COLOR_SELECT, "list":color_list, 
							"default":Color.WHITE })
	add_setting({ "name":"random_hue", "label":"Random Hue Shift ±", "type":SettingType.SLIDER, 
							"list":color_list, "default":0, "unit":"°", "range":Vector3(0, 360, 1) })
	add_setting({ "name":"random_darken", "type":SettingType.SLIDER, "list":color_list, "default":50, 
							"unit":"%", "range":Vector3(0, 100, 1) })
	collision_list = create_submenu(main_list, "Collision", Layout.VERTICAL)
	add_setting({ "name":"on_collision", "label":"On Collision", "type":SettingType.CHECKBOX, "list":collision_list,
							"default":true })
	add_setting({ "name":"raycast_height", "label":"Raycast Height", "type":SettingType.SLIDER, 
							"list":collision_list, "default":10, "unit":"m", "range":Vector3(0, 200, .25) })

	if DisplayServer.is_touchscreen_available():
		add_setting({ "name":"invert", "label":"Invert", "type":SettingType.CHECKBOX, "list":main_list, "default":false, "flags":ADD_SEPARATOR })

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_list.add_child(spacer, true)

	## Advanced Settings Menu
	advanced_list = create_submenu(main_list, "", Layout.VERTICAL, false)
	add_setting({ "name":"auto_regions", "label":"Add regions while sculpting", "type":SettingType.CHECKBOX, 
							"list":advanced_list, "default":true })
	advanced_list.add_child(HSeparator.new(), true)
	add_setting({ "name":"show_brush_texture", "type":SettingType.CHECKBOX, "list":advanced_list, "default":true })
	add_setting({ "name":"align_to_view", "type":SettingType.CHECKBOX, "list":advanced_list, "default":true })
	add_setting({ "name":"brush_spin_speed", "type":SettingType.SLIDER, "list":advanced_list, "default":50, 
							"unit":"%", "range":Vector3(0, 100, 1) })
	add_setting({ "name":"gamma", "type":SettingType.SLIDER, "list":advanced_list, "default":1.0, 
							"unit":"γ", "range":Vector3(0.1, 2.0, 0.01) })

	advanced_list.add_child(HSeparator.new(), true)
	layer_section = VBoxContainer.new()
	layer_section.visible = false
	advanced_list.add_child(layer_section, true)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_section.add_child(header, true)

	layer_header_label = Label.new()
	layer_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_header_label.text = "Layers"
	header.add_child(layer_header_label, true)

	layer_locked_filter_button = CheckBox.new()
	layer_locked_filter_button.focus_mode = Control.FOCUS_NONE
	layer_locked_filter_button.text = "Show locked"
	layer_locked_filter_button.tooltip_text = "Toggle visibility of locked layers"
	layer_locked_filter_button.button_pressed = _show_locked_layers
	layer_locked_filter_button.toggled.connect(_on_locked_filter_toggled)
	header.add_child(layer_locked_filter_button, true)

	layer_refresh_button = Button.new()
	layer_refresh_button.icon = get_theme_icon("Reload", "EditorIcons")
	layer_refresh_button.tooltip_text = "Refresh the layer list using the current brush position"
	layer_refresh_button.pressed.connect(_on_refresh_layers)
	header.add_child(layer_refresh_button, true)

	layer_add_button = Button.new()
	layer_add_button.icon = get_theme_icon("Add", "EditorIcons")
	layer_add_button.tooltip_text = "Create a new layer at the current brush position"
	layer_add_button.focus_mode = Control.FOCUS_NONE
	layer_add_button.pressed.connect(_on_add_layer)
	header.add_child(layer_add_button, true)

	layers_list = VBoxContainer.new()
	layers_list.add_theme_constant_override("separation", 4)
	layer_section.add_child(layers_list, true)


func create_submenu(p_parent: Control, p_button_name: String, p_layout: Layout, p_hover_pop: bool = true) -> Container:
	var menu_button: Button = Button.new()
	if p_button_name.is_empty():
		menu_button.icon = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	else:
		menu_button.set_text(p_button_name)
	menu_button.set_toggle_mode(true)
	menu_button.set_v_size_flags(SIZE_SHRINK_CENTER)
	menu_button.toggled.connect(_on_show_submenu.bind(menu_button))
	
	var submenu: PopupPanel = PopupPanel.new()
	submenu.popup_hide.connect(menu_button.set_pressed.bind(false))
	var panel_style: StyleBox = get_theme_stylebox("panel", "PopupMenu").duplicate()
	panel_style.set_content_margin_all(10)
	submenu.set("theme_override_styles/panel", panel_style)
	submenu.add_to_group("terrain3d_submenus")

	# Pop up menu on hover, hide on exit
	if p_hover_pop:
		menu_button.mouse_entered.connect(_on_show_submenu.bind(true, menu_button))
		
	submenu.mouse_entered.connect(func(): submenu.set_meta("mouse_entered", true))
	
	submenu.mouse_exited.connect(func():
		# On mouse_exit, hide popup unless LineEdit focused
		var focused_element: Control = submenu.gui_get_focus_owner()
		if not focused_element is LineEdit:
			_on_show_submenu(false, menu_button)
			submenu.set_meta("mouse_entered", false)
			return
			
		focused_element.focus_exited.connect(func():
			# Close submenu once lineedit loses focus
			if not submenu.get_meta("mouse_entered"):
				_on_show_submenu(false, menu_button)
				submenu.set_meta("mouse_entered", false)
		)
	)
	
	var sublist: Container
	match(p_layout):
		Layout.GRID:
			sublist = GridContainer.new()
		Layout.VERTICAL:
			sublist = VBoxContainer.new()
		Layout.HORIZONTAL, _:
			sublist = HBoxContainer.new()
	
	p_parent.add_child(menu_button, true)
	menu_button.add_child(submenu, true)
	submenu.add_child(sublist, true)
	
	return sublist


func _on_show_submenu(p_toggled: bool, p_button: Button) -> void:
	# Don't show if mouse already down (from painting)
	if p_toggled and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	
	# Hide menu if mouse is not in button or panel 
	var button_rect: Rect2 = Rect2(p_button.get_screen_transform().origin, p_button.get_global_rect().size)
	var in_button: bool = button_rect.has_point(DisplayServer.mouse_get_position())
	var popup: PopupPanel = p_button.get_child(0)
	var popup_rect: Rect2 = Rect2(popup.position, popup.size)
	var in_popup: bool = popup_rect.has_point(DisplayServer.mouse_get_position())
	if not p_toggled and ( in_button or in_popup ):
		return
	
	# Hide all submenus before possibly enabling the current one
	get_tree().call_group("terrain3d_submenus", "set_visible", false)
	popup.set_visible(p_toggled)
	var popup_pos: Vector2 = p_button.get_screen_transform().origin
	popup_pos.y -= popup.size.y
	if popup.get_child_count()>0 and popup.get_child(0) == advanced_list:
		popup_pos.x -= popup.size.x - p_button.size.x
	popup.set_position(popup_pos)
	

func add_brushes(p_parent: Control) -> void:
	var brush_list: GridContainer = create_submenu(p_parent, "Brush", Layout.GRID)
	brush_list.name = "BrushList"

	var brush_button_group: ButtonGroup = ButtonGroup.new()
	brush_button_group.pressed.connect(_on_setting_changed)
	var default_brush_btn: Button
	
	var dir: DirAccess = DirAccess.open(BRUSH_PATH)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if !dir.current_is_dir() and file_name.ends_with(".exr"):
				var img: Image = Image.load_from_file(BRUSH_PATH + "/" + file_name)
				if img:
					var value_range: Vector2 = Terrain3DUtil.get_min_max(img)
					if value_range.y - value_range.x < 0.333:
						push_warning("'%s' has a low value range and may not be visible in the brush gallery or cursor" % file_name)
					var thumbimg: Image = img.duplicate()
					img.convert(Image.FORMAT_RF)

					if thumbimg.get_width() != 100 and thumbimg.get_height() != 100:
						thumbimg.resize(100, 100, Image.INTERPOLATE_CUBIC)
					thumbimg = Terrain3DUtil.black_to_alpha(thumbimg)
					thumbimg.convert(Image.FORMAT_LA8)
					var thumbtex: ImageTexture = ImageTexture.create_from_image(thumbimg)
					
					var brush_btn: Button = Button.new()
					brush_btn.set_custom_minimum_size(Vector2.ONE * 100)
					brush_btn.set_button_icon(thumbtex)
					brush_btn.set_meta("image", img)
					brush_btn.set_expand_icon(true)
					brush_btn.set_material(_get_brush_preview_material())
					brush_btn.set_toggle_mode(true)
					brush_btn.set_button_group(brush_button_group)
					brush_btn.mouse_entered.connect(_on_brush_hover.bind(true, brush_btn))
					brush_btn.mouse_exited.connect(_on_brush_hover.bind(false, brush_btn))
					brush_list.add_child(brush_btn, true)
					if file_name == DEFAULT_BRUSH:
						default_brush_btn = brush_btn 
					
					var lbl: Label = Label.new()
					brush_btn.name = file_name.get_basename().to_pascal_case()
					brush_btn.add_child(lbl, true)
					lbl.text = brush_btn.name
					lbl.visible = false
					lbl.position.y = 70
					lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
					lbl.add_theme_constant_override("shadow_offset_x", 1)
					lbl.add_theme_constant_override("shadow_offset_y", 1)
					lbl.add_theme_font_size_override("font_size", 16)
				
			file_name = dir.get_next()
	
	brush_list.columns = sqrt(brush_list.get_child_count()) + 2
	
	if not default_brush_btn:
		default_brush_btn = brush_button_group.get_buttons()[0]
	default_brush_btn.set_pressed(true)
	_generate_brush_texture(default_brush_btn)
	
	settings["brush"] = brush_button_group

	select_brush_button = brush_list.get_parent().get_parent()
	# Optionally erase the main brush button text and replace it with the texture
	select_brush_button.set_text("")
	select_brush_button.set_button_icon(default_brush_btn.get_button_icon())
	select_brush_button.set_custom_minimum_size(Vector2.ONE * 36)
	select_brush_button.set_icon_alignment(HORIZONTAL_ALIGNMENT_CENTER)
	select_brush_button.set_expand_icon(true)


func _on_brush_hover(p_hovering: bool, p_button: Button) -> void:
	if p_button.get_child_count() > 0:
		var child = p_button.get_child(0)
		if child is Label:
			if p_hovering:
				child.visible = true
			else:
				child.visible = false


func _on_pick(p_type: Terrain3DEditor.Tool) -> void:
	if plugin.debug:
		print("Terrain3DToolSettings: _on_pick: emitting picking: ", p_type, ", ", _on_picked)
	emit_signal("picking", p_type, _on_picked)


func _on_picked(p_type: Terrain3DEditor.Tool, p_color: Color, p_global_position: Vector3) -> void:
	match p_type:
		Terrain3DEditor.HEIGHT:
			settings["height"].value = p_color.r if not is_nan(p_color.r) else 0.
		Terrain3DEditor.COLOR:
			settings["color"].color = p_color if not is_nan(p_color.r) else Color.WHITE
		Terrain3DEditor.ROUGHNESS:
			# This converts 0,1 to -100,100
			# It also quantizes explicitly so picked values matches painted values
			settings["roughness"].value = round(200. * float(int(p_color.a * 255.) / 255. - .5)) if not is_nan(p_color.r) else 0.
		Terrain3DEditor.ANGLE:
			settings["angle"].value = p_color.r
		Terrain3DEditor.SCALE:
			settings["scale"].value = p_color.r
		Terrain3DEditor.INSTANCER:
			if p_color.r < 0:
				return
			plugin.asset_dock.set_selected_by_asset_id(p_color.r)
		Terrain3DEditor.TEXTURE:
			if p_color.r < 0:
				return
			plugin.asset_dock.set_selected_by_asset_id(p_color.r)
	_on_setting_changed()


func _on_point_pick(p_type: Terrain3DEditor.Tool, p_name: String) -> void:
	assert(p_type == Terrain3DEditor.SCULPT)
	if plugin.debug:
		print("Terrain3DToolSettings: _on_pick: emitting picking: ", p_type, ", ", _on_point_picked)
	emit_signal("picking", p_type, _on_point_picked.bind(p_name))


func _on_point_picked(p_type: Terrain3DEditor.Tool, p_color: Color, p_global_position: Vector3, p_name: String) -> void:
	assert(p_type == Terrain3DEditor.SCULPT)
	var point: Vector3 = p_global_position
	point.y = p_color.r
	settings[p_name].add_point(point)
	_on_setting_changed()


func add_setting(p_args: Dictionary) -> void:
	var p_name: StringName = p_args.get("name", "")
	var p_label: String = p_args.get("label", "") # Optional replacement for name
	var p_type: SettingType = p_args.get("type", SettingType.TYPE_MAX)
	var p_list: Control = p_args.get("list")
	var p_default: Variant = p_args.get("default")
	var p_suffix: String = p_args.get("unit", "")
	var p_range: Vector3 = p_args.get("range", Vector3(0, 0, 1))
	var p_minimum: float = p_range.x
	var p_maximum: float = p_range.y
	var p_step: float = p_range.z
	var p_flags: int = p_args.get("flags", NONE)
	var p_tooltip: String = p_args.get("tooltip", "")
	
	if p_name.is_empty() or p_type == SettingType.TYPE_MAX:
		return

	var container: HBoxContainer = HBoxContainer.new()
	container.custom_minimum_size.y = 36
	container.set_v_size_flags(SIZE_EXPAND_FILL)
	var control: Control	# Houses the setting to be saved
	var pending_children: Array[Control]
	
	match p_type:
		SettingType.LABEL:
			var label := Label.new()
			label.set_text(p_label)
			pending_children.push_back(label)
			control = label

		SettingType.CHECKBOX:
			var checkbox := CheckBox.new()
			if !(p_flags & NO_SAVE):
				checkbox.set_pressed_no_signal(plugin.get_setting(ES_TOOL_SETTINGS + p_name, p_default))
				checkbox.toggled.connect( (
					func(value, path):
						plugin.set_setting(path, value)
				).bind(ES_TOOL_SETTINGS + p_name) )
			else:
				checkbox.set_pressed_no_signal(p_default)				
			checkbox.pressed.connect(_on_setting_changed)
			pending_children.push_back(checkbox)
			control = checkbox
			
		SettingType.COLOR_SELECT:
			var picker := ColorPickerButton.new()
			picker.set_custom_minimum_size(Vector2(100, 25))
			picker.edit_alpha = false
			picker.get_picker().set_color_mode(ColorPicker.MODE_HSV)
			if !(p_flags & NO_SAVE):
				picker.set_pick_color(plugin.get_setting(ES_TOOL_SETTINGS + p_name, p_default))
				picker.color_changed.connect( (
					func(value, path):
						plugin.set_setting(path, value)
				).bind(ES_TOOL_SETTINGS + p_name) )
			else:
				picker.set_pick_color(p_default)
			picker.color_changed.connect(_on_setting_changed)
			pending_children.push_back(picker)
			control = picker

		SettingType.PICKER:
			var button := Button.new()
			button.set_v_size_flags(SIZE_SHRINK_CENTER)
			button.icon = get_theme_icon("ColorPick", "EditorIcons")
			button.pressed.connect(_on_pick.bind(p_default))
			pending_children.push_back(button)
			control = button

		SettingType.MULTI_PICKER:
			var multi_picker: HBoxContainer = MultiPicker.new()
			multi_picker.pressed.connect(_on_point_pick.bind(p_default, p_name))
			multi_picker.value_changed.connect(_on_setting_changed)
			pending_children.push_back(multi_picker)
			control = multi_picker

		SettingType.OPTION:
			var option := OptionButton.new()
			for i in int(p_maximum):
				option.add_item("a", i)
			option.selected = p_minimum
			option.item_selected.connect(_on_setting_changed)
			pending_children.push_back(option)
			control = option

		SettingType.SLIDER, SettingType.DOUBLE_SLIDER:
			var slider: Control
			if p_type == SettingType.SLIDER:
				# Create an editable value box
				var spin_slider := EditorSpinSlider.new()
				spin_slider.set_flat(false)
				spin_slider.set_hide_slider(true)
				spin_slider.value_changed.connect(_on_setting_changed)
				spin_slider.set_max(p_maximum)
				spin_slider.set_min(p_minimum)
				spin_slider.set_step(p_step)
				spin_slider.set_suffix(p_suffix)
				spin_slider.set_v_size_flags(SIZE_SHRINK_CENTER)
				spin_slider.set_custom_minimum_size(Vector2(65, 0))

				# Create horizontal slider linked to the above box
				slider = HSlider.new()
				slider.share(spin_slider)
				if p_flags & ALLOW_LARGER:
					slider.set_allow_greater(true)
				if p_flags & ALLOW_SMALLER:
					slider.set_allow_lesser(true)
				
				pending_children.push_back(slider)
				pending_children.push_back(spin_slider)
				control = spin_slider
						
			else: # DOUBLE_SLIDER
				var label := Label.new()
				label.set_custom_minimum_size(Vector2(60, 0))
				label.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
				slider = DoubleSlider.new()
				slider.label = label
				slider.suffix = p_suffix
				slider.value_changed.connect(_on_setting_changed)
				pending_children.push_back(slider)
				pending_children.push_back(label)
				control = slider
			
			slider.set_min(p_minimum)
			slider.set_max(p_maximum)
			slider.set_step(p_step)
			slider.set_value(p_default)
			slider.set_v_size_flags(SIZE_SHRINK_CENTER)
			slider.set_custom_minimum_size(Vector2(50, 10))

			if !(p_flags & NO_SAVE):
				slider.set_value(plugin.get_setting(ES_TOOL_SETTINGS + p_name, p_default))
				slider.value_changed.connect( (
					func(value, path):
						plugin.set_setting(path, value)
				).bind(ES_TOOL_SETTINGS + p_name) )
			else:
				slider.set_value(p_default)

	control.name = p_name.to_pascal_case()
	if not p_tooltip.is_empty():
		control.tooltip_text = p_tooltip
	settings[p_name] = control

	# Setup button labels
	if not (p_flags & NO_LABEL):
		# Labels are actually buttons styled to look like labels
		var label := Button.new()
		label.set("theme_override_styles/normal", get_theme_stylebox("normal", "Label"))
		label.set("theme_override_styles/hover", get_theme_stylebox("normal", "Label"))
		label.set("theme_override_styles/pressed", get_theme_stylebox("normal", "Label"))
		label.set("theme_override_styles/focus", get_theme_stylebox("normal", "Label"))
		label.pressed.connect(_on_label_pressed.bind(p_name, p_default))
		if p_label.is_empty():
			label.set_text(p_name.capitalize() + ": ")
		else:
			label.set_text(p_label.capitalize() + ": ")
		pending_children.push_front(label)

	# Add separators to front
	if p_flags & ADD_SEPARATOR:
		pending_children.push_front(VSeparator.new())
	if p_flags & ADD_SPACER:
		var spacer := Control.new()
		spacer.set_custom_minimum_size(Vector2(5, 0))
		pending_children.push_front(spacer)

	# Add all children to container and list
	for child in pending_children:
		container.add_child(child, true)
	p_list.add_child(container, true)


# If label button is pressed, reset value to default or toggle checkbox
func _on_label_pressed(p_name: String, p_default: Variant) -> void:
	var control: Control = settings.get(p_name)
	if not control:
		return
	if control is CheckBox:
		set_setting(p_name, !control.button_pressed)
	elif p_default != null:
		set_setting(p_name, p_default)


func get_settings() -> Dictionary:
	var dict: Dictionary
	for key in settings.keys():
		dict[key] = get_setting(key)
	return dict


func get_setting(p_setting: String) -> Variant:
	var object: Object = settings.get(p_setting)
	var value: Variant
	if object is Range:
		value = object.get_value()
		# Adjust widths of all sliders on update of values
		var width: float = clamp( (1 + _count_digits(value)) * 19., 50, 80) * clamp(EditorInterface.get_editor_scale(), .9, 2)
		object.set_custom_minimum_size(Vector2(width, 0))
	elif object is DoubleSlider:
		value = object.get_value()
	elif object is ButtonGroup: # "brush"
		value = selected_brush_imgs
	elif object is CheckBox:
		value = object.is_pressed()
	elif object is ColorPickerButton:
		value = object.color
	elif object is MultiPicker:
		value = object.get_points()
	if value == null:
		value = 0
	return value

func update_layer_stack(region_loc: Vector2i, map_type: int, layer_entries: Array) -> void:
	if not layer_section or not layers_list or not layer_header_label or not layer_add_button:
		return
	var previous_map_type := current_layer_map_type
	current_layer_region = region_loc
	current_layer_map_type = map_type
	if previous_map_type != map_type:
		_selected_layer_groups.clear()
	_layer_entries = layer_entries.duplicate(true)
	_layer_row_panels.clear()
	for child in layers_list.get_children():
		child.queue_free()
	if map_type == Terrain3DRegion.TYPE_MAX:
		layer_section.visible = false
		layer_header_label.text = "Layers"
		layer_add_button.disabled = true
		_selected_layer_groups.clear()
		return
	layer_section.visible = true
	layer_selection_group = ButtonGroup.new()
	if layer_locked_filter_button:
		layer_locked_filter_button.button_pressed = _show_locked_layers
	var active_index: int = 0
	if plugin and plugin.editor and plugin.editor.has_method("get_active_layer_index"):
		active_index = plugin.editor.get_active_layer_index()
	if active_index > 0:
		var preview_entry_index := active_index - 1
		if preview_entry_index >= 0 and preview_entry_index < _layer_entries.size():
			var preview_entry: Dictionary = _layer_entries[preview_entry_index]
			if not bool(preview_entry.get("user_editable", true)):
				active_index = 0
				if plugin and plugin.editor and plugin.editor.has_method("set_active_layer_index"):
					plugin.editor.set_active_layer_index(0)
	var group_count := _layer_entries.size()
	var region_count := _count_unique_regions()
	var slice_count := _count_total_slices()
	var locked_group_count := 0
	for entry in _layer_entries:
		if not bool(entry.get("user_editable", true)):
			locked_group_count += 1
	var label_prefix: String = MAP_TYPE_LABELS.get(map_type, "Map")
	var group_suffix := "" if group_count == 1 else "s"
	var region_suffix := "" if region_count == 1 else "s"
	var slice_suffix := "" if slice_count == 1 else "s"
	var header_text := "%s Layers (%d group%s, %d region%s, %d slice%s)" % [label_prefix, group_count, group_suffix, region_count, region_suffix, slice_count, slice_suffix]
	if locked_group_count > 0 and not _show_locked_layers:
		header_text += " • %d locked hidden" % locked_group_count
	layer_header_label.text = header_text
	_add_base_layer_entry(active_index)
	var visible_entry_count := 0
	for entry_id in range(_layer_entries.size()):
		var entry: Dictionary = _layer_entries[entry_id]
		var layer: Terrain3DLayer = entry.get("layer")
		if layer == null:
			continue
		var ui_index := entry_id + 1
		entry["ui_index"] = ui_index
		var group_id := int(entry.get("group_id", 0))
		var locked := not bool(entry.get("user_editable", true))
		if locked and not _show_locked_layers:
			_selected_layer_groups.erase(group_id)
			continue
		visible_entry_count += 1
		var row_panel := PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.add_child(row, true)
		layers_list.add_child(row_panel, true)
		_layer_row_panels[entry_id] = row_panel
		var selection_toggle := CheckBox.new()
		selection_toggle.focus_mode = Control.FOCUS_NONE
		selection_toggle.tooltip_text = "Select this layer for batch actions"
		selection_toggle.button_pressed = _is_group_selected(group_id)
		selection_toggle.toggled.connect(_on_layer_row_selection_toggled.bind(entry_id))
		row.add_child(selection_toggle)
		var label_text := _describe_layer(entry)
		var tooltip := _describe_layer_regions(entry)
		var can_select := bool(entry.get("user_editable", true))
		var select_button := _create_layer_select_button(ui_index, label_text, active_index, entry_id, tooltip, can_select)
		row.add_child(select_button)
		var toggle := CheckBox.new()
		toggle.focus_mode = Control.FOCUS_NONE
		toggle.button_pressed = layer.is_enabled()
		toggle.tooltip_text = "Enable or disable this layer"
		toggle.toggled.connect(_on_layer_toggle.bind(entry_id))
		row.add_child(toggle)
		var remove_button := Button.new()
		remove_button.focus_mode = Control.FOCUS_NONE
		remove_button.icon = get_theme_icon("Remove", "EditorIcons")
		remove_button.tooltip_text = "Remove this layer"
		remove_button.pressed.connect(_on_layer_remove.bind(entry_id))
		row.add_child(remove_button)
		_apply_row_selection_style(entry_id)
	if visible_entry_count == 0:
		var empty_label := Label.new()
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		if group_count == 0:
			empty_label.text = "No additional layers yet"
		elif not _show_locked_layers and locked_group_count > 0:
			empty_label.text = "All additional layers are locked (enable \"Show locked\" to view them)"
		else:
			empty_label.text = "No visible layers"
		empty_label.modulate = Color(0.75, 0.75, 0.75)
		layers_list.add_child(empty_label, true)
	_update_layer_action_state()
	_sync_active_layer_row()

func clear_layer_stack() -> void:
	_layer_entries.clear()
	_selected_layer_groups.clear()
	_layer_row_panels.clear()
	update_layer_stack(Vector2i.ZERO, Terrain3DRegion.TYPE_MAX, [])

func _describe_layer(entry: Dictionary) -> String:
	var parts: Array[String] = []
	var layer: Terrain3DLayer = entry.get("layer")
	var ui_index := int(entry.get("ui_index", -1))
	if ui_index >= 0:
		parts.append("#%d" % (ui_index))
	if layer:
		parts.append(layer.get_class().replace("Terrain3D", ""))
		var blend := layer.get_blend_mode()
		if blend >= 0 and blend < LAYER_BLEND_LABELS.size():
			parts.append(LAYER_BLEND_LABELS[blend])
		var intensity := layer.get_intensity()
		if not is_equal_approx(intensity, 1.0):
			parts.append("x%.2f" % intensity)
		var coverage: Rect2i = layer.get_coverage()
		if coverage.size.x > 0 and coverage.size.y > 0:
			parts.append("%dx%d @ %d,%d" % [coverage.size.x, coverage.size.y, coverage.position.x, coverage.position.y])
	if not bool(entry.get("user_editable", true)):
		parts.append("locked")
	var slice_count := _slice_count(entry)
	var slice_suffix := "" if slice_count == 1 else "s"
	parts.append("%d slice%s" % [slice_count, slice_suffix])
	var region_count := int(entry.get("region_count", slice_count))
	var region_suffix := "" if region_count == 1 else "s"
	parts.append("%d region%s" % [region_count, region_suffix])
	var region_loc: Vector2i = entry.get("region_location", Vector2i.ZERO)
	parts.append("primary @%d,%d" % [region_loc.x, region_loc.y])
	return " • ".join(parts)

func _describe_layer_regions(entry: Dictionary) -> String:
	var slices: Array = entry.get("layers", [])
	if slices.is_empty():
		return "No regions"
	var labels: PackedStringArray = []
	for slice in slices:
		var loc: Vector2i = slice.get("region_location", Vector2i.ZERO)
		labels.append("%d,%d" % [loc.x, loc.y])
	return "Regions: %s" % ", ".join(labels)

func _slice_count(entry: Dictionary) -> int:
	var slices: Array = entry.get("layers", [])
	return slices.size()

func _describe_base_layer(map_type: int) -> String:
	match map_type:
		Terrain3DRegion.TYPE_HEIGHT:
			return "Base Heightmap"
		Terrain3DRegion.TYPE_CONTROL:
			return "Base Control Map"
		Terrain3DRegion.TYPE_COLOR:
			return "Base Color Map"
		_:
			return "Base Layer"

func _create_layer_select_button(index: int, label: String, active_index: int, entry_id: int = -1, tooltip: String = "", can_select: bool = true) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.button_group = layer_selection_group
	button.text = label
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var base_tooltip := tooltip if not tooltip.is_empty() else "Make this the active layer for painting"
	if can_select:
		button.tooltip_text = base_tooltip
	else:
		var lock_tooltip := "Layer is locked and cannot be the active paint target"
		button.tooltip_text = "%s\n%s" % [base_tooltip, lock_tooltip] if not base_tooltip.is_empty() else lock_tooltip
		button.disabled = true
	if index == active_index:
		button.set_pressed_no_signal(true)
	button.toggled.connect(_on_layer_selected.bind(index, entry_id))
	return button

func _add_base_layer_entry(active_index: int) -> void:
	var base_row := HBoxContainer.new()
	base_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var select := _create_layer_select_button(0, _describe_base_layer(current_layer_map_type), active_index)
	base_row.add_child(select)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	base_row.add_child(spacer)
	layers_list.add_child(base_row, true)

func _get_layer_entry(entry_id: int) -> Dictionary:
	if entry_id < 0 or entry_id >= _layer_entries.size():
		return {}
	return _layer_entries[entry_id]

func _count_unique_regions() -> int:
	var unique := {}
	for entry in _layer_entries:
		var slices: Array = entry.get("layers", [])
		for slice in slices:
			var region_loc: Vector2i = slice.get("region_location", Vector2i.ZERO)
			unique[str(region_loc)] = true
	return unique.size()

func _count_total_slices() -> int:
	var total := 0
	for entry in _layer_entries:
		total += _slice_count(entry)
	return total

func _region_exists(region_loc: Vector2i) -> bool:
	if not plugin or not plugin.terrain:
		return false
	var data: Terrain3DData = plugin.terrain.data
	if data == null:
		return false
	return data.has_region(region_loc)

func _update_layer_action_state() -> void:
	if not layer_add_button:
		return
	layer_add_button.disabled = not _region_exists(current_layer_region)

func _sync_active_layer_row() -> void:
	if not plugin or not plugin.editor:
		return
	if not plugin.editor.has_method("get_active_layer_group_id"):
		return
	var group_id: int = plugin.editor.get_active_layer_group_id()
	if group_id == 0:
		return
	for entry_id in range(_layer_entries.size()):
		var entry: Dictionary = _layer_entries[entry_id]
		if int(entry.get("group_id", 0)) == group_id and bool(entry.get("user_editable", true)):
			if plugin.editor.has_method("set_active_layer_index"):
				plugin.editor.set_active_layer_index(entry_id + 1)
			return

func _on_layer_selected(pressed: bool, ui_index: int, entry_id: int = -1) -> void:
	if not pressed:
		return
	if entry_id >= 0:
		var entry := _get_layer_entry(entry_id)
		if not entry.is_empty():
			if not bool(entry.get("user_editable", true)):
				return
			current_layer_region = entry.get("region_location", current_layer_region)
			_update_layer_action_state()
	if not plugin or not plugin.editor:
		return
	if not plugin.editor.has_method("set_active_layer_index"):
		return
	plugin.editor.set_active_layer_index(ui_index)
	if entry_id >= 0 and plugin.editor.has_method("set_active_layer_reference"):
		var entry := _get_layer_entry(entry_id)
		if not entry.is_empty():
			plugin.editor.set_active_layer_reference(entry.get("layer"), current_layer_map_type)
	# Ensure the editor picks up the change for pending stamp data
	_on_refresh_layers()

func _has_layer_context() -> bool:
	return plugin and plugin.terrain and plugin.terrain.data

func _on_layer_toggle(pressed: bool, entry_id: int) -> void:
	if not _has_layer_context() or current_layer_map_type == Terrain3DRegion.TYPE_MAX:
		return
	var target_ids := _get_batch_entry_ids(entry_id)
	var any_changed := false
	for target_id in target_ids:
		var entry := _get_layer_entry(target_id)
		if entry.is_empty():
			continue
		if _toggle_entry_layers(entry, pressed):
			any_changed = true
	if any_changed:
		_on_refresh_layers()

func _on_layer_remove(entry_id: int) -> void:
	if not _has_layer_context() or current_layer_map_type == Terrain3DRegion.TYPE_MAX:
		return
	var target_ids := _get_batch_entry_ids(entry_id)
	var removed_groups: Array[int] = []
	var any_removed := false
	for target_id in target_ids:
		var entry := _get_layer_entry(target_id)
		if entry.is_empty():
			continue
		removed_groups.append(int(entry.get("group_id", 0)))
		if _remove_entry_layers(entry):
			any_removed = true
	for group_id in removed_groups:
		_selected_layer_groups.erase(group_id)
	if any_removed:
		if plugin and plugin.editor and plugin.editor.has_method("set_active_layer_index"):
			plugin.editor.set_active_layer_index(0)
		if plugin and plugin.editor and plugin.editor.has_method("set_active_layer_reference"):
			plugin.editor.set_active_layer_reference(null, Terrain3DRegion.TYPE_MAX)
		_on_refresh_layers()


func _on_refresh_layers() -> void:
	if plugin and plugin.ui and plugin.ui.has_method("update_layer_panel"):
		plugin.ui.update_layer_panel()
	else:
		clear_layer_stack()
	
func _on_locked_filter_toggled(pressed: bool) -> void:
	_show_locked_layers = pressed
	if not _show_locked_layers:
		_clear_hidden_locked_selection()
	_on_refresh_layers()

func _on_layer_row_selection_toggled(pressed: bool, entry_id: int) -> void:
	var entry := _get_layer_entry(entry_id)
	if entry.is_empty():
		return
	var group_id := int(entry.get("group_id", 0))
	if group_id == 0:
		return
	_set_group_selected(group_id, pressed)
	_apply_row_selection_style(entry_id)

func _is_group_selected(group_id: int) -> bool:
	if group_id == 0:
		return false
	return _selected_layer_groups.has(group_id)

func _set_group_selected(group_id: int, selected: bool) -> void:
	if group_id == 0:
		return
	if selected:
		_selected_layer_groups[group_id] = true
	else:
		_selected_layer_groups.erase(group_id)

func _get_selected_entry_ids() -> Array:
	var ids: Array = []
	if _selected_layer_groups.is_empty():
		return ids
	for entry_id in range(_layer_entries.size()):
		var entry: Dictionary = _layer_entries[entry_id]
		if _is_group_selected(int(entry.get("group_id", 0))):
			ids.append(entry_id)
	return ids

func _get_batch_entry_ids(primary_entry_id: int) -> Array:
	var selected_ids := _get_selected_entry_ids()
	if selected_ids.is_empty():
		return [primary_entry_id]
	if selected_ids.has(primary_entry_id):
		return selected_ids
	return [primary_entry_id]

func _apply_row_selection_style(entry_id: int) -> void:
	if not _layer_row_panels.has(entry_id):
		return
	var panel: PanelContainer = _layer_row_panels[entry_id]
	if panel == null:
		return
	var entry := _get_layer_entry(entry_id)
	if entry.is_empty():
		panel.remove_theme_stylebox_override("panel")
		return
	var group_id := int(entry.get("group_id", 0))
	if _is_group_selected(group_id):
		panel.add_theme_stylebox_override("panel", _get_selected_row_style())
	else:
		panel.remove_theme_stylebox_override("panel")

func _get_selected_row_style() -> StyleBoxFlat:
	if _selected_row_style == null:
		_selected_row_style = StyleBoxFlat.new()
		_selected_row_style.bg_color = Color(0.35, 0.6, 1.0, 0.15)
		_selected_row_style.border_color = Color(0.35, 0.6, 1.0, 0.6)
		_selected_row_style.set_border_width_all(1)
		_selected_row_style.set_corner_radius_all(3)
	return _selected_row_style

func _toggle_entry_layers(entry: Dictionary, pressed: bool) -> bool:
	var slices: Array = entry.get("layers", [])
	if slices.is_empty():
		return false
	var changed := false
	for i in range(slices.size()):
		var slice: Dictionary = slices[i]
		var region_loc: Vector2i = slice.get("region_location", current_layer_region)
		var layer_index := int(slice.get("layer_index", -1))
		if layer_index < 0:
			continue
		var update := (i == slices.size() - 1)
		plugin.terrain.data.set_layer_enabled(region_loc, current_layer_map_type, layer_index, pressed, update)
		changed = true
	return changed

func _remove_entry_layers(entry: Dictionary) -> bool:
	var slices: Array = entry.get("layers", [])
	if slices.is_empty():
		return false
	var removed := false
	for i in range(slices.size()):
		var slice: Dictionary = slices[i]
		var region_loc: Vector2i = slice.get("region_location", current_layer_region)
		var layer_index := int(slice.get("layer_index", -1))
		if layer_index < 0:
			continue
		var update := (i == slices.size() - 1)
		plugin.terrain.data.remove_layer(region_loc, current_layer_map_type, layer_index, update)
		removed = true
	return removed

func _clear_hidden_locked_selection() -> void:
	if _selected_layer_groups.is_empty():
		return
	for entry in _layer_entries:
		if not bool(entry.get("user_editable", true)):
			var group_id := int(entry.get("group_id", 0))
			_selected_layer_groups.erase(group_id)

func _on_add_layer() -> void:
	if not _has_layer_context() or current_layer_map_type == Terrain3DRegion.TYPE_MAX:
		return
	if not _region_exists(current_layer_region):
		return
	if not plugin or not plugin.editor:
		return
	if not plugin.editor.has_method("create_layer"):
		return
	var new_index: int = plugin.editor.create_layer(current_layer_region, current_layer_map_type, true)
	if new_index >= 0:
		plugin.editor.set_active_layer_index(new_index)
	_on_refresh_layers()

func set_setting(p_setting: String, p_value: Variant) -> void:
	var object: Object = settings.get(p_setting)
	if object is DoubleSlider: # Expects p_value is Vector2
		object.set_value(p_value)
	elif object is Range:
		object.set_value(p_value)
	elif object is ButtonGroup: # Expects p_value is Array [ "button name", boolean ]
		if p_value is Array and p_value.size() == 2:
			for button in object.get_buttons():
				if button.name == p_value[0]:
					button.button_pressed = p_value[1]
	elif object is CheckBox:
		object.button_pressed = p_value
	elif object is ColorPickerButton:
		object.color = p_value
		plugin.set_setting(ES_TOOL_SETTINGS + p_setting, p_value) # Signal doesn't fire on CPB
	elif object is MultiPicker: # Expects p_value is PackedVector3Array
		object.points = p_value
	_on_setting_changed(object)


func show_settings(p_settings: PackedStringArray) -> void:
	for setting in settings.keys():
		var object: Object = settings[setting]
		if object is Control:
			if setting in p_settings:
				object.get_parent().show()
			else:
				object.get_parent().hide()
	if select_brush_button:
		if not "brush" in p_settings:
			select_brush_button.hide()
		else:
			select_brush_button.show()


func _on_setting_changed(p_setting: Variant = null) -> void:
	# If a brush was selected
	if p_setting is Button and p_setting.get_parent().name == "BrushList":
		_generate_brush_texture(p_setting)
		# Optionally Set selected brush texture in main brush button
		if select_brush_button:
			select_brush_button.set_button_icon(p_setting.get_button_icon())
		# Hide popup
		p_setting.get_parent().get_parent().set_visible(false)
		# Hide label
		if p_setting.get_child_count() > 0:
			p_setting.get_child(0).visible = false
	if plugin.debug:
		print("Terrain3DToolSettings: _on_setting_changed: emitting setting_changed: ", p_setting)			
	emit_signal("setting_changed", p_setting)


func _generate_brush_texture(p_btn: Button) -> void:
	if p_btn is Button:
		var img: Image = p_btn.get_meta("image")
		if img.get_width() < 1024 and img.get_height() < 1024:
			img = img.duplicate()
			img.resize(1024, 1024, Image.INTERPOLATE_CUBIC)
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		selected_brush_imgs = [ img, tex ]


func _on_drawable_toggled(p_button_pressed: bool) -> void:
	if not p_button_pressed:
		settings["gradient_points"].clear()


func _get_brush_preview_material() -> ShaderMaterial:
	if !brush_preview_material:
		brush_preview_material = ShaderMaterial.new()
		var shader: Shader = Shader.new()
		var code: String = "shader_type canvas_item;\n"
		code += "varying vec4 v_vertex_color;\n"
		code += "void vertex() {\n"
		code += "	v_vertex_color = COLOR;\n"
		code += "}\n"
		code += "void fragment(){\n"
		code += "	vec4 tex = texture(TEXTURE, UV);\n"
		code += "	COLOR.a *= pow(tex.r, 0.666);\n"
		code += "	COLOR.rgb = v_vertex_color.rgb;\n"
		code += "}\n"
		shader.set_code(code)
		brush_preview_material.set_shader(shader)
	return brush_preview_material


# Counts digits of a number including negative sign, decimal points, and up to 3 decimals 
func _count_digits(p_value: float) -> int:
	var count: int = 1
	for i in range(5, 0, -1):
		if abs(p_value) >= pow(10, i):
			count = i+1
			break
	if p_value - floor(p_value) >= .1:
		count += 1 # For the decimal
		if p_value*10 - floor(p_value*10.) >= .1: 
			count += 1
			if p_value*100 - floor(p_value*100.) >= .1: 
				count += 1
				if p_value*1000 - floor(p_value*1000.) >= .1: 
					count += 1
	# Negative sign
	if p_value < 0:
		count += 1
	return count


func inverse_slope_range() -> void:
	var slope_range: Vector2 = get_setting("slope")
	if slope_range.y - slope_range.x > 89.99:
		return
	if slope_range.x == 0.0:
		slope_range = Vector2(slope_range.y, 90.0)
	elif slope_range.y == 90.0:
		slope_range = Vector2(0.0, slope_range.x)
	else:
		# If midpoint <= 45, inverse to 90, else to 0
		var midpoint: float = 0.5 * (slope_range.x + slope_range.y)
		if midpoint <= 45.0:
			slope_range = Vector2(slope_range.y, 90.0)
		else:
			slope_range = Vector2(0.0, slope_range.x)
	set_setting("slope", slope_range)
