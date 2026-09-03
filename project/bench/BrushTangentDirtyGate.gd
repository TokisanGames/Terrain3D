# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushTangentDirtyGate — P1 of PASTURE3D_BRUSH_GIZMO_INPUT_SPEC.md: a tangent-only curve edit must
# produce a tangent-sized repaint.
#
# ---- THE BUG THIS GATE HOLDS SHUT ----
#
# `_curve_cache` used to record point POSITIONS only. A double-click smooth/sharpen (and every
# tangent-handle drag) changes `point_in`/`point_out` and leaves every position identical, so
# `_moved_point_indices` returned an EMPTY list, `_spline_dirty_aabb` took its whole-spline fallback,
# and the bake cleared and repainted the entire footprint plus every overlapping layer-mate. Dragging a
# point was fast; double-clicking the same point stalled the editor, and the stall scaled with spline
# length rather than with the edit. The cache now holds [position, in, out] triples.
#
# ---- WHAT THIS GATE MEASURES, AND WHAT IT DELIBERATELY DOES NOT ----
#
# The bug is a BOX. `_spline_dirty_aabb` decides how much terrain gets cleared and repainted, so the box
# IS the cost — measuring it is measuring the stall, in closed form, with no terrain, no rasteriser and
# no wall clock. That last part is on purpose: a timing threshold here would be a benchmark, and this
# machine is not a benchmark machine (see the house note on perf runs). [B] is therefore stated as a
# RATIO against the whole-spline box, which is the same number on any hardware.
#
# [D] is a box-coverage criterion, not a pixel round trip. A narrower box is only safe if it still
# covers everything the old curve painted, so what has to be proven is coverage, not equality of two
# height maps — and coverage is exactly what the ghost-cut gate (RoadPerfRegressionGate [A]) established
# as the right level for this question. A terrain-level round trip belongs to a bake gate, not here.
#
# House discipline (bench/PlowReliefCheck.gd): every criterion carries a CONTROL that must fail if the
# path is dead, and `_completed` counts the criteria that actually reached their end, so a run that
# crashes half way reports "measured nothing" rather than "PASS (0 failures)".
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/BrushTangentDirtyGate.tscn
@tool
extends Node

## How many criteria are expected to report. A GDScript error inside one raises no failure count, so
## the verdict checks this too.
const EXPECTED: int = 4

## The point the edits are made at — mid-spline, so its neighbours exist on both sides and the partial
## box is genuinely local rather than clamped to an end.
const EDIT_IDX: int = 20

## A tangent long enough to clear `_total_padding()` (a fixed lateral reach added to every box), so [C]'s
## control can actually miss it. A tangent shorter than the padding is invisible to the measurement.
const LONG_TANGENT: float = 300.0

## The handle length a real smooth toggle produces: `_smooth_handle` uses a quarter of the shorter
## adjacent segment, and the fixture's segments are 50 m. [D] uses THIS rather than `LONG_TANGENT`,
## because its control asserts the box stays narrow and a 300 m handle legitimately makes a wide box —
## the box would be correct and the criterion would still fail, which is a fixture defect, not a bug.
const REAL_TANGENT: float = 12.5

var _fail: int = 0
var _completed: int = 0


func _ready() -> void:
	print("=== BrushTangentDirtyGate: a tangent edit is a tangent-sized repaint (P1) ===\n")
	_a_tangent_edit_is_seen()
	_b_box_is_local()
	_c_shrinking_a_tangent_still_clears()
	_d_toggle_covers_what_it_painted()
	var ok := _fail == 0 and _completed == EXPECTED
	print("\n=== %s (%d failures, %d/%d criteria reported) ===\n" % [
		"BRUSH TANGENT DIRTY PASS" if ok else "BRUSH TANGENT DIRTY FAIL",
		_fail, _completed, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["    " if p_ok else "!!  ", p_name, p_detail])


func _area(p_box: AABB) -> float:
	return p_box.size.x * p_box.size.z


## True when `p_outer` covers `p_xz` in XZ. Corner-wise rather than AABB.has_point because the boxes
## carry a nominal ±10000 Y span that is not what is being asserted.
func _covers_point_xz(p_outer: AABB, p_xz: Vector3) -> bool:
	const EPS := 0.001
	return p_outer.position.x <= p_xz.x + EPS \
			and p_outer.position.z <= p_xz.z + EPS \
			and p_outer.position.x + p_outer.size.x >= p_xz.x - EPS \
			and p_outer.position.z + p_outer.size.z >= p_xz.z - EPS


## A brush with one long straight spline under it, both in the tree so `to_global` is meaningful.
##
## LONG on purpose, for the same reason RoadPerfRegressionGate's fixture is: `_total_padding()` is a
## fixed lateral reach added to every box, so on a short spline it swamps the measurement and even a
## perfectly narrow partial box comes out at 80%+ of the whole — a fixture that would fail [B] against
## correct code. A kilometres-long spline is also the case the partial path exists for.
func _fixture() -> Array:
	var brush := Pasture3DRidge.new()
	add_child(brush)
	var path := Path3D.new()
	var curve := Curve3D.new()
	for i in range(41):
		curve.add_point(Vector3(float(i) * 50.0 - 1000.0, 0.0, 0.0))
	path.curve = curve
	brush.add_child(path)
	# The baseline the diff measures against — the state at "last bake".
	brush._update_curve_cache(path)
	return [brush, path]


# ---- [A] a tangent edit is seen as a change ----------------------------------------------------

func _a_tangent_edit_is_seen() -> void:
	print("[A] a tangent-only edit registers as a moved point")
	var fx := _fixture()
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]

	# THE CONTROL FIRST, because it is what says the diff is awake at all. No edit → nothing moved. If
	# this and the measurement below answer the same thing, the diff is not reading tangents and [A]
	# proves nothing.
	var unedited: PackedInt32Array = brush._moved_point_indices(path)
	_check("CONTROL: an untouched curve reports no moved points",
			unedited.is_empty(), "moved %s" % [unedited])

	# The edit the user makes by double-clicking: tangents change, every POSITION stays identical.
	path.curve.set_point_in(EDIT_IDX, Vector3(0.0, 0.0, -25.0))
	path.curve.set_point_out(EDIT_IDX, Vector3(0.0, 0.0, 25.0))
	var moved: PackedInt32Array = brush._moved_point_indices(path)

	# A superset of the touched point is fine (a future diff may widen to neighbours); empty is the bug
	# and "every point" is the whole-spline fallback wearing a different hat.
	_check("the edited point is reported", EDIT_IDX in moved, "moved %s" % [moved])
	_check("not the whole spline", moved.size() < path.curve.point_count,
			"%d of %d points" % [moved.size(), path.curve.point_count])
	_completed += 1


# ---- [B] the dirty box is local ----------------------------------------------------------------

func _b_box_is_local() -> void:
	print("\n[B] the repaint box is a fraction of the spline, not all of it")
	var fx := _fixture()
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]
	var whole: AABB = brush._spline_footprint_aabb(path)
	var stale: AABB = brush._spline_dirty_aabb(path, PackedInt32Array())

	path.curve.set_point_in(EDIT_IDX, Vector3(0.0, 0.0, -25.0))
	path.curve.set_point_out(EDIT_IDX, Vector3(0.0, 0.0, 25.0))
	var moved: PackedInt32Array = brush._moved_point_indices(path)
	var partial: AABB = brush._spline_dirty_aabb(path, moved, stale)
	var frac := _area(partial) / maxf(_area(whole), 0.001)
	_check("tangent edit repaints a small fraction of the footprint", frac < 0.35,
			"%.1f%% of the whole footprint (%.1f / %.1f m2)" % [
				frac * 100.0, _area(partial), _area(whole)])

	# THE CONTROL: the pre-fix behaviour, reproduced exactly — an empty moved-index list is what the
	# positions-only cache handed `_spline_dirty_aabb` for this same edit. It must measure the whole
	# spline. A gate that cannot produce the old number cannot claim it improved anything.
	var old_way: AABB = brush._spline_dirty_aabb(path, PackedInt32Array(), stale)
	var old_frac := _area(old_way) / maxf(_area(whole), 0.001)
	_check("CONTROL: the pre-fix path repaints the whole spline", old_frac > 0.95,
			"%.1f%% of the whole footprint" % [old_frac * 100.0])
	_completed += 1


# ---- [C] a shrinking tangent still clears where it was ------------------------------------------

func _c_shrinking_a_tangent_still_clears() -> void:
	print("\n[C] sharpening a smooth point clears where the OLD handle reached")
	var fx := _fixture()
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]

	# Smooth the point with a long handle and make that the baked baseline — the terrain now holds a cut
	# out at the end of that handle.
	var far_in := Vector3(0.0, 0.0, -LONG_TANGENT)
	path.curve.set_point_in(EDIT_IDX, far_in)
	path.curve.set_point_out(EDIT_IDX, Vector3(0.0, 0.0, LONG_TANGENT))
	brush._update_curve_cache(path)
	var stale: AABB = brush._spline_dirty_aabb(path, PackedInt32Array())
	var old_handle: Vector3 = path.to_global(path.curve.get_point_position(EDIT_IDX) + far_in)

	# Sharpen it back to a corner. The new curve reaches nowhere near the old handle, so the ONLY record
	# of where the cut is lives in the previous cached tangents.
	path.curve.set_point_in(EDIT_IDX, Vector3.ZERO)
	path.curve.set_point_out(EDIT_IDX, Vector3.ZERO)
	var moved: PackedInt32Array = brush._moved_point_indices(path)
	var box: AABB = brush._spline_dirty_aabb(path, moved, stale)
	_check("the box covers the old handle's reach", _covers_point_xz(box, old_handle),
			"handle z %.1f in box z[%.1f,%.1f]" % [
				old_handle.z, box.position.z, box.position.z + box.size.z])

	# THE CONTROL: drop the previous cache and the same call has only the CURRENT curve to work from —
	# the naive fix that reads tangents forward but not backward. It must miss the old handle, or the
	# fixture never reproduced the stranded cut and [C] proves nothing.
	brush._curve_cache.erase(path.get_instance_id())
	var forward_only: AABB = brush._spline_dirty_aabb(path, moved, AABB())
	_check("CONTROL: without the previous tangents the old cut is missed",
			not _covers_point_xz(forward_only, old_handle),
			"box z[%.1f,%.1f]" % [
				forward_only.position.z, forward_only.position.z + forward_only.size.z])
	_completed += 1


# ---- [D] a smooth/sharpen round trip strands nothing ---------------------------------------------

func _d_toggle_covers_what_it_painted() -> void:
	print("\n[D] smooth then sharpen: neither box strands the other's cut")
	var fx := _fixture()
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]
	var pos: Vector3 = path.curve.get_point_position(EDIT_IDX)

	# Toggle 1 — smooth. The box must cover where the NEW curve will paint.
	var stale: AABB = brush._spline_dirty_aabb(path, PackedInt32Array())
	var handle := Vector3(0.0, 0.0, REAL_TANGENT)
	path.curve.set_point_in(EDIT_IDX, -handle)
	path.curve.set_point_out(EDIT_IDX, handle)
	var smooth_box: AABB = brush._spline_dirty_aabb(path, brush._moved_point_indices(path), stale)
	_check("the smoothing box covers the new handles",
			_covers_point_xz(smooth_box, path.to_global(pos + handle))
			and _covers_point_xz(smooth_box, path.to_global(pos - handle)),
			"box z[%.1f,%.1f]" % [smooth_box.position.z, smooth_box.position.z + smooth_box.size.z])
	brush._update_curve_cache(path)

	# Toggle 2 — sharpen. The box must cover where toggle 1 painted, or the smoothed cut is stranded.
	var sharp_box: AABB = brush._spline_dirty_aabb(path, PackedInt32Array([EDIT_IDX]), smooth_box)
	path.curve.set_point_in(EDIT_IDX, Vector3.ZERO)
	path.curve.set_point_out(EDIT_IDX, Vector3.ZERO)
	sharp_box = brush._spline_dirty_aabb(path, brush._moved_point_indices(path), smooth_box)
	_check("the sharpening box covers where smoothing painted",
			_covers_point_xz(sharp_box, path.to_global(pos + handle))
			and _covers_point_xz(sharp_box, path.to_global(pos - handle)),
			"box z[%.1f,%.1f]" % [sharp_box.position.z, sharp_box.position.z + sharp_box.size.z])

	# THE CONTROL: both boxes stay narrow through the round trip. A fix that made [D] pass by widening
	# every box back to the whole spline is the regression this whole phase exists to remove.
	var whole: AABB = brush._spline_footprint_aabb(path)
	var worst := maxf(_area(smooth_box), _area(sharp_box)) / maxf(_area(whole), 0.001)
	_check("CONTROL: neither box widened back to the whole spline", worst < 0.35,
			"worst %.1f%% of the whole footprint" % [worst * 100.0])
	_completed += 1
