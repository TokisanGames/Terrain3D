# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadGraderGate — Pasture3DRoadGrader (P2). The claim is that a road CUTS AND FILLS the ground into a
# corridor, rather than draping a ribbon over it, and that it reports where it did so.
#
# Every criterion here is measured against a closed-form answer, not against a previous run: the distance
# from a point to a straight line is exact, a plane's height at a cell is exact, and a batter of known
# slope meets a level plane at an exactly computable distance. A golden-image gate would pass just as
# happily on a grader that was subtly wrong from the first commit.
@tool
extends Node

const VS: float = 1.0
const DS: float = 1.0

var _fail: int = 0


func _ready() -> void:
	print("=== RoadGraderGate: road grading kernel (P2) ===\n")
	_a_distance_is_exact()
	_b_the_road_is_flat_across_a_tilted_plane()
	_c_the_batter_meets_the_ground_where_geometry_says()
	_d_masks_partition_the_corridor()
	_e_a_bridge_does_not_touch_the_ground()
	_f_nan_outside_the_loop_survives()
	_g_a_deep_cut_is_not_clipped_into_a_wall()
	_h_a_corner_is_banked_away_from_its_centre()
	print("\n=== %s (%d failures) ===\n" % ["ROAD GRADER PASS" if _fail == 0 else "ROAD GRADER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

## A straight road down the middle of the grid, running +Z at x = 0.
func _straight_plan(p_length: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.0, p_length)])


## A heightfield of `p_gw × p_gh` sampling `y = base + slope_x·x`, so every cell's ground height is known
## in closed form and a cut depth can be checked rather than eyeballed.
func _plane(p_gw: int, p_gh: int, p_min_x: float, p_base: float, p_slope_x: float) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(p_gw * p_gh)
	for iz in p_gh:
		for ix in p_gw:
			h[iz * p_gw + ix] = p_base + p_slope_x * (p_min_x + float(ix) * VS)
	return h


## An alignment holding the road at a constant height, with no banking — the fixture that isolates the
## grader from the P1 solver, so a failure here is the grader's.
func _level_alignment(p_n: int, p_z: float) -> Pasture3DRoadAlignment:
	var a := Pasture3DRoadAlignment.new()
	a.ds = DS
	a.s0 = 0.0
	var z := PackedFloat32Array()
	z.resize(p_n)
	z.fill(p_z)
	a.z = z
	a.ground = z.duplicate()
	a.bank = _zeros(p_n)
	a.curvature = _zeros(p_n)
	return a


func _zeros(p_n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(0.0)
	return a


func _widths(p_n: int, p_v: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(p_v)
	return a


## Index of the cell at world (x, z) in a grid whose origin is (min_x, min_z).
func _at(p_gw: int, p_min_x: float, p_min_z: float, p_x: float, p_z: float) -> int:
	var ix := int(round((p_x - p_min_x) / VS))
	var iz := int(round((p_z - p_min_z) / VS))
	return iz * p_gw + ix


# ---- A ------------------------------------------------------------------------------------------

func _a_distance_is_exact() -> void:
	print("[A] point-to-plan distance and arc length are exact, not approximated")
	# An L-shaped plan: 100 m up +Z, then 100 m along +X. Both the perpendicular distance and the arc
	# length at the closest point are known by hand at every probe below.
	var plan := PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.0, 100.0), Vector2(100.0, 100.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	print("    cumulative length %s (want [0, 100, 200])" % [cum])
	if absf(cum[2] - 200.0) > 1e-3:
		_fail += 1; print("    !! arc length along the plan is wrong")

	# 7 m to the right of the first leg, halfway along it.
	var probe := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(7.0, 50.0))
	print("    at (7, 50): d %.6f (want 7), s %.6f (want 50), side %+.0f" % [probe[0], probe[1], probe[2]])
	if absf(probe[0] - 7.0) > 1e-4 or absf(probe[1] - 50.0) > 1e-4:
		_fail += 1; print("    !! distance or arc length is wrong on a straight leg")

	# Diagonally off the CORNER: the closest point is the corner itself, so d is the hypotenuse and s is
	# exactly the corner's arc length. This is the case a per-segment infinite-line distance gets wrong.
	var corner := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(-3.0, 104.0))
	var want_d := sqrt(9.0 + 16.0)
	print("    at (-3, 104): d %.6f (want %.6f = the corner), s %.6f (want 100)"
			% [corner[0], want_d, corner[1]])
	if absf(corner[0] - want_d) > 1e-4 or absf(corner[1] - 100.0) > 1e-4:
		_fail += 1; print("    !! the closest point off a corner was not the corner")

	# Sides are opposite across the centreline, and travel direction decides which is which.
	var left := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(-5.0, 50.0))
	print("    side at x=-5 is %+.0f, at x=+7 is %+.0f (want opposite signs)" % [left[2], probe[2]])
	if left[2] * probe[2] >= 0.0:
		_fail += 1; print("    !! the two sides of the road did not get opposite signs")

	# CONTROL: a point ON the centreline is at distance 0 — so [A] measures a distance rather than always
	# returning the offset it was handed.
	var on := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(0.0, 50.0))
	print("    control: on the centreline d %.9f (want 0)" % on[0])
	if on[0] > 1e-5:
		_fail += 1; print("    !! a point on the centreline was not at distance zero")


# ---- B ------------------------------------------------------------------------------------------

func _b_the_road_is_flat_across_a_tilted_plane() -> void:
	print("[B] the carriageway is FLAT across ground that is not — the ribbon-vs-road claim")
	var gw := 81
	var gh := 40
	var min_x := -40.0
	var min_z := 0.0
	# Ground tilts 20% across the road. A draped ribbon would inherit that tilt exactly.
	var ground := _plane(gw, gh, min_x, 0.0, 0.20)
	var n_s := 60
	var a := _level_alignment(n_s, 0.0)
	var res := Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, 5.0), _widths(n_s, 1.0),
			_widths(n_s, 10.0), PackedByteArray(), {"crown": 0.0, "cut_batter": 1.0, "fill_batter": 1.0})
	var h: PackedFloat32Array = res["height"]

	# Crown is 0 in this fixture, so with no banking the whole carriageway must sit at the alignment's
	# height regardless of the ground under it.
	var lo := h[_at(gw, min_x, min_z, -4.0, 20.0)]
	var mid := h[_at(gw, min_x, min_z, 0.0, 20.0)]
	var hi := h[_at(gw, min_x, min_z, 4.0, 20.0)]
	var g_lo := ground[_at(gw, min_x, min_z, -4.0, 20.0)]
	var g_hi := ground[_at(gw, min_x, min_z, 4.0, 20.0)]
	print("    road across the carriageway: %.4f / %.4f / %.4f (want all 0)" % [lo, mid, hi])
	print("    the ground under it:         %.4f / ------ / %.4f (a %.1f m drop across 8 m)"
			% [g_lo, g_hi, g_hi - g_lo])
	if absf(lo) > 1e-3 or absf(mid) > 1e-3 or absf(hi) > 1e-3:
		_fail += 1; print("    !! the carriageway is not flat — this is a draped ribbon")
	if absf(g_hi - g_lo) < 1.0:
		_fail += 1; print("    !! the fixture is not tilted, so flatness proves nothing")

	# CONTROL: crown makes it deliberately NOT flat, by exactly the ratio asked for. Without this, [B]
	# would also pass on a grader that ignores the across-offset entirely.
	var crowned: Dictionary = Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, 5.0), _widths(n_s, 1.0),
			_widths(n_s, 10.0), PackedByteArray(), {"crown": 0.05, "cut_batter": 1.0, "fill_batter": 1.0})
	var ch: PackedFloat32Array = crowned["height"]
	var edge := ch[_at(gw, min_x, min_z, 4.0, 20.0)]
	print("    control: crown 0.05 at 4 m out -> %.4f (want -0.2000)" % edge)
	if absf(edge + 0.20) > 1e-3:
		_fail += 1; print("    !! the crown is not the ratio it was given")


# ---- C ------------------------------------------------------------------------------------------

func _c_the_batter_meets_the_ground_where_geometry_says() -> void:
	print("[C] the batter meets the ground at the distance its slope implies")
	var gw := 121
	var gh := 40
	var min_x := -60.0
	var min_z := 0.0
	# Level ground 10 m BELOW a road held at 0: the road is on an embankment, and a 1:2 fill batter
	# (0.5 rise per metre) must therefore reach the ground exactly 20 m past the edge of formation.
	var ground := _plane(gw, gh, min_x, -10.0, 0.0)
	var n_s := 60
	var a := _level_alignment(n_s, 0.0)
	var half := 5.0
	var shoulder := 1.0
	var batter := 0.5
	var res := Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, half), _widths(n_s, shoulder),
			_widths(n_s, 40.0), PackedByteArray(),
			{"crown": 0.0, "cut_batter": 1.0, "fill_batter": batter})
	var h: PackedFloat32Array = res["height"]

	var edge_d := half + shoulder
	var toe := edge_d + 10.0 / batter # 6 + 20 = 26 m from the centreline
	var before := h[_at(gw, min_x, min_z, toe - 4.0, 20.0)]
	var after := h[_at(gw, min_x, min_z, toe + 4.0, 20.0)]
	var want_before := -(toe - 4.0 - edge_d) * batter
	print("    embankment at %.0f m out: %.4f (want %.4f); at %.0f m out: %.4f (want -10, the ground)"
			% [toe - 4.0, before, want_before, toe + 4.0, after])
	if absf(before - want_before) > 1e-3:
		_fail += 1; print("    !! the batter does not descend at the slope it was given")
	if absf(after + 10.0) > 1e-3:
		_fail += 1; print("    !! the batter did not stop at the ground")

	# The join is CONTINUOUS: no cell within the corridor may sit below the ground on a pure fill.
	var worst := 0.0
	for i in h.size():
		worst = minf(worst, h[i] - ground[i])
	print("    deepest excursion below the ground on a pure fill: %.6f m (want 0)" % worst)
	if worst < -1e-3:
		_fail += 1; print("    !! the embankment cut below the ground it sits on")

	# CONTROL: a steeper batter must reach the ground SOONER, so [C] is reading the slope rather than a
	# fixed corridor width.
	var steep: Dictionary = Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, half), _widths(n_s, shoulder),
			_widths(n_s, 40.0), PackedByteArray(),
			{"crown": 0.0, "cut_batter": 1.0, "fill_batter": 1.0})
	var sh: PackedFloat32Array = steep["height"]
	var at_16 := sh[_at(gw, min_x, min_z, 16.0, 20.0)]
	print("    control: batter 1.0 at 16 m out -> %.4f (want -10, already down); gentle was %.4f"
			% [at_16, h[_at(gw, min_x, min_z, 16.0, 20.0)]])
	if absf(at_16 + 10.0) > 1e-3:
		_fail += 1; print("    !! a steeper batter did not reach the ground sooner")


# ---- D ------------------------------------------------------------------------------------------

func _d_masks_partition_the_corridor() -> void:
	print("[D] the masks partition the corridor and mark the earthworks that happened")
	var gw := 121
	var gh := 40
	var min_x := -60.0
	var min_z := 0.0
	# A cross-slope so the road cuts on one side and fills on the other — both channels get exercised by
	# one run, and each is checked on the side it must appear.
	var ground := _plane(gw, gh, min_x, 0.0, 0.30)
	var n_s := 60
	var a := _level_alignment(n_s, 0.0)
	var half := 5.0
	var res := Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, half), _widths(n_s, 1.0),
			_widths(n_s, 20.0), PackedByteArray(), {"crown": 0.0})
	var bed: PackedFloat32Array = res["roadbed"]
	var verge: PackedFloat32Array = res["verge"]
	var cut: PackedFloat32Array = res["cut"]
	var fill: PackedFloat32Array = res["fill"]

	# roadbed is the carriageway and nothing else: on at 4 m, off at 6 m (that is shoulder), off at 20 m.
	var b_in := bed[_at(gw, min_x, min_z, 4.0, 20.0)]
	var b_shoulder := bed[_at(gw, min_x, min_z, 5.6, 20.0)]
	var b_out := bed[_at(gw, min_x, min_z, 20.0, 20.0)]
	print("    roadbed at 4 m %.0f (want 1), on the shoulder %.0f (want 0), at 20 m %.0f (want 0)"
			% [b_in, b_shoulder, b_out])
	if b_in != 1.0 or b_shoulder != 0.0 or b_out != 0.0:
		_fail += 1; print("    !! roadbed is not the carriageway alone")

	# roadbed and verge are DISJOINT — a cell is formation or it is disturbance, never both, or a later
	# phase would paint tarmac and grass over each other.
	var overlap := 0
	for i in bed.size():
		if bed[i] > 0.0 and verge[i] > 0.0:
			overlap += 1
	print("    cells in both roadbed and verge: %d (want 0)" % overlap)
	if overlap != 0:
		_fail += 1; print("    !! roadbed and verge overlap")

	# The uphill side is cut, the downhill side is filled, and neither claims the other.
	# Probed 1 m past the edge of formation, NOT far out: on a 0.30 cross-slope a 1:1 batter has already
	# met the ground by 10 m, so a probe out there reports no earthworks and is right to. That is the
	# batter working, and it failed this criterion once before the probe moved in.
	var uphill := _at(gw, min_x, min_z, 7.0, 20.0)
	var downhill := _at(gw, min_x, min_z, -7.0, 20.0)
	print("    uphill: cut %.0f fill %.0f | downhill: cut %.0f fill %.0f"
			% [cut[uphill], fill[uphill], cut[downhill], fill[downhill]])
	if cut[uphill] != 1.0 or fill[uphill] != 0.0 or fill[downhill] != 1.0 or cut[downhill] != 0.0:
		_fail += 1; print("    !! cut and fill are not on the sides the cross-slope puts them")
	var both := 0
	for i in cut.size():
		if cut[i] > 0.0 and fill[i] > 0.0:
			both += 1
	if both != 0:
		_fail += 1; print("    !! %d cells are marked both cut and fill" % both)

	# CONTROL: on LEVEL ground at the road's own height there is nothing to move, so cut and fill are
	# empty while roadbed is not. Without this, masks that are simply always on would pass everything above.
	var flat := _plane(gw, gh, min_x, 0.0, 0.0)
	var none: Dictionary = Pasture3DRoadGrader.grade(flat, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, half), _widths(n_s, 1.0),
			_widths(n_s, 20.0), PackedByteArray(), {"crown": 0.0})
	var c_sum := 0.0
	var f_sum := 0.0
	var b_sum := 0.0
	for i in gw * gh:
		c_sum += none["cut"][i]
		f_sum += none["fill"][i]
		b_sum += none["roadbed"][i]
	print("    control: level ground at road height -> cut %.0f, fill %.0f cells; roadbed %.0f cells"
			% [c_sum, f_sum, b_sum])
	if c_sum != 0.0 or f_sum != 0.0:
		_fail += 1; print("    !! earthworks were reported where nothing moved")
	if b_sum <= 0.0:
		_fail += 1; print("    !! the control had no road at all, so it proves nothing")


# ---- E ------------------------------------------------------------------------------------------

func _e_a_bridge_does_not_touch_the_ground() -> void:
	print("[E] a bridged stretch reports a structure and leaves the ground alone")
	var gw := 61
	var gh := 120
	var min_x := -30.0
	var min_z := 0.0
	var ground := _plane(gw, gh, min_x, -15.0, 0.0)
	var n_s := 120
	var a := _level_alignment(n_s, 0.0)
	# Bridge the middle third of the run, in ARC LENGTH — which is the whole reason segments are stored
	# that way (§4.2).
	var suppress := PackedByteArray()
	suppress.resize(n_s)
	suppress.fill(0)
	for i in range(40, 80):
		suppress[i] = 1
	var res := Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, 5.0), _widths(n_s, 1.0),
			_widths(n_s, 20.0), suppress, {"crown": 0.0, "fill_batter": 0.5})
	var h: PackedFloat32Array = res["height"]
	var st: PackedFloat32Array = res["structure"]

	var on_bridge := _at(gw, min_x, min_z, 0.0, 60.0)
	var on_land := _at(gw, min_x, min_z, 0.0, 20.0)
	print("    under the bridge: height %.3f (ground -15), structure %.0f (want 1)"
			% [h[on_bridge], st[on_bridge]])
	print("    on the approach:  height %.3f (want 0, the deck), structure %.0f (want 0)"
			% [h[on_land], st[on_land]])
	if absf(h[on_bridge] + 15.0) > 1e-3 or st[on_bridge] != 1.0:
		_fail += 1; print("    !! the bridge graded the valley it is meant to span")
	if absf(h[on_land]) > 1e-3 or st[on_land] != 0.0:
		_fail += 1; print("    !! the approach embankment was suppressed too")

	# Nothing under the span moved AT ALL — the check that catches a partial suppression that still
	# leaves a ramp climbing into the deck.
	var moved := 0
	for iz in range(45, 75):
		for ix in gw:
			var i := iz * gw + ix
			if absf(h[i] - ground[i]) > 1e-3:
				moved += 1
	print("    cells moved beneath the span: %d (want 0)" % moved)
	if moved != 0:
		_fail += 1; print("    !! the ground moved under the bridge")

	# CONTROL: the same road with no bridge DOES build the embankment there, so [E] measures the
	# suppression rather than a road that never reached this stretch.
	var solid: Dictionary = Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, 5.0), _widths(n_s, 1.0),
			_widths(n_s, 20.0), PackedByteArray(), {"crown": 0.0, "fill_batter": 0.5})
	print("    control: unbridged, the same cell is %.3f (want 0, an embankment)"
			% solid["height"][on_bridge])
	if absf(solid["height"][on_bridge]) > 1e-3:
		_fail += 1; print("    !! the unbridged control did not build an embankment")


# ---- F ------------------------------------------------------------------------------------------

func _f_nan_outside_the_loop_survives() -> void:
	print("[F] NaN outside the brush loop passes through untouched")
	var gw := 41
	var gh := 40
	var min_x := -20.0
	var min_z := 0.0
	var ground := _plane(gw, gh, min_x, 0.0, 0.0)
	# The brush's "not my cell" marker, on cells the road otherwise covers — so this tests the boundary
	# contract, not cells the road was going to miss anyway.
	var holes: Array[int] = [_at(gw, min_x, min_z, 0.0, 10.0), _at(gw, min_x, min_z, 3.0, 11.0)]
	for i in holes:
		ground[i] = NAN
	var n_s := 40
	var a := _level_alignment(n_s, -5.0)
	var res := Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, 5.0), _widths(n_s, 1.0),
			_widths(n_s, 10.0), PackedByteArray(), {"crown": 0.0})
	var h: PackedFloat32Array = res["height"]
	var kept := 0
	for i in holes:
		if is_nan(h[i]):
			kept += 1
	print("    %d of %d NaN cells stayed NaN" % [kept, holes.size()])
	if kept != holes.size():
		_fail += 1; print("    !! the grader invented ground outside the brush loop")

	# No NaN leaked into its neighbours either — a batter reading a NaN edge would spread it outward.
	var leaked := 0
	for i in h.size():
		if is_nan(h[i]) and not holes.has(i):
			leaked += 1
	print("    NaN cells that were not holes: %d (want 0)" % leaked)
	if leaked != 0:
		_fail += 1; print("    !! NaN spread beyond the cells that carried it")

	# CONTROL: the same cells WITHOUT the marker are graded to the road, so [F] measures the passthrough
	# rather than a road that never covered them.
	var clean := _plane(gw, gh, min_x, 0.0, 0.0)
	var ok: Dictionary = Pasture3DRoadGrader.grade(clean, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, 5.0), _widths(n_s, 1.0),
			_widths(n_s, 10.0), PackedByteArray(), {"crown": 0.0})
	print("    control: without the marker the same cell grades to %.3f (want -5, the road)"
			% ok["height"][holes[0]])
	if absf(ok["height"][holes[0]] + 5.0) > 1e-3:
		_fail += 1; print("    !! the control cell was not on the road, so the passthrough proves nothing")


# ---- G ------------------------------------------------------------------------------------------

func _g_a_deep_cut_is_not_clipped_into_a_wall() -> void:
	print("[G] a deep cut runs its batter out to the ground instead of ending in a wall")
	# The bug this criterion exists for: the corridor was `half + shoulder + verge` wide, so a cut deeper
	# than the verge could absorb ended in a sheer vertical drop — legal as a height field, invisible to
	# every other criterion here, and unmistakable in the viewport as a canyon. Every earlier fixture
	# happened to use a verge wide enough to contain its batter, which is exactly why they all passed.
	var gw := 161
	var gh := 40
	var min_x := -80.0
	var min_z := 0.0
	var depth := 20.0
	var ground := _plane(gw, gh, min_x, depth, 0.0) # ground 20 m ABOVE a road held at 0
	var n_s := 60
	var a := _level_alignment(n_s, 0.0)
	var half := 5.0
	var shoulder := 1.0
	var verge := 4.0 # far too narrow to contain a 20 m batter — that is the point
	var res := Pasture3DRoadGrader.grade(ground, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, half), _widths(n_s, shoulder),
			_widths(n_s, verge), PackedByteArray(),
			{"crown": 0.0, "cut_batter": 1.0, "fill_batter": 1.0})
	var h: PackedFloat32Array = res["height"]

	# No step between neighbouring cells may exceed the batter slope itself (1.0 per metre here), plus a
	# little for the cell where the batter meets the ground. A clipped batter shows up as one ~14 m step.
	var worst_step := 0.0
	var worst_x := 0.0
	var iz := 20
	for ix in range(1, gw):
		var step := absf(h[iz * gw + ix] - h[iz * gw + ix - 1])
		if step > worst_step:
			worst_step = step
			worst_x = min_x + float(ix) * VS
	print("    steepest cell-to-cell step across the corridor: %.3f m at x=%.0f (batter is 1.0/m)"
			% [worst_step, worst_x])
	if worst_step > 1.5:
		_fail += 1; print("    !! there is a wall in the cross-section — the batter was clipped")

	# And it genuinely reached the ground: far out, the terrain is untouched.
	var far := h[_at(gw, min_x, min_z, 60.0, 20.0)]
	var toe := edge_toe(half + shoulder, depth, 1.0)
	print("    the batter toe is at %.0f m out; at 60 m the ground is %.3f (want %.1f, untouched)"
			% [toe, far, depth])
	if absf(far - depth) > 1e-3:
		_fail += 1; print("    !! the road disturbed ground well past its batter")

	# CONTROL: the same road on ground it barely has to cut has a SHORT batter, so [G] is reading the
	# depth rather than always grading out to the edge of the grid.
	var shallow := _plane(gw, gh, min_x, 1.0, 0.0)
	var sres: Dictionary = Pasture3DRoadGrader.grade(shallow, gw, gh, min_x, min_z, VS,
			_straight_plan(float(n_s - 1)), a, _widths(n_s, half), _widths(n_s, shoulder),
			_widths(n_s, verge), PackedByteArray(),
			{"crown": 0.0, "cut_batter": 1.0, "fill_batter": 1.0})
	var sh: PackedFloat32Array = sres["height"]
	var touched_deep := 0
	var touched_shallow := 0
	for ix in gw:
		if absf(h[iz * gw + ix] - ground[iz * gw + ix]) > 1e-3:
			touched_deep += 1
		if absf(sh[iz * gw + ix] - shallow[iz * gw + ix]) > 1e-3:
			touched_shallow += 1
	print("    control: a 20 m cut disturbs %d cells across, a 1 m cut disturbs %d"
			% [touched_deep, touched_shallow])
	if touched_shallow >= touched_deep:
		_fail += 1; print("    !! corridor width does not follow the depth of the cut")


## Where a batter of `p_slope` starting at `p_edge` metres out lands, for a cut of `p_depth`.
func edge_toe(p_edge: float, p_depth: float, p_slope: float) -> float:
	return p_edge + p_depth / p_slope


# ---- H ------------------------------------------------------------------------------------------

## [H] A corner comes out banked with its OUTSIDE high, measured on the graded ground rather than on the
## bank number.
##
## This is the criterion that was missing. The alignment gate checked banking against v²·κ/g and passed
## while the sign was inverted, because the magnitude is the same either way and no gate ever asked
## which side of the road ended up higher. A user seeing an inverted stop line in the editor is what
## found it. Comparing the two edges at equal distance from the centreline also cancels the crown, which
## lowers both by the same amount, so what is left is the banking alone.
func _h_a_corner_is_banked_away_from_its_centre() -> void:
	print("[H] a corner is banked away from its centre — the outside is the high side")
	# A circular arc of radius R about the ORIGIN, so the centre of the turn is a point we know rather
	# than one derived from the code under test.
	var radius := 60.0
	var n := 200
	var plan := PackedVector2Array()
	plan.resize(n)
	for i in n:
		var theta := float(i) * 0.5 / radius
		plan[i] = Vector2(radius * cos(theta), radius * sin(theta))
	var ground := PackedFloat32Array()
	ground.resize(n)
	ground.fill(0.0)
	var alignment := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, 0.5, 0.08, 25.0, 0.2)

	# A flat heightfield around the start of the arc, which is at (radius, 0) heading +Z.
	var gw := 61
	var gh := 61
	var vs := 1.0
	var min_x := radius - 30.0
	var min_z := -30.0
	var height := PackedFloat32Array()
	height.resize(gw * gh)
	height.fill(0.0)
	var half := PackedFloat32Array(); half.resize(n); half.fill(6.0)
	var shoulder := PackedFloat32Array(); shoulder.resize(n); shoulder.fill(0.5)
	var verge := PackedFloat32Array(); verge.resize(n); verge.fill(4.0)
	var suppress := PackedByteArray(); suppress.resize(n); suppress.fill(0)
	var res := Pasture3DRoadGrader.grade(height, gw, gh, min_x, min_z, vs, plan, alignment,
			half, shoulder, verge, suppress, {"crown": 0.05, "cut_batter": 1.0, "fill_batter": 0.6})
	var graded: PackedFloat32Array = res["height"]

	# Two cells the same distance either side of the centreline at z = 0, where the road runs through
	# (radius, 0). The one nearer the origin is the INSIDE of the corner.
	var probe := 4.0
	var iz := int(round((0.0 - min_z) / vs))
	var inner_ix := int(round((radius - probe - min_x) / vs))
	var outer_ix := int(round((radius + probe - min_x) / vs))
	var h_in: float = graded[iz * gw + inner_ix]
	var h_out: float = graded[iz * gw + outer_ix]
	var mid := int(n / 2)
	print("    arc R=%.0f about the origin; at %.1f m either side of the centreline: inside %.4f, outside %.4f (bank %.4f)"
			% [radius, probe, h_in, h_out, alignment.bank[mid]])

	# CONTROL: a STRAIGHT road on the same ground is symmetric about its centreline, so the comparison
	# is measuring banking rather than any left/right asymmetry the grader might have anyway.
	var s_plan := PackedVector2Array()
	s_plan.resize(n)
	for i in n:
		s_plan[i] = Vector2(radius, -50.0 + float(i) * 0.5)
	var s_align := Pasture3DRoadAlignmentSolver.solve_with_plan(s_plan, ground, 0.5, 0.08, 25.0, 0.2)
	var s_height := PackedFloat32Array()
	s_height.resize(gw * gh)
	s_height.fill(0.0)
	var s_res := Pasture3DRoadGrader.grade(s_height, gw, gh, min_x, min_z, vs, s_plan, s_align,
			half, shoulder, verge, suppress, {"crown": 0.05, "cut_batter": 1.0, "fill_batter": 0.6})
	var s_graded: PackedFloat32Array = s_res["height"]
	var s_in: float = s_graded[iz * gw + inner_ix]
	var s_out: float = s_graded[iz * gw + outer_ix]
	print("    control: a straight road at the same place -> %.4f / %.4f (must be equal)" % [s_in, s_out])

	if h_out <= h_in:
		_fail += 1
		print("    !! the corner is banked INTO its centre — a vehicle is tipped toward the inside")
	if absf(s_in - s_out) > 1e-4:
		_fail += 1
		print("    !! a straight road is not symmetric, so the corner comparison proves nothing")
