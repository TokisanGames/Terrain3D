extends PanelContainer

enum SettingType {
	CHECKBOX,
	SLIDER,
	SPINBOX,
}
	
const BRUSH_PATH: String = "res://addons/terrain/editor/brush"

var brush_preview_material: ShaderMaterial

var list: HBoxContainer
var advanced_list: VBoxContainer
var settings: Dictionary = {}
var dirty: bool = true

func _ready() -> void:
	list = HBoxContainer.new()
	add_child(list)
	
	add_setting(SettingType.SLIDER, "size", 50, list, "m", 0, 200)
	add_setting(SettingType.SLIDER, "opacity", 100, list, "%", 0, 100)
	add_setting(SettingType.SPINBOX, "height", 10, list, "m", 1, 1000, 0.1)
	
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
	
	add_setting(SettingType.SLIDER, "flow", 100, advanced_list, "%", 1, 100)
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
				btn.set_material(get_brush_preview_material())
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
		SettingType.SLIDER, SettingType.SPINBOX:
			label.set_vertical_alignment(VERTICAL_ALIGNMENT_CENTER)
			label.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
			label.set_custom_minimum_size(Vector2(32, 0))
			label.set_v_size_flags(SIZE_SHRINK_CENTER)
			label.set_text(p_name.capitalize() + ": ")
			container.add_child(label)
			
			control = EditorSpinSlider.new()
			var spinbox_only: bool = p_type == SettingType.SPINBOX
			
			control.set_custom_minimum_size(Vector2(70, 0))
			control.set_flat(!spinbox_only)
			control.set_hide_slider(!spinbox_only)
			control.connect("value_changed", _on_setting_changed)
			control.set_max(max_value)
			control.set_min(min_value)
			control.set_step(step)
			control.set_value(value)
			control.set_suffix(p_suffix)
			control.set_v_size_flags(SIZE_SHRINK_CENTER)
			
			if !spinbox_only:
				var slider: HSlider = HSlider.new()
				
				slider.set_custom_minimum_size(Vector2(110, 0))
				slider.set_v_size_flags(SIZE_SHRINK_CENTER)
				slider.set_h_size_flags(SIZE_SHRINK_END | SIZE_EXPAND)
				slider.set_max(max_value)
				slider.set_min(min_value)
				slider.set_step(step)
				slider.set_value(value)
				slider.share(control)
				
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
	if object is ButtonGroup:
		value = object.get_pressed_button().get_button_icon().get_image()
	if object is CheckBox:
		value = object.is_pressed()
		
	return value
	
func hide_settings(p_settings: Array[String]):
	for setting in settings.keys():
		var object: Object = settings[setting]
		if object is Control:
			object.get_parent().show()

	for setting in p_settings:
		var object: Object = settings[setting]
		if object is Control:
			object.get_parent().hide()
	
func is_dirty() -> bool:
	return dirty
	
func clean() -> void:
	dirty = false
	
func _on_setting_changed(p_data: Variant = null) -> void:
	dirty = true
	
func _on_show_advanced(toggled: bool, button: Button):
	var popup: PopupPanel = button.get_child(0)
	var popup_pos: Vector2 = button.get_screen_transform().origin
	popup.set_visible(toggled)
	popup_pos.y -= popup.get_size().y
	popup.set_position(popup_pos)

func get_brush_preview_material() -> ShaderMaterial:
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
