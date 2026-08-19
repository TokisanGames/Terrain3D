# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRidge — spline-as-crest hill / mountain / ridge brush. Raises the terrain under and along
# each (usually open) spline, the spline acting as the ridge crest, with a cross-section shaped by a
# profile Curve. Pasture3D's raise-side analogue of UE5's Landmass river brush. To CARVE a channel /
# river along a spline use Pasture3DTrough instead — it adds a flat bed, bank run and carve defaults.
#
# The cross-section is a TWO-reference drape: the crest sits at the spline (follow) or terrain + height,
# and the flank descends from the crest down to the ACTUAL terrain surface at every point — either over
# a fixed width or at a fixed slope angle. See PASTURE3D_RIDGE_TROUGH_FLANK_SPEC.md. Paints non-
# destructively into a reserved layer via the Pasture3DTerrainBrush base.
@tool
@icon("res://addons/pasture_3d/icons/brush_ridge.svg")
class_name Pasture3DRidge
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }
## How the flank reaches the terrain: FIXED_WIDTH spreads over `width`; SLOPE_ANGLE descends at
## `slope_angle` until it meets the ground (reach capped by `width`).
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }

@export_group("Shape")
## Extra lift of the crest above its reference. With Follow Spline Height on the spline IS the crest, so
## this is an optional bonus height (default 0). With it off the crest sits this far above the terrain.
@export var crest_height: float = 0.0:
	set(v):
		crest_height = v
		_schedule_refresh()
## Half-width: lateral reach from the centreline to the skirt edge (and the max reach in Slope Angle).
@export var width: float = 25.0:
	set(v):
		width = v
		_schedule_refresh()
## FIXED_WIDTH = flank spreads over `width`; SLOPE_ANGLE = flank descends at `slope_angle` to terrain.
@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH:
	set(v):
		flank_mode = v
		_schedule_refresh()
		notify_property_list_changed() # show/hide slope_angle
## Slope-angle mode only: degrees the flank descends from the crest before it meets the terrain.
@export_range(1.0, 89.0, 0.5) var slope_angle: float = 30.0:
	set(v):
		slope_angle = clampf(v, 1.0, 89.0)
		_schedule_refresh()
## MAX = mountain ridge (raise-only, default); ADD = additive; MIN/REPLACE for special cases.
@export var blend_mode: BlendMode = BlendMode.MAX:
	set(v):
		blend_mode = v
		_schedule_refresh() # re-bake so the new blend takes effect immediately (and undo-coherently)
## Flip the sign (lower instead of raise).
@export var invert: bool = false:
	set(v):
		invert = v
		_schedule_refresh()
## Cross-section: centre (t=0) = 1 → skirt edge (t=1) = 0. Default = rounded cosine.
@export var profile: Curve:
	set(v):
		profile = v
		_schedule_refresh()
## Optional taper along the spline: sampled start (x=0) → end (x=1), multiplies `width` per point so the
## ridge can fan wide in the middle and pinch at the ends. Null = constant width. Crest height is not
## scaled. (Closed rings wrap 0→1 around the perimeter with a small seam at the join.)
@export var width_curve: Curve:
	set(v):
		if width_curve != null and width_curve.changed.is_connected(_schedule_refresh):
			width_curve.changed.disconnect(_schedule_refresh)
		width_curve = v
		if width_curve != null and not width_curve.changed.is_connected(_schedule_refresh):
			width_curve.changed.connect(_schedule_refresh)
		_schedule_refresh()

@export_group("Crest line")
## Connect the last point back to the first, forming a closed ring ridge instead of an open line.
@export var closed: bool = false:
	set(v):
		closed = v
		_schedule_refresh() # re-bake so the ring closes/opens immediately (and undo-coherently)
		if is_inside_tree():
			update_gizmos() # redraw the loop wrap segment + tangents
## Crest follows the spline's own Y (true) or the terrain height + crest_height (false). Either way the
## flank now drapes down to the real terrain surface, so the skirt always meets the ground.
@export var follow_spline_height: bool = true:
	set(v):
		follow_spline_height = v
		_schedule_refresh()

@export_group("Noise")
@export var noise: FastNoiseLite:
	set(v):
		noise = v
		_schedule_refresh()
## Vertical jitter along the ridgeline (mountain-range feel), masked by the cross-section.
@export var noise_strength: float = 0.0:
	set(v):
		noise_strength = v
		_schedule_refresh()

@export_group("Falloff")
## Extra skirt beyond the flank reach that feathers a non-zero profile edge into the terrain.
@export var falloff: float = 10.0:
	set(v):
		falloff = v
		_schedule_refresh()

@export_group("Smoothing")
## Passes of NaN-aware separable Gaussian blur applied after rasterisation to remove chamfer-DT
## octagonal isocontour artefacts that appear as surface faceting when diff is large (e.g. an
## elevated spline point over flat terrain). 0 = off, 1-2 = typical, 3+ = heavy.
@export_range(0, 5) var smooth_passes: int = 0:
	set(v):
		smooth_passes = v
		_schedule_refresh()


func _default_layer_name() -> String:
	return "Ridges"


func _default_snap_to_surface() -> bool:
	return false # ridges author a vertical crest line; the flank drapes to terrain on its own


func _get_blend_mode() -> int:
	return int(blend_mode)


func _spline_basename() -> String:
	return "Ridge"


func _is_closed() -> bool:
	return closed


func _padding() -> float:
	return width + falloff + 2.0


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

	# Native rasteriser (Round 2): same polyline field + per-cell crest math in C++. GDScript reference
	# below for builds without it (and the A/B oracle via force_gdscript_raster).
	if _native_raster("stamp_ridge_line"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"crest_height": crest_height, "width": width, "falloff": falloff,
			"invert": invert, "follow_spline_height": follow_spline_height,
			"flank_mode": int(flank_mode), "slope_tan": tan(deg_to_rad(slope_angle)),
			"blend": _blend, "composite": not _defer_composite,
			"noise": noise, "noise_strength": noise_strength,
			"smooth_passes": smooth_passes,
			# Per-point terrain heights for ground_ref interpolation in C++ (O(npts) vs O(cells)).
			"base_below_pts": _below_pts(pts),
		}
		if width_curve != null:
			params["width_lut"] = _ramp_lut(width_curve)
		terrain.data.stamp_ridge_line(_layer_id, pts, _clip_aabb, params, _ridge_cross_lut(profile))
		return

	# Exact closest-point-on-segment field (mirrors the native ds==1 path): per cell the lateral distance,
	# the crest Y at the nearest point, the arc length, and the geometry-driven ground_ref (base_below
	# interpolated from the spline points). Exact = no chamfer angular error or Voronoi seams, so this is an
	# exact A/B oracle of the C++ rasteriser (no arc-length re-interpolation needed).
	var reach := width + falloff
	var below_pts := _below_pts(pts)
	var fld := _exact_polyline_field(pts, below_pts, min_x, min_z, vs, gw, gh, reach)
	var lat_arr: PackedFloat32Array = fld[0]
	var by_arr: PackedFloat32Array = fld[1]
	var al_arr: PackedFloat32Array = fld[2]
	var gr_arr: PackedFloat32Array = fld[3]
	var total: float = fld[4]
	var has_gr := gr_arr.size() == gw * gh
	var signed_crest := -crest_height if invert else crest_height
	var use_angle := flank_mode == FlankMode.SLOPE_ANGLE
	var slope_tan := maxf(tan(deg_to_rad(slope_angle)), 0.0001)
	var edge_val := _ridge_cross(profile, 1.0) # profile value at the skirt edge, feathered out over `falloff`
	# Buffer all ridge contributions (delta above ground) before writing so the smoothing pass can run.
	var delta_vals := PackedFloat32Array(); delta_vals.resize(gw * gh); delta_vals.fill(NAN)

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
			var ground: float = _base_height_below(pos)
			# ground_ref: terrain under the spline at this cell's arc-length (smooth, Option B).
			# Falls back to per-cell ground when base_below isn't available.
			var ground_ref: float = ground
			if has_gr:
				var gs: float = gr_arr[i]
				if is_finite(gs):
					ground_ref = gs
			var crest_top: float = (by_arr[i] if follow_spline_height else ground_ref) + signed_crest
			var w := width
			if width_curve != null:
				w *= maxf(width_curve.sample_baked(clampf(al_arr[i] / total, 0.0, 1.0)), 0.0)
			var diff := crest_top - ground_ref
			var w_eff := w
			if use_angle:
				w_eff = clampf(absf(diff) / slope_tan, 0.0, w)
			if w_eff <= 0.0:
				continue
			if lat > w_eff + falloff:
				continue
			var p: float
			if lat <= w_eff:
				p = _ridge_cross(profile, lat / w_eff)
			else:
				p = edge_val * (1.0 - clampf((lat - w_eff) / maxf(falloff, 0.001), 0.0, 1.0))
			if p > 0.0:
				var delta := diff * p
				if noise:
					delta += noise_strength * noise.get_noise_2d(x, z) * p
				delta_vals[i] = delta

	# NaN-aware separable 3-tap Gaussian blur (shared helper; same as C++ path).
	delta_vals = _blur_grid(delta_vals, gw, gh, smooth_passes)

	# Write-back: ground + blurred delta.
	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var delta: float = delta_vals[row + ix]
			if not is_finite(delta):
				continue
			var x := min_x + ix * vs
			var pos := Vector3(x, 0.0, z)
			var ground: float = _base_height_below(pos)
			# ADD writes the delta above the ground; the absolute paths write the draped height.
			_paint_height(pos, ground + delta, delta)
