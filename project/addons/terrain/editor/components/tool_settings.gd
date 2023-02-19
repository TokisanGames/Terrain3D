extends PanelContainer

signal setting_changed

enum SettingType {
	CHECKBOX,
	SLIDER,
	DOUBLE_SLIDER,
}
	
const BRUSH_PATH: String = "res://addons/terrain/editor/brush"

var brush_preview_material: ShaderMaterial

var list: HBoxContainer
var advanced_list: VBoxContainer
var settings: Dictionary = {}

func _ready() -> void:
	list = HBoxContainer.new()
	add_child(list)
	
	add_setting(SettingType.SLIDER, "size", 50, list, "m", 0, 200)
	add_setting(SettingType.SLIDER, "opacity", 100, list, "%", 0, 100)
	add_setting(SettingType.SLIDER, "height", 10, list, "m", 1, 1000, 0.1)
	add_setting(SettingType.DOUBLE_SLIDER, "slope", 0, list, "°", 0, 180, 1)
	
	var advanced_button: Button = Button.new()
	list.add_child(advanced_button)
	
	var advanced_menu: PopupPanel = PopupPanel.new()
	advanced_list = VBoxContainer.new()
	
	advanced_menu.connect("popup_hide", advanced_button.set_pressed_no_signal.bind(false))
	advanced_button.set_text("Advanced")
	advanced_button.set_toggle_mode(true)
	advanced_button.set_v_size_flags(SIZE_SHRINK_CENTER)
	advanced_button.connect("toggled", _on_show_advanced.bind(advanced_button))
	advanced_menu.set("theme_override_styles/panel", get_theme_stylebox("panel", "PopupMenu"))
	advanced_menu.set_size(Vector2i(100, 10))
	
	advanced_button.add_child(advanced_menu)
	advanced_menu.add_child(advanced_list)
	
	add_setting(SettingType.CHECKBOX, "automatic_regions", true, advanced_list)
	add_setting(SettingType.CHECKBOX, "align_with_view", true, advanced_list)
	
	advanced_list.add_child(HSeparator.new())
	
	add_setting(SettingType.SLIDER, "gamma", 1.0, advanced_list, "γ", 0.1, 2.0, 0.01)
	add_setting(SettingType.SLIDER, "jitter", 50, advanced_list, "%", 0, 100)
	
	add_brushes("shape")
	
func add_brushes(p_name: String) -> void:
	var hbox: HBoxContainer = HBoxContainer.new()
	var label: Label = Label.new()
	
	label.set_text(p_name.capitalize() + ": ")
	label.set_vertical_alignment(VERTICAL_ALIGNMENT_CENTER)
	label.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
	label.set_custom_minimum_size(Vector2(32, 0))
	label.set_v_size_flags(SIZE_SHRINK_CENTER)
	hbox.add_child(label)
	
	var brush_button_group: ButtonGroup = ButtonGroup.new()
	brush_button_group.connect("pressed", _on_setting_changed)
	
	var dir: DirAccess = DirAccess.open(BRUSH_PATH)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if !dir.current_is_dir() and file_name.ends_with(".exr"):
				var img: Image = Image.load_from_file(BRUSH_PATH + "/" + file_name)
				var tex: ImageTexture = ImageTexture.create_from_image(img)
				var btn: Button = Button.new()

				btn.set_custom_minimum_size(Vector2.ONE * 36)
				btn.set_button_icon(tex)
				btn.set_expand_icon(true)
				btn.set_material(_get_brush_preview_material())
				btn.set_toggle_mode(true)
				btn.set_button_group(brush_button_group)
				hbox.add_child(btn)
				
			file_name = dir.get_next()
	
	brush_button_group.get_buttons()[0].set_pressed(true)
	list.add_child(hbox)
	settings[p_name] = brush_button_group
	
func add_setting(p_type: SettingType, p_name: StringName, value: Variant, parent: Control, 
		p_suffix: String = "", min_value: float = 0.0, max_value: float = 0.0, step: float = 1.0) -> void:
			
	var container: HBoxContainer = HBoxContainer.new()
	var label: Label = Label.new()
	var control: Control
	
	container.set_v_size_flags(SIZE_EXPAND_FILL)
	
	match p_type:
		SettingType.SLIDER, SettingType.DOUBLE_SLIDER:
			label.set_vertical_alignment(VERTICAL_ALIGNMENT_CENTER)
			label.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
			label.set_custom_minimum_size(Vector2(32, 0))
			label.set_v_size_flags(SIZE_SHRINK_CENTER)
			label.set_text(p_name.capitalize() + ": ")
			container.add_child(label)
			
			var slider: Control
			if p_type == SettingType.SLIDER:
				control = EditorSpinSlider.new()
				control.set_flat(true)
				control.set_hide_slider(true)
				control.connect("value_changed", _on_setting_changed)
				control.set_max(max_value)
				control.set_min(min_value)
				control.set_step(step)
				control.set_value(value)
				control.set_suffix(p_suffix)
				control.set_v_size_flags(SIZE_SHRINK_CENTER)
			
				slider = HSlider.new()
				slider.share(control)
			else:
				control = Label.new()
				control.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
				control.set_vertical_alignment(VERTICAL_ALIGNMENT_CENTER)
				slider = DoubleSlider.new()
				slider.label = control
				slider.suffix = p_suffix
				slider.connect("value_changed", _on_setting_changed)
			
			control.set_custom_minimum_size(Vector2(70, 0))
			slider.set_max(max_value)
			slider.set_min(min_value)
			slider.set_step(step)
			slider.set_value(value)
			slider.set_v_size_flags(SIZE_SHRINK_CENTER)
			slider.set_h_size_flags(SIZE_SHRINK_END | SIZE_EXPAND)
			slider.set_custom_minimum_size(Vector2(110, 10))
			
			container.add_child(slider)
				
		SettingType.CHECKBOX:
			control = CheckBox.new()
			control.set_text(p_name.capitalize())
			control.set_pressed_no_signal(value)
			control.connect("pressed", _on_setting_changed)
	
	container.add_child(control)
	parent.add_child(container)
	
	settings[p_name] = control
	
func get_setting(p_setting: String) -> Variant:
	var object: Object = settings[p_setting]
	var value: Variant
	
	if object is Range:
		value = object.get_value()
	if object is DoubleSlider:
		value = [object.get_min_value(), object.get_max_value()]
	if object is ButtonGroup:
		value = object.get_pressed_button().get_button_icon().get_image()
	if object is CheckBox:
		value = object.is_pressed()
		
	return value
	
func hide_settings(p_settings: PackedStringArray):
	for setting in settings.keys():
		var object: Object = settings[setting]
		if object is Control:
			object.get_parent().show()
	
	for setting in p_settings:
		if settings.has(setting):
			var object: Object = settings[setting]
			if object is Control:
				object.get_parent().hide()
	
func _on_setting_changed(p_data: Variant = null) -> void:
	emit_signal("setting_changed")
	
func _on_show_advanced(toggled: bool, button: Button):
	var popup: PopupPanel = button.get_child(0)
	var popup_pos: Vector2 = button.get_screen_transform().origin
	popup.set_visible(toggled)
	popup_pos.y -= popup.get_size().y
	popup.set_position(popup_pos)

func _get_brush_preview_material() -> ShaderMaterial:
	if !brush_preview_material:
		brush_preview_material = ShaderMaterial.new()
		
		var shader: Shader = Shader.new()
		var code: String = "shader_type canvas_item;\n"
		
		code += "varying vec4 v_vertex_color;\n"
		code +="void vertex() {\n"
		code +="	v_vertex_color = COLOR;\n"
		code +="}\n"
		code +="void fragment(){\n"
		code +="	vec4 tex = texture(TEXTURE, UV);\n"
		code +="	COLOR.a *= pow(tex.r, 0.666);\n"
		code +="	COLOR.rgb = v_vertex_color.rgb;\n"
		code +="}\n"
		
		shader.set_code(code)
		
		brush_preview_material.set_shader(shader)
		
	return brush_preview_material

class DoubleSlider extends Range:
	
	var label: Label
	var suffix: String
	var grabbed: bool = false
	var _max_value: float
	
	func _gui_input(p_event: InputEvent):
		if p_event is InputEventMouseButton:
			if p_event.get_button_index() == MOUSE_BUTTON_LEFT:
				grabbed = p_event.is_pressed()
				set_min_max(p_event.get_position().x)
				
		if p_event is InputEventMouseMotion:
			if grabbed:
				set_min_max(p_event.get_position().x)
		
	func _notification(p_what: int) -> void:
		if p_what == NOTIFICATION_RESIZED:
			pass
		if p_what == NOTIFICATION_DRAW:
			var bg: StyleBox = get_theme_stylebox("slider", "HSlider")
			var bg_height: float = bg.get_minimum_size().y + bg.get_center_size().y
			draw_style_box(bg, Rect2(Vector2(0, (size.y - bg_height) / 2), Vector2(size.x, bg_height)))
			
			var grabber: Texture2D = get_theme_icon("grabber", "HSlider")
			var area: StyleBox = get_theme_stylebox("grabber_area", "HSlider")
			var h: float = size.y / 2 - grabber.get_size().y / 2
			
			var minpos: Vector2 = Vector2((min_value / _max_value) * size.x - grabber.get_size().x / 2, h)
			var maxpos: Vector2 = Vector2((max_value / _max_value) * size.x - grabber.get_size().x / 2, h)
			
			draw_style_box(area, Rect2(Vector2(minpos.x + grabber.get_size().x / 2, (size.y - bg_height) / 2), Vector2(maxpos.x - minpos.x, bg_height)))
			
			draw_texture(grabber, minpos)
			draw_texture(grabber, maxpos)
			
	func set_max(value: float):
		max_value = value
		if _max_value == 0:
			_max_value = max_value
		update_label()
		
	func set_min_max(xpos: float):
		var mid_value_normalized: float = ((max_value + min_value) / 2.0) / _max_value
		var mid_value: float = size.x * mid_value_normalized
		var min_active: bool = xpos < mid_value
		var xpos_ranged: float = snappedf((xpos / size.x) * _max_value, step)
		
		if min_active:
			min_value = xpos_ranged
		else:
			max_value = xpos_ranged
		
		min_value = clamp(min_value, 0, max_value - 10)
		max_value = clamp(max_value, min_value + 10, _max_value)
		
		update_label()
		emit_signal("value_changed", value)
		queue_redraw()
		
	func update_label():
		if label:
			label.set_text(str(min_value) + suffix + "/" + str(max_value) + suffix)
