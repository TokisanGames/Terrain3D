# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DMound — closed-loop spline hill / plateau / valley brush. Pasture3D's analogue of UE5's
# Landmass CustomBrush_Landmass. Each child Path3D is treated as a closed loop; the interior is
# filled with a hill (uncapped dome) or plateau (capped flat-top), falling off to the surrounding
# terrain at the loop boundary. Set invert / blend_mode = MIN to carve a basin instead.
#
# See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §4. Paints non-destructively into a reserved layer via the
# Pasture3DTerrainBrush base.
@tool
@icon("res://addons/pasture_3d/icons/brush_mound.svg")
class_name Pasture3DMound
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }
## How the height ramps in from the loop edge: FIXED_WIDTH ramps over `falloff_width`; SLOPE_ANGLE
## ramps at `slope_angle` (run = height / tan(angle)) so the flank meets the edge at a chosen grade.
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }

@export_group("Shape")
## Peak height above the base reference. Capped → plateau-top height; uncapped → dome peak.
@export var height: float = 20.0
## Flat-topped plateau (true) vs domed peak (false).
@export var capped: bool = false
## How the loop composites with the terrain: MAX = hill (raise-only), MIN = basin (lower-only),
## ADD = additive bump, REPLACE = absolute authoring (flat plateau when combined with capped).
@export var blend_mode: BlendMode = BlendMode.MAX:
	set(v):
		blend_mode = v
		_schedule_refresh() # re-bake so the new blend takes effect immediately (and undo-coherently)
## Flip the sign so the same controls carve a depression.
@export var invert: bool = false
## true = measure height above the per-pixel terrain (hill drapes on the ground); false = above the
## node's own Y plane (flat reference — pair with capped + REPLACE for a level plateau top).
@export var relative_to_terrain: bool = true

@export_group("Falloff")
## FIXED_WIDTH = ramp over `falloff_width`; SLOPE_ANGLE = ramp at `slope_angle` (run = height / tan).
@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH:
	set(v):
		flank_mode = v
		_schedule_refresh()
		notify_property_list_changed() # show/hide falloff_width vs slope_angle
## Metres from the loop edge inward over which a CAPPED plateau ramps up to full height.
@export var falloff_width: float = 15.0
## Slope-angle mode only: degrees the flank rises from the loop edge (ramp run = height / tan(angle)).
@export_range(1.0, 89.0, 0.5) var slope_angle: float = 30.0:
	set(v):
		slope_angle = clampf(v, 1.0, 89.0)
		_schedule_refresh()
## Optional 0→1 slope shape for the ramp / dome (default = smoothstep).
@export var falloff_curve: Curve
## Expand (+) or contract (−) the effective boundary off the spline, in metres.
@export var edge_offset: float = 0.0

@export_group("Noise")
## Optional vertical jitter to break up the silhouette (UE curl-noise analogue).
@export var noise: FastNoiseLite
## Metres of jitter, masked by the interior profile so the rim stays clean.
@export var noise_strength: float = 0.0

@export_group("Relief")
## Optional Pasture3DReliefMaterial — the same landform materials the Plow stamps (craggy fractal, strata,
## terraces, dunes, scree, craters), applied to this mound's own surface. Sits ALONGSIDE the noise field
## above rather than replacing it: both are added, so an existing `noise` keeps doing exactly what it did.
##
## Mapping is always TILE — the ops are evaluated in world XZ, so relief stays continuous where two mounds
## meet. Radial ops (Crater) read the loop-normalised coordinates and so are still sized and oriented to
## this loop, exactly as they are under the Plow. See PASTURE3D_MOUND_RELIEF_SPEC.md.
@export var relief: Pasture3DReliefMaterial:
	set(v):
		# Live re-bake: the material emits `changed` on every property setter.
		if relief != null and relief.changed.is_connected(_schedule_refresh):
			relief.changed.disconnect(_schedule_refresh)
		relief = v
		if relief != null and not relief.changed.is_connected(_schedule_refresh):
			relief.changed.connect(_schedule_refresh)
		_schedule_refresh()
		update_configuration_warnings()
## Metres of relief at the material's full output, masked by the interior profile so the rim stays clean.
## Deliberately separate from `height`: relief describes the surface texture of the landform, and tying its
## amplitude to the peak would rescale every detail whenever the mound was made taller.
@export var relief_strength: float = 0.0:
	set(v):
		relief_strength = v
		_schedule_refresh()
		update_configuration_warnings()

@export_group("Smoothing")
## Passes of NaN-aware separable Gaussian blur applied after rasterisation, to soften the dome/plateau
## surface and any chamfer-DT faceting. 0 = off (no cost), 1-2 = subtle, 3+ = heavy rounding.
@export_range(0, 5) var smooth_passes: int = 0:
	set(v):
		smooth_passes = v
		_schedule_refresh()


func _validate_property(property: Dictionary) -> void:
	# Fixed-width and slope-angle drive the same ramp; only one is meaningful at a time.
	if property.name == "slope_angle" and flank_mode != FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == "falloff_width" and flank_mode == FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := super()
	# The material's own complaint plus the shared sim-selector and periodic-resolution diagnostics.
	warnings.append_array(_relief_warnings(relief))
	# A material with no amplitude is the one failure mode that looks exactly like a broken material:
	# the slot is filled, the inspector looks configured, and the ground is flat.
	if relief != null and is_zero_approx(relief_strength):
		warnings.append(("A Relief Material is assigned but Relief Strength is 0 m, so it stamps nothing. "
			+ "Set Relief Strength to the depth of detail you want, in metres."))
	return warnings


## Safety ceiling for the uncapped slope-angle cone: the region's world size (verts × spacing). A steep
## angle over a large loop would otherwise author an unbounded peak; this caps it at something sane.
func _region_safety_height() -> float:
	if terrain == null:
		return 1000.0
	return maxf(float(terrain.region_size) * terrain.vertex_spacing, 1.0)


func _default_layer_name() -> String:
	return "Mounds"


func _get_blend_mode() -> int:
	return int(blend_mode)


func _min_points() -> int:
	return 3


func _spline_basename() -> String:
	return "Loop"


func _padding() -> float:
	# Painting only reaches outside the polygon by a positive edge_offset; the dome/ramp work inward.
	return maxf(edge_offset, 0.0) + 2.0


## Starter shape: a closed square loop in local space.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	var r := 20.0
	c.add_point(Vector3(-r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, r))
	c.add_point(Vector3(-r, 0.0, r))
	return c


## Loop projected to world XZ and decimated to ~terrain resolution (the raw Curve3D bake is far finer
## than the grid and would make the scanline fill needlessly slow).
func _polygon_xz(path: Path3D) -> PackedVector2Array:
	var raw := PackedVector2Array()
	for p in _baked_world_points(path):
		raw.append(Vector2(p.x, p.z))
	return _decimate(raw, maxf(terrain.vertex_spacing, 0.25))


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

	# Relief material: compile the op program ONCE per bake (never per cell). An unassigned material or a
	# zero strength leaves the arrays empty, which is what both paths test to skip the relief work entirely.
	var ops := PackedInt32Array()
	var op_params := PackedFloat32Array()
	var op_luts := PackedFloat32Array()
	var op_selectors := PackedFloat32Array()
	var mat_strength := 1.0
	if relief != null and not is_zero_approx(relief_strength):
		var prog: Array = relief.compile()
		ops = prog[0]
		op_params = prog[1]
		op_luts = prog[2]
		op_selectors = prog[3]
		mat_strength = relief.strength
	var has_relief := not ops.is_empty()

	# Oriented loop frame. Mapping is always TILE here — the ops read world XZ — but the normalised
	# coordinates radial ops use come from this frame, so a Crater is still sized and turned by the loop.
	var frame: Array = _loop_frame(poly) if has_relief else [0.0, 0.0, 1.0, 0.0, 1.0, 1.0]
	var fcx: float = frame[0]
	var fcz: float = frame[1]
	var fcos: float = frame[2]
	var fsin: float = frame[3]
	var inv_ex := 1.0 / maxf(frame[4], 0.001)
	var inv_ez := 1.0 / maxf(frame[5], 0.001)

	# Terrain-aware selectors and SCREE read the ground below this brush's layer. Built once per bake, and
	# only when the compiled program actually reads them — the field grids are O(cells).
	var use_fields := has_relief and _needs_terrain_fields(ops)
	var fields: Array = _terrain_fields(min_x, min_z, vs, gw, gh) if use_fields else []
	# The sim channels the FLOW / EROSION / DEPOSITION / WETNESS Kinds read, resampled from the
	# Pasture3DSimResult's own extent (which shares no grid with this bake). Only when a selector asks.
	var sim_res: Pasture3DSimResult = _relief_sim_result(relief) if use_fields else null
	var sim_fields: Array = []
	var sim_dict := {}
	if sim_res != null and sim_res.is_valid():
		sim_fields = _sim_fields(sim_res, min_x, min_z, vs, gw, gh)
		sim_dict = _sim_result_dict(sim_res)

	# Native rasteriser (Round 2): same SDF + per-cell math in C++ (~15-40x faster than this GDScript loop
	# on large edits). The GDScript reference below runs on builds without it (and is the A/B oracle).
	if _native_raster("stamp_mound_loop"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"height": height, "capped": capped, "invert": invert,
			"falloff_width": falloff_width, "edge_offset": edge_offset,
			"flank_mode": int(flank_mode), "slope_tan": tan(deg_to_rad(slope_angle)),
				"slope_safety": _region_safety_height(),
				"relative_to_terrain": relative_to_terrain, "plane_y": global_position.y,
			"blend": _blend, "composite": not _defer_composite,
			"noise": noise, "noise_strength": noise_strength,
				"smooth_passes": smooth_passes,
			"ops": ops, "op_params": op_params, "op_luts": op_luts, "op_selectors": op_selectors,
			"relief_strength": relief_strength, "relief_mat_strength": mat_strength,
			"fit_cx": fcx, "fit_cz": fcz, "fit_cos": fcos, "fit_sin": fsin,
			"fit_ex": frame[4], "fit_ez": frame[5],
			"need_fields": use_fields, "sim_result": sim_dict,
		}
		# C++ derives the slope/curvature/gradient grids itself (same formula, same input, so the two paths
		# agree) — but only if it is handed the below-layer heights, which otherwise travel only when the
		# brush is stamping relative to the terrain.
		if relative_to_terrain or use_fields:
			params["base_below"] = _base_below_grid(min_x, min_z, vs, gw, gh)
		terrain.data.stamp_mound_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve))
		return

	# One O(cells) signed distance field replaces the old per-pixel O(edges) polygon distance (×2 for
	# the dome's max-interior pass). Positive inside, in metres; max_inside normalises the dome.
	var sdf := _signed_distance_field(poly, min_x, min_z, vs, gw, gh)
	var field: PackedFloat32Array = sdf[0]
	var max_inside: float = sdf[1]
	var sign := -1.0 if invert else 1.0
	var dome_denom := maxf(max_inside + edge_offset, 0.001)
	var ramp_denom := maxf(falloff_width, 0.001)
	var slope_tan := maxf(tan(deg_to_rad(slope_angle)), 0.0001)
	# Slope-angle: the grade — not a typed width — drives the ramp.
	#  - CAPPED: rise at the angle until the flank reaches `height`, then flat top. ramp run = height / tan.
	#  - UNCAPPED ("cone"): keep rising at the angle all the way in (height = tan × distance-from-edge), NOT
	#    limited by `height`. Bounded only by the interior; clamped to a region-sized safety cap so a huge
	#    loop / steep angle can't author a runaway peak.
	var use_angle := flank_mode == FlankMode.SLOPE_ANGLE
	var cone := use_angle and not capped
	var safety_max := _region_safety_height()
	if use_angle and capped:
		ramp_denom = maxf(absf(height) / slope_tan, 0.001)

	# Buffer per-cell write values (NaN = no write) so the optional smoothing pass can run before writing.
	# value = delta (ADD) or absolute target (else), matching _paint_height + the C++ path for A/B parity.
	var add := _blend == BLEND_ADD
	var vals := PackedFloat32Array()
	vals.resize(gw * gh)
	vals.fill(NAN)

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var signed_d := field[row + ix] + edge_offset
			if signed_d <= 0.0:
				continue
			var x := min_x + ix * vs
			var pos := Vector3(x, 0.0, z)
			var base_y := _base_height_below(pos) if relative_to_terrain else global_position.y
			var amp: float
			var profile: float
			if cone:
				# Free-rising cone: tan × distance, capped by the region safety height. profile is the
				# 0→1 interior mask used only to keep noise / relief off the rim.
				profile = clampf(signed_d / dome_denom, 0.0, 1.0)
				amp = sign * minf(slope_tan * signed_d, safety_max)
			else:
				profile = _ramp(falloff_curve, signed_d / (ramp_denom if capped else dome_denom))
				if profile <= 0.0:
					continue
				amp = sign * height * profile
			if noise:
				amp += noise_strength * noise.get_noise_2d(x, z) * profile
			if has_relief:
				# Loop-local metres → the normalised coordinates radial ops read. TILE evaluates the ops
				# in world XZ, so only nu,nv come from the frame.
				var dx := x - fcx
				var dz := z - fcz
				var lx := dx * fcos + dz * fsin
				var lz := -dx * fsin + dz * fcos
				var f_alt := 0.0
				var f_slope := 0.0
				var f_curv := 0.0
				var f_gx := 0.0
				var f_gz := 0.0
				var f_flow := 0.0
				var f_ero := 0.0
				var f_dep := 0.0
				var f_wet := 0.0
				if use_fields:
					var fi := row + ix
					f_alt = fields[0][fi]
					f_slope = fields[1][fi]
					f_curv = fields[2][fi]
					f_gx = fields[3][fi]
					f_gz = fields[4][fi]
					if not sim_fields.is_empty():
						f_flow = sim_fields[0][fi]
						f_ero = sim_fields[1][fi]
						f_dep = sim_fields[2][fi]
						f_wet = sim_fields[3][fi]
				var rv := relief.eval(x, z, lx * inv_ex, lz * inv_ez, inv_ex, inv_ez,
						f_alt, f_slope, f_curv, f_gx, f_gz, f_flow, f_ero, f_dep, f_wet)
				amp += relief_strength * rv * profile * mat_strength
			vals[row + ix] = amp if add else base_y + amp

	vals = _blur_grid(vals, gw, gh, smooth_passes)

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var v := vals[row + ix]
			if not is_finite(v):
				continue
			var pos := Vector3(min_x + ix * vs, 0.0, z)
			if add:
				_paint_height(pos, 0.0, v)
			else:
				_paint_height(pos, v, 0.0)
