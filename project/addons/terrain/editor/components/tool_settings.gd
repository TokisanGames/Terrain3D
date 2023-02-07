extends PanelContainer
	
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

func _init() -> void:
	list = HBoxContainer.new()
	add_child(list)

func _ready() -> void:
	add_setting("Size: ", "m", 0, 500, 50)
	add_setting("Opacity: ", "%", 0, 100, 50)
	add_setting("Flow: ", "%", 0, 100, 50)
	
	set("theme_override_styles/panel", get_theme_stylebox("panel", "Panel"))
	
func add_setting(p_name: StringName, p_suffix: String, min_value: int, max_value: int, value: int) -> void:
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

func get_setting(setting: int) -> float:
	return list.get_child(setting).get_child(ControlType.SPINBOX).get_value()
	
func is_dirty() -> bool:
	return dirty
	
func clean() -> void:
	dirty = false
	
func _on_setting_changed(data: Variant) -> void:
	dirty = true
