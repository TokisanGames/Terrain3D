# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pace notes — the co-driver's calls (§9.4, P6b). A PURE KERNEL over two curves the vertical alignment
# solver already produced.
#
# ---- WHY THIS IS ALMOST FREE ----
#
# Every quantity a pace note needs was computed for a different reason. Corner severity and side come
# from plan curvature and its sign; crest and dip come from the sign of d²z/ds², which is the vertical
# solver's own smoothness term; "tightens" and "opens" come from the derivative of curvature; surface
# changes come from the intervals the runtime already carries. Nothing here solves anything — it is a
# peak detect over data that exists.
#
# This is worth stating plainly because it is the argument for §7: **the vertical alignment solver was
# argued for on realism grounds and turns out to also be the pace-note engine.** A draped road cannot
# produce these calls at all. d²z/ds² on a drape is terrain noise sampled at the road's position, so a
# draped road generates a crest call every few metres and none of them mean anything.
@tool
class_name Pasture3DRoadPaceNotes
extends RefCounted

## What a call is about. `severity` is only meaningful for CORNER.
enum Kind { CORNER, CREST, DIP, SURFACE, CAUTION }

## Corner severity boundaries, as turn RADIUS in metres, from tightest to most open. Severity 1 is a
## hairpin and 6 is nearly straight — the rally convention, where the number counts UP with speed.
##
## Which way the scale runs is a real fork: some co-drivers number the other way, and a system that
## picked silently would produce notes that are exactly wrong for half its users. This is the "1 is
## slowest" convention, stated here so it can be argued with rather than discovered.
const SEVERITY_RADII: Array[float] = [15.0, 30.0, 60.0, 110.0, 200.0, 400.0]

## Curvature below this is a straight, not a very open corner. Without a floor, a road with any noise in
## its plan is one continuous sequence of 6s and the notes are unreadable.
const STRAIGHT_CURVATURE: float = 1.0 / 500.0

## Vertical curvature that counts as a crest or a dip, in 1/m. Below this the road is merely undulating.
const CREST_CURVATURE: float = 0.0015

## Two calls closer together than this are one feature detected twice, metres.
const MERGE_DISTANCE: float = 20.0

## How much curvature must change across a corner before it is called as tightening or opening, as a
## fraction of the corner's own curvature.
const SHAPE_CHANGE: float = 0.35


## Severity 1-6 for a turn radius, or 0 for a straight.
static func severity_for_radius(p_radius: float) -> int:
	if not is_finite(p_radius) or p_radius <= 0.0:
		return 1
	for i in SEVERITY_RADII.size():
		if p_radius <= SEVERITY_RADII[i]:
			return i + 1
	return 0


## The calls along one run, as `[{s, kind, severity, direction, shape, text}, ...]` in ascending `s`.
##
## `direction` is -1 for left, +1 for right, 0 where it does not apply. Read straight off the SIGN of
## curvature, which is why reversing a run must flip that sign (P6a): a right-hander driven backwards is
## a left-hander, and a run that kept the sign would have the co-driver calling every corner wrongly on
## the reverse stage.
##
## Generated, then designer-editable — like any generated artifact. Nothing downstream re-derives them.
static func generate(p_run: Pasture3DRoadRun, p_reversed: bool = false) -> Array:
	if p_run == null or p_run.alignment == null:
		return []
	var out: Array = []
	out.append_array(_corners(p_run, p_reversed))
	out.append_array(_crests(p_run, p_reversed))
	out.append_array(_surfaces(p_run, p_reversed))
	out.sort_custom(func(a, b): return float(a["s"]) < float(b["s"]))
	return _merge(out)


## Corners: contiguous stretches where |curvature| clears the straight threshold, called at the point of
## tightest curvature within each.
##
## Called at the PEAK rather than at the entry, because severity is what the driver needs and severity is
## a property of the tightest point. A note placed at the entry with the entry's severity describes a
## corner the driver is about to stop being in.
static func _corners(p_run: Pasture3DRoadRun, p_reversed: bool) -> Array:
	var a := p_run.alignment
	var n := a.curvature.size()
	var out: Array = []
	var i := 0
	while i < n:
		if absf(a.curvature[i]) < STRAIGHT_CURVATURE:
			i += 1
			continue
		var start := i
		var peak := i
		while i < n and absf(a.curvature[i]) >= STRAIGHT_CURVATURE \
				and signf(a.curvature[i]) == signf(a.curvature[start]):
			if absf(a.curvature[i]) > absf(a.curvature[peak]):
				peak = i
			i += 1
		var k: float = absf(a.curvature[peak])
		if k <= 0.0:
			continue
		var sev := severity_for_radius(1.0 / k)
		if sev == 0:
			continue
		var raw_s := float(peak) * a.ds
		var entry: float = absf(a.curvature[start])
		var exit: float = absf(a.curvature[i - 1])
		# "Tightens" and "opens" are the derivative of curvature along the corner — and they must be read
		# in the direction of TRAVEL, so reversing swaps them. A corner that opens one way tightens the
		# other, and that is the note a driver most needs to be right.
		var first := exit if p_reversed else entry
		var last := entry if p_reversed else exit
		var shape := ""
		if last > first * (1.0 + SHAPE_CHANGE):
			shape = "tightens"
		elif first > last * (1.0 + SHAPE_CHANGE):
			shape = "opens"
		var dir := int(signf(a.curvature[peak])) * (-1 if p_reversed else 1)
		var length := float(i - start) * a.ds
		out.append(_call(p_run, raw_s, p_reversed, {
			"kind": Kind.CORNER, "severity": sev, "direction": dir, "shape": shape,
			"text": "%s %d%s%s" % ["left" if dir < 0 else "right", sev,
					" " + shape if shape != "" else "", " long" if length > 120.0 else ""],
		}))
	return out


## Crests and dips: peaks in the SECOND derivative of the profile, which the solver already smooths over.
static func _crests(p_run: Pasture3DRoadRun, p_reversed: bool) -> Array:
	var a := p_run.alignment
	var out: Array = []
	var i := 1
	while i < a.count() - 1:
		var vc := a.vertical_curvature_at(i)
		if absf(vc) < CREST_CURVATURE:
			i += 1
			continue
		var start := i
		var peak := i
		while i < a.count() - 1 and absf(a.vertical_curvature_at(i)) >= CREST_CURVATURE \
				and signf(a.vertical_curvature_at(i)) == signf(a.vertical_curvature_at(start)):
			if absf(a.vertical_curvature_at(i)) > absf(a.vertical_curvature_at(peak)):
				peak = i
			i += 1
		# A CREST is where the road stops climbing and starts falling: the profile is concave DOWN, so
		# its second derivative is negative. Getting this sign backwards calls every brow a dip, which
		# reads as plausible until a driver jumps one.
		var is_crest := a.vertical_curvature_at(peak) < 0.0
		out.append(_call(p_run, float(peak) * a.ds, p_reversed, {
			"kind": Kind.CREST if is_crest else Kind.DIP, "severity": 0, "direction": 0, "shape": "",
			"text": "crest" if is_crest else "dip",
		}))
	return out


## Surface changes, from the intervals the run already carries.
static func _surfaces(p_run: Pasture3DRoadRun, p_reversed: bool) -> Array:
	var out: Array = []
	for i in range(1, p_run.surfaces.size()):
		var at := float(p_run.surfaces[i][0])
		var onto := StringName(p_run.surfaces[i][2])
		var from := StringName(p_run.surfaces[i - 1][2])
		# Reversed, the transition is entered from the other side, so the surface being called is the one
		# that was BEHIND it going the other way.
		var into: StringName = from if p_reversed else onto
		out.append(_call(p_run, at, p_reversed, {
			"kind": Kind.SURFACE, "severity": 0, "direction": 0, "shape": "",
			"text": "onto %s" % String(into),
		}))
	return out


## Stamp a call with its arc length in the direction of travel.
static func _call(p_run: Pasture3DRoadRun, p_raw_s: float, p_reversed: bool, p_fields: Dictionary) -> Dictionary:
	var out := p_fields.duplicate()
	out["s"] = (p_run.length() - p_raw_s) if p_reversed else p_raw_s
	return out


## Collapse calls of the same KIND that are closer together than MERGE_DISTANCE.
##
## Same kind only. A crest at the apex of a corner is two calls about the same place and both are wanted
## — "crest, right 3" is a real note — whereas two corner calls 5 m apart are one corner found twice.
static func _merge(p_calls: Array) -> Array:
	var out: Array = []
	for c: Dictionary in p_calls:
		var dup := false
		for seen: Dictionary in out:
			if int(seen["kind"]) == int(c["kind"]) \
					and absf(float(seen["s"]) - float(c["s"])) < MERGE_DISTANCE:
				dup = true
				break
		if not dup:
			out.append(c)
	return out
