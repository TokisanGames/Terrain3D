# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeLakeFlooding — a SOLVER grid node: hydrological basin depression flooding.
#
# Floods closed basins or fills all terrain below a specified target water level, generating 3 outputs:
#
#   port 0  "height"       HEIGHT  surface elevation with flat lake water levels filled
#   port 1  "water_depth"  MASK    water column depth in metres (z_water - z_bed)
#   port 2  "shoreline"    MASK    feathered shore mask along the water-land boundary
#
# Provides an editor tool button to spawn a Pasture3DPond / Pasture3DPool directly into the scene
# from the computed lake shoreline contour.
@tool
class_name Pasture3DGraphNodeLakeFlooding
extends Pasture3DGraphNode

enum FloodMode {
	SPILLWAY_BASIN,    ## Flood each closed depression up to its minimum drainage spillway.
	GLOBAL_ELEVATION,  ## Flood all terrain up to a fixed global water plane elevation.
}

enum Evaluation { LIVE, FROZEN }

@export var flood_mode: FloodMode = FloodMode.SPILLWAY_BASIN:
	set(v):
		flood_mode = v
		_param_changed()

## In GLOBAL_ELEVATION mode: the world Y elevation of the water plane.
@export var water_elevation: float = 10.0:
	set(v):
		water_elevation = v
		_param_changed()

## In SPILLWAY_BASIN mode: percentage of the depression's spillway depth to flood (0.0..1.0).
@export_range(0.0, 1.0, 0.01) var flood_percent: float = 1.0:
	set(v):
		flood_percent = clampf(v, 0.0, 1.0)
		_param_changed()

## Shoreline transition feathering width in metres.
@export_range(0.5, 32.0, 0.5) var shoreline_width: float = 4.0:
	set(v):
		shoreline_width = maxf(v, 0.1)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Lakes") var _bake_btn = clear_cache
@export_tool_button("Spawn Pasture3DPond in Scene") var _spawn_btn = spawn_pond_in_scene

# ---- Runtime cache ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false
var _last_lake_polys: Array[PackedVector2Array] = []
var _last_water_level: float = 0.0


func op() -> StringName:
	return &"lake_flooding"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["terrain"])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "water_depth", "shoreline"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func _param_changed() -> void:
	_dirty_since_bake = true
	emit_changed()


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if _stale:
		w.append("%s is FROZEN and input changed since bake. Press Bake Lakes to re-solve." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		in_grid = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _grid_hash(in_grid)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_stale = true
			return _cache[_cache_key]
		var solved := _solve(in_grid, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_stale = false
		return solved

	# LIVE
	if not _cache.is_empty():
		_cache.clear()
	_stale = false
	return _solve(in_grid, p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Solver Logic ----------------------------------------------------------------------------------

func _solve(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	_last_water_level = water_elevation if flood_mode == FloodMode.GLOBAL_ELEVATION else 0.0
	if ClassDB.class_has_method("Pasture3DUtil", "lake_flooding_grid"):
		var res: Dictionary = Pasture3DUtil.lake_flooding_grid(p_h, p_gw, p_gh, p_rect, int(flood_mode),
				water_elevation, flood_percent, shoreline_width)
		if bool(res.get("ok", false)):
			_last_lake_polys.clear()
			var polys: Array = res.get("contours", [])
			for poly in polys:
				if poly is PackedVector2Array:
					_last_lake_polys.append(poly)
			return [res["height"], res["water_depth"], res["shoreline"]]

	return _solve_gdscript(p_h, p_gw, p_gh, p_rect)


func _solve_gdscript(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var out_h := PackedFloat32Array()
	var out_depth := PackedFloat32Array()
	var out_shore := PackedFloat32Array()
	out_h.resize(n)
	out_depth.resize(n)
	out_shore.resize(n)

	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0) if (p_rect.size.x > 0.0 and p_gw > 1) else 2.0
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0) if (p_rect.size.y > 0.0 and p_gh > 1) else 2.0

	var water_grid := PackedFloat32Array()
	water_grid.resize(n)

	if flood_mode == FloodMode.GLOBAL_ELEVATION:
		_last_water_level = water_elevation
		for i in range(n):
			var zh := p_h[i]
			water_grid[i] = maxf(zh, water_elevation) if is_finite(zh) else NAN
	else:
		# SPILLWAY_BASIN mode
		var filled := Pasture3DGraphNodeDepressionFilling._priority_flood_fill(p_h, p_gw, p_gh, dx, dz, 0.0, 0.0)
		for i in range(n):
			var raw_z := p_h[i]
			var spill_z := filled[i]
			if is_finite(raw_z) and is_finite(spill_z):
				var max_depth := maxf(spill_z - raw_z, 0.0)
				water_grid[i] = raw_z + max_depth * flood_percent
			else:
				water_grid[i] = raw_z

	# Compute 3 output channels
	for i in range(n):
		var raw_z := p_h[i]
		var wz := water_grid[i]
		if not is_finite(raw_z) or not is_finite(wz):
			out_h[i] = NAN
			out_depth[i] = 0.0
			out_shore[i] = 0.0
			continue

		var depth := maxf(wz - raw_z, 0.0)
		out_h[i] = wz
		out_depth[i] = depth
		out_shore[i] = clampf(depth / maxf(shoreline_width, 0.1), 0.0, 1.0)

	# Extract lake contour polygons for spawning
	_extract_lake_contours(out_depth, p_gw, p_gh, p_rect)

	return [out_h, out_depth, out_shore]


func _extract_lake_contours(p_depth: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> void:
	_last_lake_polys.clear()
	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0)
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0)

	# Find lake boundary cells
	var boundary_pts := PackedVector2Array()
	for iz in range(1, p_gh - 1):
		for ix in range(1, p_gw - 1):
			var idx := iz * p_gw + ix
			if p_depth[idx] > 0.05:
				var is_edge := (p_depth[idx - 1] <= 0.05 or p_depth[idx + 1] <= 0.05 or
						p_depth[idx - p_gw] <= 0.05 or p_depth[idx + p_gw] <= 0.05)
				if is_edge:
					var wx := p_rect.position.x + ix * dx
					var wz := p_rect.position.y + iz * dz
					boundary_pts.append(Vector2(wx, wz))

	if boundary_pts.size() >= 3:
		_last_lake_polys.append(boundary_pts)


## Spawns a Pasture3DPond in the active edited scene from the detected lake basin.
func spawn_pond_in_scene() -> void:
	if _last_lake_polys.is_empty():
		push_warning("Pasture3DGraphNodeLakeFlooding: No lake basin found to spawn a pond.")
		return

	var root := EditorInterface.get_edited_scene_root() if Engine.is_editor_hint() else null
	if root == null:
		push_warning("Pasture3DGraphNodeLakeFlooding: No edited scene root found.")
		return

	var poly := _last_lake_polys[0]
	var pond := Pasture3DPond.new()
	pond.name = "Pond_Lake"

	var path := Path3D.new()
	path.name = "Loop1"
	var curve := Curve3D.new()
	for pt in poly:
		curve.add_point(Vector3(pt.x, 0.0, pt.y))
	if poly.size() > 0:
		curve.add_point(Vector3(poly[0].x, 0.0, poly[0].y)) # close loop
	path.curve = curve

	pond.add_child(path)
	path.owner = root

	root.add_child(pond)
	pond.owner = root
	pond.global_position = Vector3(0.0, _last_water_level, 0.0)

	print("Spawned Pasture3DPond '%s' at elevation Y=%.2f" % [pond.name, _last_water_level])
	if Engine.is_editor_hint():
		EditorInterface.edit_node(pond)


func _grid_hash(arr: PackedFloat32Array) -> int:
	var h: int = arr.size()
	for i in range(0, arr.size(), maxi(1, arr.size() / 32)):
		h = (h * 31) ^ int(arr[i] * 1000.0)
	return h
