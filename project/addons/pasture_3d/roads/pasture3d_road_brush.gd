# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadBrush — lays out a road along one or more child Path3D splines, open or closed, exactly
# as Pasture3DRidge and Pasture3DTrough lay out a crest or a channel.
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §2 and §4.1.
#
# ---- WHY A BRUSH ----
#
# The plugin's authoring idiom is a Pasture3DTerrainBrush with child splines and a modifier stack, and a
# brush can already mount an entire terrain graph inside that stack (Pasture3DNodeGraph). So
# "brush-authored" and "graph-driven" were never alternatives: the brush is the authoring surface and
# the stack is how a road's terrain effect will reach the heightmap in P2. Extending the base hands over
# the spline gizmos, `snap_to_surface`, the debounced repaint, undo, the FROZEN/stale/Bake contract and
# the native rasteriser path — none of which a standalone road node would get.
#
# ---- P0 SCOPE: THIS BRUSH DOES NOT TOUCH THE TERRAIN YET ----
#
# `_paint_spline` is deliberately empty. P0 is the data model and the resolve chain; the grading
# modifier is P2 (a Pasture3DRoadModifier in the stack, with the mask channels the proposal's §8 lists).
# An empty paint is safe rather than half-done — the brush can be placed, parented, given segments and
# resolved against, and it will not write a single vertex until the phase that is supposed to.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DRoadBrush
extends Pasture3DTerrainBrush

@export_group("Road")
## What this brush overrides for its whole length. Sits between its segments and its group in the
## resolve chain (§5.3). Unset fields inherit; they are never copied down from the group.
@export var road_defaults: Pasture3DRoadOverrides:
	set(v):
		if road_defaults != null and road_defaults.changed.is_connected(_on_road_changed):
			road_defaults.changed.disconnect(_on_road_changed)
		road_defaults = v
		if road_defaults != null and not road_defaults.changed.is_connected(_on_road_changed):
			road_defaults.changed.connect(_on_road_changed)
		_on_road_changed()

## Per-stretch overrides, each covering a range of arc length along the spline (§4.2). Later entries win
## where two overlap, so a short bridge can sit inside a long gravel stretch.
@export var segments: Array[Pasture3DRoadSegment] = []:
	set(v):
		for s: Pasture3DRoadSegment in segments:
			if s != null and s.changed.is_connected(_on_road_changed):
				s.changed.disconnect(_on_road_changed)
		segments = v
		for s: Pasture3DRoadSegment in segments:
			if s != null and not s.changed.is_connected(_on_road_changed):
				s.changed.connect(_on_road_changed)
		_on_road_changed()

## Close the spline into a loop. Roads are usually open runs; a ring road or a closed test circuit is
## the exception, which is why this defaults off where Pasture3DMound's equivalent defaults on.
@export var closed: bool = false:
	set(v):
		closed = v
		_schedule_refresh()

# ---- Inspector proxies (§5.3) -------------------------------------------------------------------
#
# `road_defaults` is a sub-resource, so the fields a road is actually authored with sit one fold-out
# click away in the inspector. These forward straight into it — no second storage, no shadow state, and
# no semantic change: every one of them still means "override this level", and INHERIT / -1 / "" still
# means "ask the level above". Reading one when `road_defaults` is missing answers with the sentinel
# rather than creating the resource, so merely inspecting a brush never gives it an opinion.

@export_group("Road Overrides", "road_")


## The road type this brush uses. INHERIT (null) takes the group's, then the network's.
@export var road_road_type: Pasture3DRoadType:
	set(v): _set_override(&"road_type", v)
	get: return _get_override(&"road_type", null)

## Lanes across the carriageway. -1 inherits, and the road type is the last word.
@export_range(-1, 8) var road_lane_count: int = -1:
	set(v): _set_override(&"lane_count", v)
	get: return int(_get_override(&"lane_count", -1))

## One-way or two-way. Which SIDE traffic drives on is the network's call, not this one.
@export var road_traffic_flow: Pasture3DRoadOverrides.TrafficFlow = Pasture3DRoadOverrides.TrafficFlow.INHERIT:
	set(v): _set_override(&"traffic_flow", v)
	get: return _get_override(&"traffic_flow", Pasture3DRoadOverrides.TrafficFlow.INHERIT)

## Physics surface. A mid-run change is a SEGMENT override, not this one (§4.4).
@export var road_surface_id: StringName = &"":
	set(v): _set_override(&"surface_id", v)
	get: return StringName(_get_override(&"surface_id", &""))

## Posted speed, m/s. NAN inherits.
@export var road_speed_limit: float = NAN:
	set(v): _set_override(&"speed_limit", v)
	get: return float(_get_override(&"speed_limit", NAN))

## Drape on the terrain instead of solving a grade-limited alignment. INHERIT, and then FALSE — a draped
## road is the failure the P1 solver exists to avoid, so it has to be asked for.
@export var road_follow_terrain: Pasture3DRoadOverrides.Tri = Pasture3DRoadOverrides.Tri.INHERIT:
	set(v): _set_override(&"follow_terrain", v)
	get: return _get_override(&"follow_terrain", Pasture3DRoadOverrides.Tri.INHERIT)


## Write through to `road_defaults`, creating it only when something is actually being set. A proxy that
## created the resource on every read would hand a brush an override just for being looked at.
func _set_override(p_field: StringName, p_value: Variant) -> void:
	if road_defaults == null:
		if Pasture3DRoadOverrides.is_unset(p_value):
			return
		road_defaults = Pasture3DRoadOverrides.new()
	road_defaults.set(p_field, p_value)


func _get_override(p_field: StringName, p_unset: Variant) -> Variant:
	return road_defaults.get(p_field) if road_defaults != null else p_unset


## Re-bake guard for the corridor-width feedback in `grade_surface`. Not saved: it is true only for the
## duration of one widening pass.
var _widening: bool = false
var _last_corridor_half: float = 0.0

## The junction demands the last bake actually used. Compared against a fresh digest after each resolve;
## see `junction_digest`. Not saved — a reload re-bakes and re-resolves anyway.
var last_junction_digest: String = ""

## Bumped whenever a resolved value could have changed. The staleness key P2's grading modifier and P4's
## intersection resolver will fold into their caches.
var content_key: int = 0


func _init() -> void:
	super()
	if road_defaults == null:
		road_defaults = Pasture3DRoadOverrides.new()


func _ready() -> void:
	super()
	if road_defaults != null and not road_defaults.changed.is_connected(_on_road_changed):
		road_defaults.changed.connect(_on_road_changed)
	for s: Pasture3DRoadSegment in segments:
		if s != null and not s.changed.is_connected(_on_road_changed):
			s.changed.connect(_on_road_changed)


func _on_road_changed() -> void:
	content_key += 1
	update_configuration_warnings()


# ---- The resolve chain (§5.3) -------------------------------------------------------------------

## This brush's group, or null when it is parented straight under the network. A group is optional.
func road_group() -> Pasture3DRoadGroup:
	return Pasture3DRoadGroup.find_for(get_parent())


## This brush's network, or null when it is not under one.
func road_network() -> Pasture3DRoadNetwork:
	return Pasture3DRoadNetwork.find_for(get_parent())


## The override levels, NEAREST FIRST, optionally including the segment covering `p_distance` metres
## along the spline. The one place the hierarchy's order is written down: everything that resolves a
## road value goes through here rather than walking parents itself.
func resolve_chain(p_distance: float = NAN) -> Array:
	var chain: Array = []
	if is_finite(p_distance):
		var seg := segment_at(p_distance)
		if seg != null:
			chain.append(seg)
	chain.append(road_defaults)
	var grp := road_group()
	if grp != null:
		chain.append(grp.road_defaults)
	var net := road_network()
	if net != null:
		chain.append(net.road_defaults)
	return chain


## The resolved value of one inheritable field, walking Segment -> Brush -> Group -> Network. Returns
## null when no level has an opinion — ask the road type for those (`resolved_road_type` first).
func resolved(p_field: StringName, p_distance: float = NAN) -> Variant:
	return Pasture3DRoadOverrides.resolve(resolve_chain(p_distance), p_field)


## The road type in force, optionally at a distance along the spline. Falls back to the first type the
## group offers, so a freshly placed brush under a configured network builds something rather than
## nothing.
func resolved_road_type(p_distance: float = NAN) -> Pasture3DRoadType:
	var t: Variant = resolved(&"road_type", p_distance)
	if t != null:
		return t as Pasture3DRoadType
	var grp := road_group()
	if grp != null:
		var avail := grp.available_road_types()
		if not avail.is_empty():
			return avail[0]
	var net := road_network()
	if net != null:
		var types := net.valid_road_types()
		if not types.is_empty():
			return types[0]
	return null


## Lanes in force at `p_distance`, falling through to the road type's own default — the last link in
## the chain, and the reason a type carries real values rather than sentinels.
func resolved_lane_count(p_distance: float = NAN) -> int:
	var v: Variant = resolved(&"lane_count", p_distance)
	if v != null:
		return int(v)
	var t := resolved_road_type(p_distance)
	return t.lane_count if t != null else 2


## Physics surface in force at `p_distance`. Mid-stage surface changes (§4.4) are a segment overriding
## this, which is exactly the case arc-length ranges exist for.
func resolved_surface_id(p_distance: float = NAN) -> StringName:
	var v: Variant = resolved(&"surface_id", p_distance)
	if v != null:
		return StringName(v)
	var t := resolved_road_type(p_distance)
	return t.surface_id if t != null else &""


## True when the road drapes on the terrain instead of solving a grade-limited alignment. Defaults
## FALSE: a draped road is the failure the P1 solver exists to avoid, so it has to be asked for.
func resolved_follow_terrain(p_distance: float = NAN) -> bool:
	var v: Variant = resolved(&"follow_terrain", p_distance)
	return int(v) == int(Pasture3DRoadOverrides.Tri.ON) if v != null else false


## True when this road carries traffic in one direction only. TWO_WAY where nothing has an opinion:
## a road that nobody declared one-way is a normal road, and defaulting the other way would silently
## delete every oncoming lane in a world that never mentioned traffic flow.
func resolved_one_way(p_distance: float = NAN) -> bool:
	var v: Variant = resolved(&"traffic_flow", p_distance)
	return int(v) == int(Pasture3DRoadOverrides.TrafficFlow.ONE_WAY) if v != null else false


## This road's lane cross-section at `p_distance`, resolved against the hierarchy and the world's
## traffic side. The one place the lane kernel is fed, so a road's lanes mean the same thing to the
## junction solver, the gizmo and every query.
func resolved_lanes(p_distance: float = NAN) -> Array:
	var t := resolved_road_type(p_distance)
	if t == null:
		return []
	var net := road_network()
	var left_hand: bool = net != null and net.traffic_side == Pasture3DRoadNetwork.TrafficSide.LEFT
	return Pasture3DRoadLanes.cross_section(resolved_lane_count(p_distance), t.lane_width,
			resolved_one_way(p_distance), left_hand)


# ---- Segments -----------------------------------------------------------------------------------

## The segment covering `p_distance`, or null. LAST match wins, so a short bridge declared after a long
## gravel stretch overrides it inside its range — the array order is the precedence, which is the same
## rule the modifier stack uses and the only one that survives being read out loud.
func segment_at(p_distance: float) -> Pasture3DRoadSegment:
	var found: Pasture3DRoadSegment = null
	for s: Pasture3DRoadSegment in segments:
		if s != null and s.covers(p_distance):
			found = s
	return found


## True when `p_distance` is carried on a bridge. Read by P2's grader (do not cut the terrain here) and
## by P4's intersection resolver (an overpass overlaps without meeting, §6.3).
func is_bridge_at(p_distance: float) -> bool:
	var s := segment_at(p_distance)
	return s != null and s.is_bridge


# ---- Brush base hooks ---------------------------------------------------------------------------

## A road IS its modifier stack — the grading step is where the whole terrain effect lives (§8), so
## without this the brush has no Modifiers list to put a Pasture3DNodeRoad in and paints a bare footprint
## forever. Only Mound and Plow carried the stack before roads existed.
func _supports_modifiers() -> bool:
	return true


func _default_layer_name() -> String:
	var grp := road_group()
	return grp.layer_name if grp != null else "Roads"


func _default_snap_to_surface() -> bool:
	return true # the plan alignment is placed ON the ground; P1 then decides the road's own height


func _spline_basename() -> String:
	return "Road"


func _is_closed() -> bool:
	return closed


## Half the corridor, INCLUDING the batter run — the ONE definition of how wide a road reaches.
##
## The batter reaches (height to make up) / (batter slope) past the formation, so a deep cut needs a far
## wider corridor than the road's own width suggests. This existed in three places at once — the grader's
## per-cell reach, the footprint padding, and the corridor mask below — and fixing two of them left a
## sheer wall exactly where the third one stopped. Any of the three being narrow produces the identical
## artefact, so there is now one answer and three callers.
##
## The depth allowance is the worst offset the LAST bake actually produced where that is known, and the
## modifier's structure threshold before then, because that is the depth past which the user is already
## being told to bridge.
func corridor_half_width() -> float:
	var t := resolved_road_type()
	if t == null:
		return 16.0
	var allowance := 8.0
	var batter := minf(t.cut_batter, t.fill_batter)
	for m in modifiers:
		if m is Pasture3DNodeRoad and m.is_active():
			var road_mod: Pasture3DNodeRoad = m
			allowance = maxf(allowance, road_mod.structure_threshold)
			allowance = maxf(allowance, road_mod._deepest_structure())
			if road_mod.cut_batter_override >= 0.0:
				batter = minf(batter, road_mod.cut_batter_override)
			if road_mod.fill_batter_override >= 0.0:
				batter = minf(batter, road_mod.fill_batter_override)
	return t.disturbed_width(resolved_lane_count()) * 0.5 + allowance / maxf(batter, 0.05)


func _padding() -> float:
	return corridor_half_width() + 2.0


## Starter shape: a straight run, matching Ridge's.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(0.0, 0.0, -50.0))
	c.add_point(Vector3(0.0, 0.0, 50.0))
	return c


## The terrain effect lives in the Pasture3DNodeRoad modifier, not here — see the header and §8. This
## hook still has to run, because it is what establishes the footprint grid the stack is applied over;
## the road brush contributes no profile of its own, so it paints a flat zero amplitude and lets the
## grader write the actual surface.
func _paint_spline(path: Path3D) -> void:
	if not is_configured():
		return
	_paint_flat_footprint(path)




## Establish the working grid over this road's corridor and run the modifier stack on it.
##
## The road brush contributes NO profile of its own — this paints a flat, zero-amplitude footprint and
## the Pasture3DNodeRoad step writes the surface. That is not a placeholder: a road has no falloff to
## author, because the thing that blends it into the surrounding terrain is the BATTER, which is real
## geometry with a slope an engineer would recognise rather than a ramp curve. So `profile` is 1 across
## the whole corridor and 0 outside it, and the grader's batter does the job a falloff does elsewhere.
##
## Without an active road modifier the footprint is written back unchanged, so a road brush with an empty
## stack leaves the terrain exactly as it found it rather than stamping a flat pad.
func _paint_flat_footprint(path: Path3D) -> void:
	var plan := _plan_points()
	if plan.size() < 2:
		return
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var min_x: float = b[0]
	var min_z: float = b[2]
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	if gw < 1 or gh < 1:
		return
	var n := gw * gh

	# The SAME reach the grader and the padding use. When this was narrower than the grader's, every cell
	# past it was marked NaN before the grader saw it, so the batter had nowhere to land and ended in a
	# wall — with the grader itself already fixed and looking innocent.
	var reach := corridor_half_width()
	var cum := Pasture3DRoadGrader.cumulative_length(plan)

	var extent := _extent_key(min_x, min_z, vs, gw, gh)
	var stack := _compile_modifiers(extent, 1.0, 1.0)
	var basey := _base_below_grid(min_x, min_z, vs, gw, gh)
	if basey.is_empty():
		basey.resize(n)
		basey.fill(global_position.y)

	# NaN outside the corridor is the brush-loop contract (§6.8): those cells are not this brush's to
	# write, and the grader passes them straight through.
	var amp := PackedFloat64Array()
	var profile := PackedFloat64Array()
	amp.resize(n)
	profile.resize(n)
	for iz in range(gh):
		var wz := min_z + float(iz) * vs
		var row := iz * gw
		for ix in range(gw):
			var hit := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(min_x + float(ix) * vs, wz))
			if float(hit[0]) > reach:
				amp[row + ix] = NAN
				profile[row + ix] = 0.0
			else:
				amp[row + ix] = 0.0
				profile[row + ix] = 1.0

	var vals := PackedFloat32Array()
	vals.resize(n)
	vals.fill(NAN)
	if not stack["gd"].is_empty():
		vals = _run_modifier_stack(stack["gd"], amp, profile, basey, {
			"gw": gw, "gh": gh, "min_x": min_x, "min_z": min_z, "vs": vs, "add": false,
			"fit_cx": 0.0, "fit_cz": 0.0, "fit_cos": 1.0, "fit_sin": 0.0,
			"inv_ex": 1.0, "inv_ez": 1.0,
			"fields": [], "sim_fields": [], "host_fields": [],
			"measured": [], "host_measured": [], "host_div": 1.0,
			"profile": profile, "basey": basey, "extent": extent,
			"sdf": PackedFloat32Array(), "edge_offset": 0.0,
			"profile_ext": PackedFloat64Array(),
		})
		_commit_modifier_caches(stack, extent, [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, min_x, min_z, vs])
	else:
		for k in range(n):
			if not is_nan(amp[k]):
				vals[k] = basey[k]

	_store_stamp_cache(path, _compute_stamp_key(path), min_x, min_z, vs, gw, gh, vals,
			_spline_footprint_aabb(path))
	if _layer_id >= 0 and terrain.data.has_method("apply_sim_block"):
		terrain.data.apply_sim_block(_layer_id, min_x, min_z, vs, gw, gh, vals, _blend)
	else:
		for iz in range(gh):
			var z := min_z + iz * vs
			var row := iz * gw
			for ix in range(gw):
				var wv := vals[row + ix]
				if is_finite(wv):
					_paint_height(Vector3(min_x + ix * vs, 0.0, z), wv, 0.0)

# ---- Grading (P2) -------------------------------------------------------------------------------

## Grade `p_z` (an ABSOLUTE surface, row-major gw × gh) into this road's corridor, for one
## Pasture3DNodeRoad step. Returns the grader's `{height, roadbed, cut, fill, verge, structure}`, or an
## empty Dictionary when there is nothing to grade.
##
## This is where the resolve chain meets the geometry: widths, batters and bridging are asked for PER
## ALIGNMENT SAMPLE, so a segment covering 800–1040 m simply produces different numbers at those indices
## and the grader never learns that segments exist.
func grade_surface(p_mod: Pasture3DNodeRoad, p_z: PackedFloat32Array, p_gw: int, p_gh: int,
		p_min_x: float, p_min_z: float, p_vs: float) -> Dictionary:
	var plan := _plan_points()
	if plan.size() < 2:
		return {}
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var total: float = cum[cum.size() - 1]
	var ds: float = maxf(p_mod.alignment_step, 0.05)
	var n_s := maxi(int(ceil(total / ds)) + 1, 2)

	# The ground the alignment is solved against is the SURFACE ENTERING THIS STEP, not the terrain — so
	# an Erosion step above this one is ground the road cuts through, which is the ordering §8 exists to
	# make editable.
	var ground := PackedFloat32Array()
	ground.resize(n_s)
	for i in n_s:
		var at := _plan_point_at(plan, cum, float(i) * ds)
		ground[i] = _sample_grid(p_z, p_gw, p_gh, p_min_x, p_min_z, p_vs, at)

	var t := resolved_road_type()
	if t == null:
		return {}
	var half := PackedFloat32Array()
	var shoulder := PackedFloat32Array()
	var verge := PackedFloat32Array()
	var suppress := PackedByteArray()
	half.resize(n_s); shoulder.resize(n_s); verge.resize(n_s); suppress.resize(n_s)
	for i in n_s:
		var s := float(i) * ds
		var ti := resolved_road_type(s)
		var tt: Pasture3DRoadType = ti if ti != null else t
		half[i] = tt.half_width(resolved_lane_count(s))
		shoulder[i] = tt.shoulder_width
		verge[i] = p_mod.verge_override if p_mod.verge_override >= 0.0 else tt.verge_width
		suppress[i] = 1 if is_bridge_at(s) else 0

	# ---- WHAT THE JUNCTIONS ASK OF THIS ROAD (§6) ---------------------------------------------------
	#
	# Two things, and they go to two different places. The PIN goes into the alignment solve, because a
	# minor road has to arrive at the major road's height and P1 already honours pins exactly — and
	# already reports a pin it cannot reach as an infeasible gradient breach, so an impossible junction
	# surfaces through gated machinery instead of a new failure mode. The TRIM goes into the grading,
	# because two roads writing the same cells is how a crossroads turns into a lumpy scar: the minor
	# approach stops at the footprint and the major road, which keeps its own profile, paves through.
	var pins := {}
	var skip := PackedByteArray()
	skip.resize(n_s)
	var jnet := road_network()
	if jnet != null:
		var jkey := road_key()
		for j in jnet.junctions_for(jkey):
			var js: float = j.arc_length_for(jkey)
			if not is_finite(js):
				continue
			var jpin: float = j.pin_for(jkey)
			var ji := clampi(int(round(js / ds)), 0, n_s - 1)
			if is_finite(jpin):
				pins[ji] = jpin
			if not j.is_major(jkey):
				var trim: float = j.trim_back_for(jkey)
				var lo := clampi(int(floor((js - trim) / ds)), 0, n_s - 1)
				var hi := clampi(int(ceil((js + trim) / ds)), 0, n_s - 1)
				for i in range(lo, hi + 1):
					skip[i] = 1
		last_junction_digest = junction_digest()

	var alignment: Pasture3DRoadAlignment
	if resolved_follow_terrain():
		# A draped road is a deliberate choice, not a fallback: the alignment is the ground, so the
		# grader still crowns, banks and batters — it just does not solve a profile.
		alignment = Pasture3DRoadAlignment.new()
		alignment.ds = ds
		alignment.z = ground.duplicate()
		alignment.ground = ground.duplicate()
		alignment.bank = Pasture3DRoadGrader._zeros(n_s)
		alignment.curvature = Pasture3DRoadGrader._zeros(n_s)
	else:
		alignment = Pasture3DRoadAlignmentSolver.solve_with_plan(_resample_plan(plan, cum, ds, n_s),
				ground, ds, t.max_grade, t.design_speed, t.max_superelevation, {"pins": pins})
	p_mod.last_alignment = alignment

	# ---- THE CORRIDOR WIDTH DEPENDS ON A RESULT THE BAKE HAS TO PRODUCE FIRST -----------------------
	#
	# How far the batter reaches is (how deep the cut is) / (batter slope), and how deep the cut is only
	# becomes known once the alignment has been solved — which happens here, inside the bake that already
	# committed to a footprint width. So the FIRST bake of a deep cutting is necessarily too narrow, and
	# without this it would sit there with a wall down each side until something happened to refresh it
	# again. One re-bake, guarded so it cannot recurse: the second pass has `_deepest_structure` and gets
	# the width right.
	if not _widening:
		var needed := corridor_half_width()
		if needed > _last_corridor_half + 0.5:
			_last_corridor_half = needed
			_widening = true
			_schedule_refresh()
			(func() -> void: _widening = false).call_deferred()

	var res := Pasture3DRoadGrader.grade(p_z, p_gw, p_gh, p_min_x, p_min_z, p_vs, plan, alignment,
			half, shoulder, verge, suppress, {
				"crown": p_mod.resolved_number(p_mod.crown_override, t.crown),
				"cut_batter": p_mod.resolved_number(p_mod.cut_batter_override, t.cut_batter),
				"fill_batter": p_mod.resolved_number(p_mod.fill_batter_override, t.fill_batter),
				"skip": skip,
			})
	# The alignment this bake solved is what makes this road detectable, so the resolve is asked for
	# AFTER it exists — and coalesced on the network, so a refresh that bakes six roads resolves once.
	if jnet != null:
		jnet.request_resolve()

	p_mod.last_masks = {} if not p_mod.publish_masks else {
		"roadbed": res["roadbed"], "cut": res["cut"], "fill": res["fill"],
		"verge": res["verge"], "structure": res["structure"], "surface": res["surface"],
		# The grid ORIGIN travels with the masks. Without it a mask is a rectangle of numbers with no
		# place in the world, and every consumer has to be told separately where the bake happened —
		# which is how a road ends up painted half a region from the road.
		"gw": p_gw, "gh": p_gh, "min_x": p_min_x, "min_z": p_min_z, "vs": p_vs,
	}
	return res


# ---- TIER FAR: the carriageway paints itself (P5, §10) -----------------------------------------------


## Paint this road's surface into the group's reserved control layer.
##
## Driven by the NETWORK rather than called at the end of the bake, and that is not incidental: where two
## roads overlap the higher-priority surface must win (§5.2), and a brush painting itself at bake time
## lands in scene order, which has nothing to do with priority. The network sorts and calls.
##
## Returns the number of cells written; 0 when there is nothing to paint or no layer to paint into,
## which is the normal answer on a terrain without the layers API rather than an error.
func paint_surface() -> int:
	var mod := road_modifier()
	if mod == null or mod.last_masks.is_empty() or terrain == null or terrain.data == null:
		return 0
	var masks: Dictionary = mod.last_masks
	var cover: PackedFloat32Array = masks.get("surface", PackedFloat32Array())
	if cover.is_empty():
		return 0
	# The road type is asked FIRST, before a layer is reserved. `surface_layer_id` is -1 by default and
	# -1 means "do not paint" (§4.4), so a project that has not chosen a road texture yet must end up
	# with no layer rather than an empty one — and must not paint texture 31, which is what -1 becomes
	# the moment it reaches a 5-bit field.
	var t := resolved_road_type()
	if t == null or t.surface_layer_id < 0:
		return 0
	var layer_id := paint_layer_id()
	if layer_id < 0:
		return 0

	var gw := int(masks.get("gw", 0))
	var min_x := float(masks.get("min_x", 0.0))
	var min_z := float(masks.get("min_z", 0.0))
	var vs := float(masks.get("vs", 1.0))
	# Read back what is already there so the paint keeps the base texture and any hole somebody carved.
	# One read per covered cell: the corridor is a thin strip of the bake grid, not the whole of it.
	var existing := PackedInt32Array()
	existing.resize(cover.size())
	for i in cover.size():
		if cover[i] < Pasture3DRoadPaint.MIN_COVERAGE:
			continue
		var at := Pasture3DRoadPaint.cell_position(i, gw, min_x, min_z, vs)
		var c: int = terrain.data.get_control(at)
		existing[i] = 0 if c == -1 else c

	var plan := Pasture3DRoadPaint.surface_control(cover, existing, {
		"texture_id": t.surface_layer_id,
		"preserve_base": true,
	})
	var cells: PackedInt32Array = plan["cells"]
	var control: PackedInt32Array = plan["control"]
	var weight: PackedFloat32Array = plan["weight"]
	for k in cells.size():
		var at := Pasture3DRoadPaint.cell_position(cells[k], gw, min_x, min_z, vs)
		# Composite deferred: the network composites once when every road has painted, rather than each
		# road compositing its own cells and the overlaps being composited as many times as they overlap.
		terrain.data.set_control_on_layer(layer_id, at, control[k], weight[k], false)
	return cells.size()


## The reserved control layer this road paints into: its group's, or the network's own when the road has
## no group. Negative when there is nowhere to paint.
##
## Owned by the GROUP and not by the brush, unlike the height layer every terrain brush owns. A group is
## the level at which "these roads are one surface" is true, so twenty brushes in one group share one
## layer and cost one composite — and the group is also where the user named it.
func paint_layer_id() -> int:
	var group := road_group()
	if group != null:
		return group.ensure_paint_layer(terrain)
	var net := road_network()
	return net.ensure_paint_layer(terrain) if net != null else -1


## This road's splines as ONE world-space XZ polyline. Multiple splines under one road brush are
## concatenated in child order, which is also the order arc length runs in — the same order segments
## are measured against, so a segment range means the same thing here as it does in the inspector.
func _plan_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	for path: Path3D in _get_splines():
		if path == null or path.curve == null or path.curve.point_count < 2:
			continue
		var xf := path.global_transform
		for p in path.curve.tessellate():
			var w: Vector3 = xf * p
			out.append(Vector2(w.x, w.z))
	return out


## The point `p_s` metres along the plan polyline. Delegated: the grader owns the definition, because the
## mesher needs the same one and a second copy is a second place for an off-by-one to live.
func _plan_point_at(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float) -> Vector2:
	return Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, p_s)


func _resample_plan(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_ds: float,
		p_n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(p_n)
	for i in p_n:
		out[i] = _plan_point_at(p_plan, p_cum, float(i) * p_ds)
	return out


## Bilinear sample of a working grid at a world XZ. NaN-aware: a tap on a cell the brush does not own
## falls back to the nearest finite corner rather than poisoning the alignment with NaN ground.
func _sample_grid(p_z: PackedFloat32Array, p_gw: int, p_gh: int, p_min_x: float, p_min_z: float,
		p_vs: float, p_at: Vector2) -> float:
	if p_gw <= 0 or p_gh <= 0:
		return 0.0
	var fx := clampf((p_at.x - p_min_x) / p_vs, 0.0, float(p_gw - 1))
	var fz := clampf((p_at.y - p_min_z) / p_vs, 0.0, float(p_gh - 1))
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var x1 := mini(x0 + 1, p_gw - 1)
	var z1 := mini(z0 + 1, p_gh - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var v00 := p_z[z0 * p_gw + x0]
	var v10 := p_z[z0 * p_gw + x1]
	var v01 := p_z[z1 * p_gw + x0]
	var v11 := p_z[z1 * p_gw + x1]
	var acc := 0.0
	var wsum := 0.0
	for pair in [[v00, (1.0 - tx) * (1.0 - tz)], [v10, tx * (1.0 - tz)],
			[v01, (1.0 - tx) * tz], [v11, tx * tz]]:
		if is_finite(pair[0]):
			acc += float(pair[0]) * float(pair[1])
			wsum += float(pair[1])
	return (acc / wsum) if wsum > 0.0 else 0.0


func _get_configuration_warnings() -> PackedStringArray:
	var out := super()
	if road_network() == null:
		out.append("No Pasture3DRoadNetwork above this brush. Road types and defaults cannot resolve.")
	if resolved_road_type() == null:
		out.append("No road type resolves here. Set one on this brush, or add one to the network catalogue.")
	var total := _spline_length()
	for s: Pasture3DRoadSegment in segments:
		if s != null:
			out.append_array(s.range_warnings(total))
	return out


## Total arc length of this brush's splines, metres, or NAN when there is nothing to measure. Used to
## tell a segment it has been left past the end of a shortened spline.
func _spline_length() -> float:
	var total := 0.0
	var any := false
	for path: Path3D in _get_splines():
		if path != null and path.curve != null and path.curve.point_count >= 2:
			total += path.curve.get_baked_length()
			any = true
	return total if any else NAN


# ---- JUNCTIONS (P4a) --------------------------------------------------------------------------------

## This road's identity in the junction records. The node's path relative to its network, so it survives
## reparenting inside the network, a scene reload and a re-resolve — unlike `content_key`, which is a
## change counter and would detach every override the moment anything was edited.
func road_key() -> String:
	var net := road_network()
	if net == null:
		return str(get_path())
	return str(net.get_path_to(self))


## The first active road modifier, or null. The alignment and the grading options live on it.
func road_modifier() -> Pasture3DNodeRoad:
	for m in modifiers:
		if m is Pasture3DNodeRoad and m.is_active():
			return m as Pasture3DNodeRoad
	return null


## This road as a run for Pasture3DRoadJunctionSolver, or {} when it has nothing to contribute yet.
##
## Empty until the brush has baked once, because the run carries the SOLVED alignment: the solver's
## clearance test asks how far apart two roads are vertically, and a road with no profile cannot answer.
## A resolve before the first bake therefore finds no junctions rather than finding them in the wrong
## places and pinning roads to heights derived from nothing.
func build_run() -> Dictionary:
	var mod := road_modifier()
	if mod == null or mod.last_alignment == null or mod.last_alignment.count() == 0:
		return {}
	var plan := _plan_points()
	if plan.size() < 2:
		return {}
	var t := resolved_road_type()
	if t == null:
		return {}
	var alignment: Pasture3DRoadAlignment = mod.last_alignment
	var bridge := PackedByteArray()
	bridge.resize(alignment.count())
	for i in alignment.count():
		bridge[i] = 1 if is_bridge_at(float(i) * alignment.ds) else 0
	return {
		"key": road_key(),
		"plan": plan,
		"cum": Pasture3DRoadGrader.cumulative_length(plan),
		"alignment": alignment,
		"bridge": bridge,
		"priority": t.priority,
		"half_width": t.half_width(resolved_lane_count()),
	}


## This road's resolved priority (§5.2), or 0 when it has no road type yet. Higher wins a junction, gets
## the longer green, and holds right of way over the roads it crosses.
func road_priority() -> int:
	var t := resolved_road_type()
	return t.priority if t != null else 0


## What this road's junctions currently ask of it, as a string. The rebake test: if this is unchanged
## after a resolve, the profile the brush already baked is the one the junctions want, and re-baking would
## produce the same bytes. That equality is what makes the bake→resolve→bake loop terminate.
func junction_digest() -> String:
	var net := road_network()
	if net == null:
		return ""
	var key := road_key()
	var parts := PackedStringArray()
	for j in net.junctions_for(key):
		parts.append("%s|%.3f|%.3f|%.3f" % [j.id, j.arc_length_for(key), j.pin_for(key),
				j.trim_back_for(key)])
	parts.sort()
	return "\n".join(parts)


## Bake again because the junctions moved. Records the digest FIRST, so the bake it triggers is credited
## with the pins it is about to use and the next resolve does not ask for another one.
func schedule_junction_rebake() -> void:
	last_junction_digest = junction_digest()
	_schedule_refresh()


## The world XZ point `p_s` metres along this road's plan. The junction gizmo's way of asking where an
## approach actually is, without reaching into the brush's private plan arrays.
## How long this road is, metres — the solved alignment's length, or NAN before the first bake.
##
## Published because a consumer following a lane has to know where the road ENDS: without it a vehicle
## walks off the last point and the only alternatives are to reach into the modifier's alignment or to
## re-measure the spline, both of which are the consumer doing the road system's job.
func road_length() -> float:
	var mod := road_modifier()
	if mod == null or mod.last_alignment == null or mod.last_alignment.count() == 0:
		return NAN
	return float(mod.last_alignment.count() - 1) * mod.last_alignment.ds


func point_at_arc(p_s: float) -> Vector2:
	var plan := _plan_points()
	if plan.size() < 2:
		return Vector2.ZERO
	return _plan_point_at(plan, Pasture3DRoadGrader.cumulative_length(plan), p_s)


## Plan direction at `p_s`, normalised, in the direction of INCREASING arc length.
##
## A central difference rather than the segment direction: an arc length that lands exactly on a plan
## vertex would otherwise pick one of two different answers depending on rounding, and a junction arm
## frequently lands near one. Straddling the point averages the two, which is also the right answer on
## the curve the tessellation is approximating.
func tangent_at_arc(p_s: float, p_h: float = 0.5) -> Vector2:
	var plan := _plan_points()
	if plan.size() < 2:
		return Vector2.RIGHT
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var total: float = cum[cum.size() - 1]
	var a := _plan_point_at(plan, cum, clampf(p_s - p_h, 0.0, total))
	var b := _plan_point_at(plan, cum, clampf(p_s + p_h, 0.0, total))
	var d := b - a
	return d.normalized() if d.length() > 1e-6 else Vector2.RIGHT


## The road's solved height at `p_s`, or NAN when it has not been baked. World metres.
func height_at_arc(p_s: float) -> float:
	var mod := road_modifier()
	if mod == null or mod.last_alignment == null or mod.last_alignment.count() == 0:
		return NAN
	return mod.last_alignment.height_at(p_s)
