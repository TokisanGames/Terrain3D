# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphReliefNodeGate — the first graph-native relief nodes: Furrows (GENERATOR) and Terrace (FILTER),
# built under clean single-purpose category semantics (PASTURE3D_TERRAIN_GRAPH_SPEC.md §6).
#
# The claims:
#   Furrows is a pure GENERATOR — 0 inputs, world-space corrugation — and the graph evaluator's output
#   matches an INDEPENDENT re-derivation of the corrugation formula per cell (which also cross-checks that
#   the node's delegation to Pasture3DReliefMaterial._furrows agrees with the hand math).
#   Terrace is a pure FILTER — 1 input — that bands EXACTLY the field wired into it and generates nothing
#   of its own: a flat input yields a flat output, and terracing two different inputs gives two different
#   results. Its output matches an independent metric-band re-derivation.
#   Furrows -> Terrace -> Output composes generator into filter end to end.
#   The category metadata (input_count/role/has_output) is correct, and a graph holding these ops is NOT
#   native_supported (so the host falls back to the GDScript path). Controls throughout.
#
# Pure GDScript on the graph model + relief statics; no DLL, no terrain. Headless-safe.
extends Node

const GW := 44
const GH := 30
const RECT := Rect2(-30.0, 15.0, 120.0, 90.0)
const EPS := 1.0e-5

var _fail := 0


func _ready() -> void:
	print("=== GraphReliefNodeGate: graph-native Furrows (generator) + Terrace (filter) ===\n")
	_a_furrows_matches_formula()
	_b_terrace_bands_its_input()
	_c_terrace_is_a_filter_not_a_generator()
	_d_furrows_then_terrace_composite()
	_e_categories_and_native_fallback()
	_f_dunes_matches_formula()
	_g_crater_fills_the_frame()
	_h_strata_bands_its_input_tilted()
	_i_curve_remaps_its_input()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH RELIEF NODE PASS" if _fail == 0 else "GRAPH RELIEF NODE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. Furrows generator == an independent corrugation re-derivation ---------------------------------
func _a_furrows_matches_formula() -> void:
	print("[A] Furrows (0 inputs) == hand-derived corrugation, per cell")
	var f := _furrows(1.4, 12.0, 40.0, Pasture3DGraphNodeFurrows.Profile.U, 2.5, 55.0, 7)
	var g := _gen_graph(f) # Furrows(0) -> Output(1)
	var got := g.evaluate(GW, GH, RECT)
	var want := _furrows_oracle(f)
	var d := _max_abs_diff(got, want)
	print("    max |graph - oracle| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Furrows node diverged from the hand-derived formula")
	# CONTROL: amplitude 0 emits a flat 0 (the generator genuinely reads amplitude).
	var f0 := _furrows(0.0, 12.0, 40.0, Pasture3DGraphNodeFurrows.Profile.U, 2.5, 55.0, 7)
	var flat := _absmax(_gen_graph(f0).evaluate(GW, GH, RECT))
	print("    control: amplitude 0 -> flat field (absmax %.7f, want < %.7f)" % [flat, EPS])
	if flat > EPS:
		_fail += 1; print("    !! amplitude 0 did not flatten the generator")
	# CONTROL: it actually varies across the grid (it is not a constant).
	var spread := _spread(got)
	print("    control: the field varies across the grid (spread %.3f, want > 0.05)" % spread)
	if spread <= 0.05:
		_fail += 1; print("    !! the Furrows field is flat — the generator produced nothing")


# --- B. Terrace filters its input into metric benches ------------------------------------------------
func _b_terrace_bands_its_input() -> void:
	print("[B] Input -> Terrace -> Output bands the surface, matching a metric-band re-derivation")
	var t := _terrace(8.0, 1.0, 1.0, 0.0, 40.0, 0) # band every 8 m, hard risers, full amount, no jitter
	var surf := _ramp(60.0) # a tall ramp so it climbs through many benches
	var g := _filter_graph(t)
	var got := g.evaluate(GW, GH, RECT, null, surf)
	var want := _terrace_oracle(t, surf)
	var d := _max_abs_diff(got, want)
	print("    max |graph - oracle| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Terrace node diverged from the metric-band re-derivation")
	# CONTROL: hard terracing creates FLATS — many cells equal their left neighbour, which a raw ramp
	# (the amount-0 case below) does not.
	var flats := _horizontal_flats(got)
	print("    control: terraced field has flat benches (%d flat steps, want > %d)" % [flats, GW])
	if flats <= GW:
		_fail += 1; print("    !! no benches formed — Terrace did not quantise")
	# CONTROL: amount 0 is the identity (it passes the input straight through).
	var t0 := _terrace(8.0, 1.0, 0.0, 0.0, 40.0, 0)
	var id := _max_abs_diff(_filter_graph(t0).evaluate(GW, GH, RECT, null, surf), surf)
	print("    control: amount 0 is the identity (diff %.7f, want < %.7f)" % [id, EPS])
	if id > EPS:
		_fail += 1; print("    !! amount 0 did not pass the input through unchanged")


# --- C. Terrace generates nothing of its own (it is a FILTER) -----------------------------------------
func _c_terrace_is_a_filter_not_a_generator() -> void:
	print("[C] Terrace reads its input and invents nothing")
	var t := _terrace(8.0, 1.0, 1.0, 0.0, 40.0, 0)
	# A FLAT input yields a FLAT output — no self-generated pattern (unlike the relief TERRACE op, which
	# bands its material's own accumulator). One constant maps to one bench value.
	var flat_in := _const_surface(21.3)
	var out_flat := _filter_graph(t).evaluate(GW, GH, RECT, null, flat_in)
	print("    control: flat input -> flat output (spread %.7f, want < %.7f)" % [_spread(out_flat), EPS])
	if _spread(out_flat) > EPS:
		_fail += 1; print("    !! Terrace invented texture from a flat input — it is generating, not filtering")
	# Two DIFFERENT inputs give two DIFFERENT outputs — it is a function of what is wired in.
	var oa := _filter_graph(t).evaluate(GW, GH, RECT, null, _ramp(60.0))
	var ob := _filter_graph(t).evaluate(GW, GH, RECT, null, _ramp(30.0))
	var moved := _max_abs_diff(oa, ob)
	print("    control: different inputs -> different outputs (diff %.3f, want > 0.5)" % moved)
	if moved <= 0.5:
		_fail += 1; print("    !! Terrace ignored its input")


# --- D. Furrows -> Terrace -> Output: generator feeding a filter ---------------------------------------
func _d_furrows_then_terrace_composite() -> void:
	print("[D] Furrows -> Terrace -> Output == terrace(furrows) per cell")
	var f := _furrows(6.0, 14.0, 25.0, Pasture3DGraphNodeFurrows.Profile.V, 0.0, 70.0, 3)
	var t := _terrace(2.0, 1.0, 1.0, 0.0, 40.0, 0)
	# 0 Furrows -> 1 Terrace -> 2 Output.
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [f, t, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	var got := g.evaluate(GW, GH, RECT)
	# Oracle: furrows per cell, then the metric band of that value.
	var fv := _furrows_oracle(f)
	var want := _terrace_oracle(t, fv)
	var d := _max_abs_diff(got, want)
	print("    max |graph - terrace(furrows)| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Furrows->Terrace chain did not match the composed oracle")
	# CONTROL: the terrace actually changed the furrows (banded it), not a pass-through.
	var changed := _max_abs_diff(got, fv)
	print("    control: terracing changed the furrows (diff %.3f, want > 0.05)" % changed)
	if changed <= 0.05:
		_fail += 1; print("    !! Terrace passed the furrows straight through")


# --- E. Category metadata + native fallback ----------------------------------------------------------
func _e_categories_and_native_fallback() -> void:
	print("[E] node categories, and a relief-node graph falls back to GDScript")
	var f := Pasture3DGraphNodeFurrows.new()
	var t := Pasture3DGraphNodeTerrace.new()
	var cats_ok := f.input_count() == 0 and f.role() == Pasture3DGraphNode.Role.GENERATOR and f.has_output() \
			and t.input_count() == 1 and t.role() == Pasture3DGraphNode.Role.FILTER and t.has_output()
	print("    Furrows: inputs=%d role=%d ; Terrace: inputs=%d role=%d"
		% [f.input_count(), f.role(), t.input_count(), t.role()])
	if not cats_ok:
		_fail += 1; print("    !! a node reported the wrong category (generator/filter)")
	# A graph with a relief op is NOT natively supported yet -> the host runs the GDScript path.
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), t.duplicate(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	print("    Input->Terrace->Output native_supported=%s (want false)" % g.native_supported())
	if g.native_supported():
		_fail += 1; print("    !! a relief-op graph wrongly claimed native support")
	# CONTROL: an all-native graph (Input->Smooth->Output) IS supported — the check is not vacuous.
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 1
	var gn := Pasture3DTerrainGraph.new()
	var nn: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), sm, Pasture3DGraphNodeOutput.new()]
	gn.nodes = nn
	gn.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	print("    control: Input->Smooth->Output native_supported=%s (want true)" % gn.native_supported())
	if not gn.native_supported():
		_fail += 1; print("    !! the native check is broken — a supported graph reported false")


# --- F. Dunes generator == an independent asymmetric-ridge re-derivation ------------------------------
func _f_dunes_matches_formula() -> void:
	print("[F] Dunes (0 inputs) == hand-derived asymmetric ridges, per cell")
	var dn := _dunes(3.0, 35.0, 20.0, 0.7, 1.4, 10.0, 110.0, 5)
	var got := _gen_graph(dn).evaluate(GW, GH, RECT)
	var want := _dunes_oracle(dn)
	var d := _max_abs_diff(got, want)
	print("    max |graph - oracle| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Dunes node diverged from the hand-derived formula")
	# CONTROL: amplitude 0 -> flat; and it varies across the grid.
	var flat := _absmax(_gen_graph(_dunes(0.0, 35.0, 20.0, 0.7, 1.4, 10.0, 110.0, 5)).evaluate(GW, GH, RECT))
	print("    control: amplitude 0 -> flat (absmax %.7f, want < %.7f) ; spread %.3f (want > 0.05)"
		% [flat, EPS, _spread(got)])
	if flat > EPS or _spread(got) <= 0.05:
		_fail += 1; print("    !! amplitude control dead, or the dune field is flat")


# --- G. Crater grid generator fills the FRAME (the new code: nu,nv,inv_ex,inv_ez from the rect) --------
func _g_crater_fills_the_frame() -> void:
	print("[G] Crater (grid, 0 inputs) fills the rect; graph == independent-frame + _crater profile")
	var cr := _crater(20.0, 0.7, 0.15, 0.25, 2.0, 0.35, 0)
	var got := _gen_graph(cr).evaluate(GW, GH, RECT)
	var want := _crater_oracle(cr)
	var d := _max_abs_diff(got, want)
	print("    max |graph - oracle| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Crater node diverged from the independent-frame oracle")
	# CONTROL: the centre cell is the deepest point (a bowl) and is negative.
	var centre := got[(GH / 2) * GW + (GW / 2)]
	var lo := got[0]
	for v in got:
		lo = minf(lo, v)
	print("    control: centre = %.3f (want < 0) and is the minimum (min %.3f)" % [centre, lo])
	if centre >= 0.0 or absf(centre - lo) > 0.5:
		_fail += 1; print("    !! the crater is not a bowl centred in the frame")
	# CONTROL: a corner (outside the inscribed ellipse, r >= 1) reads 0 — the crater does not fill corners.
	print("    control: corner (r>=1) reads %.7f (want < %.7f)" % [got[0], EPS])
	if absf(got[0]) > EPS:
		_fail += 1; print("    !! the crater bled past r = 1 into the frame corners")
	# CONTROL: amplitude 0 -> flat.
	var flat := _absmax(_gen_graph(_crater(0.0, 0.7, 0.15, 0.25, 2.0, 0.35, 0)).evaluate(GW, GH, RECT))
	print("    control: amplitude 0 -> flat (absmax %.7f, want < %.7f)" % [flat, EPS])
	if flat > EPS:
		_fail += 1; print("    !! amplitude 0 did not flatten the crater")


# --- H. Strata filter bands its input with a tilt -----------------------------------------------------
func _h_strata_bands_its_input_tilted() -> void:
	print("[H] Input -> Strata -> Output bands the surface (tilted), matching a re-derivation")
	var st := _strata(7.0, 1.0, 1.0, 5.0, 30.0, 2.0, 45.0, 4)
	var surf := _ramp(70.0)
	var got := _filter_graph(st).evaluate(GW, GH, RECT, null, surf)
	var want := _strata_oracle(st, surf)
	var d := _max_abs_diff(got, want)
	print("    max |graph - oracle| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Strata node diverged from the re-derivation")
	# CONTROL: it forms benches; amount 0 is the identity.
	var flats := _horizontal_flats(got)
	var t0 := _strata(7.0, 1.0, 0.0, 5.0, 30.0, 2.0, 45.0, 4)
	var id := _max_abs_diff(_filter_graph(t0).evaluate(GW, GH, RECT, null, surf), surf)
	print("    control: %d flat steps (want > %d) ; amount 0 identity diff %.7f (want < %.7f)"
		% [flats, GW, id, EPS])
	if flats <= GW or id > EPS:
		_fail += 1; print("    !! no benches formed, or amount 0 was not the identity")
	# CONTROL: dip actually tilts — beds under a nonzero dip differ from horizontal beds.
	var horiz := _strata(7.0, 1.0, 1.0, 0.0, 30.0, 0.0, 45.0, 4) # dip 0, break 0
	var tilted := _strata(7.0, 1.0, 1.0, 12.0, 30.0, 0.0, 45.0, 4) # strong dip, break 0
	var moved := _max_abs_diff(_filter_graph(horiz).evaluate(GW, GH, RECT, null, surf),
			_filter_graph(tilted).evaluate(GW, GH, RECT, null, surf))
	print("    control: dip changes the bedding (diff %.3f, want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! dip did nothing — the beds are not tilted")


# --- I. Curve filter remaps its input through the transfer curve --------------------------------------
func _i_curve_remaps_its_input() -> void:
	print("[I] Input -> Curve -> Output remaps the surface, matching a re-derivation")
	var c := _const_curve(0.5)
	var cn := _curve(c, 0.0, 100.0, 0.0, 100.0, 1.0)
	var surf := _ramp(70.0)
	var got := _filter_graph(cn).evaluate(GW, GH, RECT, null, surf)
	var want := _curve_oracle(cn, surf)
	var d := _max_abs_diff(got, want)
	print("    max |graph - oracle| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Curve node diverged from the re-derivation")
	# CONTROL: a constant-0.5 curve over [0,100]->[0,100] maps every cell to ~50 (it is remapping).
	var at50 := true
	for v in got:
		if absf(v - 50.0) > 0.01:
			at50 = false
	print("    control: constant curve -> flat 50 (spread %.5f, all==50 %s)" % [_spread(got), at50])
	if not at50:
		_fail += 1; print("    !! the constant curve did not flatten the output to its value")
	# CONTROL: amount 0 is the identity; a null curve passes through.
	var c0 := _curve(c, 0.0, 100.0, 0.0, 100.0, 0.0)
	var id := _max_abs_diff(_filter_graph(c0).evaluate(GW, GH, RECT, null, surf), surf)
	var cnull := _curve(null, 0.0, 100.0, 0.0, 100.0, 1.0)
	var pass_through := _max_abs_diff(_filter_graph(cnull).evaluate(GW, GH, RECT, null, surf), surf)
	print("    control: amount 0 diff %.7f, null curve diff %.7f (want < %.7f)" % [id, pass_through, EPS])
	if id > EPS or pass_through > EPS:
		_fail += 1; print("    !! amount 0 or a null curve did not pass the input through")


# ---- node builders ----------------------------------------------------------------------------------

func _furrows(amp: float, spacing: float, dir_deg: float, profile, wobble_amt: float, wobble_size: float,
		seed: int) -> Pasture3DGraphNodeFurrows:
	var n := Pasture3DGraphNodeFurrows.new()
	n.amplitude = amp; n.spacing = spacing; n.direction_degrees = dir_deg; n.profile = profile
	n.wobble_amount = wobble_amt; n.wobble_size = wobble_size; n.seed = seed
	return n


func _terrace(band_h: float, hardness: float, amount: float, jitter: float, jitter_size: float,
		seed: int) -> Pasture3DGraphNodeTerrace:
	var n := Pasture3DGraphNodeTerrace.new()
	n.band_height = band_h; n.hardness = hardness; n.amount = amount
	n.jitter = jitter; n.jitter_size = jitter_size; n.seed = seed
	return n


func _dunes(amp: float, wavelength: float, dir_deg: float, asymmetry: float, sharpness: float,
		wander_amt: float, wander_size: float, seed: int) -> Pasture3DGraphNodeDunes:
	var n := Pasture3DGraphNodeDunes.new()
	n.amplitude = amp; n.wavelength = wavelength; n.direction_degrees = dir_deg; n.asymmetry = asymmetry
	n.crest_sharpness = sharpness; n.wander_amount = wander_amt; n.wander_size = wander_size; n.seed = seed
	return n


func _crater(amp: float, floor_depth: float, rim_height: float, rim_width: float, ejecta: float,
		flatness: float, steps: int) -> Pasture3DGraphNodeCrater:
	var n := Pasture3DGraphNodeCrater.new()
	n.amplitude = amp; n.floor_depth = floor_depth; n.rim_height = rim_height; n.rim_width = rim_width
	n.ejecta_falloff = ejecta; n.floor_flatness = flatness; n.terrace_steps = steps
	return n


func _strata(band_h: float, hardness: float, amount: float, dip: float, break_size: float,
		break_amt: float, dip_dir: float, seed: int) -> Pasture3DGraphNodeStrata:
	var n := Pasture3DGraphNodeStrata.new()
	n.band_height = band_h; n.hardness = hardness; n.amount = amount; n.dip = dip
	n.break_size = break_size; n.break_amount = break_amt; n.dip_direction_degrees = dip_dir; n.seed = seed
	return n


func _curve(c: Curve, in_min: float, in_max: float, out_min: float, out_max: float,
		amount: float) -> Pasture3DGraphNodeCurve:
	var n := Pasture3DGraphNodeCurve.new()
	n.curve = c; n.input_min = in_min; n.input_max = in_max
	n.output_min = out_min; n.output_max = out_max; n.amount = amount
	return n


func _const_curve(p_y: float) -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, p_y))
	c.add_point(Vector2(1.0, p_y))
	return c


func _gen_graph(p_gen: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_gen, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0)]
	return g


func _filter_graph(p_filter: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), p_filter, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	return g


# ---- independent oracles (re-derive the math; do NOT call the node's eval) ---------------------------

## Per-cell corrugation, hand-derived. Matches Pasture3DReliefMaterial._furrows, which the node delegates
## to — so agreement cross-checks BOTH the relief static and the graph wiring.
func _furrows_oracle(f: Pasture3DGraphNodeFurrows) -> PackedFloat32Array:
	var noise := Pasture3DReliefMaterial._configure_noise(1.0 / maxf(f.wobble_size, 0.01), 2, 2.0, 0.5, f.seed, false)
	var dir := deg_to_rad(f.direction_degrees)
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var d := w.x * cos(dir) + w.y * sin(dir)
			d += noise.get_noise_2d(w.x, w.y) * f.wobble_amount
			var phase := fposmod(d / maxf(f.spacing, 0.001), 1.0)
			var a := absf(phase * 2.0 - 1.0)
			var val := a
			if f.profile == Pasture3DGraphNodeFurrows.Profile.U:
				val = smoothstep(0.0, 1.0, a)
			elif f.profile == Pasture3DGraphNodeFurrows.Profile.SQUARE:
				val = smoothstep(0.42, 0.58, a)
			out[iz * GW + ix] = (val * 2.0 - 1.0) * f.amplitude
	return out


## Per-cell metric terrace of an arbitrary field, hand-derived to match the node's eval_cell.
func _terrace_oracle(t: Pasture3DGraphNodeTerrace, p_field: PackedFloat32Array) -> PackedFloat32Array:
	var jn := Pasture3DReliefMaterial._configure_noise(1.0 / maxf(t.jitter_size, 0.01), 2, 2.0, 0.5, t.seed, false)
	var bh := maxf(t.band_height, 0.001)
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var i := iz * GW + ix
			var x := p_field[i]
			if is_nan(x):
				out[i] = x
				continue
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var xj := x
			if t.jitter > 0.0:
				xj += jn.get_noise_2d(w.x, w.y) * t.jitter
			var tt := xj / bh
			var q := floorf(tt)
			var fr := tt - q
			var stepped := (q + pow(fr, 1.0 + t.hardness * 15.0)) * bh
			out[i] = lerpf(x, stepped, t.amount)
	return out


## Per-cell asymmetric dune ridge, hand-derived. Matches Pasture3DReliefMaterial._dunes, which the node
## delegates to — so agreement cross-checks both the relief static and the graph wiring.
func _dunes_oracle(dn: Pasture3DGraphNodeDunes) -> PackedFloat32Array:
	var noise := Pasture3DReliefMaterial._configure_noise(1.0 / maxf(dn.wander_size, 0.01), 2, 2.0, 0.5, dn.seed, false)
	var dir := deg_to_rad(dn.direction_degrees)
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var d := w.x * cos(dir) + w.y * sin(dir)
			d += noise.get_noise_2d(w.x, w.y) * dn.wander_amount
			var phase := fposmod(d / maxf(dn.wavelength, 0.001), 1.0)
			var a := clampf(dn.asymmetry, 0.01, 0.99)
			var t := (phase / a) if phase < a else (1.0 - (phase - a) / (1.0 - a))
			out[iz * GW + ix] = (pow(clampf(t, 0.0, 1.0), maxf(dn.crest_sharpness, 0.01)) * 2.0 - 1.0) * dn.amplitude
	return out


## The crater field, computing the FRAME (the node's new code) INDEPENDENTLY here and reusing the vetted
## Pasture3DReliefMaterial._crater profile — so this isolates the nu,nv,inv_ex,inv_ez mapping under test.
func _crater_oracle(cr: Pasture3DGraphNodeCrater) -> PackedFloat32Array:
	var cx := RECT.position.x + RECT.size.x * 0.5
	var cz := RECT.position.y + RECT.size.y * 0.5
	var inv_ex := 2.0 / maxf(RECT.size.x, 1.0e-9)
	var inv_ez := 2.0 / maxf(RECT.size.y, 1.0e-9)
	var params := PackedFloat32Array([cr.amplitude, cr.floor_depth, cr.rim_height, cr.rim_width,
			cr.ejecta_falloff, cr.floor_flatness, float(cr.terrace_steps)])
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			out[iz * GW + ix] = Pasture3DReliefMaterial._crater((w.x - cx) * inv_ex, (w.y - cz) * inv_ez,
					inv_ex, inv_ez, params, 0)
	return out


## Per-cell tilted metric strata, hand-derived to match the Strata node's eval_cell.
func _strata_oracle(st: Pasture3DGraphNodeStrata, p_field: PackedFloat32Array) -> PackedFloat32Array:
	var noise := Pasture3DReliefMaterial._configure_noise(1.0 / maxf(st.break_size, 0.01), 3, 2.0, 0.5, st.seed, false)
	var dipdir := deg_to_rad(st.dip_direction_degrees)
	var bh := maxf(st.band_height, 0.001)
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var i := iz * GW + ix
			var x := p_field[i]
			if is_nan(x):
				out[i] = x
				continue
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var tilt := st.dip * (w.x * cos(dipdir) + w.y * sin(dipdir)) * 0.01
			if st.break_amount > 0.0:
				tilt += noise.get_noise_2d(w.x, w.y) * st.break_amount
			var t := (x + tilt) / bh
			var q := floorf(t)
			var fr := t - q
			out[i] = lerpf(x, (q + pow(fr, 1.0 + st.hardness * 15.0)) * bh, st.amount)
	return out


## Per-cell metric curve remap, computing the domain/range mapping (the node's new code) INDEPENDENTLY and
## reusing the same Curve sampler — so this isolates the mapping under test.
func _curve_oracle(cn: Pasture3DGraphNodeCurve, p_field: PackedFloat32Array) -> PackedFloat32Array:
	var span := cn.input_max - cn.input_min
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for i in range(p_field.size()):
		var x := p_field[i]
		if cn.curve == null or is_nan(x):
			out[i] = x
			continue
		var tx := clampf((x - cn.input_min) / span, 0.0, 1.0) if absf(span) > 1.0e-9 else 0.0
		var y := cn.curve.sample_baked(tx)
		out[i] = lerpf(x, lerpf(cn.output_min, cn.output_max, y), cn.amount)
	return out


# ---- generic helpers --------------------------------------------------------------------------------

func _c4(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])


func _ramp(p_scale: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_scale * (float(ix) / GW + float(iz) / GH)
	return s


func _const_surface(p_v: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	s.fill(p_v)
	return s


# How many cells equal their left neighbour (within EPS): a count of flat bench runs.
func _horizontal_flats(p: PackedFloat32Array) -> int:
	var c := 0
	for iz in range(GH):
		for ix in range(1, GW):
			var i := iz * GW + ix
			if absf(p[i] - p[i - 1]) < EPS:
				c += 1
	return c


func _absmax(p: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p:
		m = maxf(m, absf(v))
	return m


func _spread(p: PackedFloat32Array) -> float:
	if p.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in p:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
