# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadGrader — the road's terrain effect, as a pure kernel: given a heightfield, a plan polyline
# and a SOLVED vertical alignment (Pasture3DRoadAlignment, P1), produce the graded surface and the channel
# masks. Driven by Pasture3DNodeRoad inside a brush's modifier stack; see
# PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §8.
#
# ---- WHY THIS IS STATIC, AND TAKES ARRAYS RATHER THAN NODES ----
#
# Nothing here touches a Node, a Terrain, a Path3D or an editor. It takes numbers and returns numbers, so
# it can be gated on analytic fixtures where the right answer is known in closed form — a straight road on
# a tilted plane has an exact cut depth at every cell, and that is the only kind of fixture that can tell
# a working grader from one that merely produces plausible-looking earthworks. The brush resolves the
# hierarchy (§5.3) and the RoadType widths, and hands the results in as plain per-sample arrays.
#
# ---- DISTANCE IS ANALYTIC, NOT JUMP-FLOODED (§8) ----
#
# The distance transform uses JFA because an exact scan is sequential and could not go to the GPU, so CPU
# and GPU would disagree across the 256² threshold. That reasoning does NOT apply to a set of line
# segments: point-to-segment distance is closed form, embarrassingly parallel, and bit-comparable on both
# backends by construction. It also yields `s` — the arc length at the closest point — which JFA cannot,
# and without which there is no way to ask the alignment how high the road is here. The whole grader
# hangs off that one query.
@tool
class_name Pasture3DRoadGrader
extends RefCounted

## Cells whose height moved by less than this are treated as untouched, so the cut and fill masks mark
## real earthworks rather than float noise at the batter's feather edge.
const EARTHWORK_EPSILON: float = 0.001


## Cumulative arc length at each plan point, metres. Element 0 is 0 and the last is the total length.
static func cumulative_length(p_plan: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := p_plan.size()
	out.resize(n)
	if n == 0:
		return out
	out[0] = 0.0
	for i in range(1, n):
		out[i] = out[i - 1] + p_plan[i].distance_to(p_plan[i - 1])
	return out


## The road surface height at signed across-distance `p_u`, given the centreline height there.
##
## THE PROFILE, DEFINED ONCE. The mesher (P5b) draws the ribbon this describes and the grader carves the
## ground it sits on, and if the two ever disagreed by a millimetre the road would z-fight along its whole
## length — a defect that looks like a rendering bug and is arithmetic. So neither owns it.
##
## `p_bank` is superelevation as a rise/run ratio signed like curvature (positive across-distance is the
## driver's RIGHT), and `p_crown` sheds water from the centreline to both edges, so it is a function of
## |u| and the two edges come out level with each other.
static func surface_height(p_centre: float, p_bank: float, p_crown: float, p_u: float) -> float:
	return p_centre + p_bank * p_u - p_crown * absf(p_u)


## World XZ of the point `p_s` metres along the plan polyline. Clamped at both ends.
##
## Public because the mesher, the brush and the junction gizmo all need it, and three copies of "walk the
## cumulative lengths and lerp" is three places for an off-by-one to live.
static func plan_point_at(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_s: float) -> Vector2:
	var n := p_plan.size()
	if n == 0:
		return Vector2.ZERO
	if n == 1 or p_cum.size() < n:
		return p_plan[0]
	var total: float = p_cum[n - 1]
	var s := clampf(p_s, 0.0, total)
	# Binary search rather than a walk: the mesher asks per vertex, and a linear scan makes meshing a road
	# quadratic in its own length.
	var lo := 0
	var hi := n - 1
	while lo + 1 < hi:
		var mid := (lo + hi) / 2
		if p_cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	var span: float = p_cum[hi] - p_cum[lo]
	if span <= 1e-9:
		return p_plan[lo]
	return p_plan[lo].lerp(p_plan[hi], (s - p_cum[lo]) / span)


## Plan direction at `p_s`, normalised, pointing along INCREASING arc length.
##
## A central difference straddling the point, not the segment direction: an arc length landing exactly on
## a plan vertex has two segment answers and would pick one by rounding — and junction arms land near
## vertices constantly.
static func plan_tangent_at(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float,
		p_h: float = 0.5) -> Vector2:
	var n := p_plan.size()
	if n < 2 or p_cum.size() < n:
		return Vector2.RIGHT
	var total: float = p_cum[n - 1]
	var a := plan_point_at(p_plan, p_cum, clampf(p_s - p_h, 0.0, total))
	var b := plan_point_at(p_plan, p_cum, clampf(p_s + p_h, 0.0, total))
	var d := b - a
	return d.normalized() if d.length() > 1e-6 else Vector2.RIGHT


## Closest point on the plan polyline to `p_at`, as `[distance, s, side]`:
##   distance — metres from `p_at` to the centreline, always positive
##   s        — arc length of that closest point, metres from the start of the run
##   side     — +1 RIGHT of the direction of travel, -1 left, 0 exactly on it. (In the (x, z) plane the
##              2D cross below is positive at +Z for a +X heading, and left of +X is -Z.)
##
## Exact, by projecting onto each segment and keeping the best. Brute force over segments: a road brush's
## plan is tens to a few hundred points and this runs per CELL, so a uniform bucket index over segment
## bounds is the obvious optimisation — deliberately NOT done here, because the native port is where that
## belongs and a spatial index in the reference kernel would make the A/B against it compare two different
## algorithms rather than two backends.
static func nearest_on_plan(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_at: Vector2) -> Array:
	var n := p_plan.size()
	if n == 0:
		return [INF, 0.0, 0.0]
	if n == 1:
		return [p_at.distance_to(p_plan[0]), 0.0, 0.0]

	var best_d2 := INF
	var best_s := 0.0
	var best_side := 0.0
	for i in range(n - 1):
		var a := p_plan[i]
		var b := p_plan[i + 1]
		# Quick bounding-box rejection: if point is farther from segment AABB than best_d2, skip projection
		var min_x := minf(a.x, b.x)
		var max_x := maxf(a.x, b.x)
		var min_y := minf(a.y, b.y)
		var max_y := maxf(a.y, b.y)
		var dx := maxf(0.0, maxf(min_x - p_at.x, p_at.x - max_x))
		var dy := maxf(0.0, maxf(min_y - p_at.y, p_at.y - max_y))
		if dx * dx + dy * dy >= best_d2:
			continue
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 <= 0.0:
			continue
		# t is the projection parameter CLAMPED so the closest point stays on the segment — which is what
		# makes the union over segments the true distance to the polyline rather than to its infinite lines.
		var t := clampf((p_at - a).dot(ab) / len2, 0.0, 1.0)
		var proj := a + ab * t
		var d2 := p_at.distance_squared_to(proj)
		if d2 < best_d2:
			best_d2 = d2
			best_s = p_cum[i] + sqrt(len2) * t
			# 2D cross of the travel direction with the offset: its sign is which side we are on, and it
			# stays well defined where the distance itself is zero.
			best_side = signf(ab.x * (p_at.y - a.y) - ab.y * (p_at.x - a.x))
	return [sqrt(best_d2), best_s, best_side]


## Grade a heightfield around one road.
##
## `p_height` is row-major gw × gh, world X increasing along a row, in METRES, and may contain NaN for
## cells outside the brush's own loop — those are passed through untouched, which is what keeps the
## brush-loop boundary contract intact.
##
## The per-sample arrays are indexed by ALIGNMENT sample, so a width or a surface that changes partway
## along the run (§4.4) is just a different value at a different index. A true `p_suppress[i]` leaves the
## terrain alone at that arc length — a bridge deck carries the road, so grading under it would build the
## earth dam across the valley that the bridge exists to avoid.
##
## Returns `{height, roadbed, cut, fill, verge, structure, surface}`; every mask is 0..1 over the same
## grid.
static func grade(p_height: PackedFloat32Array, p_gw: int, p_gh: int, p_min_x: float, p_min_z: float,
		p_vs: float, p_plan: PackedVector2Array, p_alignment: Pasture3DRoadAlignment,
		p_half_width: PackedFloat32Array, p_shoulder: PackedFloat32Array,
		p_verge: PackedFloat32Array, p_suppress: PackedByteArray,
		p_opts: Dictionary = {}) -> Dictionary:
	if not ClassDB.class_has_method("Pasture3DUtil", "road_grade_grid"):
		push_error("[Pasture3D] Pasture3DUtil.road_grade_grid is not bound. Rebuild GDExtension.")
		return _pass_through(p_height, p_gw * p_gh)

	# The alignment is flattened to the four numbers the grade actually reads. A null or unsolved one is
	# handed to the kernel as an empty profile rather than short-circuited here, so the pass-through answer
	# has ONE definition — the destructive alternative being a grader that returns zeros for a road that is
	# merely being renamed.
	var ds: float = p_alignment.ds if p_alignment != null else 1.0
	var s0: float = p_alignment.s0 if p_alignment != null else 0.0
	var az: PackedFloat32Array = p_alignment.z if p_alignment != null else PackedFloat32Array()
	var bank: PackedFloat32Array = p_alignment.bank if p_alignment != null else PackedFloat32Array()
	var res: Dictionary = Pasture3DUtil.road_grade_grid(p_height, p_gw, p_gh, p_min_x, p_min_z, p_vs,
			p_plan, ds, s0, az, bank, p_half_width, p_shoulder, p_verge, p_suppress, p_opts)
	return res


## The safe answer when the kernel is missing: the ground, untouched, and no earthworks reported. Not
## zeros — a grader that flattened a terrain because a symbol was missing would be the silent degradation
## the native separation exists to delete.
static func _pass_through(p_height: PackedFloat32Array, p_n: int) -> Dictionary:
	return {
		"ok": false, "height": p_height.duplicate(),
		"roadbed": _zeros(p_n), "cut": _zeros(p_n), "fill": _zeros(p_n),
		"verge": _zeros(p_n), "structure": _zeros(p_n), "surface": _zeros(p_n),
	}


## The GDScript REFERENCE grade — the oracle `grade` is measured against by RoadNativeParityGate [F], and
## the place the argument for every rule below is written down.
##
## Not dead code and not a fallback: it is the definition. It is kept in production rather than in a gate
## for the reason every oracle in this codebase is — a definition that lives only in a test drifts from
## the thing it defines, and here the thing it defines is the shape of every road in the project.
static func grade_reference(p_height: PackedFloat32Array, p_gw: int, p_gh: int, p_min_x: float,
		p_min_z: float, p_vs: float, p_plan: PackedVector2Array, p_alignment: Pasture3DRoadAlignment,
		p_half_width: PackedFloat32Array, p_shoulder: PackedFloat32Array,
		p_verge: PackedFloat32Array, p_suppress: PackedByteArray,
		p_opts: Dictionary = {}) -> Dictionary:
	var n := p_gw * p_gh
	var out := {
		"height": p_height.duplicate(),
		"roadbed": _zeros(n), "cut": _zeros(n), "fill": _zeros(n),
		"verge": _zeros(n), "structure": _zeros(n), "surface": _zeros(n),
	}
	if p_alignment == null or p_alignment.count() == 0 or p_plan.size() < 2 or n <= 0:
		return out

	var crown: float = float(p_opts.get("crown", 0.05))
	var cut_batter: float = maxf(float(p_opts.get("cut_batter", 1.0)), 0.01)
	var fill_batter: float = maxf(float(p_opts.get("fill_batter", 0.6)), 0.01)
	# `skip` is NOT `p_suppress`. Suppress means "a structure carries the road here", and says so in the
	# structure mask. Skip means "this arc length belongs to something else" — a junction footprint the
	# approach was trimmed back from (§6) — and must leave no trace at all: marking it as a bridge deck
	# would tell every later phase to build a viaduct at every crossroads.
	var skip: PackedByteArray = p_opts.get("skip", PackedByteArray())
	var cum := cumulative_length(p_plan)
	var graded: PackedFloat32Array = out["height"]
	var m_bed: PackedFloat32Array = out["roadbed"]
	var m_cut: PackedFloat32Array = out["cut"]
	var m_fill: PackedFloat32Array = out["fill"]
	var m_verge: PackedFloat32Array = out["verge"]
	var m_struct: PackedFloat32Array = out["structure"]
	var m_surface: PackedFloat32Array = out["surface"]
	# How far past the edge of formation the painted surface fades out, in SHOULDERS rather than metres:
	# a farm track and a motorway should not share an edge width, and the shoulder is already the road's
	# own statement of how wide its margin is.
	var fade: float = maxf(float(p_opts.get("surface_fade", 1.0)), 0.0)

	for iz in range(p_gh):
		var wz := p_min_z + float(iz) * p_vs
		var row := iz * p_gw
		for ix in range(p_gw):
			var idx := row + ix
			var ground := p_height[idx]
			# NaN is the brush's "not my cell" marker, not a height. Writing a road through it would
			# invent ground outside the loop.
			if not is_finite(ground):
				continue
			var wx := p_min_x + float(ix) * p_vs

			var hit := nearest_on_plan(p_plan, cum, Vector2(wx, wz))
			var d: float = hit[0]
			var s: float = hit[1]
			var side: float = hit[2]

			var si := p_alignment.index_at(s)
			if si < skip.size() and skip[si] != 0:
				continue
			var half: float = _at(p_half_width, si, 3.5)
			var shoulder: float = _at(p_shoulder, si, 0.5)
			var verge: float = _at(p_verge, si, 4.0)
			var edge_d := half + shoulder
			# THE CORRIDOR IS AS WIDE AS THE BATTER NEEDS, plus the verge.
			#
			# It used to be `edge_d + verge`, which silently CLIPPED the batter: a 20 m cut with a 1:1
			# batter needs 20 m of run, and with a 4 m verge it got 4 — the remaining 16 m became a sheer
			# vertical wall down the side of the road. It looked like a canyon and reported no error,
			# because a clipped batter is still a legal height field.
			#
			# The run needed is (height to make up) / (batter slope), so it is computed here rather than
			# authored. `verge` keeps its meaning — disturbed ground BEYOND where the batter lands — and
			# stops being an accidental cap on how deep a cutting may be.
			var z_ref: float = p_alignment.height_at(s)
			var rise := absf(z_ref - ground)
			var slope: float = cut_batter if z_ref < ground else fill_batter
			var reach := edge_d + rise / slope + verge
			if d > reach:
				continue

			# A suppressed stretch still REPORTS itself — the structure mask is how a later phase learns
			# where to build a deck — it just does not touch the ground.
			if si < p_suppress.size() and p_suppress[si] != 0:
				m_struct[idx] = 1.0
				continue

			# The road surface across the carriageway: the solved centreline height, banked by the
			# superelevation the alignment already carries, and crowned so water sheds to the edges. Both
			# are offsets from the centreline, so both are read at the SIGNED across-distance.
			var u := d * side
			var z_road: float = p_alignment.height_at(s)
			var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
			var z_surface := surface_height(z_road, bank, crown, u)

			var h := ground
			if d <= edge_d:
				h = z_surface
			else:
				# Beyond the shoulder the batter runs from the edge of formation down (fill) or up (cut)
				# until it MEETS the ground, and the meet is a max/min rather than a solved crossing —
				# which is what makes the join continuous with no seam to chase, at any terrain slope.
				var z_edge := surface_height(z_road, bank, crown, edge_d * side)
				var beyond := d - edge_d
				if z_edge > ground:
					h = maxf(ground, z_edge - beyond * fill_batter)
				else:
					h = minf(ground, z_edge + beyond * cut_batter)

			graded[idx] = h
			# Coverage masks. `roadbed` is the carriageway ONLY — the shoulder is not driving surface and
			# a later phase paints it differently — and `verge` is everything the road disturbed outside
			# the formation, which is what a prop scatter wants to avoid and a grass blend wants to follow.
			# COVERAGE FOR PAINTING, as a float, and computed here because this is the only place that
			# knows `d`. The binary roadbed mask says where the carriageway is; this says how much of the
			# surface material a cell should receive, which is what a control-map paint needs and what a
			# consumer cannot recover from a 0/1 mask without re-measuring the road.
			#
			# Solid out to the edge of formation, then eased to nothing over `fade` shoulders. Smoothstep
			# rather than linear, so the painted edge has no visible line where the gradient starts — which
			# a linear ramp does have, because its derivative jumps.
			var fade_end := edge_d + shoulder * fade
			if d <= edge_d:
				m_surface[idx] = 1.0
			elif fade_end > edge_d:
				var u_fade := clampf((fade_end - d) / (fade_end - edge_d), 0.0, 1.0)
				m_surface[idx] = u_fade * u_fade * (3.0 - 2.0 * u_fade)
			if d <= half:
				m_bed[idx] = 1.0
			elif d > edge_d:
				m_verge[idx] = 1.0
			if d > edge_d and absf(h - ground) <= EARTHWORK_EPSILON:
				m_verge[idx] = 1.0 # past the batter toe: disturbed ground the road did not have to move
			var delta := h - ground
			if delta > EARTHWORK_EPSILON:
				m_fill[idx] = 1.0
			elif delta < -EARTHWORK_EPSILON:
				m_cut[idx] = 1.0

	out["height"] = graded
	return out


static func _at(p_arr: PackedFloat32Array, p_i: int, p_default: float) -> float:
	if p_arr.is_empty():
		return p_default
	return p_arr[clampi(p_i, 0, p_arr.size() - 1)]


static func _zeros(p_n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(0.0)
	return a
