# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDomainRangeGate — Falloff and Contrast, phase 1 of PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.2
# and §4.3. Criteria FA-FD and CA-CC.
#
# Two nodes, one gate, because they share a shape: both are pointwise CELL filters whose whole risk profile
# is "did the port from Hesiod's normalised [0,1] space survive contact with metres".
#
# CC IS THE ONE THAT MATTERS. Hesiod applies pow() straight to a heightmap value because its heightmaps are
# normalised. Pasture3D heights are metres and terrain below sea level is NEGATIVE, where pow() with a
# fractional exponent returns NaN. A naive port produces a terrain that looks perfect on a fixture that
# happens to sit above y=0 and silently punches NaN holes in any terrain that does not. CC runs the fixture
# deliberately below zero.
#
# FD is the other one worth explaining. Falloff has no GPU kernel of its own — it is handled as mode 4 of
# GRAPH_GRID_GLSL. The whole-graph GPU evaluator bails to the CPU for ANY op it does not implement, and the
# bail is graph-wide, not per-node (src/pasture_3d_graph_gpu.cpp, `default: return fail()`). So a Falloff
# without GPU support would not merely be unaccelerated, it would DE-accelerate every graph containing it.
# FD asserts the GPU path actually produced the result rather than quietly falling back.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphDomainRangeGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)
const EPS := 1.0e-5
## The A/B tolerance every evaluator path in this plugin is held to.
const PARITY_EPS := 2.0e-6
## GPU/CPU parity gets its OWN, looser budget, and it is not slack. PARITY_EPS is the native-vs-oracle
## number, where both sides accumulate in double; the GPU shader accumulates in float32, so on a field of
## tens of metres the last bit is already ~1e-6 m. Holding the GPU to PARITY_EPS would fail on rounding
## and teach us to widen it later for a real bug. This matches GraphGpuParityGate.TOL.
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphDomainRangeGate: Falloff (§4.2) + Contrast (§4.3) ===\n")
	_fa_strength_zero_is_passthrough()
	_fb_band_endpoints()
	_fc_invert_is_complement()
	_fd_gpu_path_runs()
	_ca_identity_amount()
	_cb_outside_window_untouched()
	_cc_negative_heights_are_not_nan()
	_cd_contrast_gpu_path_runs()
	_ce_auto_window()
	print("\n=== %s (%d failures) ===\n" % ["DOMAIN/RANGE PASS" if _fail == 0 else "DOMAIN/RANGE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- FA. strength = 0 is a pass-through --------------------------------------------------------------
func _fa_strength_zero_is_passthrough() -> void:
	print("[FA] Falloff strength=0 passes the input through")
	var surf := _ramp(4.0)
	var off := _eval_falloff(surf, 0.0)
	var d := _max_abs_diff(off, surf)
	print("    max |falloff(strength=0) - in| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! strength=0 did not pass through")
	# CONTROL: at full strength the node must actually do something, else FA passes vacuously.
	var on := _eval_falloff(surf, 1.0)
	var moved := _max_abs_diff(on, surf)
	print("    control: strength=1 moves the field by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the falloff is not attenuating at all")


# --- FB. the attenuation band's endpoints ------------------------------------------------------------
func _fb_band_endpoints() -> void:
	print("[FB] inside radius = untouched, past radius+feather = 0")
	var n := Pasture3DGraphNodeFalloff.new()
	n.centre = Vector2.ZERO
	n.radius = 50.0
	n.feather = 50.0
	n.strength = 1.0

	# At the centre the attenuation is 1 (no change); well past the feather it is 0 (fully cut).
	var a_in := n.attenuation(0.0, 0.0, n.radius, 0.0)
	var a_out := n.attenuation(500.0, 0.0, n.radius, 0.0)
	print("    attenuation at d=0   = %.7f (want 1.0)" % a_in)
	print("    attenuation at d=500 = %.7f (want 0.0)" % a_out)
	if absf(a_in - 1.0) > EPS:
		_fail += 1; print("    !! the centre is not passing through at full amplitude")
	if absf(a_out) > EPS:
		_fail += 1; print("    !! the far field is not cut to zero")
	# CONTROL: the midpoint of the feather is strictly between the two, so the edge is a ramp and not a
	# step. Without this, a node that returned a hard binary cut would pass FB.
	var a_mid := n.attenuation(75.0, 0.0, n.radius, 0.0)
	print("    control: attenuation at d=75 (mid-feather) = %.4f (want strictly in 0..1)" % a_mid)
	if a_mid <= 0.001 or a_mid >= 0.999:
		_fail += 1; print("    !! the feather is a hard step, not a ramp")


# --- FC. invert is exactly the complement ------------------------------------------------------------
func _fc_invert_is_complement() -> void:
	print("[FC] invert produces exactly 1 - attenuation")
	var a := Pasture3DGraphNodeFalloff.new()
	a.radius = 60.0; a.feather = 40.0
	var b := Pasture3DGraphNodeFalloff.new()
	b.radius = 60.0; b.feather = 40.0; b.invert = true

	var worst := 0.0
	var worst_same := 0.0
	for i in 40:
		var d := float(i) * 8.0
		var va := a.attenuation(d, 0.0, a.radius, 0.0)
		var vb := b.attenuation(d, 0.0, b.radius, 0.0)
		worst = maxf(worst, absf(vb - (1.0 - va)))
		worst_same = maxf(worst_same, absf(vb - va))
	print("    max |inverted - (1 - plain)| = %.7f (want < %.7f)" % [worst, EPS])
	if worst > EPS:
		_fail += 1; print("    !! invert is not the complement of the plain attenuation")
	# CONTROL: comparing the inverted curve against the PLAIN one must fail — otherwise the two nodes
	# are producing the same field and FC is comparing something to itself.
	print("    control: max |inverted - plain| = %.4f (want > 0.5)" % worst_same)
	if worst_same <= 0.5:
		_fail += 1; print("    !! control dead — invert changed nothing")


# --- FD. the GPU path actually runs a Falloff graph ---------------------------------------------------
func _fd_gpu_path_runs() -> void:
	print("[FD] a graph containing Falloff still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is missing — the DLL is stale")
		return

	var surf := _ramp(6.0)
	var g := _falloff_graph(1.0)
	# Calling the GPU evaluator DIRECTLY is the route proof. Pasture3DGraphGPU returns an EMPTY array
	# when it bails, and it bails graph-wide on the first op it does not implement — so a non-empty
	# return here is proof that mode 4 (FALLOFF) was actually dispatched, which comparing two
	# threshold-routed evaluate() calls can never establish.
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH, RECT, surf)
	if gpu.is_empty():
		# Distinguish "no GPU here" from "Falloff dropped the graph to the CPU": re-run the probe with a
		# graph that is known to be fully GPU-supported. If THAT also comes back empty there is simply no
		# RenderingDevice (headless), and this criterion has measured nothing.
		var control: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				_io_graph().compile_graph_program(), GW, GH, RECT, surf)
		if control.is_empty():
			print("    NO-SIGNAL: no local RenderingDevice (headless / no driver) — GPU route unverified.")
			print("    Re-run WITHOUT --headless to actually exercise the Falloff GPU kernel.")
			return
		_fail += 1
		print("    !! the GPU evaluator bailed on Falloff but not on a bare in->out graph.")
		print("       Falloff has no kernel of its own; it is mode 4 of GRAPH_GRID_GLSL, and the bail is")
		print("       graph-wide — so this drops EVERY node in the graph to the CPU, not just Falloff.")
		return

	var cpu := _eval_falloff(surf, 1.0)
	var d := _max_abs_diff(gpu, cpu)
	print("    the GPU evaluator accepted the graph (mode 4 dispatched)")
	print("    max |gpu - cpu| = %.8f (want < %.8f)" % [d, GPU_TOL])
	if d > GPU_TOL:
		_fail += 1; print("    !! the GPU falloff kernel disagrees with the CPU kernel")
	# CONTROL: both paths must have produced a non-trivial field, or the comparison is 0 == 0.
	var amp := _max_abs_diff(cpu, surf)
	print("    control: the field is non-trivial, moved by %.3f (want > 0.05)" % amp)
	if amp <= 0.05:
		_fail += 1; print("    !! NO-SIGNAL — both paths returned the input unchanged")


## A bare Input -> Output graph: the reference for "the GPU evaluator works at all here".
func _io_graph() -> Pasture3DTerrainGraph:
	return _build_graph([])


# --- CA. amount = 1 is the identity in both modes -----------------------------------------------------
func _ca_identity_amount() -> void:
	print("[CA] Contrast amount=1 is the identity in GAIN and GAMMA")
	var surf := _ramp_positive()
	for mode in [Pasture3DGraphNodeContrast.Mode.GAIN, Pasture3DGraphNodeContrast.Mode.GAMMA]:
		var got := _eval_contrast(surf, mode, 1.0, 0.0, 100.0)
		var d := _max_abs_diff(got, surf)
		print("    mode %d: max |contrast(amount=1) - in| = %.7f (want < %.7f)" % [mode, d, EPS])
		if d > EPS:
			_fail += 1; print("    !! amount=1 is not the identity in mode %d" % mode)
		# CONTROL: amount=2 must move the field, else CA passes on a dead node.
		var moved := _max_abs_diff(_eval_contrast(surf, mode, 2.0, 0.0, 100.0), surf)
		print("    control: amount=2 moves the field by %.3f (want > 0.5)" % moved)
		if moved <= 0.5:
			_fail += 1; print("    !! control dead — the curve is not being applied in mode %d" % mode)


# --- CB. heights outside the window pass through ------------------------------------------------------
func _cb_outside_window_untouched() -> void:
	print("[CB] heights outside [range_min, range_max] pass through unchanged")
	# The window is 40..60; the ramp spans 0..100, so most cells sit outside it.
	var surf := _ramp_positive()
	var got := _eval_contrast(surf, Pasture3DGraphNodeContrast.Mode.GAMMA, 3.0, 40.0, 60.0)

	var worst_outside := 0.0
	var moved_inside := 0.0
	for i in surf.size():
		var v := surf[i]
		if v <= 40.0 or v >= 60.0:
			worst_outside = maxf(worst_outside, absf(got[i] - v))
		else:
			moved_inside = maxf(moved_inside, absf(got[i] - v))
	print("    max |change| outside the window = %.7f (want < %.7f)" % [worst_outside, EPS])
	if worst_outside > EPS:
		_fail += 1; print("    !! the window is leaking — heights outside it were modified")
	# CONTROL: inside the window something must have happened, else CB is trivially satisfied by a
	# node that does nothing at all.
	print("    control: max |change| inside the window = %.3f (want > 0.5)" % moved_inside)
	if moved_inside <= 0.5:
		_fail += 1; print("    !! control dead — nothing was shaped inside the window either")


# --- CC. negative heights do not become NaN -----------------------------------------------------------
func _cc_negative_heights_are_not_nan() -> void:
	print("[CC] a terrain BELOW zero produces no NaN (the naive pow() port)")
	# Deliberately below sea level: -120 .. -20 m. Hesiod would never see this, because its heightmaps
	# are normalised to [0,1]. A direct pow() port returns NaN across this whole fixture.
	var surf := PackedFloat32Array()
	surf.resize(GW * GH)
	for i in surf.size():
		surf[i] = -120.0 + 100.0 * (float(i) / float(surf.size() - 1))

	for mode in [Pasture3DGraphNodeContrast.Mode.GAIN, Pasture3DGraphNodeContrast.Mode.GAMMA]:
		var got := _eval_contrast(surf, mode, 0.4, -120.0, -20.0)
		var nans := 0
		for i in got.size():
			if is_nan(got[i]):
				nans += 1
		print("    mode %d: NaN cells = %d of %d (want 0)" % [mode, nans, got.size()])
		if nans > 0:
			_fail += 1; print("    !! NaN produced on negative terrain — the height window is not being applied")
		# CONTROL: the node still SHAPED the negative terrain rather than dodging the problem by
		# passing everything through. Without this, a node that gave up on negative input would pass.
		var moved := _max_abs_diff(got, surf)
		print("    control: the negative terrain was shaped, moved by %.3f (want > 0.5)" % moved)
		if moved <= 0.5:
			_fail += 1; print("    !! control dead — negative heights were skipped rather than shaped")


# --- CD. Contrast reaches its own GPU kernel, with the mask port UNWIRED ------------------------------
func _cd_contrast_gpu_path_runs() -> void:
	print("[CD] a graph containing Contrast still takes the GPU path (mask unwired)")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is missing — the DLL is stale")
		return

	# The unwired mask is the case worth testing. Contrast is mode 5 of GRAPH_GRID_GLSL and its mask
	# port binds a buffer whether or not anything is connected; an unwired mask binds the ZERO buffer,
	# so the shader has to be told (via the f7 flag) not to read it. Get that wrong and every Contrast
	# node with no mask multiplies its shaping to nothing on the GPU and works fine on the CPU — a
	# difference that only appears above the GPU cell threshold, i.e. only on large terrain.
	var surf := _ramp(6.0)
	for mode in [0, 1]:
		var g := _contrast_graph(mode, 2.0, 0.0, 100.0)
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				g.compile_graph_program(), GW, GH, RECT, surf)
		if gpu.is_empty():
			var control: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					_io_graph().compile_graph_program(), GW, GH, RECT, surf)
			if control.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    !! mode %d: the GPU evaluator bailed on Contrast but not on a bare in->out graph;" % mode)
			print("       the bail is graph-wide, so this drops EVERY node in the graph to the CPU.")
			continue

		var cpu := _eval_contrast(surf, mode, 2.0, 0.0, 100.0)
		var d := _max_abs_diff(gpu, cpu)
		print("    mode %d: max |gpu - cpu| = %.8f (want < %.8f)" % [mode, d, GPU_TOL])
		if d > GPU_TOL:
			_fail += 1; print("    !! the GPU contrast kernel disagrees with the CPU kernel")
		# CONTROL: the GPU must have actually SHAPED the field. This is the criterion that would have
		# caught the zero-buffer mask bug — a nulled mask returns the input untouched, which passes any
		# comparison that only asks "is it finite".
		var amp := _max_abs_diff(gpu, surf)
		print("    mode %d: control — the GPU shaped the field by %.3f (want > 0.5)" % [mode, amp])
		if amp <= 0.5:
			_fail += 1; print("    !! NO-SIGNAL — the GPU returned the input unchanged (mask nulled the shaping?)")


# --- CE. the AUTO height window (spec §11 q1, settled 2026-08-30) --------------------------------------
# The shipped default windows to the input's own min/max for that bake instead of to authored metres.
# Three things have to hold, and the third is the one that bites: the window must actually be the
# input's extremes, the authored Range Min / Range Max must be IGNORED while auto is on, and the GPU
# kernel must reach the same answer as the CPU. Auto-windowing is a whole-grid reduction, which a
# pointwise kernel cannot do — it runs as two extra dispatches — so a CPU/GPU split here would be
# invisible until a terrain crossed the GPU cell threshold.
func _ce_auto_window() -> void:
	print("[CE] the auto window is the input's own extremes, and the GPU agrees")
	var surf := _ramp_positive()
	var lo := INF
	var hi := -INF
	for v in surf:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	print("    the input spans %.3f .. %.3f m" % [lo, hi])

	for mode in [0, 1]:
		# Authored metres deliberately WRONG for this input, so honouring them would show up loudly.
		var g := _contrast_graph(mode, 2.5, -900.0, -800.0, false)
		var auto_out: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, surf)

		# What the same node computes when the input's extremes are authored by hand. If auto is doing
		# what it claims, these are the same field.
		var pinned := _eval_contrast(surf, mode, 2.5, lo, hi)
		var d := _max_abs_diff(auto_out, pinned)
		print("    mode %d: max |auto - hand-pinned window| = %.7f (want < %.7f)" % [mode, d, EPS])
		if d > EPS:
			_fail += 1
			print("    !! auto did not window to the input's extremes")

		# CONTROL. Everything above is also satisfied by a node that shapes nothing at all — the two
		# would agree at zero. The shaping has to be visible.
		var amp := _max_abs_diff(auto_out, surf)
		print("    mode %d: CONTROL the auto window shaped the field by %.3f m (want > 0.5)" % [mode, amp])
		if amp <= 0.5:
			_fail += 1
			print("    !! NO-SIGNAL — auto returned the input untouched, so the agreement above is vacuous")

		# CONTROL. The authored metres must be dead while auto is on. Same absurd window, Explicit ON:
		# it selects nothing in this input, so the node passes through. If THIS also shapes the field,
		# the flag is not being read and the agreement above happened for some other reason.
		var ignored := _eval_contrast(surf, mode, 2.5, -900.0, -800.0)
		var moved := _max_abs_diff(ignored, surf)
		print("    mode %d: CONTROL the same window with Explicit ON moves %.7f m (want ~0)" % [mode, moved])
		if moved > EPS:
			_fail += 1
			print("    !! an explicit window far below the input still shaped it")

	# The GPU half. Two extra dispatches reduce the grid before the shaping pass; if that reduction is
	# wrong the CPU and GPU disagree only for auto-windowed nodes, and only above the GPU threshold.
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1
		print("    !! Pasture3DUtil.graph_eval_grid_gpu is missing — the DLL is stale")
		return
	for mode in [0, 1]:
		var g := _contrast_graph(mode, 2.5, -900.0, -800.0, false)
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				g.compile_graph_program(), GW, GH, RECT, surf)
		if gpu.is_empty():
			var control: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					_io_graph().compile_graph_program(), GW, GH, RECT, surf)
			if control.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    !! mode %d: the GPU bailed on an auto-windowed Contrast. The bail is graph-wide," % mode)
			print("       so the DEFAULT setting would drop every node in the graph to the CPU.")
			continue
		var cpu: PackedFloat32Array = g.evaluate(GW, GH, RECT, null, surf)
		var d := _max_abs_diff(gpu, cpu)
		print("    mode %d: max |gpu auto - cpu auto| = %.7f (want < %.7f)" % [mode, d, GPU_TOL])
		if d > GPU_TOL:
			_fail += 1
			print("    !! the GPU min/max reduction disagrees with the CPU window")
		var amp := _max_abs_diff(gpu, surf)
		print("    mode %d: CONTROL the GPU shaped the field by %.3f m (want > 0.5)" % [mode, amp])
		if amp <= 0.5:
			_fail += 1
			print("    !! NO-SIGNAL — the GPU returned the input unchanged")


# --- helpers ------------------------------------------------------------------------------------------
## The one Falloff configuration every criterion here shares, as a graph, so FD can hand the SAME graph
## to the GPU evaluator directly instead of hoping evaluate() routed it there.
func _falloff_graph(p_strength: float) -> Pasture3DTerrainGraph:
	var n := Pasture3DGraphNodeFalloff.new()
	n.centre = Vector2.ZERO
	n.radius = 60.0
	n.feather = 80.0
	n.strength = p_strength
	return _build_graph([n])


func _eval_falloff(p_surf: PackedFloat32Array, p_strength: float) -> PackedFloat32Array:
	return _falloff_graph(p_strength).evaluate(GW, GH, RECT, null, p_surf)


## Sections CA-CD all assert behaviour of an AUTHORED window, so they pin Explicit Window on. Auto is
## the shipped default and is section CE's subject.
func _contrast_graph(p_mode: int, p_amount: float, p_lo: float, p_hi: float,
		p_explicit: bool = true) -> Pasture3DTerrainGraph:
	var n := Pasture3DGraphNodeContrast.new()
	n.mode = p_mode
	n.amount = p_amount
	n.explicit_window = p_explicit
	n.range_min = p_lo
	n.range_max = p_hi
	return _build_graph([n])


func _eval_contrast(p_surf: PackedFloat32Array, p_mode: int, p_amount: float,
		p_lo: float, p_hi: float) -> PackedFloat32Array:
	return _contrast_graph(p_mode, p_amount, p_lo, p_hi).evaluate(GW, GH, RECT, null, p_surf)


func _chain(p_mid: Array, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return _build_graph(p_mid).evaluate(GW, GH, RECT, null, p_surf)


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


## A diagonal ramp centred on zero, so the falloff has something with sign to attenuate.
func _ramp(p_scale: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			a[iz * GW + ix] = p_scale * (float(ix) + float(iz)) * 0.1 - 20.0
	return a


## A 0..100 m ramp, matching the default Contrast window so the curve has range to act on.
func _ramp_positive() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	var n := float(a.size() - 1)
	for i in a.size():
		a[i] = 100.0 * float(i) / n
	return a


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
