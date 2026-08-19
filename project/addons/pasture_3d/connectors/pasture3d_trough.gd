# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTrough — spline-as-channel river / canyon / road-cut brush. Pasture3D's analogue of UE5's
# Landmass CustomBrush_LandmassRiver. Carves a channel UNDER and along each (usually open) spline: an
# optionally flat bed flanked by banks that rise back to the surrounding terrain. With Follow Spline
# Height on the spline IS the bed floor, so drawing the spline downhill produces a channel that descends
# (water flow). Banks rise from the bed up to the ACTUAL terrain surface, over a fixed width or at a
# fixed slope angle. Defaults to MIN (carve-only) so banks never bulge above the ground.
#
# See PASTURE3D_RIDGE_TROUGH_FLANK_SPEC.md. Paints non-destructively into a reserved layer via the
# Pasture3DTerrainBrush base.
@tool
@icon("res://addons/pasture_3d/icons/brush_trough.svg")
class_name Pasture3DTrough
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }
## How the banks reach the terrain: FIXED_WIDTH spreads over `bank_width`; SLOPE_ANGLE rises at
## `slope_angle` until it meets the ground (reach capped by `bank_width`).
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }

@export_group("Channel")
## Extra carve below the bed reference. With Follow Spline Height on the spline IS the bed floor, so this
## is an optional bonus depth (default 0). With it off the bed sits this far below the terrain.
@export var depth: float = 0.0:
	set(v):
		depth = v
		_schedule_refresh()
## Half-width of the (flat) channel floor, centred on the spline.
@export var bed_half_width: float = 4.0:
	set(v):
		bed_half_width = v
		_schedule_refresh()
## true = flat floor of bed_half_width + bank ramp; false = a single smooth V/U basin across the
## whole half-width (bed_half_width + bank_width), deepest at the centreline.
@export var flat_bed: bool = true:
	set(v):
		flat_bed = v
		_schedule_refresh()
## FIXED_WIDTH = banks spread over `bank_width`; SLOPE_ANGLE = banks rise at `slope_angle` to terrain.
@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH:
	set(v):
		flank_mode = v
		_schedule_refresh()
		notify_property_list_changed() # show/hide slope_angle
## Slope-angle mode only: degrees the banks rise from the bed before they meet the terrain.
@export_range(1.0, 89.0, 0.5) var slope_angle: float = 30.0:
	set(v):
		slope_angle = clampf(v, 1.0, 89.0)
		_schedule_refresh()
## MIN = carve-only (default, never raises); REPLACE/ADD available for special cases.
@export var blend_mode: BlendMode = BlendMode.MIN:
	set(v):
		blend_mode = v
		_schedule_refresh() # re-bake so the new blend takes effect immediately (and undo-coherently)

@export_group("Banks")
## Lateral run from the bed edge up to terrain level (the bank slope length / max reach in Slope Angle).
@export var bank_width: float = 10.0:
	set(v):
		bank_width = v
		_schedule_refresh()
## Bank shape: bed edge (0, deep) → bank top (1, terrain). Default = smoothstep.
@export var bank_profile: Curve:
	set(v):
		bank_profile = v
		_schedule_refresh()
## Extra feather beyond the bank top into the surrounding terrain.
@export var falloff: float = 6.0:
	set(v):
		falloff = v
		_schedule_refresh()
## Optional taper along the spline: sampled start (x=0) → end (x=1), multiplies the channel half-width
## (bed + banks) per point so the channel can pinch toward the ends. Null = constant width. Depth is not
## scaled. (Closed rings wrap 0→1 around the perimeter with a small seam at the join.)
@export var width_curve: Curve:
	set(v):
		if width_curve != null and width_curve.changed.is_connected(_schedule_refresh):
			width_curve.changed.disconnect(_schedule_refresh)
		width_curve = v
		if width_curve != null and not width_curve.changed.is_connected(_schedule_refresh):
			width_curve.changed.connect(_schedule_refresh)
		_schedule_refresh()

@export_group("Bed line")
## Connect the last point back to the first, forming a closed ring channel (a moat) instead of a line.
@export var closed: bool = false:
	set(v):
		closed = v
		_schedule_refresh() # re-bake so the ring closes/opens immediately (and undo-coherently)
		if is_inside_tree():
			update_gizmos() # redraw the loop wrap segment + tangents
## Bed reference = the spline's own Y (true; author flow by drawing downhill) or the per-pixel terrain
## height (false; a uniform-depth ditch). Either way the banks rise to the real terrain surface.
@export var follow_spline_height: bool = true:
	set(v):
		follow_spline_height = v
		_schedule_refresh()

@export_group("Noise")
@export var noise: FastNoiseLite:
	set(v):
		noise = v
		_schedule_refresh()
## Jitter on the banks for a natural edge (never lifts the bed above terrain).
@export var noise_strength: float = 0.0:
	set(v):
		noise_strength = v
		_schedule_refresh()

@export_group("Smoothing")
## Passes of NaN-aware separable Gaussian blur applied after rasterisation, to soften the bed/bank
## surface and any chamfer-DT faceting. 0 = off (no cost), 1-2 = subtle, 3+ = heavy rounding.
@export_range(0, 5) var smooth_passes: int = 0:
	set(v):
		smooth_passes = v
		_schedule_refresh()

## Clamp each spline's points so its Y never rises along the path — guarantees a downhill channel.
@export_tool_button("Make Descend") var _descend_btn = make_descend


func _default_layer_name() -> String:
	return "Troughs"


func _default_snap_to_surface() -> bool:
	return false # troughs author a vertical bed line (downhill flow); banks rise to terrain on their own


func _get_blend_mode() -> int:
	return int(blend_mode)


func _spline_basename() -> String:
	return "Channel"


func _is_closed() -> bool:
	return closed


func _padding() -> float:
	return bed_half_width + bank_width + falloff + 2.0


func _validate_property(property: Dictionary) -> void:
	# Slope-angle field is only meaningful in SLOPE_ANGLE mode.
	if property.name == "slope_angle" and flank_mode != FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Starter shape: a straight line in local space.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(0.0, 0.0, -20.0))
	c.add_point(Vector3(0.0, 0.0, 20.0))
	return c


func _paint_spline(path: Path3D) -> void:
	var pts := _baked_world_points(path)
	if pts.size() < 2:
		return
	var vs: float = terrain.vertex_spacing
	pts = _decimate3(pts, vs)
	if pts.size() < 2:
		return
	if closed:
		pts.append(pts[0]) # wrap the ring: rasterisers see the last->first segment like any other
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var min_x: float = b[0]
	var min_z: float = b[2]
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	if gw < 1 or gh < 1:
		return

	# Native rasteriser (Round 2): same polyline field + per-cell bed/bank math in C++. GDScript
	# reference below for builds without it (and the A/B oracle via force_gdscript_raster).
	if _native_raster("stamp_trough_line"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"bed_half_width": bed_half_width, "bank_width": bank_width, "falloff": falloff,
			"depth": depth, "flat_bed": flat_bed, "follow_spline_height": follow_spline_height,
			"flank_mode": int(flank_mode), "slope_tan": tan(deg_to_rad(slope_angle)),
			"blend": _blend, "composite": not _defer_composite,
			"noise": noise, "noise_strength": noise_strength,
			"smooth_passes": smooth_passes,
			# Per-point terrain heights for ground interpolation in C++ (O(npts) vs O(cells)).
			"base_below_pts": _below_pts(pts),
		}
		if width_curve != null:
			params["width_lut"] = _ramp_lut(width_curve)
		terrain.data.stamp_trough_line(_layer_id, pts, _clip_aabb, params, _ramp_lut(bank_profile))
		return

	# Exact closest-point-on-segment field (mirrors the native ds==1 path): per cell the lateral distance,
	# the bed-reference Y at the nearest point, the arc length, and the geometry-driven ground_ref. Exact =
	# no chamfer error/seams, an exact A/B oracle of the C++ rasteriser.
	var use_angle := flank_mode == FlankMode.SLOPE_ANGLE
	var slope_tan := maxf(tan(deg_to_rad(slope_angle)), 0.0001)
	var reach := bed_half_width + bank_width + falloff
	var below_pts := _below_pts(pts)
	var fld := _exact_polyline_field(pts, below_pts, min_x, min_z, vs, gw, gh, reach)
	var lat_arr: PackedFloat32Array = fld[0]
	var by_arr: PackedFloat32Array = fld[1]
	var al_arr: PackedFloat32Array = fld[2]
	var gr_arr: PackedFloat32Array = fld[3]
	var total: float = fld[4]
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
			var i := row + ix
			var lat := lat_arr[i]
			if lat > reach:
				continue
			var x := min_x + ix * vs
			var pos := Vector3(x, 0.0, z)
			# ground = geometry-driven below-layer ground at the nearest spline point (Option B), matching
			# the native path; falls back to the per-cell below height where no spline ground is available.
			var gs := gr_arr[i]
			var ground: float = gs if is_finite(gs) else _base_height_below(pos)
			var bed_y: float = (by_arr[i] if follow_spline_height else ground) - depth
			var wscale := 1.0
			if width_curve != null:
				wscale = maxf(width_curve.sample_baked(clampf(al_arr[i] / total, 0.0, 1.0)), 0.0)
			var bed_hw := bed_half_width * wscale
			var span := (bed_half_width + bank_width) * wscale
			if lat > span + falloff:
				continue
			# Bank reach: FIXED_WIDTH spans the whole half-width; SLOPE_ANGLE rises at the angle to ground.
			# Flat bed keeps a level floor of bed_hw then ramps; basin ramps from the centreline.
			var bank_floor := bed_hw if flat_bed else 0.0
			var w_eff := span
			if use_angle:
				w_eff = clampf(bank_floor + absf(ground - bed_y) / slope_tan, bank_floor, span)
			var h: float
			if flat_bed and lat <= bed_hw:
				h = bed_y
			elif lat <= w_eff:
				var t := (lat - bank_floor) / maxf(w_eff - bank_floor, 0.001)
				h = lerpf(bed_y, ground, _ramp(bank_profile, t))
			else:
				h = ground
			if noise and h < ground:
				# Lift the banks a little for a natural edge, never above the surrounding terrain. Mask by
				# the local carve (ground - bed_y) so it fades to nothing at the rim, deepest in the bed.
				var mask := clampf((ground - h) / maxf(ground - bed_y, 0.001), 0.0, 1.0)
				h = minf(h + noise_strength * noise.get_noise_2d(x, z) * mask, ground)
			vals[i] = (h - ground) if add else h

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


func make_descend() -> void:
	# Gather the clamps first so we can register a single undoable action. Walk each curve carrying the
	# running (already-clamped) previous Y, so a run of rising points all collapse to the first's level.
	var old_points: Array = [] # [curve, index, original_position]
	var new_points: Array = [] # [curve, index, clamped_position]
	for s in _get_splines():
		var c: Curve3D = s.curve
		if c == null or c.point_count == 0:
			continue
		var prev_y := c.get_point_position(0).y
		for i in range(1, c.point_count):
			var p := c.get_point_position(i)
			if p.y > prev_y:
				old_points.append([c, i, p])
				new_points.append([c, i, Vector3(p.x, prev_y, p.z)])
			else:
				prev_y = p.y
	if new_points.is_empty():
		return
	var ur := _editor_undo()
	if ur:
		ur.create_action("Make %s Descend" % _spline_basename())
		ur.add_do_method(self, "_set_curve_points_and_repaint", new_points)
		ur.add_undo_method(self, "_set_curve_points_and_repaint", old_points)
		ur.commit_action() # executes the do method now (applies the clamps + repaints)
	else:
		_set_curve_points_and_repaint(new_points)
