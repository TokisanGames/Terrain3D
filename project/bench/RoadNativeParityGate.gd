# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadNativeParityGate — the native path kernels against the [Dev/GD] oracles (P2a).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md P2a moves the road query into C++. The GDScript that was there is
# not deleted: it becomes the reference oracle, and this gate is the thing that makes that demotion mean
# something. Every criterion runs the SAME fixture through the production node and the [Dev/GD] node and
# requires them to agree.
#
# ---- WHY AGREEMENT ALONE IS NOT ENOUGH, AND WHAT EACH CONTROL IS FOR ----
#
# Two implementations of a query agree trivially when neither is doing anything: an empty path, a fixture
# the road misses entirely, a kernel that is not bound and a GDScript node quietly filling the same
# constant. Each criterion therefore carries a control that fails when the fixture stopped being a test:
#
#   * the kernel must actually be BOUND (a missing symbol must fail, never fall back)
#   * the field must actually VARY over the fixture (a constant field is two implementations of nothing)
#   * the road must actually be REACHED (some cells on it, some far from it)
#
# Tolerance is 1e-4 on metres, not exact equality. The kernel accumulates in double and returns float32,
# the GDScript accumulates in double throughout; the two differ in the last bits of the float and that is
# not a defect. `s` is the exception worth naming: a WRONG NEAREST SEGMENT on a doubling-back path gives a
# plausible distance and an absurd s, so s is compared at the same tolerance rather than loosely.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]

const G_N: int = 96
const G_MIN: float = -48.0
const G_VS: float = 1.0
const EPS: float = 1.0e-4

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadNativeParityGate: the native path query vs the [Dev/GD] oracle ===")
	print("    spec: PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md P2a")

	_a_the_kernel_is_bound_at_all()
	_b_the_native_query_matches_the_oracle()
	_c_an_empty_path_reads_far_away_on_both()
	_d_the_corridor_mask_matches_the_oracle()
	_e_a_closed_path_masks_its_interior()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== ROAD NATIVE PARITY %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


func _rect() -> Rect2:
	return Rect2(G_MIN, G_MIN, float(G_N) * G_VS, float(G_N) * G_VS)


## A road that doubles back on itself, with a width that changes along it.
##
## The hairpin is the shape that catches a broken index: a cell inside the bend is near two segments that
## are far apart in ARC LENGTH, so picking the wrong one leaves `distance` looking perfectly reasonable
## while `s` is off by half the road. A straight fixture cannot tell a correct index from a broken one.
func _hairpin() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	for i in 9:
		pts.append(Vector2(-32.0 + float(i) * 8.0, -18.0))
		w.append(3.0 + float(i) * 0.25)
	for i in 9:
		pts.append(Vector2(32.0 - float(i) * 8.0, 18.0))
		w.append(5.0 - float(i) * 0.25)
	path.points = pts
	path.half_widths = w
	return path


func _prod(p_path: Pasture3DGraphPath) -> Array:
	var node := Pasture3DGraphNodePathDistance.new()
	node.set_path_inputs([p_path])
	return node.eval_grid_channels([], G_N, G_N, null, _rect())


func _oracle(p_path: Pasture3DGraphPath) -> Array:
	var node := Pasture3DGraphNodeDevPathDistance.new()
	node.set_path_inputs([p_path])
	return node.eval_grid_channels([], G_N, G_N, null, _rect())


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in mini(p_a.size(), p_b.size()):
		worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _spread(p_v: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_v:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return 0.0 if lo > hi else hi - lo


# ---- A ------------------------------------------------------------------------------------------

## [A] The kernel is bound, and the production node is really calling it.
##
## Checked FIRST and separately, because every other criterion in this file would pass without it: the
## production node's fail-fast returns the unreachable fill, and on a fixture the road happened to miss,
## that is the same answer the oracle gives. A gate for a native port has to prove the native code ran.
func _a_the_kernel_is_bound_at_all() -> void:
	print("[A] the native kernel is bound")
	var bound := ClassDB.class_has_method("Pasture3DUtil", "path_query_grid")
	print("    Pasture3DUtil.path_query_grid bound: %s" % str(bound))
	if not bound:
		_check("A", false, "path_query_grid is not bound — rebuild the GDExtension")
		return

	# Call it DIRECTLY, not through the node, so this says something about the binding rather than about
	# the node's fallback. A straight 100 m road, and the answer at a known point is arithmetic.
	var pts := PackedVector2Array([Vector2(-50.0, 0.0), Vector2(50.0, 0.0)])
	var res: Dictionary = Pasture3DUtil.path_query_grid(pts, PackedFloat32Array(), 3, 3,
			Rect2(-1.5, -1.5, 3.0, 3.0), 10000.0, 0.0)
	var ok := bool(res.get("ok", false))
	var d: PackedFloat32Array = res.get("distance", PackedFloat32Array())
	# Cell centres over a 3x3 rect from -1.5: rows at z = -1, 0, +1. The middle row sits ON the road.
	var on_road: float = d[4] if d.size() == 9 else -1.0
	var one_off: float = d[1] if d.size() == 9 else -1.0
	print("    a straight road reads %.4f m at its centre and %.4f m one metre off it" % [on_road, one_off])
	_check("A", ok and d.size() == 9 and absf(on_road) < EPS and absf(one_off - 1.0) < EPS,
			"ok %s, %d cell(s), centre %.4f m, offset %.4f m" % [str(ok), d.size(), on_road, one_off])


# ---- B ------------------------------------------------------------------------------------------

## [B] Native and oracle agree on distance, s and t over a hairpin.
##
## All three channels, because they are three answers from one solve and a port can get one right while
## getting another wrong — most easily `t`, whose sign is a cross product that is trivial to invert and
## whose magnitude divides by an interpolated half-width the port could have sampled at the wrong vertex.
func _b_the_native_query_matches_the_oracle() -> void:
	print("[B] the native query matches the oracle over a hairpin")
	var path := _hairpin()
	var prod := _prod(path)
	var orc := _oracle(path)

	var d_worst := _worst(prod[0], orc[0])
	var s_worst := _worst(prod[1], orc[1])
	var t_worst := _worst(prod[2], orc[2])
	print("    worst disagreement: distance %.7f m, s %.7f m, t %.7f" % [d_worst, s_worst, t_worst])
	_check("B", d_worst < EPS and s_worst < EPS and t_worst < EPS,
			"distance %.7f / s %.7f / t %.7f (want < %.4f)" % [d_worst, s_worst, t_worst, EPS])

	# CONTROL: the fields must actually VARY. Two implementations of a constant agree perfectly and say
	# nothing, and that is exactly what a fail-fast fill looks like from here.
	var d_spread := _spread(prod[0])
	var s_spread := _spread(prod[1])
	print("    control: distance spans %.2f m and s spans %.2f m across the fixture (want both > 1)"
			% [d_spread, s_spread])
	if d_spread <= 1.0 or s_spread <= 1.0:
		_fail += 1
		print("    !! the field is nearly constant, so this criterion compared two constants")

	# CONTROL: the road must be REACHED — cells on it and cells well off it. A fixture the road misses
	# entirely would agree at the unreachable fill everywhere.
	var on := 0
	var off := 0
	for i in prod[0].size():
		if prod[0][i] < 2.0:
			on += 1
		elif prod[0][i] > 20.0:
			off += 1
	print("    control: %d cell(s) within 2 m of the road, %d cell(s) beyond 20 m (want both > 0)"
			% [on, off])
	if on == 0 or off == 0:
		_fail += 1
		print("    !! the fixture does not straddle the road, so the comparison covers one regime")

	# CONTROL: t must be SIGNED on both, and signed the same way. A port that dropped the sign would agree
	# on |t| everywhere and would put every verge on one side of every road.
	var neg_prod := 0
	var neg_orc := 0
	for i in prod[2].size():
		if prod[2][i] < -0.001:
			neg_prod += 1
		if orc[2][i] < -0.001:
			neg_orc += 1
	print("    control: t is negative on %d cell(s) natively and %d in the oracle (want equal, non-zero)"
			% [neg_prod, neg_orc])
	if neg_prod == 0 or neg_prod != neg_orc:
		_fail += 1
		print("    !! the two disagree about which side of the road is which")


# ---- C ------------------------------------------------------------------------------------------

## [C] An empty path reads FAR AWAY on both, not zero.
##
## The most destructive single value in the road system. `distance == 0` means every cell is on the road,
## so an unresolved Road Source feeding a Road Grade would flatten the entire terrain to the crown — and
## it would look like a working graph. The kernel owns this answer now (the node passes an empty array
## straight through), so it has to be gated on the kernel and not only on the node.
func _c_an_empty_path_reads_far_away_on_both() -> void:
	print("[C] an empty path reads far away on both")
	var empty := Pasture3DGraphPath.new()
	var prod := _prod(empty)
	var orc := _oracle(empty)

	var d_worst := _worst(prod[0], orc[0])
	var lo := INF
	for v in prod[0]:
		lo = minf(lo, v)
	print("    the native fill is %.1f m everywhere; the two differ by %.7f m" % [lo, d_worst])
	_check("C", d_worst < EPS and lo > 100.0 and is_finite(lo),
			"fill %.1f m, disagreement %.7f m (want a large finite fill)" % [lo, d_worst])

	# CONTROL: the kernel itself, not the node. The node has its own unreachable fill for the missing-symbol
	# case, and that fill would satisfy the criterion above while the kernel returned zeros.
	var res: Dictionary = Pasture3DUtil.path_query_grid(PackedVector2Array(), PackedFloat32Array(),
			4, 4, _rect(), 10000.0, 0.0)
	var d: PackedFloat32Array = res.get("distance", PackedFloat32Array())
	var kernel_fill: float = d[0] if d.size() > 0 else -1.0
	print("    control: the KERNEL fills an empty path with %.1f m (want the unreachable value, not 0)"
			% kernel_fill)
	if not (kernel_fill > 100.0):
		_fail += 1
		print("    !! the kernel reads an empty path as ON the road, which flattens a terrain")

	# CONTROL: a single point is still an empty PATH — no segments, nothing to be near. Off by one here
	# would index points[i + 1] past the end on the first query.
	var one := Pasture3DGraphPath.new()
	one.points = PackedVector2Array([Vector2(0.0, 0.0)])
	var single := _prod(one)
	print("    control: a one-point path reads %.1f m (want the same unreachable fill)" % single[0][0])
	if not (single[0][0] > 100.0):
		_fail += 1
		print("    !! a one-point path is being treated as a road")


# ---- D ------------------------------------------------------------------------------------------

func _mask_prod(p_path: Pasture3DGraphPath, p_feather: float, p_invert: bool) -> PackedFloat32Array:
	var node := Pasture3DGraphNodePathMask.new()
	node.feather = p_feather
	node.invert = p_invert
	node.set_path_inputs([p_path])
	return node.eval_grid([], G_N, G_N, null, _rect())


func _mask_oracle(p_path: Pasture3DGraphPath, p_feather: float, p_invert: bool) -> PackedFloat32Array:
	var node := Pasture3DGraphNodeDevPathMask.new()
	node.feather = p_feather
	node.invert = p_invert
	node.set_path_inputs([p_path])
	return node.eval_grid([], G_N, G_N, null, _rect())


## A closed outline: an L-shaped hexagon whose interior a corridor rule cannot reproduce.
##
## Deliberately NOT convex and NOT centred on the origin. A convex blob would pass a winding test written
## with the wrong crossing rule, and a centred one would hide an origin-relative mistake in the ray cast.
func _outline() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([
		Vector2(-30.0, -26.0), Vector2(6.0, -26.0), Vector2(6.0, -4.0),
		Vector2(26.0, -4.0), Vector2(26.0, 20.0), Vector2(-30.0, 20.0)])
	path.half_widths = PackedFloat32Array([4.0])
	path.closed = true
	return path


## [D] The native corridor mask matches the oracle, feathered and inverted.
##
## Both flags on, because `invert` and `feather` are the two places a port can be subtly wrong while still
## producing a mask-shaped field: inverting before the clamp, or feathering in `t` units instead of metres,
## both give a smooth [0,1] result that only disagrees with the oracle where the road changes width. The
## hairpin does change width, which is why it is the fixture here too.
func _d_the_corridor_mask_matches_the_oracle() -> void:
	print("[D] the native corridor mask matches the oracle")
	if not ClassDB.class_has_method("Pasture3DUtil", "path_mask_grid"):
		_check("D", false, "path_mask_grid is not bound — rebuild the GDExtension")
		return
	var path := _hairpin()
	var prod := _mask_prod(path, 4.0, false)
	var orc := _mask_oracle(path, 4.0, false)
	var worst := _worst(prod, orc)
	var inv_worst := _worst(_mask_prod(path, 4.0, true), _mask_oracle(path, 4.0, true))
	print("    worst disagreement: %.7f plain, %.7f inverted" % [worst, inv_worst])
	_check("D", worst < EPS and inv_worst < EPS,
			"plain %.7f / inverted %.7f (want < %.4f)" % [worst, inv_worst, EPS])

	# CONTROL: the mask must have BOTH ends and a middle. All-zero, all-one, or hard-edged are each a mask
	# that two implementations could agree on while neither did the work asked for.
	var on := 0
	var off := 0
	var mid := 0
	for v in prod:
		if v > 0.999:
			on += 1
		elif v < 0.001:
			off += 1
		else:
			mid += 1
	print("    control: %d cell(s) fully on, %d fully off, %d in the feather (want all three > 0)"
			% [on, off, mid])
	if on == 0 or off == 0 or mid == 0:
		_fail += 1
		print("    !! the mask is degenerate, so this criterion compared two constants")

	# CONTROL: inverting must actually change the answer. A port that ignored `invert` would agree with an
	# oracle that also ignored it, and the two checks above would both still pass.
	if _worst(prod, _mask_prod(path, 4.0, true)) < 0.5:
		_fail += 1
		print("    !! inverting the mask changed nothing")


# ---- E ------------------------------------------------------------------------------------------

## [E] A closed path masks its INTERIOR, and the two backends agree cell for cell about which cells those
## are.
##
## This is the criterion §8.1 exists for: reusing a Mound, Plow or Pond outline as a graph mask. Parity
## alone is weak here — two even-odd tests written from the same description agree easily — so the
## controls check the two ways the feature can be built and still be useless: an interior that never fills,
## and a "closed" path that is quietly still being read as a corridor.
func _e_a_closed_path_masks_its_interior() -> void:
	print("[E] a closed path masks its interior")
	if not ClassDB.class_has_method("Pasture3DUtil", "path_mask_grid"):
		_check("E", false, "path_mask_grid is not bound — rebuild the GDExtension")
		return
	var ring := _outline()
	var prod := _mask_prod(ring, 3.0, false)
	var orc := _mask_oracle(ring, 3.0, false)
	var worst := _worst(prod, orc)
	print("    worst disagreement over the outline: %.7f" % worst)
	_check("E", worst < EPS, "region mask disagrees by %.7f (want < %.4f)" % [worst, EPS])

	# CONTROL: the interior is FILLED, and it is a large fraction of the fixture. A region rule that
	# degenerated to a boundary corridor would still be smooth, still be [0,1], and still match an oracle
	# that had degenerated the same way — but it would fill a few percent, not a quarter.
	var filled := 0
	for v in prod:
		if v > 0.999:
			filled += 1
	var frac := float(filled) / float(prod.size())
	print("    control: %.1f%% of the grid is fully inside (want > 15%%)" % (frac * 100.0))
	if frac <= 0.15:
		_fail += 1
		print("    !! the interior is not being filled, so this is a boundary corridor wearing a region's name")

	# CONTROL: the SAME points read as an open path must give a materially different mask. This is what
	# proves `closed` reached the kernel at all: without it the corridor branch runs, the field still looks
	# like a mask, and every check above still passes.
	var open_path := Pasture3DGraphPath.new()
	open_path.points = ring.points
	open_path.half_widths = ring.half_widths
	var open_mask := _mask_prod(open_path, 3.0, false)
	var differ := 0
	for i in mini(prod.size(), open_mask.size()):
		if absf(prod[i] - open_mask[i]) > 0.5:
			differ += 1
	print("    control: %d cell(s) differ from the same points read OPEN (want a large count)" % differ)
	if differ < prod.size() / 20:
		_fail += 1
		print("    !! closed and open read the same, so the closed flag is not reaching the kernel")

	# CONTROL: a point known to be OUTSIDE the L's notch must read 0. The notch is the part a convex hull
	# or a non-zero winding rule would wrongly include, and it is the reason the fixture is L-shaped.
	var notch := _mask_prod(ring, 0.0, false)
	var ix := int((16.0 - G_MIN) / G_VS)
	var iz := int((-16.0 - G_MIN) / G_VS)
	var at_notch: float = notch[iz * G_N + ix]
	print("    control: the notch at (16, -16) reads %.3f (want 0 — it is outside the L)" % at_notch)
	if at_notch > 0.001:
		_fail += 1
		print("    !! the concave notch is being filled, so the winding test is not even-odd")
