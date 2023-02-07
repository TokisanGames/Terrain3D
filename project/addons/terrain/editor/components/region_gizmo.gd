extends EditorNode3DGizmo
	
var rect_material: StandardMaterial3D
var grid_material: StandardMaterial3D
var position: Vector2
var size: float
var grid: Array[Vector2i]
var use_secondary_color: bool = false
var show_rect: bool = true

var main_color: Color = Color.GREEN_YELLOW
var secondary_color: Color = Color.RED

func _init() -> void:
	rect_material = StandardMaterial3D.new()
	rect_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	rect_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rect_material.render_priority = 1
	rect_material.albedo_color = main_color
	
	grid_material = StandardMaterial3D.new()
	grid_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_material.albedo_color = Color.WHITE

func _redraw() -> void:
	clear()
	
	if show_rect:
		rect_material.albedo_color = main_color if !use_secondary_color else secondary_color
		draw_rect(position, rect_material)
	
	for pos in grid:
		draw_rect(Vector2(pos) * size, grid_material)
	
func draw_rect(pos: Vector2, material: StandardMaterial3D) -> void:
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
		
