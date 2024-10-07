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


func _ready() -> void:
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
	

func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		if p_event.get_button_index() == MOUSE_BUTTON_LEFT:
			if p_event.is_pressed():
				var mid_point = (range.x + range.y) / 2.0
				var xpos: float = p_event.get_position().x * 2.0
				if xpos >= mid_point:
					grabbed_handle = 1
				else:
					grabbed_handle = -1
				set_slider(p_event.get_position().x)
			else:
				grabbed_handle = 0
			
	if p_event is InputEventMouseMotion:
		if grabbed_handle != 0:
			set_slider(p_event.get_position().x)
	
	
func set_slider(p_xpos: float) -> void:
	if grabbed_handle == 0:
		return
	var xpos_step: float = clamp(snappedf((p_xpos / size.x) * max_value, step), min_value, max_value)
	if(grabbed_handle < 0):
		range.x = xpos_step
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
		var h: float = size.y / 2 - handle.get_size().y / 2
		var startx: float = (range.x / max_value) * size.x
		var endx: float = (range.y / max_value) * size.x #- startx
		draw_style_box(area, Rect2(Vector2(startx, mid_y), Vector2(endx - startx, bg_height)))
		
		# Draw handles, slightly in so they don't get on the outside edges
		var handle_pos: Vector2
		handle_pos.x = clamp(startx - handle.get_size().x/2, -5, size.x)
		handle_pos.y = clamp(endx - handle.get_size().x/2, 0, size.x - 10)
		draw_texture(handle, Vector2(handle_pos.x, -mid_y))
		draw_texture(handle, Vector2(handle_pos.y, -mid_y))
