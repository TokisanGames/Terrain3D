# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPlow — closed-loop spline HEIGHT brush driven by the modifier system (Pasture3DNodeGraph,
# Pasture3DNodeNoise, Pasture3DNodeRelief, Pasture3DNodeSmooth, Pasture3DNodeErosion). The loop is an
# area mask with falloff; inside it the modifier stack transforms and displaces the ground.
#
# Paints non-destructively into a reserved HEIGHT layer via the Pasture3DTerrainBrush base, so it gets
# layer-sharing, undo, surface-snap and the clear-then-snap climbing-fix for free.

@tool
@icon("res://addons/pasture_3d/icons/brush_plow.svg")
class_name Pasture3DPlow
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }

const _LUT_MAX := 256

@export_group("Mask")
## Metres from the loop edge inward over which the relief fades to flat (seamless with the surrounds).
@export var falloff_width: float = 10.0:
	set(v):
		falloff_width = maxf(v, 0.0)
		_schedule_refresh()

## Optional 0→1 falloff shape (default = smoothstep).
@export var falloff_curve: Curve:
	set(v):
		if falloff_curve != null and falloff_curve.changed.is_connected(_schedule_refresh):
			falloff_curve.changed.disconnect(_schedule_refresh)
		falloff_curve = v
		if falloff_curve != null and not falloff_curve.changed.is_connected(_schedule_refresh):
			falloff_curve.changed.connect(_schedule_refresh)
		_schedule_refresh()

## Expand (+) / contract (−) the masked area off the spline, in metres.
@export var edge_offset: float = 0.0:
	set(v):
		edge_offset = v
		_schedule_refresh()

@export_group("Compositing")
## true = stamp relief onto the existing per-pixel ground; false = relative to the node's Y plane.
@export var relative_to_terrain: bool = true:
	set(v):
		relative_to_terrain = v
		_schedule_refresh()

## How the relief composites: ADD = stamp on top; MAX/MIN = raise/lower-only; REPLACE = absolute pad.
@export var blend_mode: BlendMode = BlendMode.ADD:
	set(v):
		blend_mode = v
		_schedule_refresh()

@export_group("Smoothing")
## Passes of NaN-aware separable Gaussian blur applied after rasterisation.
@export_range(0, 5) var smooth_passes: int = 0:
	set(v):
		smooth_passes = clampi(v, 0, 5)
		_schedule_refresh()


func _default_layer_name() -> String:
	return "Plow"


func _get_blend_mode() -> int:
	return int(blend_mode)


## Whether this Plow's stamp digs, so `brush_raises()` knows an Add Water prompt must not treat it as
## burying the water it is about to author.
##
## This returned a hardcoded `false` — a stub left by the move to the modifier stack. Before that move it
## read `relief != null and not relief._raises()`, and the base class's own comment still names Pasture3DPlow
## as the class whose inversion lives somewhere other than an `invert` property. So a Crater plow said it
## RAISED ground, and the water prompt trusted it.
##
## Generalised to the stack rather than restored literally, because a Plow no longer has one source. The
## answer is only `true` when EVERY active height contribution digs: `false` conservatively means "this may
## raise", which is the side that warns, and a stack mixing a crater with a mound genuinely might.
func _raise_inverted() -> bool:
	var any := false
	for m in modifiers:
		if m == null or not m.has_method("is_active") or not m.is_active():
			continue
		var digs := false
		var strength := float(m.get("strength")) if m.get("strength") != null else 1.0
		if m is Pasture3DNodeRelief:
			var mat = m.material
			# A material that digs, flipped again by a negative strength, raises.
			digs = (mat != null and not mat._raises()) != (strength < 0.0)
		else:
			digs = strength < 0.0
		if not digs:
			return false
		any = true
	return any


func _init() -> void:
	super._init()


func _min_points() -> int:
	return 3


func _supports_modifiers() -> bool:
	return true


func _spline_basename() -> String:
	return "Area"


func _padding() -> float:
	return maxf(edge_offset, 0.0) + 2.0


## Starter shape: a closed square loop in local space.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	var r := 50.0
	c.add_point(Vector3(-r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, r))
	c.add_point(Vector3(-r, 0.0, r))
	return c


func _polygon_xz(path: Path3D) -> PackedVector2Array:
	var raw := PackedVector2Array()
	for p in _baked_world_points(path):
		raw.append(Vector2(p.x, p.z))
	var vs: float = terrain.vertex_spacing if terrain else 1.0
	return _decimate(raw, minf(vs * 0.25, 0.25))


func _paint_spline(path: Path3D) -> void:
	var poly := _polygon_xz(path)
	if poly.size() < 3:
		return
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var min_x: float = b[0]
	var min_z: float = b[2]
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	if gw < 1 or gh < 1:
		return

	var extent := _extent_key(min_x, min_z, vs, gw, gh)
	var wants_frame := _has_relief_modifier()
	var frame: Array = _loop_frame(poly) if wants_frame else [0.0, 0.0, 1.0, 0.0, 1.0, 1.0]
	var stack := _compile_modifiers(extent, frame[4], frame[5])
	var op_selectors: PackedFloat32Array = stack["op_selectors"]
	var use_fields := bool(stack["need_fields"])
	var sim_res: Pasture3DSimResult = stack["sim"]
	var fcx: float = frame[0]
	var fcz: float = frame[1]
	var fcos: float = frame[2]
	var fsin: float = frame[3]
	var inv_ex := 1.0 / maxf(frame[4], 0.001)
	var inv_ez := 1.0 / maxf(frame[5], 0.001)

	var fields: Array = _terrain_fields(min_x, min_z, vs, gw, gh) if use_fields else []
	var measured: Array = _measured_fields(fields[0], fields[2], op_selectors, vs, gw, gh,
			Pasture3DTerrainMask.FieldSource.BELOW_LAYER) if use_fields else []
	var sim_fields: Array = []
	var sim_dict := {}
	if sim_res != null and sim_res.is_valid():
		sim_fields = _sim_fields(sim_res, min_x, min_z, vs, gw, gh)
		sim_dict = _sim_result_dict(sim_res)

	# Native rasteriser: same SDF + per-cell modifier math in C++ (~15-40x faster than GDScript loop
	# on large edits).
	if _native_raster("stamp_mound_loop"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"height": 0.0, "capped": true, "invert": false,
			"falloff_width": falloff_width, "edge_offset": edge_offset,
			"flank_mode": 0, "slope_tan": 1.0,
			"slope_safety": 1000.0,
			"relative_to_terrain": relative_to_terrain, "plane_y": global_position.y,
			"blend": _blend, "composite": not _defer_composite,
			"smooth_passes": smooth_passes,
			"modifiers": stack["list"], "op_selectors": op_selectors,
			"fit_cx": fcx, "fit_cz": fcz, "fit_cos": fcos, "fit_sin": fsin,
			"fit_ex": frame[4], "fit_ez": frame[5],
			"need_fields": use_fields, "sim_result": sim_dict,
			"need_host_fields": false,
			# Metres of real ground seeded off the loop so an Erosion modifier can deposit a skirt there
			# (0 = §6.8's no-margin behaviour). The grid was already widened to match by `_total_padding`.
			"modifier_margin": _effective_modifier_margin(),
		}
		if relative_to_terrain or use_fields:
			params["base_below"] = _base_below_grid(min_x, min_z, vs, gw, gh)
		terrain.data.stamp_mound_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve))
		_commit_modifier_caches(stack, extent,
				[fcx, fcz, fcos, fsin, frame[4], frame[5], min_x, min_z, vs])
		return

	var sdf := _signed_distance_field(poly, min_x, min_z, vs, gw, gh)
	var field: PackedFloat32Array = sdf[0]
	var ramp_denom := maxf(falloff_width, 0.001)
	var add := _blend == BLEND_ADD

	var amp := PackedFloat64Array()
	amp.resize(gw * gh)
	var profile := PackedFloat64Array()
	profile.resize(gw * gh)
	var basey := _base_below_grid(min_x, min_z, vs, gw, gh) if (relative_to_terrain or use_fields) else PackedFloat32Array()
	if basey.is_empty():
		basey.resize(gw * gh)
		basey.fill(global_position.y)

	# The Modifier Margin's mask: THIS SAME RAMP, translated outward by the margin, so a modifier reaches
	# into the band and fades at the band's outer edge rather than at the loop rim. Only the host knows the
	# curve, which is why it is built here and not in `_run_modifier_stack`. Empty at margin 0 — the stack
	# then uses `profile` unchanged, which is byte-for-byte the historical path.
	var margin_m := _effective_modifier_margin()
	var profile_ext := PackedFloat64Array()
	if margin_m > 0.0:
		profile_ext.resize(gw * gh)

	for iz in range(gh):
		var row := iz * gw
		for ix in range(gw):
			var signed_d := field[row + ix] + edge_offset
			# Computed for EVERY cell, including the ones the loop skips below: the band is made of exactly
			# those, and they are where the extended ramp has to carry a value.
			if margin_m > 0.0:
				profile_ext[row + ix] = clampf(_ramp(falloff_curve, (signed_d + margin_m) / ramp_denom), 0.0, 1.0)
			if signed_d <= 0.0:
				amp[row + ix] = NAN
				profile[row + ix] = 0.0
				continue
			var mask := _ramp(falloff_curve, signed_d / ramp_denom)
			if mask <= 0.0:
				amp[row + ix] = NAN
				profile[row + ix] = 0.0
				continue
			amp[row + ix] = 0.0
			profile[row + ix] = mask

	var vals := PackedFloat32Array()
	vals.resize(gw * gh)
	vals.fill(NAN)

	# Execute modifier stack over the masked footprint
	if not stack["gd"].is_empty():
		var ctx := {
			"gw": gw, "gh": gh, "min_x": min_x, "min_z": min_z, "vs": vs, "add": add,
			"fit_cx": fcx, "fit_cz": fcz, "fit_cos": fcos, "fit_sin": fsin,
			"inv_ex": inv_ex, "inv_ez": inv_ez,
			"fields": fields, "sim_fields": sim_fields, "host_fields": [],
			"measured": measured, "host_measured": [], "host_div": 1.0,
			"profile": profile, "basey": basey, "extent": extent,
			# The signed distance (positive inside the loop) the Modifier Margin feathers its band against.
			"sdf": field, "edge_offset": edge_offset, "profile_ext": profile_ext,
		}
		vals = _run_modifier_stack(stack["gd"], amp, profile, basey, ctx)
		_commit_modifier_caches(stack, extent, [fcx, fcz, fcos, fsin, frame[4], frame[5], min_x, min_z, vs])
	else:
		if not add:
			for k in range(gw * gh):
				if not is_nan(amp[k]):
					vals[k] = basey[k]

	vals = _blur_grid(vals, gw, gh, smooth_passes)
	_store_stamp_cache(path, _compute_stamp_key(path), min_x, min_z, vs, gw, gh, vals, _spline_footprint_aabb(path))

	if _layer_id >= 0 and terrain.data.has_method("apply_sim_block"):
		terrain.data.apply_sim_block(_layer_id, min_x, min_z, vs, gw, gh, vals, _blend)
	else:
		for iz in range(gh):
			var z := min_z + iz * vs
			var row := iz * gw
			for ix in range(gw):
				var wv := vals[row + ix]
				if not is_finite(wv):
					continue
				var pos := Vector3(min_x + ix * vs, 0.0, z)
				if add:
					_paint_height(pos, 0.0, wv)
				else:
					_paint_height(pos, wv, 0.0)


func _brush_param_signature() -> Array:
	return [
		super._brush_param_signature(),
		blend_mode, relative_to_terrain,
		falloff_width, edge_offset, smooth_passes,
		falloff_curve.get_baked_points() if falloff_curve != null else []
	]
