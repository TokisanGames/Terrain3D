# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# MarginSeamGate — the Modifier Margin must not put a step in any modifier's mask at the loop rim.
#
# The margin band carries a taper that runs 1 AT THE RIM down to 0 at the band's outer edge. The brush's own
# interior profile runs the other way: 1 at the loop centre down to 0 AT THE RIM. Both are 0..1 masks over
# the same grid, and folding the first into the second is what produced a visible seam: a GENERATOR — noise,
# relief, or a graph with no Input node — read a mask that fell to 0 at the rim and jumped straight back to
# ~1 one cell outside it, so it wrote a ring of its full amplitude around every loop.
#
# The fix keeps them apart. `profile` stays the generator's mask and is 0 through the band; `margin_feather`
# is the filter's, and a filter is 1 across the loop, so IT meets the band without a step. This gate pins
# both, and measures the step across the rim in each mask, because "0 in the band" and "no seam" are not the
# same claim and only the second is what the user sees.
#
# THE CONTROL IS THE OLD BEHAVIOUR, recomputed here from the same inputs: [C] asserts that folding the
# feather into the profile — exactly what the code used to do — produces a step of nearly the modifier's
# full amplitude. Without that row, a gate reporting "generator step = 0.000" cannot distinguish a fixed
# seam from a fixture whose band is empty and which therefore measures nothing.

extends Node

const CELL := 1.0
const MARGIN := 10.0 ## metres of band on each side
const HALF := 30.0 ## metres from the loop's centre to its rim
const FALLOFF := 30.0 ## metres the interior profile ramps over — a real mound's flank, not one cell
const N := 121

## The first cell INSIDE the loop and the last one outside it, derived from the signed field rather than
## counted by hand: the rim falls between two cells and an off-by-one here would compare two band cells to
## each other and report a seam of zero on code that has one.
var _rim_in := -1
var _rim_out := -1

var _fail := 0


func _ready() -> void:
	print("=== MarginSeamGate: no step in any mask at the loop rim ===\n")
	_test_masks()
	print("\n=== %s (%d failures) ===\n" % [
		"MARGIN SEAM PASS" if _fail == 0 else "MARGIN SEAM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label,
			("  (%s)" % p_detail) if p_detail != "" else ""])


## A 1-cell-tall strip through a loop: cells IN0..IN1 inside, everything else real ground the band can
## claim. One row is enough — the seam is a function of the signed distance and nothing else.
func _run() -> Dictionary:
	var mound := Pasture3DMound.new()
	mound.modifier_margin = MARGIN
	add_child(mound)

	var amp := PackedFloat64Array()
	var profile := PackedFloat64Array()
	var basey := PackedFloat32Array()
	var sdf := PackedFloat32Array()
	amp.resize(N)
	profile.resize(N)
	basey.resize(N)
	sdf.resize(N)

	var mid := 0.5 * float(N - 1)
	for i in range(N):
		basey[i] = 0.0
		# Signed distance in metres: positive inside the loop, negative outside.
		var d: float = HALF - absf(float(i) - mid) * CELL
		sdf[i] = d
		if d > 0.0:
			# Inside: the brush contributes, and its interior mask ramps 0 at the rim to 1 over the
			# falloff. At one metre in, that is 1/30 — which is why a band starting at 1 is a cliff.
			amp[i] = 1.0
			profile[i] = clampf(d / FALLOFF, 0.0, 1.0)
			if _rim_in < 0:
				_rim_in = i
				_rim_out = i - 1
		else:
			amp[i] = NAN # off the loop — the band is exactly these cells
			profile[i] = 0.0

	var ctx := {
		"gw": N, "gh": 1, "add": false, "sdf": sdf, "edge_offset": 0.0,
		"vertex_spacing": CELL, "min_x": 0.0, "min_z": 0.0,
	}
	mound._run_modifier_stack([], amp, profile, basey, ctx)
	mound.queue_free()
	return ctx


func _test_masks() -> void:
	var ctx := _run()
	var profile: PackedFloat64Array = ctx["profile"]
	var mask: PackedByteArray = ctx["margin_mask"]
	var feather: PackedFloat64Array = ctx["margin_feather"]

	print("[A] The band exists at all — without this every other row is vacuous")
	var band := 0
	var inside := 0
	for k in range(N):
		if mask[k] == 1:
			band += 1
		elif is_finite(profile[k]) and ctx["sdf"][k] > 0.0:
			inside += 1
	_check("the rim was located between two cells", _rim_in > 0 and _rim_out == _rim_in - 1,
			"inside starts at %d" % _rim_in)
	_check("every cell off the loop became a band cell", band == N - inside,
			"%d band + %d inside = %d" % [band, inside, N])
	_check("the feather is ~1 where the band meets the rim",
			absf(feather[_rim_out] - 1.0) < 0.05, "%.4f" % feather[_rim_out])
	_check("and falls to 0 at the band's outer edge", feather[0] < 0.05, "%.4f" % feather[0])
	print("")

	print("[B] A GENERATOR's mask (`profile`) is 0 through the band")
	var worst := 0.0
	for k in range(N):
		if mask[k] == 1:
			worst = maxf(worst, absf(profile[k]))
	_check("no band cell carries any interior profile", worst == 0.0, "worst %.6f" % worst)
	# The seam as the user sees it: the jump in the mask across the rim, in units of the modifier's
	# amplitude. The interior side is ~0 there because the profile feathers to 0 at the rim.
	var gen_step: float = absf(profile[_rim_out] - profile[_rim_in])
	_check("so the generator's mask is continuous across the rim", gen_step < 0.05,
			"step %.4f" % gen_step)
	print("")

	print("[C] Control: the old fold, recomputed from the same inputs")
	# What the code used to do — write the feather into `profile` — reconstructed cell for cell. If this
	# does NOT show a large step, the fixture has no band at the rim and [B] proved nothing.
	var old := profile.duplicate()
	for k in range(N):
		if mask[k] == 1:
			old[k] = feather[k]
	var old_step: float = absf(old[_rim_out] - old[_rim_in])
	_check("folding the feather into the profile DOES step at the rim", old_step > 0.9,
			"step %.4f — this is the seam" % old_step)
	_check("and the fix is strictly better", gen_step < old_step,
			"%.4f vs %.4f" % [gen_step, old_step])
	print("")

	print("[D] A FILTER's mask is 1 across the loop, then the feather")
	# The mask `_apply_graph_step` builds for a graph that reads its input, reconstructed by the same rule.
	var fmask := PackedFloat64Array()
	fmask.resize(N)
	for k in range(N):
		fmask[k] = feather[k] if mask[k] == 1 else 1.0
	var filt_step: float = absf(fmask[_rim_out] - fmask[_rim_in])
	_check("full strength inside the loop", fmask[_rim_in] == 1.0 and fmask[N / 2] == 1.0)
	_check("continuous across the rim too", filt_step < 0.05, "step %.4f" % filt_step)
	_check("and it still tapers away — the erosion skirt survives the fix",
			fmask[0] < 0.05, "outer edge %.4f" % fmask[0])
	print("")
