# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SaleveMarginInvarianceProbe — does a brush's Modifier Margin change the sim inside the brush?
#
# A margin widens the solved grid without moving one vertex of the shape (see
# PASTURE3D_BRUSH_EROSION_SPEC.md §6.8.1), so the erosion INSIDE the loop should not care. It used to
# care a great deal: the solver's unit of length was `1 / gw`, so adding cells rescaled every slope,
# drainage distance and deposition radius against the landform.
#
# This probe solves the SAME dome twice at the SAME cell size — once on a tight grid, once on a grid
# widened by a margin band of surrounding (lower) ground — and compares the overlapping core cell for
# cell. It reports, rather than asserts, because two of the remaining couplings are inherent to the
# algorithm and are worth seeing as numbers:
#
#   * Stage 1 renormalises its result to [0..1] over the WHOLE grid, and
#   * the output is anchored at the grid's `zmin`,
#
# both of which see the band. Pinning `reference_relief` removes the third and largest coupling (the
# vertical scale every length is divided by). The AUTO row is the control: it must be visibly worse
# than the PINNED row, or this probe is measuring nothing.

extends Node

const DevSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")

const CELL := 2.0 ## metres per cell, identical in both solves — this is a footprint change, not a resize.
const CORE := 64 ## cells across the brush's own footprint.
const DOME_RELIEF := 90.0 ## metres, peak above the surrounding plain.


func _ready() -> void:
	print("=== SaleveMarginInvarianceProbe: does a Modifier Margin move the sim inside the loop? ===\n")
	print("    cell %.1f m | core %d cells (%.0f m) | dome relief %.0f m\n" % [
		CELL, CORE, CORE * CELL, DOME_RELIEF])

	# margin 0 is the null row: the two solves are the same solve, so every column must read 0.000. If it
	# does not, the harness is measuring itself and no other row means anything.
	var rows := []
	for margin_cells in [0, 2, 8, 30]:
		rows.append(_measure(margin_cells, 0.0))
		rows.append(_measure(margin_cells, DOME_RELIEF))

	print("\n    margin   reference_relief    max drift   RMS drift  |  offset   RESHAPING (max/RMS)")
	for r in rows:
		print("    %4d m   %-16s  %8.3f m  %8.3f m  | %7.3f m  %7.3f m / %.3f m" % [
			int(r["margin_m"]),
			"auto (control)" if r["ref"] == 0.0 else "pinned %.0f m" % r["ref"],
			r["max"], r["rms"], r["offset"], r["max_shape"], r["rms_shape"],
		])
	print("\n    'offset' is a bulk vertical shift (the output is anchored at the grid's zmin, which the")
	print("    band lowers) — a brush composites through its own blend, so a shift is far less visible")
	print("    than RESHAPING, which is the drainage network itself moving inside the loop.")

	var auto_worst := 0.0
	var pinned_worst := 0.0
	for r in rows:
		if r["ref"] == 0.0:
			auto_worst = maxf(auto_worst, r["max"])
		else:
			pinned_worst = maxf(pinned_worst, r["max"])

	print("\n    control (auto)  worst drift = %.3f m" % auto_worst)
	print("    pinned          worst drift = %.3f m" % pinned_worst)
	var ok := pinned_worst < auto_worst
	print("\n=== %s ===\n" % [
		"MARGIN INVARIANCE IMPROVED by pinning the reference" if ok
		else "NO IMPROVEMENT — pinning the reference did not help, investigate"])
	get_tree().quit(0 if ok else 1)


## Solve the same dome on a tight grid and on one widened by `p_margin_cells` of surrounding ground,
## then compare the overlapping core.
func _measure(p_margin_cells: int, p_reference_relief: float) -> Dictionary:
	var tight := _solve(CORE, 0, p_reference_relief)
	var wide := _solve(CORE, p_margin_cells, p_reference_relief)
	var wide_w: int = CORE + 2 * p_margin_cells

	# Collect the signed differences first: a drift that is mostly a constant OFFSET (the output is
	# anchored at the grid's zmin, which the band lowers) is a different defect from one that is a
	# reshaping (the drainage network itself moved). Splitting them says which is worth chasing.
	var diffs := PackedFloat32Array()
	var sum := 0.0
	for iz in range(CORE):
		for ix in range(CORE):
			var a: float = tight[iz * CORE + ix]
			var b: float = wide[(iz + p_margin_cells) * wide_w + (ix + p_margin_cells)]
			if not (is_finite(a) and is_finite(b)):
				continue
			diffs.append(b - a)
			sum += b - a

	var count := maxi(diffs.size(), 1)
	var mean: float = sum / float(count)
	var max_d := 0.0
	var sum_sq := 0.0
	var max_shape := 0.0
	var sum_sq_shape := 0.0
	for d in diffs:
		max_d = maxf(max_d, absf(d))
		sum_sq += d * d
		var s: float = d - mean # the same difference with the bulk vertical shift taken out
		max_shape = maxf(max_shape, absf(s))
		sum_sq_shape += s * s

	return {
		"margin_m": float(p_margin_cells) * CELL,
		"ref": p_reference_relief,
		"max": max_d,
		"rms": sqrt(sum_sq / float(count)),
		"offset": mean,
		"max_shape": max_shape,
		"rms_shape": sqrt(sum_sq_shape / float(count)),
	}


## The dome sits at a fixed WORLD position and keeps its shape; only how much surrounding ground is
## included in the solve changes. Cell size is constant, so this is a footprint change and nothing else.
func _solve(p_core: int, p_margin_cells: int, p_reference_relief: float) -> PackedFloat32Array:
	var w: int = p_core + 2 * p_margin_cells
	var origin: float = -float(p_margin_cells) * CELL
	var rect := Rect2(origin, origin, float(w) * CELL, float(w) * CELL)

	var surface := PackedFloat32Array()
	surface.resize(w * w)
	var cx: float = 0.5 * float(p_core) * CELL
	var radius: float = 0.45 * float(p_core) * CELL
	for iz in range(w):
		for ix in range(w):
			var wx: float = origin + float(ix) * CELL
			var wz: float = origin + float(iz) * CELL
			var r: float = Vector2(wx - cx, wz - cx).length()
			# Dome inside the radius, gently falling plain outside it — the band is real, lower ground.
			var h: float = DOME_RELIEF * cos(minf(r / radius, 1.0) * PI * 0.5)
			h += 3.0 * sin(wx * 0.01) * cos(wz * 0.013) # a little relief so the band is not dead flat
			surface[iz * w + ix] = h

	var params := {
		"iterations": 20,
		"erosion_strength": 0.7,
		"drainage_exponent": 0.15,
		"drainage_noise": 0.15,
		"shape_preservation": 2.0,
		"reference_relief": p_reference_relief,
		"bank_smoothing": 0.1,
		"deposition_radius": 25.0,
		"deposition_strength": 0.5,
		"stream_strength": 0.02,
		"stream_exp": 0.8,
		"enable_post_smoothing": false,
		"gain": 1.0,
		"gamma": 1.0,
		"mix_factor": 1.0,
		"seed": 0,
	}
	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, w, w, rect, params)
	return res.get("height", surface)
