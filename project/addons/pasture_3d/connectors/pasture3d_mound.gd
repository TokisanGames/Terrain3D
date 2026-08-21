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

# ---- Legacy property migration (PASTURE3D_BRUSH_EROSION_SPEC.md §6.6) ------------------------------
#
# `noise`, `noise_strength`, `relief`, `relief_strength` and `smooth_passes` were deleted at the end of
# phase 3a; the Modifiers stack replaces them. Scenes saved before that still carry the old keys, so
# loading one would otherwise drop a mound's relief on the floor without a word.
#
# This is a ONE-WAY MIGRATION, not a second spelling of the same thing. There is no getter, the
# properties are absent from `_get_property_list` so nothing re-saves them, and a `set()` after the node
# is in the tree is an error rather than a quiet no-op. Delete this block once the scenes in the repo
# have been opened and saved.
const _LEGACY_PROPS := ["noise", "noise_strength", "relief", "relief_strength", "smooth_passes"]

## Legacy values seen during scene load, flushed into `modifiers` by `_ready`. Not exported, so nothing
## about it survives a save.
var _legacy: Dictionary = {}


func _set(property: StringName, value: Variant) -> bool:
	if _LEGACY_PROPS.has(String(property)):
		if _ready_done:
			# Not silent: a script still assigning these is assigning to nothing, and the failure mode
			# that hides is "my relief stopped appearing and no one said why".
			push_error(("Pasture3DMound.%s was removed in phase 3a. Build a Pasture3DModRelief / "
				+ "Pasture3DModNoise / Pasture3DModSmooth and put it in `modifiers` instead.") % property)
			return true
		_legacy[String(property)] = value
		return true
	return super(property, value)


func _ready() -> void:
	super()
	_migrate_legacy()


## Turn the stashed legacy values into the stack they describe, in the order the old pipeline ran them:
## noise, then relief, then smoothing. A value that would have contributed nothing (no material, zero
## strength, zero passes) becomes no modifier at all rather than a disabled one — an empty step in the
## list would be a worse description of the old behaviour than its absence.
func _migrate_legacy() -> void:
	if _legacy.is_empty():
		return
	var old := _legacy
	_legacy = {}
	if not modifiers.is_empty():
		push_warning(("Pasture3DMound '%s' carries BOTH a Modifiers stack and the removed noise / relief "
			+ "properties. The stack wins; the old values were dropped.") % name)
		return
	var out: Array[Pasture3DBrushModifier] = []
	var n_strength := float(old.get("noise_strength", 0.0))
	if old.get("noise", null) != null and not is_zero_approx(n_strength):
		var mn := Pasture3DModNoise.new()
		mn.noise = old["noise"]
		mn.strength = n_strength
		out.append(mn)
	var r_strength := float(old.get("relief_strength", 0.0))
	if old.get("relief", null) != null and not is_zero_approx(r_strength):
		var mr := Pasture3DModRelief.new()
		mr.material = old["relief"]
		mr.strength = r_strength
		out.append(mr)
	var passes := int(old.get("smooth_passes", 0))
	if passes > 0:
		var ms := Pasture3DModSmooth.new()
		ms.passes = passes
		out.append(ms)
	if out.is_empty():
		return
	modifiers = out
	push_warning(("Pasture3DMound '%s': the removed noise / relief / smoothing properties were migrated "
		+ "into a %d-step Modifiers stack. Save the scene to make that permanent.") % [name, out.size()])


func _validate_property(property: Dictionary) -> void:
	# Fixed-width and slope-angle drive the same ramp; only one is meaningful at a time.
	if property.name == "slope_angle" and flank_mode != FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == "falloff_width" and flank_mode == FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## A Mound generates a dome, so its own shape is a field a selector or a band op can read. This is what
## makes "craggy on the flanks, smooth on top" expressible here and not on a Plow.
func _offers_host_profile() -> bool:
	return true


func _get_configuration_warnings() -> PackedStringArray:
	# Every relief complaint now comes from the Relief modifier that owns the material — the base folds
	# `_modifier_warnings()` in, and Pasture3DModRelief calls `_relief_warnings` from there.
	return super()


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

	# ---- What this bake needs, compiled from the MODIFIER STACK once (never per cell). An empty stack
	# leaves every field below empty or false, and the brush stamps its bare profile — which is exactly
	# what a Mound with nothing configured should do.
	var extent := _extent_key(min_x, min_z, vs, gw, gh)

	# Oriented loop frame. Mapping is always TILE here — the ops read world XZ — but the normalised
	# coordinates radial ops use come from this frame, so a Crater is still sized and turned by the loop.
	#
	# Computed BEFORE the stack compiles, and asked of the modifier list rather than of the compiled stack,
	# because a material with a BAKED FIELD (a DLA) grows that field to the loop's proportions and does it
	# inside compile(). Handing the frame over afterwards is handing it over one bake late — which for a
	# material that only regrows when the shape changes means never.
	var wants_frame := _has_relief_modifier()
	var frame: Array = _loop_frame(poly) if wants_frame else [0.0, 0.0, 1.0, 0.0, 1.0, 1.0]
	var stack := _compile_modifiers(extent, frame[4], frame[5])
	var op_selectors: PackedFloat32Array = stack["op_selectors"]
	var use_fields := bool(stack["need_fields"])
	var use_host := bool(stack["need_host"])
	var sim_res: Pasture3DSimResult = stack["sim"]
	var fcx: float = frame[0]
	var fcz: float = frame[1]
	var fcos: float = frame[2]
	var fsin: float = frame[3]
	var inv_ex := 1.0 / maxf(frame[4], 0.001)
	var inv_ez := 1.0 / maxf(frame[5], 0.001)

	var fields: Array = _terrain_fields(min_x, min_z, vs, gw, gh) if use_fields else []
	# §21.6: the wider grids any selector's `measure_radius` asks for, indexed by selector id. Empty when
	# every selector left it at 0, which is the default.
	var measured: Array = _measured_fields(fields[0], fields[2], op_selectors, vs, gw, gh,
			Pasture3DReliefSelector.FieldSource.BELOW_LAYER) if use_fields else []
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
			# The stack, and the ONE selector block every relief modifier in it indexes into.
			"modifiers": stack["list"], "op_selectors": op_selectors,
			"fit_cx": fcx, "fit_cz": fcz, "fit_cos": fcos, "fit_sin": fsin,
			"fit_ex": frame[4], "fit_ez": frame[5],
			"need_fields": use_fields, "sim_result": sim_dict,
			"need_host_fields": use_host,
		}
		# C++ derives the slope/curvature/gradient grids itself (same formula, same input, so the two paths
		# agree) — but only if it is handed the below-layer heights, which otherwise travel only when the
		# brush is stamping relative to the terrain.
		if relative_to_terrain or use_fields:
			params["base_below"] = _base_below_grid(min_x, min_z, vs, gw, gh)
		terrain.data.stamp_mound_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve))
		# The rasteriser writes each frozen modifier's solve into the `out` dictionary it was handed, so
		# there is something to collect the moment it returns.
		_commit_modifier_caches(stack, extent,
				[fcx, fcz, fcos, fsin, frame[4], frame[5], min_x, min_z, vs])
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

	# What gets written per cell (NaN = no write): a delta under ADD, an absolute target otherwise,
	# matching _paint_height and the C++ path for A/B parity. The stack produces it.
	var add := _blend == BLEND_ADD

	# This brush's OWN generated shape at one cell, before noise and before relief: `[amp_metres, profile]`,
	# or `[]` where it contributes nothing. Written once and called from both the host-profile pre-pass and
	# the cell loop, for the same reason the C++ path extracts it: a second copy of this arithmetic is how
	# the field a selector reads would quietly stop being the shape the brush stamps.
	var host_profile_at := func(signed_d: float) -> Array:
		if signed_d <= 0.0:
			return []
		if cone:
			return [sign * minf(slope_tan * signed_d, safety_max),
					clampf(signed_d / dome_denom, 0.0, 1.0)]
		var pr := _ramp(falloff_curve, signed_d / (ramp_denom if capped else dome_denom))
		if pr <= 0.0:
			return []
		return [sign * height * pr, pr]

	# The HOST PROFILE fields. A pre-pass over the WHOLE grid, because slope and curvature need
	# neighbours and so cannot be derived inside the loop that is producing the values. Mirrors the
	# pre-pass in stamp_mound_loop; gate BQ compares the two.
	var host_fields: Array = []
	var host_measured: Array = []
	var host_div := 1.0
	if use_host:
		var host_alt := PackedFloat32Array()
		host_alt.resize(gw * gh)
		var peak := 0.0
		for iz in range(gh):
			var row := iz * gw
			for ix in range(gw):
				# Outside the loop the brush contributes nothing, and 0 is the honest value there — it is
				# what makes the rim read as the foot of the slope rather than as a hole.
				var hp: Array = host_profile_at.call(field[row + ix] + edge_offset)
				var a: float = hp[0] if not hp.is_empty() else 0.0
				host_alt[row + ix] = a
				peak = maxf(peak, absf(a))
		host_fields = _derive_fields(host_alt, vs, gw, gh)
		# The divisor is the MEASURED peak, not the `height` property: an uncapped slope derives its height
		# from geometry and never reads `height`, and a capped mound whose falloff_width exceeds its
		# half-width never reaches full profile. See the same note in stamp_mound_loop.
		host_div = peak if peak > 0.0 else 1.0
		host_measured = _measured_fields(host_fields[0], host_fields[2], op_selectors, vs, gw, gh,
				Pasture3DReliefSelector.FieldSource.HOST_PROFILE)

	# Rasterise the profile into its own grids, then let the modifier stack run over them. The split is
	# not a tidier spelling of one fused loop: a FIELD modifier reads the whole grid, so the profile has
	# to be finished before any modifier can look at it.
	var amp := PackedFloat64Array()
	amp.resize(gw * gh)
	var profile := PackedFloat64Array()
	profile.resize(gw * gh)
	var basey := PackedFloat32Array()
	basey.resize(gw * gh)
	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			amp[row + ix] = NAN
			var signed_d := field[row + ix] + edge_offset
			if signed_d <= 0.0:
				continue
			var hp: Array = host_profile_at.call(signed_d)
			if hp.is_empty():
				continue
			var pos := Vector3(min_x + ix * vs, 0.0, z)
			amp[row + ix] = hp[0]
			profile[row + ix] = hp[1]
			basey[row + ix] = _base_height_below(pos) if relative_to_terrain else global_position.y
	var vals := _run_modifier_stack(stack["gd"], amp, profile, basey, {
		"gw": gw, "gh": gh, "min_x": min_x, "min_z": min_z, "vs": vs, "add": add,
		"fit_cx": fcx, "fit_cz": fcz, "fit_cos": fcos, "fit_sin": fsin,
		"inv_ex": inv_ex, "inv_ez": inv_ez,
		"fields": fields, "sim_fields": sim_fields, "measured": measured,
		"host_fields": host_fields, "host_measured": host_measured, "host_div": host_div,
		"extent": extent,
	})
	_commit_modifier_caches(stack, extent,
			[fcx, fcz, fcos, fsin, frame[4], frame[5], min_x, min_z, vs])

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


## True when the stack holds at least one active Relief modifier, i.e. when the oriented loop frame is
## worth computing. A stack of noise and smoothing alone never reads it.
##
## Asks the MODIFIER LIST and not the compiled stack, because the frame is now an input to the compile
## (see the bake) — and `is_active()` is the same test `_compile_modifiers` skips on, so the two agree.
## A relief step that compiles to nothing but is waiting for a seed surface still counts, and should:
## it is about to be handed one, and it will grow its field against this frame when it is.
func _has_relief_modifier() -> bool:
	for m in modifiers:
		if m is Pasture3DModRelief and m.is_active():
			return true
	return false


## Phase 3a wires the modifier stack into this rasteriser and no other (§6.6).
func _supports_modifiers() -> bool:
	return true


func _update_mask_preview() -> void:
	_update_relief_mask_preview(_preview_relief_material() if _mask_preview_on else null)


## §18.6: the material whose selectors the Mask Preview Source dropdown lists — the first Relief modifier
## in the stack WITH A MATERIAL ASSIGNED. The overlay shows one material's selectors, and a stack with two
## of them has to pick; first is the honest pick, because it is the one whose gating decides what
## everything after it lands on.
##
## NOT `is_active()`, which was the first build and was wrong twice over. `is_active()` is false at
## `strength == 0`, so this dropdown — and therefore the node's whole property list — was A FUNCTION OF A
## SLIDER: dragging Strength up from 0 made the Mask Preview group appear, which rebuilt the inspector,
## which collapsed the modifier being edited, under the cursor. Toggling `enabled` did the same. See
## `_inspector_rebuild_signature`.
##
## It is also the better rule on its own terms: the preview exists to show WHERE a selector would put
## things, which is exactly what you want to look at before you decide how many metres to ask for.
## `_mask_preview_warnings` says so when the previewed modifier is not currently stamping.
func _preview_relief_material():
	for m in modifiers:
		if m is Pasture3DModRelief and m.material != null:
			return m.material
	return null


## The Relief modifier `_preview_relief_material` picked, so the warnings can talk about it by name.
func _preview_relief_modifier():
	for m in modifiers:
		if m is Pasture3DModRelief and m.material != null:
			return m
	return null
