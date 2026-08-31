# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphTransformGate — Pasture3DGraphNodeTransform, phase 1 of
# PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.1. Criteria TA-TE plus native/oracle parity.
#
# Transform is an inverse affine plus a bilinear tap, which is the single most reliable place in this whole
# batch to hide a HALF-TEXEL OFFSET: the result looks correct in isolation and is wrong by half a cell
# everywhere, which only shows itself as a seam where two transformed regions meet. TB (round-trip) and TC
# (pivot) are the two criteria that catch it, because both compare the field against ITSELF under a known
# relationship rather than against an eyeballed expectation.
#
# TE exists because every other criterion here is a comparison, and a comparison between two flat fields
# passes. If the fixture has no relief there is nothing to move and the gate has measured nothing.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphTransformGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const EPS := 1.0e-5
## The A/B tolerance every evaluator path in this plugin is held to.
const PARITY_EPS := 2.0e-6
## A resample is lossy: a round trip through two bilinear taps cannot return the input bit-for-bit. This
## is the budget for TB, as a fraction of the fixture's own relief.
const RESAMPLE_TOL := 0.08
## Cells this close to the grid edge are excluded from TB's recoverable set — the bilinear tap that
## produced them straddles the border.
const RECOVER_BUFFER := 2.0

var _fail := 0


func _ready() -> void:
	print("=== GraphTransformGate: affine resample (§4.1) ===\n")
	_te_fixture_has_signal()
	_ta_identity_is_bit_exact()
	_tb_round_trip()
	_tc_rotation_about_pivot()
	_td_nan_is_not_smeared()
	_tp_native_matches_oracle()
	_tw_brush_context_warning()
	print("\n=== %s (%d failures) ===\n" % ["TRANSFORM PASS" if _fail == 0 else "TRANSFORM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- TE. the fixture actually carries relief ----------------------------------------------------------
func _te_fixture_has_signal() -> void:
	print("[TE] NO-SIGNAL guard: the fixture has relief to move")
	var surf := _bumps()
	var lo := INF
	var hi := -INF
	for i in surf.size():
		lo = minf(lo, surf[i])
		hi = maxf(hi, surf[i])
	var rng := hi - lo
	print("    fixture height range = %.3f m (want > 1.0)" % rng)
	if rng <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the fixture is flat, every other criterion here is vacuous")


# --- TA. the identity affine is a bit-for-bit pass-through --------------------------------------------
func _ta_identity_is_bit_exact() -> void:
	print("[TA] identity (offset 0, rot 0, scale 1) reproduces the input exactly")
	var surf := _bumps()
	var got := _eval(surf, Vector2.ZERO, 0.0, 1.0, Vector2.ZERO)
	var d := _max_abs_diff(got, surf)
	print("    max |transform(identity) - in| = %.9f (want 0)" % d)
	if d > 0.0:
		_fail += 1; print("    !! the identity is not bit-exact — it is resampling when it should copy")
	# CONTROL: a 5 m offset must change the field, or TA is passing because the node does nothing.
	var moved := _max_abs_diff(_eval(surf, Vector2(5.0, 0.0), 0.0, 1.0, Vector2.ZERO), surf)
	print("    control: a 5 m offset moves the field by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the transform is not transforming")


# --- TB. transform then inverse-transform returns to the input ----------------------------------------
func _tb_round_trip() -> void:
	print("[TB] M then M-inverse returns to the input (grid interior only)")
	var surf := _bumps()
	var off := Vector2(37.0, -19.0)
	var rot := 23.0
	var scl := 1.35
	var piv := Vector2(15.0, 40.0)

	var there := _eval(surf, off, rot, scl, piv)
	# The exact inverse: undo scale and rotation about the same pivot, then undo the offset. Applied as
	# a second Transform node so the criterion tests the node, not a private inverse helper.
	var back := _eval_inverse(there, off, rot, scl, piv)

	# A round trip can only recover cells whose intermediate sample stayed on the grid. Where the first
	# transform pulled its value from beyond the border, `edge_mode` invented that value and no inverse
	# brings it back — comparing there would be measuring the edge policy, not the affine.
	var mask := _recoverable_mask(off, rot, scl, piv)

	var relief := _relief(surf)
	var d := _masked_max_abs_diff(back, surf, mask)
	var tol := RESAMPLE_TOL * relief
	var covered := 0
	for m in mask:
		if m:
			covered += 1
	print("    recoverable cells: %d of %d (%.0f%%)" % [covered, mask.size(), 100.0 * covered / mask.size()])
	print("    max |round-trip - in| over those = %.4f m (want < %.4f = %.0f%% of %.2f m relief)"
			% [d, tol, RESAMPLE_TOL * 100.0, relief])
	if covered < mask.size() / 4:
		_fail += 1; print("    !! NO-SIGNAL — too little of the grid round-trips for this to mean anything")
	if d > tol:
		_fail += 1; print("    !! the round trip did not return to the input — check for a half-texel offset")
	# CONTROL: a SINGLE transform must NOT be within tolerance of the input, or TB would pass for a
	# node that ignores its parameters entirely.
	var single := _masked_max_abs_diff(there, surf, mask)
	print("    control: a single transform differs by %.4f m (want > %.4f)" % [single, tol])
	if single <= tol:
		_fail += 1; print("    !! control dead — one transform already looks like the identity")


# --- TC. rotation is about `pivot`, not about the grid origin -----------------------------------------
func _tc_rotation_about_pivot() -> void:
	print("[TC] rotation is about `pivot` — a feature AT the pivot does not move")
	# A single sharp peak placed exactly at the pivot. Rotating about that point must leave it in place.
	var piv := Vector2(60.0, -35.0)
	var surf := _peak_at(piv)
	var got := _eval(surf, Vector2.ZERO, 47.0, 1.0, piv)

	var before := _value_at(surf, piv)
	var after := _value_at(got, piv)
	print("    peak height at the pivot: before %.3f, after %.3f" % [before, after])
	if absf(after - before) > 0.05 * maxf(absf(before), 1.0):
		_fail += 1; print("    !! the pivot moved — rotation is not being applied about it")
	# CONTROL: rotating about a FAR pivot must move the peak away. Without this, a node that ignored
	# rotation entirely would sail through TC.
	var far := _eval(surf, Vector2.ZERO, 47.0, 1.0, Vector2(-220.0, 220.0))
	var after_far := _value_at(far, piv)
	print("    control: with a far pivot the peak reads %.3f (want far from %.3f)" % [after_far, before])
	if absf(after_far - before) <= 0.05 * maxf(absf(before), 1.0):
		_fail += 1; print("    !! control dead — the pivot is being ignored, or rotation is not applied")


# --- TD. NaN survives and does not bleed into finite cells --------------------------------------------
func _td_nan_is_not_smeared() -> void:
	print("[TD] NaN in => NaN out, and no finite cell is contaminated through the bilinear tap")
	var surf := _bumps()
	# Punch a NaN hole — this is how the brush loop masks a region (spec §3.4).
	var hole_lo := 30
	var hole_hi := 40
	for iz in range(hole_lo, hole_hi):
		for ix in range(hole_lo, hole_hi):
			surf[iz * GW + ix] = NAN

	var got := _eval(surf, Vector2(12.0, 7.0), 0.0, 1.0, Vector2.ZERO)

	var nan_kept := 0
	var nan_total := 0
	var finite_nan := 0
	for i in surf.size():
		if is_nan(surf[i]):
			nan_total += 1
			if is_nan(got[i]):
				nan_kept += 1
		elif is_nan(got[i]):
			finite_nan += 1
	print("    NaN cells preserved: %d of %d (want all)" % [nan_kept, nan_total])
	print("    finite cells turned NaN: %d (want 0)" % finite_nan)
	if nan_kept != nan_total:
		_fail += 1; print("    !! NaN did not survive the transform — the loop mask would be lost")
	if finite_nan > 0:
		_fail += 1; print("    !! NaN bled into finite cells — this is the seam along every loop rim")


# --- Parity. the native kernel matches the [Dev/GD] oracle --------------------------------------------
func _tp_native_matches_oracle() -> void:
	print("[TP] native transform_grid == the GDScript oracle")
	if not ClassDB.class_has_method("Pasture3DUtil", "transform_grid"):
		_fail += 1; print("    !! Pasture3DUtil.transform_grid is not bound — rebuild the GDExtension")
		return

	var surf := _bumps()
	var off := Vector2(23.0, -41.0)
	var rot := 31.0
	var scl := 0.8
	var piv := Vector2(10.0, 10.0)

	var native: PackedFloat32Array = Pasture3DUtil.transform_grid(surf, GW, GH, RECT, off, rot, scl, piv, 0, 1.0)

	var oracle := Pasture3DGraphNodeDevTransform.new()
	oracle.offset = off
	oracle.rotation_deg = rot
	oracle.scale = scl
	oracle.pivot = piv
	oracle.amount = 1.0
	var want: PackedFloat32Array = oracle.eval_grid([surf], GW, GH, null, RECT)

	var d := _max_abs_diff(native, want)
	print("    max |native - oracle| = %.9f (want < %.9f)" % [d, PARITY_EPS])
	if d > PARITY_EPS:
		_fail += 1; print("    !! the C++ kernel and the oracle disagree")
	# CONTROL: the oracle produced a real transform, not a copy of the input.
	var moved := _max_abs_diff(want, surf)
	print("    control: the oracle moved the field by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the oracle returned the input unchanged")


# --- TW. the brush-context warning (spec §11 q2, settled 2026-08-30) -----------------------------------
# Every generator samples in WORLD XZ, which is what lets two masked brush regions agree where they meet.
# Transform breaks that for its subtree. On a full-terrain graph that is the node doing its job and there
# is nothing to disagree with, so it must stay SILENT there; inside a brush there is a neighbour and the
# break reads as a seam, so it says so once.
#
# The context is an argument, not state on the graph: the same .tres is meant to drive a landscape AND
# sit in a brush, so caching "am I in a brush" on the resource would make the warning depend on whichever
# host touched it last.
func _tw_brush_context_warning() -> void:
	print("[TW] Transform warns inside a brush graph and stays silent on a full terrain")
	var n := Pasture3DGraphNodeTransform.new()
	n.offset = Vector2(40.0, 0.0)
	var g := _build_graph([n])

	var terrain_w := g.graph_warnings(false)
	var brush_w := g.graph_warnings(true)
	var in_terrain := _mentions(terrain_w, "world XZ")
	var in_brush := _mentions(brush_w, "world XZ")
	print("    a moved Transform: full-terrain graph warns = %s (want false), brush graph warns = %s (want true)"
		% [in_terrain, in_brush])
	if in_terrain:
		_fail += 1
		print("    !! it warns on a full terrain, where the break costs nothing — that is the noise the")
		print("       decision was made to avoid, and users learn to ignore a tray that cries wolf")
	if not in_brush:
		_fail += 1
		print("    !! it stays silent inside a brush, so a seam between two footprints goes unannounced")

	# CONTROL. An identity Transform relocates nothing, so there is nothing to disagree about and it must
	# stay silent even in a brush. Without this, a warning hardwired to fire would pass both lines above.
	var idn := Pasture3DGraphNodeTransform.new()
	var ident_w := _build_graph([idn]).graph_warnings(true)
	var ident_warns := _mentions(ident_w, "world XZ")
	print("    CONTROL an identity Transform in a brush warns = %s (want false)" % ident_warns)
	if ident_warns:
		_fail += 1
		print("    !! the warning fires regardless of what the node does, so it carries no information")

	# CONTROL. The brush call must not simply return everything the terrain call does plus noise: the
	# ordinary warnings have to survive the new argument unchanged.
	var idn2 := Pasture3DGraphNodeTransform.new()
	var idg := _build_graph([idn2])
	var ok_shared: bool = _mentions(idg.graph_warnings(false), "identity") \
			and _mentions(idg.graph_warnings(true), "identity")
	print("    CONTROL the ordinary warnings still fire in both contexts = %s" % ok_shared)
	if not ok_shared:
		_fail += 1
		print("    !! the context argument dropped the node's normal warnings")


func _mentions(p_w: PackedStringArray, p_needle: String) -> bool:
	for line in p_w:
		if line.contains(p_needle):
			return true
	return false


# --- helpers ------------------------------------------------------------------------------------------
func _eval(p_surf: PackedFloat32Array, p_off: Vector2, p_rot: float, p_scale: float,
		p_pivot: Vector2) -> PackedFloat32Array:
	var n := Pasture3DGraphNodeTransform.new()
	n.offset = p_off
	n.rotation_deg = p_rot
	n.scale = p_scale
	n.pivot = p_pivot
	return _chain([n], p_surf)


## The exact inverse of _eval's affine, expressed as a Transform node so TB tests the node both ways.
## Forward is T(pivot) R S T(-pivot) T(offset); the inverse rotates and scales back about the same pivot
## and then removes the offset, which the node expresses as an offset rotated into the undone frame.
func _eval_inverse(p_surf: PackedFloat32Array, p_off: Vector2, p_rot: float, p_scale: float,
		p_pivot: Vector2) -> PackedFloat32Array:
	var n := Pasture3DGraphNodeTransform.new()
	n.rotation_deg = -p_rot
	n.scale = 1.0 / p_scale
	n.pivot = p_pivot
	# The forward pass shifted by `offset` BEFORE rotating and scaling about the pivot, so undoing it
	# here means applying the negated offset in the already-undone frame.
	var rad := deg_to_rad(-p_rot)
	var cs := cos(rad)
	var sn := sin(rad)
	var o := -p_off
	n.offset = Vector2(o.x * cs - o.y * sn, o.x * sn + o.y * cs) / p_scale
	return _chain([n], p_surf)


func _chain(p_mid: Array, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return _build_graph(p_mid).evaluate(GW, GH, RECT, null, p_surf)


## Split out of `_chain` so section TW can interrogate a graph's WARNINGS without evaluating it.
func _build_graph(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for m in p_mid:
		nodes.append(m)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(PackedInt32Array([i, 0, i + 1, 0]))
	g.connections = conns
	return g


## Asymmetric bumps: rotation-detectable (a radially symmetric fixture would look unchanged under any
## rotation, which would make TC pass for free) and band-limited enough to survive a resample.
func _bumps() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = 40.0 * sin(w.x * 0.011) * cos(w.y * 0.017) + 12.0 * sin(w.x * 0.004 + 1.3)
	return a


## A single smooth peak centred on a world point, wide enough that the bilinear tap does not alias it.
func _peak_at(p_centre: Vector2) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var d := w.distance_to(p_centre)
			a[iz * GW + ix] = 100.0 * exp(-(d * d) / (2.0 * 55.0 * 55.0))
	return a


func _value_at(p_g: PackedFloat32Array, p_world: Vector2) -> float:
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	var ix := clampi(int((p_world.x - RECT.position.x) / dx), 0, GW - 1)
	var iz := clampi(int((p_world.y - RECT.position.y) / dz), 0, GH - 1)
	return p_g[iz * GW + ix]


func _relief(p_g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for i in p_g.size():
		if is_nan(p_g[i]):
			continue
		lo = minf(lo, p_g[i])
		hi = maxf(hi, p_g[i])
	return maxf(hi - lo, 1.0)


## Cells the round trip can legitimately recover. The second (inverting) pass reads the first pass's
## output at F(v) = pivot + offset + scale * R(rot) * (v - pivot); when that point is off the grid, the
## value it reads was fabricated by `edge_mode` and is not the input's to return.
func _recoverable_mask(p_off: Vector2, p_rot: float, p_scale: float, p_pivot: Vector2) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(GW * GH)
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	var rad := deg_to_rad(p_rot)
	var cs := cos(rad)
	var sn := sin(rad)
	for iz in GH:
		for ix in GW:
			var v := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var q := v - p_pivot
			var fx := p_pivot.x + p_off.x + p_scale * (q.x * cs - q.y * sn)
			var fz := p_pivot.y + p_off.y + p_scale * (q.x * sn + q.y * cs)
			var cx := (fx - RECT.position.x) / dx - 0.5
			var cz := (fz - RECT.position.y) / dz - 0.5
			var inside := (cx >= RECOVER_BUFFER and cz >= RECOVER_BUFFER
					and cx <= GW - 1 - RECOVER_BUFFER and cz <= GH - 1 - RECOVER_BUFFER)
			mask[iz * GW + ix] = 1 if inside else 0
	return mask


func _masked_max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array,
		p_mask: PackedByteArray) -> float:
	var m := 0.0
	for i in p_mask.size():
		if p_mask[i] == 0 or is_nan(p_a[i]) or is_nan(p_b[i]):
			continue
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		var x := p_a[i]
		var y := p_b[i]
		if is_nan(x) and is_nan(y):
			continue
		if is_nan(x) or is_nan(y):
			return INF
		m = maxf(m, absf(x - y))
	return m
