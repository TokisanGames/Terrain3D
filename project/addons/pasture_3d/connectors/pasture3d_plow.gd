# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPlow — closed-loop spline HEIGHT brush driven by a "material" (a displacement source). The
# loop is an area mask with falloff; inside it the chosen source's relief is stamped into the height
# map, tiling across the area and feathering back to the existing ground at the rim. Drop it on flat
# ground to generate small hills, dunes, or a craggy surface. It is the height-map twin of
# Pasture3DSplat (which paints WHICH texture shows) and the Pasture3D analogue of how UE5 Landmass
# custom brushes render a material into the landscape heightmap. See PASTURE3D_PLOW_BRUSH_SPEC.md.
#
# Paints non-destructively into a reserved HEIGHT layer via the Pasture3DTerrainBrush base, so it gets
# layer-sharing, undo, surface-snap and the clear-then-snap climbing-fix for free.
@tool
@icon("res://addons/pasture_3d/icons/brush_plow.svg")
class_name Pasture3DPlow
extends Pasture3DTerrainBrush

enum Source { NOISE, TEXTURE, MATERIAL, RELIEF }
enum BlendMode { REPLACE, ADD, MAX, MIN }
## How the source is laid out across the loop. TILE repeats across world space (craggy sections, strata);
## FIT maps the source once onto the loop's oriented bounding rect (one crater per loop); SCATTER places
## N jittered instances inside the loop (a crater field, boulders — and the standard fix for the
## repetition TILE has). SCATTER requires Source = RELIEF.
## See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §6.
enum Mapping { TILE, FIT, SCATTER }
## How overlapping scatter instances combine. STRONGEST keeps whichever is furthest from flat, so two
## overlapping craters merge into the deeper one instead of cancelling or doubling.
enum ScatterBlend { STRONGEST, ADD, MAX, MIN }

# A height source is normalised to [0,1] then biased by `height_offset` so mid-grey = no change and the
# relief goes up AND down. Cap the LUT resolution: terrain relief never needs more than this per tile,
# and it keeps the per-bake image read fast regardless of source texture size.
const _LUT_MAX := 256

@export_group("Relief")
## Which displacement source deforms the ground (see spec §3). The matching input appears just below.
@export var source: Source = Source.NOISE:
	set(v):
		source = v
		notify_property_list_changed() # show only the active source's input
		_schedule_refresh()
## Source.NOISE — procedural relief (ridged/cellular = craggy, Perlin/Simplex = rolling hills).
@export var noise: FastNoiseLite:
	set(v):
		noise = v
		_schedule_refresh()
## Source.TEXTURE — a tiling grayscale heightmap (red channel). Prefer a Lossless/uncompressed import.
@export var height_texture: Texture2D:
	set(v):
		height_texture = v
		_schedule_refresh()
## Source.MATERIAL — a dedicated Pasture3DPlowMaterial (a reusable brush material, independent of the
## terrain's surface textures). Create or load one here, then set its height map.
@export var plow_material: Pasture3DPlowMaterial:
	set(v):
		if plow_material != null and plow_material.changed.is_connected(_schedule_refresh):
			plow_material.changed.disconnect(_schedule_refresh)
		plow_material = v
		if plow_material != null and not plow_material.changed.is_connected(_schedule_refresh):
			plow_material.changed.connect(_schedule_refresh)
		_schedule_refresh()
## Source.RELIEF — a Pasture3DReliefMaterial: procedural landform relief (craggy fractal, crater, or a
## stack of both). This is the default for newly placed brushes.
@export var relief: Pasture3DReliefMaterial:
	set(v):
		if relief != null and relief.changed.is_connected(_schedule_refresh):
			relief.changed.disconnect(_schedule_refresh)
		relief = v
		if relief != null and not relief.changed.is_connected(_schedule_refresh):
			relief.changed.connect(_schedule_refresh)
		# Separate from the re-bake: a material emits `changed` when its Selector's band moves, and the
		# overlay has to follow that as you drag it, not only when the toggle is flipped.
		if relief != null and not relief.changed.is_connected(_queue_mask_preview):
			relief.changed.connect(_queue_mask_preview)
		notify_property_list_changed() # the Mask Preview Source list is built from this material
		_queue_mask_preview()
		update_configuration_warnings()
		_schedule_refresh()
## How the source is laid out across the loop (TILE repeats; FIT maps it once onto the loop's oriented
## rect). Craters need FIT. Hidden for NOISE, which is world-space by definition.
@export var mapping: Mapping = Mapping.TILE:
	set(v):
		mapping = v
		update_configuration_warnings()
		_schedule_refresh()
## Metres of relief across the source's range (peak-to-trough at full mask).
@export var height_scale: float = 8.0:
	set(v):
		height_scale = v
		_schedule_refresh()
## Sample value treated as "no change". 0.5 = mid-grey neutral → relief rises and sinks symmetrically.
@export_range(0.0, 1.0) var height_offset: float = 0.5:
	set(v):
		height_offset = clampf(v, 0.0, 1.0)
		_schedule_refresh()
## Metres per repeat when tiling a TEXTURE / MATERIAL source across the area.
@export var tile_size: float = 16.0:
	set(v):
		tile_size = maxf(v, 0.01)
		_schedule_refresh()
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

@export_group("Scatter")
## How many instances to place inside the loop. Placement is deterministic from Scatter Seed.
@export_range(1, 256) var scatter_count: int = 12:
	set(v):
		scatter_count = maxi(v, 1)
		_schedule_refresh()
@export var scatter_seed: int = 0:
	set(v):
		scatter_seed = v
		_schedule_refresh()
## Smallest / largest instance radius, in metres.
@export_range(0.5, 256.0, 0.5, "or_greater") var scatter_radius_min: float = 8.0:
	set(v):
		scatter_radius_min = maxf(v, 0.1)
		_schedule_refresh()
@export_range(0.5, 256.0, 0.5, "or_greater") var scatter_radius_max: float = 24.0:
	set(v):
		scatter_radius_max = maxf(v, 0.1)
		_schedule_refresh()
## 0 = every instance keeps the material's own orientation; 1 = free rotation.
@export_range(0.0, 1.0, 0.01) var scatter_rotation_jitter: float = 1.0:
	set(v):
		scatter_rotation_jitter = clampf(v, 0.0, 1.0)
		_schedule_refresh()
## Random variation in each instance's strength, ± this fraction.
@export_range(0.0, 1.0, 0.01) var scatter_scale_jitter: float = 0.25:
	set(v):
		scatter_scale_jitter = clampf(v, 0.0, 1.0)
		_schedule_refresh()
## 0 = instances may not overlap at all (placement rejects clashes); 1 = overlap freely. Low values with
## a high count can exhaust the placement attempt budget — the brush warns when that happens.
@export_range(0.0, 1.0, 0.01) var scatter_overlap: float = 0.0:
	set(v):
		scatter_overlap = clampf(v, 0.0, 1.0)
		_schedule_refresh()
@export var scatter_blend: ScatterBlend = ScatterBlend.STRONGEST:
	set(v):
		scatter_blend = v
		_schedule_refresh()

@export_group("Mask")
## Metres from the loop edge inward over which the relief fades to flat (seamless with the surrounds).
@export var falloff_width: float = 10.0:
	set(v):
		falloff_width = v
		_schedule_refresh()
## Optional 0→1 falloff shape (default = smoothstep).
@export var falloff_curve: Curve:
	set(v):
		falloff_curve = v
		_schedule_refresh()
## Expand (+) / contract (−) the masked area off the spline, in metres.
@export var edge_offset: float = 0.0:
	set(v):
		edge_offset = v
		_schedule_refresh()

@export_group("Smoothing")
## Passes of NaN-aware separable Gaussian blur applied after rasterisation, to soften the stamped relief
## and any chamfer-DT faceting. 0 = off (no cost), 1-2 = subtle, 3+ = heavy rounding.
@export_range(0, 5) var smooth_passes: int = 0:
	set(v):
		smooth_passes = v
		_schedule_refresh()


func _default_layer_name() -> String:
	return "Plow"


func _get_blend_mode() -> int:
	return int(blend_mode)


## Pasture3DPlow has no `invert` of its own — the stamp's sign lives on the material it renders, and only
## in MATERIAL / RELIEF mode (NOISE and TEXTURE have no inversion to read). Drives the Add Water button's
## raise check; see PASTURE3D_WATER_BODIES_SPEC.md §7.8.
func _raise_inverted() -> bool:
	if source == Source.MATERIAL:
		return plow_material != null and plow_material.invert
	if source == Source.RELIEF:
		return relief != null and not relief._raises()
	return false


func _min_points() -> int:
	return 3


func _spline_basename() -> String:
	return "Area"


func _padding() -> float:
	return maxf(edge_offset, 0.0) + 2.0


## Show only the input that belongs to the active Source, and hide the knobs that source cannot use.
func _validate_property(property: Dictionary) -> void:
	match property.name:
		"noise":
			if source != Source.NOISE:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"height_texture":
			if source != Source.TEXTURE:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"plow_material":
			if source != Source.MATERIAL:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"relief":
			if source != Source.RELIEF:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"mapping":
			if source == Source.NOISE: # world-space by definition; nothing to lay out
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"height_offset":
			if source == Source.RELIEF: # relief materials output a signed value already
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"tile_size":
			# NOISE tiles via its own frequency, relief ops carry their own feature size, and FIT maps
			# the source exactly once — in none of those cases does a metres-per-repeat mean anything.
			if source == Source.NOISE or source == Source.RELIEF or mapping != Mapping.TILE:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"scatter_count", "scatter_seed", "scatter_radius_min", "scatter_radius_max", \
		"scatter_rotation_jitter", "scatter_scale_jitter", "scatter_overlap", "scatter_blend":
			if mapping != Mapping.SCATTER:
				property.usage &= ~PROPERTY_USAGE_EDITOR


## Starter shape: a closed square loop in local space (same as Splat/Mound).
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	var r := 20.0
	c.add_point(Vector3(-r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, r))
	c.add_point(Vector3(-r, 0.0, r))
	return c


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := super()
	if source == Source.RELIEF:
		if relief == null:
			warnings.append("Source is Relief but no Relief Material is assigned — nothing will be stamped.")
		else:
			# The material's own complaint, the sim-selector diagnostics (PASTURE3D_SIM_NODE_SPEC.md §9)
			# and the periodic-resolution guard — all shared with the other relief hosts.
			warnings.append_array(_relief_warnings(relief))
			if mapping == Mapping.TILE and _relief_has_crater_op(relief):
				warnings.append(("This Relief Material contains a Crater, which is sized by the loop. "
					+ "With Mapping = Tile it repeats once per tile; set Mapping = Fit for a single crater."))
	elif mapping == Mapping.SCATTER:
		warnings.append(("Mapping = Scatter only applies to Source = Relief; this source will tile "
			+ "instead. Switch the source, or pick Tile / Fit."))
	if mapping == Mapping.SCATTER:
		if scatter_radius_min > scatter_radius_max:
			warnings.append("Scatter Radius Min is larger than Radius Max — no instances will be placed.")
		elif _scatter_shortfall > 0:
			warnings.append(("Scatter placed only %d of %d instances before running out of attempts. "
				+ "Raise Scatter Overlap, shrink the radii, or lower the count.")
				% [scatter_count - _scatter_shortfall, scatter_count])
	return warnings


## The one Pasture3DSimResult this bake reads, or null. Resolved from the compiled material tree's
## selectors, because §9 puts the reference on the SELECTOR, not on the brush. The resolution itself lives
## on the base (shared with Pasture3DMound); this only adds the source gate.
##
## A bake takes ONE result. Several layers gated on several different sims is a coherent thing to want
## and a disproportionate thing to support — it would mean a set of sampled grids per bake indexed by
## selector, for a case nobody has yet asked for. So the first wins and the brush warns by name, which
## is a great deal better than silently gating one layer on another sim's channels.
func _sim_result_for() -> Pasture3DSimResult:
	if source != Source.RELIEF:
		return null
	return _relief_sim_result(relief)


## How many instances the last scatter placement fell short by (0 = all placed). Drives the warning above.
var _scatter_shortfall := 0


## Deterministic dart-throwing placement inside the loop. Runs ONCE per bake in GDScript — C++ only
## evaluates what this produces — so the placement stays easy to read and debug, and identical on both
## paths by construction. Returns a stride-6 table: [cx, cz, radius, cos_rot, sin_rot, amp_scale].
## Attempts are capped so an impossible request (many large non-overlapping instances in a tight loop)
## terminates with a warning instead of spinning.
func _place_scatter(poly: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	_scatter_shortfall = scatter_count
	var r_min := minf(scatter_radius_min, scatter_radius_max)
	var r_max := maxf(scatter_radius_min, scatter_radius_max)
	if scatter_radius_min > scatter_radius_max:
		return out
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.y)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.y)

	var rng := RandomNumberGenerator.new()
	rng.seed = scatter_seed
	var placed: Array[Vector3] = [] # (x, z, radius)
	var attempts := 0
	var cap := scatter_count * 32
	while placed.size() < scatter_count and attempts < cap:
		attempts += 1
		var px := rng.randf_range(mn.x, mx.x)
		var pz := rng.randf_range(mn.y, mx.y)
		var r := rng.randf_range(r_min, r_max)
		if not Geometry2D.is_point_in_polygon(Vector2(px, pz), poly):
			continue
		if scatter_overlap < 1.0:
			var clash := false
			for q in placed:
				if Vector2(px - q.x, pz - q.y).length() < (r + q.z) * (1.0 - scatter_overlap):
					clash = true
					break
			if clash:
				continue
		placed.append(Vector3(px, pz, r))
		var rot := rng.randf() * TAU * scatter_rotation_jitter
		out.append(px)
		out.append(pz)
		out.append(r)
		out.append(cos(rot))
		out.append(sin(rot))
		out.append(1.0 + (rng.randf() * 2.0 - 1.0) * scatter_scale_jitter)
	_scatter_shortfall = scatter_count - placed.size()
	return out


## Combine every scatter instance covering this point. Mirrors relief_scatter_eval in C++ — the C++ side
## buckets instances spatially, but visits the same set in the same ascending order, so the two agree.
func _scatter_eval(x: float, z: float, inst: PackedFloat32Array, alt: float = 0.0,
		slope_deg: float = 0.0, curv: float = 0.0, gx: float = 0.0, gz: float = 0.0,
		flow: float = 0.0, ero: float = 0.0, dep: float = 0.0, wet: float = 0.0,
		measured: Array = [], fi: int = -1) -> float:
	var has := false
	var acc := 0.0
	for i in range(inst.size() / 6):
		var b := i * 6
		var r := maxf(inst[b + 2], 0.001)
		var dx := x - inst[b]
		var dz := z - inst[b + 1]
		var c := inst[b + 3]
		var s := inst[b + 4]
		var lx := dx * c + dz * s
		var lz := -dx * s + dz * c
		var inv := 1.0 / r
		var nu := lx * inv
		var nv := lz * inv
		var rad := sqrt(nu * nu + nv * nv)
		if rad >= 1.0:
			continue
		# Window the outer 10% to zero so a non-radial material fades out instead of stamping a hard disc.
		var val := relief.eval(lx, lz, nu, nv, inv, inv, alt, slope_deg, curv, gx, gz,
				flow, ero, dep, wet, measured, fi) * inst[b + 5] * smoothstep(1.0, 0.9, rad)
		if not has:
			acc = val
			has = true
			continue
		match scatter_blend:
			ScatterBlend.ADD: acc += val
			ScatterBlend.MAX: acc = maxf(acc, val)
			ScatterBlend.MIN: acc = minf(acc, val)
			_: # STRONGEST — whichever is furthest from flat
				if absf(val) > absf(acc):
					acc = val
	return acc if has else 0.0


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

	# Resolve the height source ONCE (decompress + cache the LUT for TEXTURE/MATERIAL, compile the op
	# program for RELIEF). Bail if the active source has nothing to read — nothing to stamp. Shared by the
	# native path and the fallback.
	var lut := _load_height_lut()
	var lut_w: int = lut[1]
	var lut_h: int = lut[2]
	var data: PackedFloat32Array = lut[0]
	var ops := PackedInt32Array()
	var op_params := PackedFloat32Array()
	var op_luts := PackedFloat32Array()
	var op_selectors := PackedFloat32Array()
	if source == Source.NOISE:
		if noise == null:
			return
	elif source == Source.RELIEF:
		if relief == null:
			return
		var prog: Array = relief.compile()
		ops = prog[0]
		op_params = prog[1]
		op_luts = prog[2]
		op_selectors = prog[3]
		if ops.is_empty():
			return
	elif data.is_empty():
		return

	# A plow / relief material can carry its own multiplier on top of Height Scale.
	var src_strength := 1.0
	if source == Source.MATERIAL and plow_material != null:
		src_strength = plow_material.strength
	elif source == Source.RELIEF:
		src_strength = relief.strength

	# Oriented loop frame — FIT maps the source onto it, and every mapping mode uses it for the
	# normalised coordinates that radial ops (craters) read.
	var frame := _loop_frame(poly)
	var fcx: float = frame[0]
	var fcz: float = frame[1]
	var fcos: float = frame[2]
	var fsin: float = frame[3]
	var inv_ex := 1.0 / maxf(frame[4], 0.001)
	var inv_ez := 1.0 / maxf(frame[5], 0.001)
	var fit := mapping == Mapping.FIT

	# Terrain-aware selectors and SCREE read the ground below this brush's layer. Built once per bake,
	# and only when the compiled program actually reads them.
	var fields: Array = []
	var use_fields := source == Source.RELIEF and _needs_terrain_fields(ops)
	# §21.6: plus the wider grids any selector's `measure_radius` asks for, indexed by selector id. Empty
	# when every selector left it at 0, which is the default and costs nothing.
	var measured: Array = []
	if use_fields:
		fields = _terrain_fields(min_x, min_z, vs, gw, gh)
		measured = _measured_fields(fields[0], fields[2], op_selectors, vs, gw, gh)
	# The sim channels the FLOW / EROSION / DEPOSITION / WETNESS Filter Types read (spec §9). Resampled from the
	# Pasture3DSimResult's own extent, which is at SIM resolution over the SIMULATED area and shares
	# nothing with this bake grid. Only when a selector actually asks for them.
	var sim_res := _sim_result_for() if use_fields else null
	var sim_fields: Array = []
	var sim_dict := {}
	if sim_res != null and sim_res.is_valid():
		sim_fields = _sim_fields(sim_res, min_x, min_z, vs, gw, gh)
		sim_dict = _sim_result_dict(sim_res)

	# SCATTER places its instances once per bake, here, so both paths evaluate the identical layout.
	# It only applies to RELIEF; other sources fall back to tiling (and the brush warns).
	var instances := PackedFloat32Array()
	var scattered := source == Source.RELIEF and mapping == Mapping.SCATTER
	if scattered:
		instances = _place_scatter(poly)
		if instances.is_empty():
			update_configuration_warnings()
			return
		update_configuration_warnings()

	# Native rasteriser (Round 2): same SDF + source-sample + relief math in C++.
	if _native_raster("stamp_plow_loop"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"height_scale": height_scale, "height_offset": height_offset,
			"edge_offset": edge_offset, "falloff_width": falloff_width,
			"relative_to_terrain": relative_to_terrain, "plane_y": global_position.y,
			"blend": _blend, "composite": not _defer_composite,
			"src_strength": src_strength, "tile_size": tile_size, "source": int(source),
			"data_w": lut_w, "data_h": lut_h, "noise": noise,
			"smooth_passes": smooth_passes,
			"ops": ops, "op_params": op_params, "op_luts": op_luts,
			"op_selectors": op_selectors, "mapping": int(mapping),
			"fit_cx": fcx, "fit_cz": fcz, "fit_cos": fcos, "fit_sin": fsin,
			"fit_ex": frame[4], "fit_ez": frame[5],
			"instances": instances, "scatter_blend": int(scatter_blend),
			"need_fields": use_fields, "sim_result": sim_dict,
		}
		# C++ derives the slope/curvature/gradient grids itself (the same formula on the same input, so
		# the two paths agree) — but it can only do that if it is handed the below-layer heights, which
		# otherwise only travel when the brush is stamping relative to the terrain.
		if relative_to_terrain or use_fields:
			params["base_below"] = _base_below_grid(min_x, min_z, vs, gw, gh)
		terrain.data.stamp_plow_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve), data)
		return

	# Same O(cells) area mask as Splat/Mound.
	var sdf := _signed_distance_field(poly, min_x, min_z, vs, gw, gh)
	var field: PackedFloat32Array = sdf[0]
	var ramp_denom := maxf(falloff_width, 0.001)
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
			var mask := _ramp(falloff_curve, signed_d / ramp_denom)
			if mask <= 0.0:
				continue
			var x := min_x + ix * vs
			# Loop-local metres, then the same point normalised to the frame's half-extents.
			var dx := x - fcx
			var dz := z - fcz
			var lx := dx * fcos + dz * fsin
			var lz := -dx * fsin + dz * fcos
			var amp: float
			if source == Source.RELIEF:
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
				var rv: float
				if scattered:
					rv = _scatter_eval(x, z, instances, f_alt, f_slope, f_curv, f_gx, f_gz,
							f_flow, f_ero, f_dep, f_wet, measured, row + ix if use_fields else -1)
				else:
					rv = relief.eval(lx if fit else x, lz if fit else z,
							lx * inv_ex, lz * inv_ez, inv_ex, inv_ez,
							f_alt, f_slope, f_curv, f_gx, f_gz, f_flow, f_ero, f_dep, f_wet,
							measured, row + ix if use_fields else -1)
				amp = height_scale * rv * mask * src_strength
			else:
				var v := _sample01(x, z, lx * inv_ex, lz * inv_ez, fit, data, lut_w, lut_h)
				amp = height_scale * (v - height_offset) * mask * src_strength
			if absf(amp) < 0.0001:
				continue
			var pos := Vector3(x, 0.0, z)
			var base_y: float = _base_height_below(pos) if relative_to_terrain else global_position.y
			vals[row + ix] = amp if add else base_y + amp

	vals = _blur_grid(vals, gw, gh, smooth_passes)

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


## Sample the active source at world XZ, normalised to [0,1]. NOISE maps [-1,1]→[0,1]; TEXTURE/MATERIAL
## read the cached LUT, either tiled by `tile_size` or — under FIT — mapped once across the loop's
## oriented rect, using the normalised loop coordinates `nu,nv`.
func _sample01(x: float, z: float, nu: float, nv: float, fit: bool, data: PackedFloat32Array,
		w: int, h: int) -> float:
	if source == Source.NOISE:
		return clampf(noise.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
	if data.is_empty() or w <= 0 or h <= 0:
		return height_offset # neutral → no change
	var u: float
	var t: float
	if fit:
		u = clampf(nu * 0.5 + 0.5, 0.0, 1.0)
		t = clampf(nv * 0.5 + 0.5, 0.0, 1.0)
	else:
		u = fposmod(x / tile_size, 1.0)
		t = fposmod(z / tile_size, 1.0)
	var px := clampi(int(u * w), 0, w - 1)
	var py := clampi(int(t * h), 0, h - 1)
	return data[py * w + px]


## Build a [0,1] grayscale-height lookup table once per bake from the assigned source texture (TEXTURE →
## height_texture, MATERIAL → plow_material.height_map; both read luminance). Returns
## [PackedFloat32Array, w, h]; empty array when the source is NOISE or nothing is assigned.
func _load_height_lut() -> Array:
	var empty: Array = [PackedFloat32Array(), 0, 0]
	var tex: Texture2D = null
	var invert := false
	if source == Source.TEXTURE:
		tex = height_texture
	elif source == Source.MATERIAL:
		if plow_material == null:
			return empty
		tex = plow_material.height_map
		invert = plow_material.invert
	else:
		return empty
	if tex == null:
		return empty

	var img := tex.get_image()
	if img == null:
		return empty
	img = img.duplicate() # don't mutate the shared resource image
	if img.is_compressed():
		if img.decompress() != OK:
			push_warning("Pasture3DPlow: could not decompress height source image; skipping.")
			return empty
	if img.has_mipmaps():
		img.clear_mipmaps()
	# Cap resolution for a fast, bounded per-bake read.
	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) > _LUT_MAX:
		var s := float(_LUT_MAX) / float(maxi(w, h))
		w = maxi(1, int(round(w * s)))
		h = maxi(1, int(round(h * s)))
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)

	var data := PackedFloat32Array()
	data.resize(w * h)
	for yy in range(h):
		var rowy := yy * w
		for xx in range(w):
			var v := img.get_pixel(xx, yy).get_luminance()
			data[rowy + xx] = (1.0 - v) if invert else v
	return [data, w, h]


func _update_mask_preview() -> void:
	_update_relief_mask_preview(relief if _mask_preview_on else null)


## §18.6: the material whose selectors the Mask Preview Source dropdown lists.
func _preview_relief_material():
	return relief
