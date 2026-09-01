# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadGpuParityGate — the path query in the compute shader, against the CPU op (P2d).
#
# ---- WHAT IS BEING COMPARED, AND AGAINST WHAT ----
#
# GPU vs the CPU NATIVE op (`graph_eval_grid`), never against GDScript directly. Two hops compared as one
# would leave a disagreement pointing at both, and the CPU op is already gated against the GDScript oracle
# by GraphGeometryLoweringGate — so a failure here localises to the shader.
#
# ---- WHY THE SHADER WALKS EVERY SEGMENT WHEN THE CPU WALKS AN INDEX ----
#
# The bucket index is an acceleration whose whole justification is that it returns the same answer as
# brute force. On the GPU the per-pixel loop is already parallel, and a bucket walk would be a divergent
# gather with a ring-stopping rule to get wrong. So the shader is the definition and the CPU is the
# optimisation of it — which makes this gate a comparison between an optimisation and the thing it
# optimises, rather than between two optimisations that might be wrong together.
#
# ---- WHAT IS NOT ON THE GPU, AND WHY THAT IS A PASS ----
#
# Road Grade is not, and neither is the region rule for a closed Path Mask, and neither are secondary
# channels. Each of those must REFUSE — `graph_eval_grid_gpu` returns empty and the whole graph takes the
# CPU evaluator. [D] is the criterion for that, and it matters more than the two parity criteria above
# it: a native path that cannot do something must say so, never approximate it. An approximated region
# mask is two ribbons along a boundary with a hole down the middle, and it looks like a mask.
#
# RUN NON-HEADLESS: the dummy headless driver has no local RenderingDevice. When none is available the
# gate SKIPS with a clear message rather than failing.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project res://bench/RoadGpuParityGate.tscn   (no --headless)
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]

const GW: int = 96
const GH: int = 96
const RECT := Rect2(-48.0, -48.0, 96.0, 96.0)
# GPU float32 against CPU double intermediates, on a field measured in metres across a 96 m grid. The
# mask is compared at the same tolerance: its feather divides a distance error by several metres, so a
# looser bound there would only hide a real one.
const TOL: float = 5.0e-3

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== RoadGpuParityGate: the path query in the compute shader vs the CPU op (P2d) ===")
	print("    spec: PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §5.5, P2d")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! Pasture3DUtil.graph_eval_grid_gpu is missing — the DLL is stale; rebuild the extension.")
		_fail += 1
		_finish()
		return
	# Availability probe: an empty return means no local RenderingDevice (headless / no driver). Probed
	# with a graph that has NO geometry in it, so a refusal by the geometry path cannot be mistaken for
	# an absent GPU — which would turn every criterion below into a silent skip.
	if _gpu(_plain_graph(), _terrain()).is_empty():
		print("GPU unavailable (no local RenderingDevice — running --headless?). SKIPPING.")
		print("Run WITHOUT --headless on a machine with a GPU to actually verify GPU/CPU parity.")
		get_tree().quit(0)
		return

	_a_the_distance_field_matches_the_cpu_op()
	_b_the_corridor_mask_matches_the_cpu_op()
	_c_an_empty_path_reads_far_away_on_the_gpu()
	_d_what_the_shader_cannot_do_it_refuses()
	_e_one_road_shared_and_two_roads_kept_apart()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	_finish()


func _finish() -> void:
	print("=== ROAD GPU PARITY %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures ------------------------------------------------------------------------------------

func _terrain() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	var dx := RECT.size.x / float(GW)
	for iz in GH:
		for ix in GW:
			out[iz * GW + ix] = 0.09 * (RECT.position.x + (float(ix) + 0.5) * dx)
	return out


## A road that DOUBLES BACK, and it has to. On a straight fixture every tie-break rule agrees and the
## shader's first-segment-wins loop cannot be told from any other; on a hairpin, a cell inside the bend is
## near two segments far apart in arc length, so a different choice leaves `distance` looking perfectly
## reasonable while the half-width read at that `s` — and therefore the mask — is wrong.
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


## A second, unrelated road, well away from the first: [E] needs two entries that a confused table would
## visibly swap. Placed in a corner the hairpin never reaches, so swapping them changes every cell.
func _lane() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([
		Vector2(-44.0, 34.0), Vector2(-20.0, 40.0), Vector2(10.0, 44.0)])
	path.half_widths = PackedFloat32Array([2.0, 2.0, 2.0])
	return path


func _outline() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([
		Vector2(-30.0, -26.0), Vector2(6.0, -26.0), Vector2(6.0, -4.0),
		Vector2(26.0, -4.0), Vector2(26.0, 20.0), Vector2(-30.0, 20.0)])
	path.half_widths = PackedFloat32Array([4.0])
	path.closed = true
	return path


func _road_with_profile() -> Pasture3DGraphPath:
	var plan := PackedVector2Array()
	for i in 41:
		plan.append(Vector2(-40.0 + float(i) * 2.0, -20.0 + 0.012 * float(i) * float(i)))
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var n_s := int(cum[cum.size() - 1]) + 1
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	a.s0 = 0.0
	var z := PackedFloat32Array()
	var half := PackedFloat32Array()
	for i in n_s:
		z.append(4.0 - 8.0 * float(i) / float(maxi(n_s - 1, 1)))
		half.append(4.0)
	a.z = z
	var path := Pasture3DGraphPath.new()
	path.points = plan
	path.half_widths = half
	path.alignment = a
	path.sample_half_widths = half
	return path


func _source(p_path: Pasture3DGraphPath) -> Pasture3DGraphNodeRoadSource:
	var n := Pasture3DGraphNodeRoadSource.new()
	n.path = p_path
	return n


## Input → Output: no geometry at all, for the availability probe.
func _plain_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return g


func _distance_graph(p_path: Pasture3DGraphPath, p_max: float = 0.0) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var q := Pasture3DGraphNodePathDistance.new()
	q.max_distance = p_max
	var nodes: Array[Pasture3DGraphNode] = [_source(p_path), q, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	return g


func _mask_graph(p_path: Pasture3DGraphPath, p_invert: bool, p_feather: float,
		p_scale: float = 1.0) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var m := Pasture3DGraphNodePathMask.new()
	m.invert = p_invert
	m.feather = p_feather
	m.width_scale = p_scale
	var nodes: Array[Pasture3DGraphNode] = [_source(p_path), m, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	return g


func _gpu(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid_gpu(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


func _cpu(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.is_empty() or p_b.is_empty() or p_a.size() != p_b.size():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _spread(p_v: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_v:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return 0.0 if lo > hi else hi - lo


# ---- A -------------------------------------------------------------------------------------------

## [A] The distance field the shader produces is the field the CPU op produces.
func _a_the_distance_field_matches_the_cpu_op() -> void:
	print("[A] the shader's distance field matches the CPU op")
	var surf := _terrain()
	var g := _distance_graph(_hairpin())
	var gpu := _gpu(g, surf)
	var cpu := _cpu(g, surf)
	var worst := _worst(gpu, cpu)
	print("    worst %.6f m over %d cells (tolerance %.4f)" % [worst, gpu.size(), TOL])
	_check("A", not gpu.is_empty() and worst < TOL, "worst %.6f m" % worst)

	# CONTROL: the GPU actually RAN. An empty return is the refusal path, and a gate that treated it as
	# agreement would pass on every machine with no driver — which is most CI.
	if gpu.is_empty():
		print("    !! the GPU returned nothing, so [A] compared the CPU with itself")

	# CONTROL: the field VARIES and the road is REACHED. Two evaluators agree perfectly on a constant, and
	# a fixture the road missed would be the unreachable fill compared against itself.
	var near := 0
	for v in gpu:
		if v < 2.0:
			near += 1
	print("    control: spans %.2f m, %d cell(s) within 2 m of the road (want > 0 both)"
			% [_spread(gpu), near])
	if _spread(gpu) <= 1.0 or near == 0:
		_fail += 1
		print("    !! the road is not reached on this fixture, so nothing here compared a query")

	# CONTROL: max_distance clamps on the GPU as it does on the CPU. It is a separate branch in the
	# shader, and an unclamped field agrees with a clamped one everywhere the road is near.
	var gc := _distance_graph(_hairpin(), 12.0)
	var clamped := _gpu(gc, surf)
	var over := 0
	for v in clamped:
		if v > 12.0 + TOL:
			over += 1
	print("    control: with max_distance 12 m, %d cell(s) exceed it (want 0), worst vs CPU %.6f"
			% [over, _worst(clamped, _cpu(gc, surf))])
	if over != 0 or _worst(clamped, _cpu(gc, surf)) >= TOL:
		_fail += 1
		print("    !! the clamp does not agree between the two paths")


# ---- B -------------------------------------------------------------------------------------------

## [B] The corridor mask matches, inverted and not, and its feather is in metres on both.
##
## The mask is where the half-width lookup shows up, and the half-width is read AT THE ARC LENGTH the
## nearest-segment search returned. So this criterion tests the tie-break as well as the arithmetic: on
## the hairpin, a segment chosen differently gives a different `s`, a different half-width and a mask edge
## in the wrong place — while `distance` in [A] stays perfectly plausible.
func _b_the_corridor_mask_matches_the_cpu_op() -> void:
	print("[B] the corridor mask matches the CPU op")
	var surf := _terrain()
	var worst := 0.0
	var fields: Array = []
	for cfg in [[false, 3.0, 1.0], [true, 3.0, 1.0], [false, 0.0, 1.0], [false, 4.0, 1.8]]:
		var g := _mask_graph(_hairpin(), bool(cfg[0]), float(cfg[1]), float(cfg[2]))
		var gpu := _gpu(g, surf)
		var w := _worst(gpu, _cpu(g, surf))
		fields.append(gpu)
		worst = maxf(worst, w)
		print("    invert=%s feather=%.1f scale=%.1f: worst %.6f" % [str(cfg[0]), cfg[1], cfg[2], w])
	_check("B", worst < TOL, "worst %.6f" % worst)

	# CONTROL: the mask covers the road and not the world. All-zero or all-one agrees with anything.
	var on := 0
	for v in fields[0]:
		if v > 0.5:
			on += 1
	var pct := 100.0 * float(on) / float(GW * GH)
	print("    control: %.1f%% of the grid is masked (want a corridor, not nothing and not everything)" % pct)
	if on == 0 or on == GW * GH:
		_fail += 1
		print("    !! the mask is constant, so [B] compared two constants")

	# CONTROL: inverting changed something. A shader that dropped the invert flag would still match a CPU
	# op on the plain reading and would quietly protect nothing.
	var flipped := 0
	for i in fields[0].size():
		if absf(fields[0][i] - fields[1][i]) > 0.5:
			flipped += 1
	print("    control: %d cell(s) differ between the plain and inverted masks (want many)" % flipped)
	if flipped == 0:
		_fail += 1
		print("    !! inverting the mask changed nothing on the GPU")


# ---- C -------------------------------------------------------------------------------------------

## [C] An unresolved road reads FAR AWAY on the GPU, not zero.
##
## The one answer whose wrong value is invisible. Zero does not read as an error — it reads as "every cell
## is on the road", and a Road Grade downstream then flattens the terrain to the crown and reports
## success. It is also a different branch from the CPU's: on the GPU the empty path is a vertex count of
## less than two inside the shader, decided per invocation.
func _c_an_empty_path_reads_far_away_on_the_gpu() -> void:
	print("[C] an unresolved Road Source reads unreachable on the GPU")
	var surf := _terrain()
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeRoadSource.new(), Pasture3DGraphNodePathDistance.new(),
		Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	var gpu := _gpu(g, surf)
	var lo := INF
	for v in gpu:
		lo = minf(lo, v)
	print("    the empty path reads %.1f m everywhere (want 10000, never 0)" % lo)
	_check("C", not gpu.is_empty() and lo > 9999.0 and _worst(gpu, _cpu(g, surf)) < TOL,
			"minimum %.1f m, vs CPU %.6f" % [lo, _worst(gpu, _cpu(g, surf))])

	# CONTROL: an unresolved path under an INVERTED mask must read as "all terrain, no road" — 1, not 0.
	# Inverting the empty answer too is what stops a graph being edited briefly erasing everything the
	# mask was protecting.
	var gm := _mask_graph(Pasture3DGraphPath.new(), true, 3.0)
	var mgpu := _gpu(gm, surf)
	var mhi := -INF
	var mlo := INF
	for v in mgpu:
		mhi = maxf(mhi, v)
		mlo = minf(mlo, v)
	print("    control: an empty inverted mask reads %.1f..%.1f (want 1..1)" % [mlo, mhi])
	if mlo < 0.999 or mhi > 1.001:
		_fail += 1
		print("    !! the empty path is not inverted, so an inverted mask erases what it protects")


# ---- D -------------------------------------------------------------------------------------------

## [D] Everything the shader cannot do, it REFUSES.
##
## Three separate gaps, three separate refusals, and each one would otherwise be a plausible wrong answer
## rather than an error:
##
##   * a CLOSED Path Mask — the region rule is even-odd winding and is not in the shader. Answered with
##     the corridor rule it is two ribbons along the boundary with a hole down the middle.
##   * a Road Grade — the grader reads a per-sample profile and writes six channels; this plan holds one
##     buffer per slot. Answered by falling through, it would be an unmodified surface.
##   * a SECONDARY CHANNEL — P2b gave the CPU program channels and this path has none, so a program that
##     asked for `s` would be served `distance`.
##
## An empty return is the refusal. The caller then takes the CPU evaluator, which is slower and right.
func _d_what_the_shader_cannot_do_it_refuses() -> void:
	print("[D] a closed mask, a Road Grade and a secondary channel all refuse")
	var surf := _terrain()

	var g_closed := _mask_graph(_outline(), false, 3.0)
	var g_grade := Pasture3DTerrainGraph.new()
	var nodes_g: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(_road_with_profile()),
		Pasture3DGraphNodeRoadGrade.new(), Pasture3DGraphNodeOutput.new()]
	g_grade.nodes = nodes_g
	g_grade.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]

	# Path Distance's port 1 is `s`, a channel the shader does not write.
	var g_chan := Pasture3DTerrainGraph.new()
	var nodes_c: Array[Pasture3DGraphNode] = [
		_source(_hairpin()), Pasture3DGraphNodePathDistance.new(), Pasture3DGraphNodeOutput.new()]
	g_chan.nodes = nodes_c
	g_chan.connections = [[0, 0, 1, 0], [1, 1, 2, 0]]

	var closed_out := _gpu(g_closed, surf)
	var grade_out := _gpu(g_grade, surf)
	var chan_out := _gpu(g_chan, surf)
	print("    closed mask empty=%s, road grade empty=%s, secondary channel empty=%s (want all true)"
			% [str(closed_out.is_empty()), str(grade_out.is_empty()), str(chan_out.is_empty())])
	_check("D", closed_out.is_empty() and grade_out.is_empty() and chan_out.is_empty(),
			"closed %s, grade %s, channel %s" % [str(closed_out.is_empty()),
					str(grade_out.is_empty()), str(chan_out.is_empty())])

	# CONTROL: the same three graphs, minus the one thing each cannot do, must RUN on the GPU. Without
	# this, [D] would pass on a build whose GPU path refused everything — including the fixtures [A] and
	# [B] measured — and would be reporting a broken shader as a careful one.
	var open_out := _gpu(_mask_graph(_hairpin(), false, 3.0), surf)
	var port0_out := _gpu(_distance_graph(_hairpin()), surf)
	print("    control: the open mask and the port-0 query still run: %s, %s (want both true)"
			% [str(not open_out.is_empty()), str(not port0_out.is_empty())])
	if open_out.is_empty() or port0_out.is_empty():
		_fail += 1
		print("    !! the GPU refuses the control graphs too, so [D] is not measuring a refusal")

	# CONTROL: and every refused graph still produces the RIGHT field on the CPU. A refusal is only
	# correct if the fallback carries it; refusing and then evaluating to a constant would have turned a
	# performance decision into a wrong answer.
	for pair in [[g_closed, "closed mask"], [g_grade, "road grade"], [g_chan, "secondary channel"]]:
		var g: Pasture3DTerrainGraph = pair[0]
		var cpu := g.evaluate(GW, GH, RECT, null, surf)
		if _spread(cpu) <= 0.0:
			_fail += 1
			print("    !! the refused %s graph evaluates to a constant on the CPU" % pair[1])


# ---- E -------------------------------------------------------------------------------------------

## [E] One road bound once is still one road, and two roads stay two.
##
## The geometry table is uploaded per ENTRY and shared by every dispatch naming it. That sharing is the
## point — a road read four times is indexed and uploaded once — and it is also the thing that can go
## wrong invisibly: a table that handed one road's buffer to the other node's dispatch would produce a
## perfectly smooth, entirely wrong distance field, and nothing would report it.
func _e_one_road_shared_and_two_roads_kept_apart() -> void:
	print("[E] a shared upload stays shared, and two roads stay apart")
	var surf := _terrain()
	var road := _hairpin()

	# One road, two consumers, combined so both reach the output.
	var g1 := Pasture3DTerrainGraph.new()
	var mask := Pasture3DGraphNodePathMask.new()
	mask.feather = 3.0
	var nodes1: Array[Pasture3DGraphNode] = [
		_source(road), Pasture3DGraphNodePathDistance.new(), mask,
		Pasture3DGraphNodeBlend.new(), Pasture3DGraphNodeOutput.new()]
	g1.nodes = nodes1
	g1.connections = [[0, 0, 1, 0], [0, 0, 2, 0], [1, 0, 3, 0], [2, 0, 3, 1], [3, 0, 4, 0]]
	var one_gpu := _gpu(g1, surf)
	var one_worst := _worst(one_gpu, _cpu(g1, surf))

	# Two DIFFERENT roads in one graph, each read by its own query and summed.
	var g2 := Pasture3DTerrainGraph.new()
	var nodes2: Array[Pasture3DGraphNode] = [
		_source(_hairpin()), _source(_lane()), Pasture3DGraphNodePathDistance.new(),
		Pasture3DGraphNodePathDistance.new(), Pasture3DGraphNodeBlend.new(),
		Pasture3DGraphNodeOutput.new()]
	g2.nodes = nodes2
	g2.connections = [[0, 0, 2, 0], [1, 0, 3, 0], [2, 0, 4, 0], [3, 0, 4, 1], [4, 0, 5, 0]]
	var two_gpu := _gpu(g2, surf)
	var two_worst := _worst(two_gpu, _cpu(g2, surf))
	print("    one road, two consumers: worst %.6f; two roads, two queries: worst %.6f"
			% [one_worst, two_worst])
	_check("E", one_worst < TOL and two_worst < TOL,
			"shared %.6f, distinct %.6f" % [one_worst, two_worst])

	# CONTROL: the two roads really are different fields. If the lane's query answered with the hairpin's
	# geometry, the sum would be twice the hairpin — and it would still be smooth, plausible, and only
	# catchable by comparing against a graph that reads the lane alone.
	var g_lane := _distance_graph(_lane())
	var g_hair := _distance_graph(_hairpin())
	var apart := _worst(_gpu(g_lane, surf), _gpu(g_hair, surf))
	print("    control: the two roads' own fields differ by %.2f m (want a large number)" % apart)
	if apart < 5.0:
		_fail += 1
		print("    !! the two roads produce the same field, so [E] cannot tell them apart either")
