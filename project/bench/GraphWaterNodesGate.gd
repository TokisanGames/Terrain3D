# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphWaterNodesGate — spec §8.1 FloodingUniformLevel (FLA-FLD) and §8.2 WaterMask (WMA-WMD), plus the
# native-route and GPU-route checks.
#
# One gate for two nodes because they are one pipeline: WaterMask's input IS FloodingUniformLevel's depth
# channel, and a fixture that produced the depth some other way would be testing a pipeline nobody runs.
#
# WMB is the criterion the whole shore band exists for. A band thresholded in GRID CELLS looks identical at
# one resolution and is wrong at every other, so WMB measures the band's width in METRES at two resolutions
# and runs a cell-space band alongside as a control that must fail.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphWaterNodesGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const PARITY_EPS := 2.0e-6
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphWaterNodesGate: flooding and the shore band (§8.1, §8.2) ===\n")
	_fla_depth_is_exact()
	_flb_clamp_terrain_off_is_bit_identical()
	_flc_mask_matches_depth()
	_fld_no_pond_bodies_spawned()
	_wma_water_matches_threshold()
	_wmb_shore_band_is_metric()
	_wmc_zero_width_is_empty()
	_wmd_parity_and_route()
	_gpu()
	print("\n=== %s (%d failures) ===\n" % ["WATER NODES PASS" if _fail == 0 else "WATER NODES FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- FLA. depth is exactly max(level - z, 0) ---------------------------------------------------------
func _fla_depth_is_exact() -> void:
	print("[FLA] depth == max(level - z, 0), cell for cell")
	var surf := _basin()
	var ch := _flood_channels(surf, 20.0, true)
	var depth: PackedFloat32Array = ch[1]
	# The expected value goes through a PackedFloat32Array first. The channel is float32 and the subtraction
	# happens in double, so comparing against a double expectation measures the STORE, not the maths — it
	# reports a 2e-6 disagreement for a kernel that is exactly right.
	var want_arr := PackedFloat32Array()
	want_arr.resize(surf.size())
	for i in surf.size():
		want_arr[i] = maxf(20.0 - surf[i], 0.0)
	var worst := 0.0
	for i in surf.size():
		worst = maxf(worst, absf(depth[i] - want_arr[i]))
	print("    max |depth - max(level - z, 0)| = %.9f (want 0 exactly)" % worst)
	if worst > 0.0:
		_fail += 1; print("    !! the depth channel is not the plane minus the surface")

	# CONTROL: the fixture must actually straddle the level, or FLA compares zeros to zeros.
	var wet := 0
	for i in depth.size():
		if depth[i] > 0.0:
			wet += 1
	print("    control: %d of %d cells are below the level (want a real mix)" % [wet, depth.size()])
	if wet < 100 or wet > depth.size() - 100:
		_fail += 1; print("    !! NO-SIGNAL — the level is outside the fixture, so FLA compared a constant")


# --- FLB. clamp_terrain = false passes the height through bit-identically -----------------------------
func _flb_clamp_terrain_off_is_bit_identical() -> void:
	print("[FLB] clamp_terrain = false returns the input height unchanged")
	var surf := _basin()
	var off: PackedFloat32Array = _flood_channels(surf, 20.0, false)[0]
	var d := _max_abs_diff(off, surf)
	print("    max |height(clamp=false) - input| = %.9f (want 0 exactly)" % d)
	if d > 0.0:
		_fail += 1; print("    !! clamp_terrain = false still modified the height")

	# CONTROL: clamp_terrain = true MUST differ, or FLB is passing on a node that never clamps.
	var on: PackedFloat32Array = _flood_channels(surf, 20.0, true)[0]
	var c := _max_abs_diff(on, surf)
	print("    control: clamp_terrain = true changes the height by %.4f m (want > 1.0)" % c)
	if c <= 1.0:
		_fail += 1; print("    !! control dead — the node never raises the terrain at all")


# --- FLC. the mask is 1 exactly where depth > 0 ------------------------------------------------------
func _flc_mask_matches_depth() -> void:
	print("[FLC] mask == 1 exactly where depth > 0")
	var ch := _flood_channels(_basin(), 20.0, true)
	var depth: PackedFloat32Array = ch[1]
	var mask: PackedFloat32Array = ch[2]
	var wrong := 0
	for i in depth.size():
		var want := 1.0 if depth[i] > 0.0 else 0.0
		if mask[i] != want:
			wrong += 1
	print("    cells where the mask disagrees with the depth: %d (want 0)" % wrong)
	if wrong > 0:
		_fail += 1; print("    !! the mask channel and the depth channel disagree about where the water is")


# --- FLD. no pond bodies are spawned -----------------------------------------------------------------
func _fld_no_pond_bodies_spawned() -> void:
	print("[FLD] evaluating the node spawns no Pasture3DPond")
	# The integration mistake most likely to be made: LakeFlooding owns the pond relationship, and two
	# nodes racing to create water bodies is a bug factory. Counting nodes in the tree is the honest test —
	# it catches a spawn wherever the node chose to parent it.
	var before := _count_ponds()
	var g := _build_graph([_flood_node(20.0, true)])
	g.evaluate(GW, GH, RECT, null, _basin())
	var after := _count_ponds()
	print("    ponds in the tree: %d before, %d after (want unchanged)" % [before, after])
	if after != before:
		_fail += 1; print("    !! FloodingUniformLevel spawned a water body — that is LakeFlooding's job")

	# CONTROL: the counter must be able to SEE a pond, or FLD passes because it counts nothing.
	# Pasture3DPond is a GDScript class_name, not a ClassDB-registered native class, so the probe comes
	# from the script rather than from ClassDB.instantiate.
	var pond_script: Script = load("res://addons/pasture_3d/connectors/pasture3d_pond.gd")
	if pond_script == null:
		print("    NO-SIGNAL: pasture3d_pond.gd did not load, so this criterion counted nothing.")
		_fail += 1
		return
	var probe: Node = pond_script.new()
	add_child(probe)
	var seen := _count_ponds()
	print("    control: with one pond parented, the counter reads %d (want %d)" % [seen, before + 1])
	if seen != before + 1:
		_fail += 1; print("    !! the pond counter cannot see a pond — FLD proved nothing")
	probe.queue_free()


# --- WMA. the water mask is a direct threshold of the depth ------------------------------------------
func _wma_water_matches_threshold() -> void:
	print("[WMA] water == (depth > threshold), cell for cell")
	var depth: PackedFloat32Array = _flood_channels(_basin(), 20.0, true)[1]
	var water: PackedFloat32Array = _water_channels(depth, 0.5, 20.0)[0]
	var wrong := 0
	var wet := 0
	for i in depth.size():
		var want := 1.0 if depth[i] > 0.5 else 0.0
		if water[i] != want:
			wrong += 1
		wet += int(want)
	print("    disagreeing cells: %d (want 0); wet cells: %d" % [wrong, wet])
	if wrong > 0:
		_fail += 1; print("    !! the water mask is not a plain threshold of the depth channel")
	if wet < 100 or wet > depth.size() - 100:
		_fail += 1; print("    !! NO-SIGNAL — the threshold is outside the fixture, so WMA compared a constant")


# --- WMB. the shore band is METRIC ------------------------------------------------------------------
func _wmb_shore_band_is_metric() -> void:
	print("[WMB] the shore band is the specified width in METRES at any resolution")
	var width := 24.0
	var lo_n := 64
	var hi_n := 128
	var lo := _band_width_m(lo_n, width)
	var hi := _band_width_m(hi_n, width)
	print("    measured band half-width: %.2f m at %d², %.2f m at %d² (want ~%.1f both)"
			% [lo, lo_n, hi, hi_n, width])
	# The tolerance is one cell of the COARSE grid: the band edge can only be resolved to a cell, and the
	# coarse grid is the one that resolves it worst.
	var tol := RECT.size.x / float(lo_n) * 1.5
	if absf(lo - width) > tol or absf(hi - width) > tol:
		_fail += 1; print("    !! the band width is not the requested metric width (tolerance %.2f m)" % tol)
	if absf(lo - hi) > tol:
		_fail += 1; print("    !! the band width changed with resolution — it is being measured in cells")

	# CONTROL: a band thresholded in CELLS must fail this. Without it, a metric band and a cell band are
	# indistinguishable at a single resolution, which is exactly how this bug survives.
	var clo := _cell_band_width_m(lo_n, 8)
	var chi := _cell_band_width_m(hi_n, 8)
	print("    control: an 8-CELL band measures %.2f m at %d² and %.2f m at %d² (must differ)"
			% [clo, lo_n, chi, hi_n])
	if absf(clo - chi) <= tol:
		_fail += 1; print("    !! control dead — the cell-space band did not change with resolution, so")
		print("       this criterion cannot tell a metric band from a cell one")


# --- WMC. shore_width = 0 gives an empty shore channel ------------------------------------------------
func _wmc_zero_width_is_empty() -> void:
	print("[WMC] shore_width = 0 leaves the shore channel empty")
	var depth: PackedFloat32Array = _flood_channels(_basin(), 20.0, true)[1]
	var shore: PackedFloat32Array = _water_channels(depth, 0.5, 0.0)[1]
	var hi := 0.0
	for i in shore.size():
		hi = maxf(hi, absf(shore[i]))
	print("    max |shore| at width 0 = %.9f (want 0)" % hi)
	if hi > 0.0:
		_fail += 1; print("    !! a zero-width band still produced a shore")

	# CONTROL: a non-zero width must produce one.
	var s2: PackedFloat32Array = _water_channels(depth, 0.5, 20.0)[1]
	var hi2 := 0.0
	for i in s2.size():
		hi2 = maxf(hi2, s2[i])
	# 0.5, not ~1. The waterline falls BETWEEN cells, so the nearest sample is half a cell away and the
	# smoothstep never reaches its peak. Demanding ~1 here would be demanding that a cell sit exactly on the
	# zero crossing, which is a property of the fixture, not of the node.
	print("    control: at width 20 m the band peaks at %.4f (want > 0.5)" % hi2)
	if hi2 < 0.5:
		_fail += 1; print("    !! control dead — the node never produces a shore band at all")


# --- WMD. parity and the native route ----------------------------------------------------------------
func _wmd_parity_and_route() -> void:
	print("[WMD] native == oracle, and both nodes take the native C++ route")
	var surf := _basin()

	# FloodingUniformLevel: no oracle in the spec, so what is checked is the ROUTE and the lowering — the
	# graph program's own output against the node's evaluation.
	var gf := _build_graph([_flood_node(20.0, true)])
	if not gf.native_supported():
		_fail += 1
		print("    flooding  native_supported() = FALSE")
		print("      !! the op is missing from SUPPORTED in native_supported(). This does not fail loudly —")
		print("         it drops the WHOLE graph onto the GDScript evaluator.")
	else:
		var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(gf.compile_graph_program(), GW, GH,
				RECT, surf)
		var dev := Pasture3DGraphNodeDevFloodingUniformLevel.new()
		dev.water_level = 20.0
		dev.clamp_terrain = true
		var orc: PackedFloat32Array = dev.solve(surf, GW, GH)[0]
		var d := _max_abs_diff(nat, orc)
		print("    flooding  route=native  max |native - oracle| = %.9f" % d)
		if d > PARITY_EPS:
			_fail += 1; print("      !! the lowered opcode and the oracle disagree")
		if _max_abs_diff(nat, surf) <= 0.01:
			_fail += 1; print("      !! NO-SIGNAL — this configuration is a pass-through")

	# WaterMask against its oracle, which reuses the Phase 2 distance-transform oracle.
	var depth: PackedFloat32Array = _flood_channels(surf, 20.0, true)[1]
	var gw_ := _build_graph([_water_node(0.5, 20.0)])
	if not gw_.native_supported():
		_fail += 1; print("    watermask native_supported() = FALSE — add the op to SUPPORTED")
	else:
		print("    watermask route=native")
	var node := _water_node(0.5, 20.0)
	var ch: Array = node.eval_grid_channels([depth, PackedFloat32Array()], GW, GH, null, RECT)
	var dev2 := Pasture3DGraphNodeDevWaterMask.new()
	dev2.depth_threshold = 0.5
	dev2.shore_width = 20.0
	dev2.shore_falloff = 1
	var och: Array = dev2.solve(depth, GW, GH, RECT)
	for k in 2:
		var label: String = ["water", "shore"][k]
		var d2 := _max_abs_diff(ch[k], och[k])
		print("    watermask %-6s max |native - oracle| = %.9f" % [label, d2])
		if d2 > PARITY_EPS:
			_fail += 1; print("      !! the C++ kernel and the oracle disagree on the %s channel" % label)


# --- GPU route ---------------------------------------------------------------------------------------
func _gpu() -> void:
	print("[gpu] FloodingUniformLevel still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var surf := _basin()
	var g := _build_graph([_flood_node(20.0, true)])
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH,
			RECT, surf)
	if gpu.is_empty():
		var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				_build_graph([]).compile_graph_program(), GW, GH, RECT, surf)
		if ctrl.is_empty():
			print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
			return
		_fail += 1
		print("    !! the GPU evaluator ABANDONED the graph. An unsupported op drops the WHOLE graph to")
		print("       the CPU, so this is not a slow path, it is no GPU path at all.")
		return
	var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(), GW, GH, RECT,
			surf)
	var d := _max_abs_diff(gpu, cpu)
	print("    route=gpu  max |gpu - cpu| = %.7f (want < %.4f)" % [d, GPU_TOL])
	if d > GPU_TOL:
		_fail += 1; print("    !! the shader and the C++ kernel disagree beyond float32 tolerance")

	# WaterMask is deliberately NOT on the GPU: its shore band runs the JFA distance transform, and the
	# transform's plan is built inline in the DistanceTransform case rather than as a reusable sub-plan.
	# It stays on the native C++ kernel — which is a compiled route, not a GDScript one — and that is the
	# claim this line records so a later reader does not mistake it for an oversight.
	var gwm := _build_graph([_water_node(0.5, 20.0)])
	var gres: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(gwm.compile_graph_program(), GW, GH,
			RECT, surf)
	print("    watermask GPU plan: %s (expected: declined, native C++ route)"
			% ("declined" if gres.is_empty() else "accepted"))


# --- fixtures and helpers ----------------------------------------------------------------------------

## A bowl with a rim: a level at 20 m floods the middle and leaves the rim dry, so every criterion here has
## both a wet side and a dry one to compare.
func _basin(p_n: int = 0) -> PackedFloat32Array:
	var n := p_n if p_n > 0 else GW
	var g := PackedFloat32Array()
	g.resize(n * n)
	for iz in n:
		for ix in n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, n, n, RECT)
			var r := sqrt(w.x * w.x + w.y * w.y)
			g[iz * n + ix] = -30.0 + r * 0.5
	return g


func _flood_node(p_level: float, p_clamp: bool) -> Pasture3DGraphNodeFloodingUniformLevel:
	var n := Pasture3DGraphNodeFloodingUniformLevel.new()
	n.water_level = p_level
	n.clamp_terrain = p_clamp
	return n


func _water_node(p_threshold: float, p_width: float) -> Pasture3DGraphNodeWaterMask:
	var n := Pasture3DGraphNodeWaterMask.new()
	n.depth_threshold = p_threshold
	n.shore_width = p_width
	n.shore_falloff = Pasture3DGraphNodeWaterMask.ShoreFalloff.SMOOTH
	return n


func _flood_channels(p_surf: PackedFloat32Array, p_level: float, p_clamp: bool) -> Array:
	var gw_ := int(sqrt(p_surf.size()))
	return _flood_node(p_level, p_clamp).eval_grid_channels([p_surf, PackedFloat32Array()], gw_, gw_,
			null, RECT)


func _water_channels(p_depth: PackedFloat32Array, p_threshold: float, p_width: float) -> Array:
	var gw_ := int(sqrt(p_depth.size()))
	return _water_node(p_threshold, p_width).eval_grid_channels([p_depth, PackedFloat32Array()], gw_,
			gw_, null, RECT)


## The half-width of the shore band along the +X axis, in METRES: the distance from the waterline to the
## last cell whose shore value is still above zero.
func _band_width_m(p_n: int, p_width: float) -> float:
	var surf := _basin(p_n)
	var depth: PackedFloat32Array = _flood_node(20.0, true).eval_grid_channels(
			[surf, PackedFloat32Array()], p_n, p_n, null, RECT)[1]
	var shore: PackedFloat32Array = _water_node(0.5, p_width).eval_grid_channels(
			[depth, PackedFloat32Array()], p_n, p_n, null, RECT)[1]
	return _band_reach_along_x(shore, p_n)


## The same measurement for a band thresholded in CELLS — the control WMB needs. It is built from the
## signed distance in NORMALISED-free metres and then converted back through the cell size, which is exactly
## the mistake a cell-space implementation makes.
func _cell_band_width_m(p_n: int, p_cells: int) -> float:
	var surf := _basin(p_n)
	var depth: PackedFloat32Array = _flood_node(20.0, true).eval_grid_channels(
			[surf, PackedFloat32Array()], p_n, p_n, null, RECT)[1]
	var cell := RECT.size.x / float(p_n)
	var shore: PackedFloat32Array = _water_node(0.5, float(p_cells) * cell).eval_grid_channels(
			[depth, PackedFloat32Array()], p_n, p_n, null, RECT)[1]
	return _band_reach_along_x(shore, p_n)


func _band_reach_along_x(p_shore: PackedFloat32Array, p_n: int) -> float:
	# The basin is radial, so the waterline crosses the +X axis once. Walk out from the centre row and find
	# where the band starts and stops; half that span is the half-width.
	var iz := p_n / 2
	var first := -1
	var last := -1
	for ix in range(p_n / 2, p_n):
		if p_shore[iz * p_n + ix] > 0.0:
			if first < 0:
				first = ix
			last = ix
	if first < 0:
		return 0.0
	var cell := RECT.size.x / float(p_n)
	return (float(last - first + 1) * cell) * 0.5


func _count_ponds() -> int:
	var count := 0
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		# Pasture3DPond is a GDScript class, so is_class() will not see it — identity is the attached
		# script, walked up its inheritance chain so a subclassed pond still counts.
		var sc: Script = node.get_script()
		while sc != null:
			if sc.resource_path.ends_with("pasture3d_pond.gd"):
				count += 1
				break
			sc = sc.get_base_script()
		for child in node.get_children():
			stack.append(child)
	return count


func _build_graph(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for mnode in p_mid:
		nodes.append(mnode)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append([i, 0, i + 1, 0])
	g.connections = conns
	return g


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
