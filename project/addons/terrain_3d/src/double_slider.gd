# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# DoubleSlider for Terrain3D
# Should work for other UIs
@tool
class_name DoubleSlider
extends Control

signal value_changed(Vector2)
var label: Label
var suffix: String
var grabbed_handle: int = 0 # -1 left, 0 none, 1 right
var min_value: float = 0.0
var max_value: float = 100.0
var step: float = 1.0
var range := Vector2(0, 100) 
var display_scale: float = 1.
var position_x: float = 0.
var minimum_x: float = 60.


func _ready() -> void:
	# Setup Display Scale
	# 0 auto, 1 75%, 2 100%, 3 125%, 4 150%, 5 175%, 6 200%, 7 custom
	var es: EditorSettings = EditorInterface.get_editor_settings()
	var ds: int = es.get_setting("interface/editor/display_scale")
	if ds == 0:
		ds = 2
	elif ds == 7:
		display_scale = es.get_setting("interface/editor/custom_display_scale")
	else:
		display_scale = float(ds + 2) * .25

	update_label()


func set_min(p_value: float) -> void:
	min_value = p_value
	if range.x <= min_value:
		range.x = min_value
		set_value(range)
	update_label()


func get_min() -> float:
	return min_value
	
	
func set_max(p_value: float) -> void:
	max_value = p_value
	if range.y == 0 or range.y >= max_value:
		range.y = max_value
		set_value(range)
	update_label()


func get_max() -> float:
	return max_value
	
	
func set_step(p_step: float) -> void:
	step = p_step
	

func get_step() -> float:
	return step
	

func set_value(p_range: Vector2) -> void:
	range.x = clamp(p_range.x, min_value, max_value)
	range.y = clamp(p_range.y, min_value, max_value)
	if range.y < range.x:
		var tmp: float = range.x
		range.x = range.y
		range.y = tmp

	update_label()
	emit_signal("value_changed", Vector2(range.x, range.y))
	queue_redraw()


func get_value() -> Vector2:
	return range


func update_label() -> void:
	if label:
		label.set_text(str(range.x) + suffix + "/" + str(range.y) + suffix)
		if position_x == 0:
			position_x = label.position.x
		else:
			label.position.x = position_x + 5 * display_scale
		label.custom_minimum_size.x = minimum_x + 5 * display_scale


func _get_handle() -> int:
	return 1


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		var button: int = p_event.get_button_index()
		if button in [ MOUSE_BUTTON_LEFT, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN ]:
			if p_event.is_pressed():
				var mid_point = (range.x + range.y) / 2.0
				var xpos: float = p_event.get_position().x * 2.0
				if xpos >= mid_point:
					grabbed_handle = 1
				else:
					grabbed_handle = -1
				match button:
					MOUSE_BUTTON_LEFT:
						set_slider(p_event.get_position().x)
					MOUSE_BUTTON_WHEEL_DOWN:
						set_slider(-1., true)
					MOUSE_BUTTON_WHEEL_UP:
						set_slider(1., true)
			else:
				grabbed_handle = 0
			
	if p_event is InputEventMouseMotion:
		if grabbed_handle != 0:
			set_slider(p_event.get_position().x)
	
	
func set_slider(p_xpos: float, p_relative: bool = false) -> void:
	if grabbed_handle == 0:
		return
	var xpos_step: float = clamp(snappedf((p_xpos / size.x) * max_value, step), min_value, max_value)
	if(grabbed_handle < 0):
		if p_relative:
			range.x += p_xpos
		else:
			range.x = xpos_step
	else:
		if p_relative:
			range.y += p_xpos
		else:
			range.y = xpos_step	
	set_value(range)


func _notification(p_what: int) -> void:
	if p_what == NOTIFICATION_DRAW:
		# Draw background bar
		var bg: StyleBox = get_theme_stylebox("slider", "HSlider")
		var bg_height: float = bg.get_minimum_size().y
		var mid_y: float = (size.y - bg_height) / 2.0
		draw_style_box(bg, Rect2(Vector2(0, mid_y), Vector2(size.x, bg_height)))
		
		# Draw foreground bar
		var handle: Texture2D = get_theme_icon("grabber", "HSlider")
		var area: StyleBox = get_theme_stylebox("grabber_area", "HSlider")
		var startx: float = (range.x / max_value) * size.x
		var endx: float = (range.y / max_value) * size.x
		draw_style_box(area, Rect2(Vector2(startx, mid_y), Vector2(endx - startx, bg_height)))
		
		# Draw handles, slightly in so they don't get on the outside edges
		var handle_pos: Vector2
		handle_pos.x = clamp(startx - handle.get_size().x/2, -10, size.x)
		handle_pos.y = clamp(endx - handle.get_size().x/2, 0, size.x - 10)
		draw_texture(handle, Vector2(handle_pos.x, -mid_y - 10 * (display_scale - 1.)))
		draw_texture(handle, Vector2(handle_pos.y, -mid_y - 10 * (display_scale - 1.)))
		
		update_label()
