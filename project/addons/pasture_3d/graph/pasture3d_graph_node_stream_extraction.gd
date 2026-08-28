# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeStreamExtraction — a SOLVER grid node: drainage flow routing and river channel extraction.
#
# Routes surface runoff downhill to calculate accumulated drainage catchment area across the terrain grid.
# Carves natural parabolic riverbed channels along high-discharge thalwegs and generates 3 output channels:
#
#   port 0  "height"        HEIGHT  terrain surface with carved riverbed channels
#   port 1  "channel_mask"  MASK    channel intensity mask with lateral bank falloff
#   port 2  "flow_rate"     MASK    normalized drainage flow accumulation
#
# Provides an editor tool button to vectorize the primary river streamline and spawn a Pasture3DStream
# ribbon directly into the scene along the valley.
@tool
class_name Pasture3DGraphNodeStreamExtraction
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

## Minimum upstream catchment cells required to initiate stream channel formation.
@export_range(4.0, 500.0, 2.0, "or_greater") var min_catchment_cells: float = 24.0:
	set(v):
		min_catchment_cells = maxf(v, 1.0)
		_param_changed()

## Maximum vertical depth (metres) to carve along river channels.
@export_range(0.0, 20.0, 0.1, "or_greater") var carve_depth: float = 3.0:
	set(v):
		carve_depth = maxf(v, 0.0)
		_param_changed()

## Base width (metres) of carved stream channels.
@export_range(1.0, 64.0, 0.5, "or_greater") var channel_width: float = 8.0:
	set(v):
		channel_width = maxf(v, 0.5)
		_param_changed()

## Lateral bank transition falloff (metres).
@export_range(0.5, 32.0, 0.5) var bank_falloff: float = 4.0:
	set(v):
		bank_falloff = maxf(v, 0.1)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Streams") var _bake_btn = clear_cache
@export_tool_button("Spawn Pasture3DStream in Scene") var _spawn_btn = spawn_stream_in_scene

# ---- Runtime cache ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false
var _last_stream_points: PackedVector3Array = PackedVector3Array()


func op() -> StringName:
	return &"stream_extraction"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "min_catchment", "carve_depth", "channel_width"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return min_catchment_cells
		2: return carve_depth
		3: return channel_width
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "channel_mask", "flow_rate"])


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
		w.append("%s is FROZEN and input changed since bake. Press Bake Streams to re-solve." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		in_grid = Pasture3DGraphOps.zeros(n)

	var mc: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else min_catchment_cells
	var cd: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else carve_depth
	var cw: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else channel_width

	if evaluation == Evaluation.FROZEN:
		var key := _grid_hash(in_grid)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_stale = true
			return _cache[_cache_key]
		var solved := _solve_dynamic(in_grid, p_gw, p_gh, p_rect, mc, cd, cw)
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
	return _solve_dynamic(in_grid, p_gw, p_gh, p_rect, mc, cd, cw)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Solver Logic ----------------------------------------------------------------------------------

func _solve_dynamic(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_mc: float, p_cd: float, p_cw: float) -> Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "stream_extraction_grid"):
		push_error("[Pasture3D] Pasture3DUtil.stream_extraction_grid is not bound. Rebuild GDExtension.")
		return [p_h.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.stream_extraction_grid(p_h, p_gw, p_gh, p_rect,
			p_mc, p_cd, p_cw, bank_falloff)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Stream extraction native solve failed.")
		return [p_h.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	_last_stream_points = res.get("stream_points", PackedVector3Array())
	return [res["height"], res["channel_mask"], res["flow_rate"]]


func _trace_primary_streamline(p_accum: PackedFloat32Array, p_rec: PackedInt32Array,
		p_gw: int, p_gh: int, p_h: PackedFloat32Array, p_rect: Rect2, p_dx: float, p_dz: float) -> void:
	var pts := PackedVector3Array()

	# Find cell with maximum accumulated flow that initiates a major stream
	var max_idx := -1
	var max_val := min_catchment_cells
	for i in range(p_accum.size()):
		if p_accum[i] > max_val:
			max_val = p_accum[i]
			max_idx = i

	if max_idx < 0:
		_last_stream_points = pts
		return

	# Trace upstream to headwaters
	var stream_cells: Array[int] = [max_idx]
	var visited := {}
	var curr := max_idx

	# Trace downstream
	while curr >= 0 and curr < p_rec.size() and not visited.has(curr):
		visited[curr] = true
		curr = p_rec[curr]
		if curr >= 0:
			stream_cells.append(curr)

	for c_idx in stream_cells:
		var ix := c_idx % p_gw
		var iz := c_idx / p_gw
		var wx := p_rect.position.x + ix * p_dx
		var wz := p_rect.position.y + iz * p_dz
		var wy := p_h[c_idx] if is_finite(p_h[c_idx]) else 0.0
		pts.append(Vector3(wx, wy, wz))

	_last_stream_points = pts


## Spawns a Pasture3DStream ribbon in the active edited scene from the extracted river path.
func spawn_stream_in_scene() -> void:
	if _last_stream_points.size() < 2:
		push_warning("Pasture3DGraphNodeStreamExtraction: No stream thalweg found to spawn.")
		return

	var root := EditorInterface.get_edited_scene_root() if Engine.is_editor_hint() else null
	if root == null:
		push_warning("Pasture3DGraphNodeStreamExtraction: No edited scene root found.")
		return

	var stream := Pasture3DStream.new()
	stream.name = "Stream_River"

	var path := Path3D.new()
	path.name = "Channel1"
	var curve := Curve3D.new()
	for pt in _last_stream_points:
		curve.add_point(pt)
	path.curve = curve

	stream.add_child(path)
	path.owner = root

	root.add_child(stream)
	stream.owner = root

	print("Spawned Pasture3DStream '%s' with %d waypoint nodes." % [stream.name, _last_stream_points.size()])
	if Engine.is_editor_hint():
		EditorInterface.edit_node(stream)


func _grid_hash(arr: PackedFloat32Array) -> int:
	var h: int = arr.size()
	for i in range(0, arr.size(), maxi(1, arr.size() / 32)):
		h = (h * 31) ^ int(arr[i] * 1000.0)
	return h
