# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# TerrainRealismNodesGate — Headless verification gate for high-fidelity terrain generation and shaping nodes:
#   [A] Hydraulic Erosion (erosion_hydraulic): rainfall, sediment capacity, erosion/deposition, multi-output channels.
#   [B] Thermal Erosion (erosion_thermal): angle of repose gravity slippage, talus apron accumulation, hardness mask.
#   [C] Domain Warp (warp): 2D coordinate distortion vector noise fields.
#   [D] Curvature Mask (curvature): discrete Laplacian convexity (ridge) vs concavity (valley) masks.
#   [E] Geological Strata (strata): tilted sedimentary bedding, dip angle, strike direction, hardness contrast, custom curve.
#   [F] Curve Remap (curve): transfer curve shaping and input/output window mapping.
#   [G] Range Remap (remap): linear remap, inversion, clamping, and soft-knee saturation.
#   [H] Registry & Preset Networks: registry discovery and evaluation of high-fidelity presets.
#
# Every criterion measures a concrete delta and carries a distinct dead-path control test.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-32.0, -32.0, 64.0, 64.0)
const EPS := 1.0e-4

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")

var _fail := 0


func _ready() -> void:
	print("=== TerrainRealismNodesGate: High-Fidelity Terrain Shaping Nodes ===\n")
	_a_hydraulic_erosion()
	_b_thermal_erosion()
	_c_domain_warp()
	_d_curvature_mask()
	_e_geological_strata()
	_f_curve_remap()
	_g_range_remap()
	_h_registry_and_presets()
	print("\n=== %s (%d failures) ===\n" % ["TERRAIN REALISM NODES PASS" if _fail == 0 else "TERRAIN REALISM NODES FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _mound_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	var cx := RECT.position.x + RECT.size.x * 0.5
	var cz := RECT.position.y + RECT.size.y * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var d2 := (w.x - cx) * (w.x - cx) + (w.y - cz) * (w.y - cz)
			g[iz * GW + ix] = 40.0 * exp(-d2 / 250.0)
	return g


func _steep_cone_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	var cx := RECT.position.x + RECT.size.x * 0.5
	var cz := RECT.position.y + RECT.size.y * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var r := sqrt((w.x - cx) * (w.x - cx) + (w.y - cz) * (w.y - cz))
			# Slope = 45 degrees (1.0 m drop per 1.0 m dist)
			g[iz * GW + ix] = maxf(30.0 - r * 1.0, 0.0)
	return g


# ---- [A] Hydraulic Erosion -------------------------------------------------------------------------

func _a_hydraulic_erosion() -> void:
	print("[A] Hydraulic Erosion: rainfall routing, sediment transport & channels")
	var node = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
	if node == null:
		_fail += 1; print("    !! failed to instance erosion_hydraulic from registry"); return

	var ok_decl: bool = node.output_count() == 3 and node.output_names().size() == 3 \
			and node.output_port_types()[0] == Pasture3DGraphNode.PortType.HEIGHT \
			and node.output_port_types()[1] == Pasture3DGraphNode.PortType.MASK \
			and node.output_port_types()[2] == Pasture3DGraphNode.PortType.MASK
	print("    outputs=%d names=%s ok_decl=%s" % [node.output_count(), node.output_names(), ok_decl])
	if not ok_decl:
		_fail += 1; print("    !! hydraulic erosion ports declaration mismatch")

	var surf := _mound_surface()
	node.set("iterations", 15)
	node.set("rain_rate", 0.02)
	node.set("erosion_speed", 0.3)
	node.set("deposition_speed", 0.3)

	var channels: Array = node.eval_grid_channels([surf], GW, GH, null, RECT)
	var h: PackedFloat32Array = channels[0]
	var sed: PackedFloat32Array = channels[1]
	var flow: PackedFloat32Array = channels[2]

	var max_diff := 0.0
	var non_zero_flow := 0
	var non_zero_sed := 0
	for i in range(GW * GH):
		max_diff = maxf(max_diff, absf(h[i] - surf[i]))
		if flow[i] > 1e-4: non_zero_flow += 1
		if sed[i] > 1e-4: non_zero_sed += 1

	print("    eroded max |h - surf| = %f m, flow active=%d/%d cells, sed active=%d/%d cells" % [
		max_diff, non_zero_flow, GW * GH, non_zero_sed, GW * GH])
	if max_diff < EPS or non_zero_flow == 0:
		_fail += 1; print("    !! hydraulic erosion changed nothing on mound surface")

	# Control: iterations = 0 or rain_rate = 0 -> no change
	var ctrl_node = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
	ctrl_node.set("rain_rate", 0.0)
	var ctrl_ch: Array = ctrl_node.eval_grid_channels([surf], GW, GH, null, RECT)
	var ctrl_h: PackedFloat32Array = ctrl_ch[0]
	var ctrl_diff := 0.0
	for i in range(GW * GH):
		ctrl_diff = maxf(ctrl_diff, absf(ctrl_h[i] - surf[i]))
	print("    control (rain_rate=0): max diff = %f m (want ~0)" % ctrl_diff)
	if ctrl_diff > EPS:
		_fail += 1; print("    !! control failed: zero rain altered surface")


# ---- [B] Thermal Erosion ---------------------------------------------------------------------------

func _b_thermal_erosion() -> void:
	print("[B] Thermal Erosion: talus slippage on cliffs > talus angle & hardness resistance")
	var node = Pasture3DGraphNodeRegistry.create(&"erosion_thermal")
	if node == null:
		_fail += 1; print("    !! failed to instance erosion_thermal from registry"); return

	# Ports are asserted by SHAPE, not by count. `input_count() == 2` was a literal, and it broke the day
	# erosion_thermal exposed talus_angle / iterations / settling_rate as driveable parameter ports — a
	# gate going red because the node gained a feature, which teaches everyone to ignore it. What has to
	# hold is that port 0 is the surface, every other input is a scalar parameter, and the two output
	# channels are still height + mask.
	var in_types: PackedInt32Array = node.input_port_types()
	# Port 1 is the `hardness` MASK — a real grid, not a scalar: thermal erosion resists where the rock is
	# hard. Everything past it is a driveable scalar.
	var params := 0
	for i in range(2, in_types.size()):
		if in_types[i] == Pasture3DGraphNode.PortType.FLOAT or in_types[i] == Pasture3DGraphNode.PortType.INT:
			params += 1
	var ok_decl: bool = node.output_count() == 2 and node.output_names().size() == 2 			and node.output_port_types()[0] == Pasture3DGraphNode.PortType.HEIGHT 			and node.output_port_types()[1] == Pasture3DGraphNode.PortType.MASK 			and in_types.size() == node.input_count() and node.input_names().size() == node.input_count() 			and in_types.size() > 1 and in_types[0] == Pasture3DGraphNode.PortType.HEIGHT 			and in_types[1] == Pasture3DGraphNode.PortType.MASK 			and params == node.input_count() - 2
	print("    inputs=%d (surface + hardness mask + %d parameters) outputs=%d ok_decl=%s"
			% [node.input_count(), params, node.output_count(), ok_decl])
	if not ok_decl:
		_fail += 1; print("    !! thermal erosion ports declaration mismatch")

	var steep_cone := _steep_cone_surface()
	node.set("talus_angle", 30.0) # cone is 45 deg > 30 deg talus angle -> should slip
	node.set("iterations", 20)
	node.set("settling_rate", 0.5)

	var res: Array = node.eval_grid_channels([steep_cone, Pasture3DGraphOps.zeros(GW * GH)], GW, GH, null, RECT)
	var h: PackedFloat32Array = res[0]
	var talus: PackedFloat32Array = res[1]

	var apex_drop := steep_cone[GH/2 * GW + GW/2] - h[GH/2 * GW + GW/2]
	var max_talus := 0.0
	for i in range(GW * GH):
		max_talus = maxf(max_talus, talus[i])

	print("    apex elevation drop = %f m, max talus apron = %f" % [apex_drop, max_talus])
	if apex_drop < 0.1 or max_talus < 0.1:
		_fail += 1; print("    !! thermal erosion did not slip on 45 degree cone")

	# Hardness test: full hardness (1.0) must reduce slippage
	var hard_grid := Pasture3DGraphOps.filled(GW * GH, 1.0)
	var hard_res: Array = node.eval_grid_channels([steep_cone, hard_grid], GW, GH, null, RECT)
	var hard_h: PackedFloat32Array = hard_res[0]
	var hard_drop: float = steep_cone[GH/2 * GW + GW/2] - hard_h[GH/2 * GW + GW/2]
	print("    hardened apex drop = %f m (want < unhardened %f m)" % [hard_drop, apex_drop])
	if hard_drop >= apex_drop:
		_fail += 1; print("    !! hardness mask did not resist talus slippage")

	# Control: flat ground (< talus angle) must have 0 slippage
	var flat_surf := Pasture3DGraphOps.filled(GW * GH, 10.0)
	var flat_res: Array = node.eval_grid_channels([flat_surf, Pasture3DGraphOps.zeros(GW * GH)], GW, GH, null, RECT)
	var flat_h: PackedFloat32Array = flat_res[0]
	var flat_diff := 0.0
	for i in range(GW * GH):
		flat_diff = maxf(flat_diff, absf(flat_h[i] - flat_surf[i]))
	print("    control (flat terrain): max diff = %f m (want ~0)" % flat_diff)
	if flat_diff > EPS:
		_fail += 1; print("    !! control failed: flat ground slipped")


# ---- [C] Domain Warp -------------------------------------------------------------------------------

func _c_domain_warp() -> void:
	print("[C] Domain Warp: coordinate distortion vector noise fields")
	var node = Pasture3DGraphNodeRegistry.create(&"warp")
	if node == null:
		_fail += 1; print("    !! failed to instance warp from registry"); return

	node.set("frequency", 0.02)
	node.set("amplitude", 20.0)
	node.set("strength", 30.0)
	node.set("octaves", 3)

	var g := Pasture3DTerrainGraph.new()
	var w_idx := g.add_node(node, Vector2.ZERO)
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(200, 0))
	g.connect_ports(w_idx, 0, out, 0)

	var warped := g.evaluate(GW, GH, RECT)
	var min_h := INF; var max_h := -INF
	for v in warped:
		min_h = minf(min_h, v); max_h = maxf(max_h, v)
	print("    warped field span = [%.2f, %.2f] m" % [min_h, max_h])
	if max_h - min_h < 1.0:
		_fail += 1; print("    !! warp generated flat or degenerate output")

	# Control: strength 0 vs strength 30 must produce a significant spatial delta
	node.set("strength", 0.0)
	var unwarped := g.evaluate(GW, GH, RECT)
	var max_diff := 0.0
	for i in range(GW * GH):
		max_diff = maxf(max_diff, absf(warped[i] - unwarped[i]))
	print("    warp delta (strength 30 vs 0) = %f m (want > 0)" % max_diff)
	if max_diff < 0.5:
		_fail += 1; print("    !! warp strength did not distort sampling coordinates")


# ---- [D] Curvature Mask -----------------------------------------------------------------------------

func _d_curvature_mask() -> void:
	print("[D] Curvature Mask: Laplacian convexity (ridge) vs concavity (valley)")
	var node = Pasture3DGraphNodeRegistry.create(&"curvature")
	if node == null:
		_fail += 1; print("    !! failed to instance curvature from registry"); return

	var surf := _mound_surface() # mound center is convex (peak), skirt is concave (toe)
	node.set("mode", 0) # Convexity / Ridge
	node.set("radius", 2)
	node.set("contrast", 1.5)

	var ridge_mask: PackedFloat32Array = node.eval_grid([surf], GW, GH, null, RECT)
	var peak_val := ridge_mask[GH/2 * GW + GW/2]
	var edge_val := ridge_mask[0]
	print("    ridge mask peak = %f, flat edge = %f" % [peak_val, edge_val])
	if peak_val < 0.5 or edge_val > 0.3:
		_fail += 1; print("    !! convexity mode did not isolate mound peak")

	# Concavity mode
	node.set("mode", 1) # Concavity / Valley
	var valley_mask: PackedFloat32Array = node.eval_grid([surf], GW, GH, null, RECT)
	var peak_val_v := valley_mask[GH/2 * GW + GW/2]
	print("    valley mask at peak = %f (want ~0)" % peak_val_v)
	if peak_val_v > 0.2:
		_fail += 1; print("    !! concavity mode falsely triggered on mound peak")

	# Control: planar surface has 0 curvature
	var plane := PackedFloat32Array(); plane.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			plane[iz * GW + ix] = float(ix) * 2.0 + float(iz) * 1.5
	var plane_curv: PackedFloat32Array = node.eval_grid([plane], GW, GH, null, RECT)
	var max_plane_c := 0.0
	for v in plane_curv: max_plane_c = maxf(max_plane_c, v)
	print("    control (plane): max curvature mask = %f (want ~0)" % max_plane_c)
	if max_plane_c > 0.05:
		_fail += 1; print("    !! planar surface produced non-zero curvature")


# ---- [E] Geological Strata -------------------------------------------------------------------------

func _e_geological_strata() -> void:
	print("[E] Geological Strata: tilted sedimentary bedding & terrace profile")
	var node = Pasture3DGraphNodeRegistry.create(&"strata")
	if node == null:
		_fail += 1; print("    !! failed to instance strata from registry"); return

	node.set("band_height", 8.0)
	node.set("hardness", 0.8)
	node.set("dip", 5.0)
	node.set("dip_direction_degrees", 45.0)

	var inp := _mound_surface()
	var g := Pasture3DTerrainGraph.new()
	var in_nd := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var st_nd := g.add_node(node, Vector2(200, 0))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(400, 0))
	g.connect_ports(in_nd, 0, st_nd, 0)
	g.connect_ports(st_nd, 0, out, 0)

	var stepped := g.evaluate(GW, GH, RECT, null, inp)
	var max_diff := 0.0
	for i in range(GW * GH):
		max_diff = maxf(max_diff, absf(stepped[i] - inp[i]))
	print("    strata max delta = %f m" % max_diff)
	if max_diff < 0.5:
		_fail += 1; print("    !! strata did not terrace slopes")

	# Control: amount 0 -> identity (height == input)
	node.set("amount", 0.0)
	var soft_res := g.evaluate(GW, GH, RECT, null, inp)
	var soft_diff := 0.0
	for i in range(GW * GH):
		soft_diff = maxf(soft_diff, absf(soft_res[i] - inp[i]))
	print("    control (amount=0): max delta = %f m (want ~0)" % soft_diff)
	if soft_diff > EPS:
		_fail += 1; print("    !! control failed: zero amount altered field")


# ---- [F] Curve Remap -------------------------------------------------------------------------------

func _f_curve_remap() -> void:
	print("[F] Curve Remap: transfer function and window scaling")
	var node = Pasture3DGraphNodeRegistry.create(&"curve")
	if node == null:
		_fail += 1; print("    !! failed to instance curve from registry"); return

	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.5, 1.0)) # peak response at middle
	c.add_point(Vector2(1.0, 0.0))
	node.set("curve", c)
	node.set("input_min", 0.0)
	node.set("input_max", 40.0)
	node.set("output_min", 0.0)
	node.set("output_max", 100.0)

	# Cell test: input 20.0 (X=0.5) -> curve Y=1.0 -> output 100.0
	var out_val := node.eval_cell(0.0, 0.0, PackedFloat32Array([20.0]))
	print("    input 20.0 m (X=0.5) -> remap output = %f m (want 100.0)" % out_val)
	if absf(out_val - 100.0) > 0.5:
		_fail += 1; print("    !! curve node remap mismatch")

	# Test auto_fit_range
	node.auto_fit_range(10.0, 50.0)
	if absf(node.input_min - 10.0) > EPS or absf(node.input_max - 50.0) > EPS:
		_fail += 1; print("    !! curve auto_fit_range failed")

	# Control: amount 0 -> pass-through
	node.set("amount", 0.0)
	var pass_val := node.eval_cell(0.0, 0.0, PackedFloat32Array([20.0]))
	print("    control (amount=0): output = %f m (want 20.0)" % pass_val)
	if absf(pass_val - 20.0) > EPS:
		_fail += 1; print("    !! curve amount=0 did not pass through input")


# ---- [G] Range Remap & Soft Clamp ------------------------------------------------------------------

func _g_range_remap() -> void:
	print("[G] Range Remap: linear scaling, clamping, inversion, and soft-knee")
	var node = Pasture3DGraphNodeRegistry.create(&"remap")
	if node == null:
		_fail += 1; print("    !! failed to instance remap from registry"); return

	node.set("in_min", 0.0)
	node.set("in_max", 100.0)
	node.set("out_min", 0.0)
	node.set("out_max", 1.0)
	node.set("clamp_output", true)

	var v50 := node.eval_cell(0.0, 0.0, PackedFloat32Array([50.0]))
	var v150 := node.eval_cell(0.0, 0.0, PackedFloat32Array([150.0])) # clamped to 1.0
	print("    input 50.0 -> %f (want 0.5), input 150.0 -> %f (want 1.0)" % [v50, v150])
	if absf(v50 - 0.5) > EPS or absf(v150 - 1.0) > EPS:
		_fail += 1; print("    !! remap linear / clamp calculation mismatch")

	# Invert test
	node.set("invert", true)
	var v50_inv := node.eval_cell(0.0, 0.0, PackedFloat32Array([50.0]))
	var v0_inv := node.eval_cell(0.0, 0.0, PackedFloat32Array([0.0]))
	print("    inverted: input 50.0 -> %f (want 0.5), input 0.0 -> %f (want 1.0)" % [v50_inv, v0_inv])
	if absf(v50_inv - 0.5) > EPS or absf(v0_inv - 1.0) > EPS:
		_fail += 1; print("    !! remap inversion mismatch")

	# Soft-knee test: input at boundary smoothly rounds without hard inflection
	node.set("invert", false)
	node.set("soft_knee", 0.4)
	var v_knee := node.eval_cell(0.0, 0.0, PackedFloat32Array([95.0]))
	print("    soft-knee at 95%% = %f (want smoothly < 1.0)" % v_knee)
	if v_knee <= 0.80 or v_knee >= 1.0:
		_fail += 1; print("    !! soft-knee did not smooth boundary transition")

	# Test auto_fit_range
	node.auto_fit_range(-5.0, 45.0)
	if absf(node.in_min - (-5.0)) > EPS or absf(node.in_max - 45.0) > EPS:
		_fail += 1; print("    !! remap auto_fit_range failed")

	# Control: identity window [0, 100] -> [0, 100] with soft_knee=0
	node.set("in_min", 0.0)
	node.set("in_max", 100.0)
	node.set("out_max", 100.0)
	node.set("soft_knee", 0.0)
	var v_id := node.eval_cell(0.0, 0.0, PackedFloat32Array([42.5]))
	print("    control (identity): input 42.5 -> %f (want 42.5)" % v_id)
	if absf(v_id - 42.5) > EPS:
		_fail += 1; print("    !! identity remap altered input value")


# ---- [H] Registry & Preset Networks ----------------------------------------------------------------

func _h_registry_and_presets() -> void:
	print("[H] Registry discovery & Preset template generation")
	var ops: Array[StringName] = [&"erosion_hydraulic", &"erosion_thermal", &"warp", &"curvature", &"strata", &"curve", &"remap"]
	for op in ops:
		var nd = Pasture3DGraphNodeRegistry.create(op)
		if nd == null:
			_fail += 1; print("    !! registry create failed for op %s" % op)

	# Verify search tags
	var search_sed := Pasture3DGraphNodeRegistry.search("sediment")
	var search_talus := Pasture3DGraphNodeRegistry.search("talus")
	var search_strata := Pasture3DGraphNodeRegistry.search("strata")
	print("    tag search: 'sediment' matches=%d, 'talus' matches=%d, 'strata' matches=%d" % [
		search_sed.size(), search_talus.size(), search_strata.size()])
	if search_sed.is_empty() or search_talus.is_empty() or search_strata.is_empty():
		_fail += 1; print("    !! tag search missed required node keywords")

	# Test Editor Preset generation
	var editor = GraphEditorScript.new()
	var g := Pasture3DTerrainGraph.new()
	editor.edit_graph(g)

	for preset_id in [5, 6, 7]:
		editor._insert_preset(preset_id, Vector2.ZERO)
		var res := g.evaluate(GW, GH, RECT)
		var valid_cells := 0
		for v in res:
			if is_finite(v): valid_cells += 1
		print("    preset %d evaluated -> %d/%d finite cells" % [preset_id, valid_cells, GW * GH])
		if valid_cells != GW * GH:
			_fail += 1; print("    !! preset %d generated invalid / NaN field" % preset_id)
