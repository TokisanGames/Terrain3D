# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# ClosedLoopMaskGate — Verification suite for:
# 1. Standardized Mask Falloff Width exposure across closed-loop brushes (Mound, Plow, Splat, Pond).
# 2. Hybrid feathering on Pasture3DNodeGraph (USE_BRUSH_MASK, CUSTOM, OFF).
# 3. Boundary continuity (linear blend to incoming ground at loop rim with 0 delta).
# 4. Mound reach capping in SLOPE_ANGLE mode.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/ClosedLoopMaskGate.tscn
extends Node

const GW := 50
const GH := 50
const VS := 1.0
const X0 := -25.0
const Z0 := -25.0
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("\n=== ClosedLoopMaskGate: Mask Falloff Width & Graph Feathering ===\n")
	_audit_property_visibility()
	_audit_graph_feather_modes()
	_audit_boundary_continuity()
	_audit_mound_reach_capping()
	print("\n=== %s (%d failures) ===\n" % ["CLOSED LOOP MASK PASS" if _fail == 0 else "CLOSED LOOP MASK FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _audit_property_visibility() -> void:
	print("[1] Property visibility and defaults across closed-loop brushes:")
	var mound := Pasture3DMound.new()
	var plow := Pasture3DPlow.new()
	var splat := Pasture3DSplat.new()
	var pond := Pasture3DPond.new()

	# Mound defaults and visibility
	print("    Mound default flank_mode: %s" % mound.flank_mode)
	var mound_fw_editor := _has_editor_usage(mound, "falloff_width")
	print("    Mound falloff_width in SLOPE_ANGLE editor-visible: %s (want true)" % mound_fw_editor)
	if not mound_fw_editor:
		_fail += 1
		print("    !! Mound falloff_width is hidden in SLOPE_ANGLE mode")

	mound.flank_mode = Pasture3DMound.FlankMode.FIXED_WIDTH
	var mound_fw_fixed := _has_editor_usage(mound, "falloff_width")
	print("    Mound falloff_width in FIXED_WIDTH editor-visible: %s (want true)" % mound_fw_fixed)
	if not mound_fw_fixed:
		_fail += 1
		print("    !! Mound falloff_width is hidden in FIXED_WIDTH mode")

	# Pond defaults and visibility
	print("    Pond default flank_mode: %s (want FIXED_WIDTH=%d)" % [pond.flank_mode, Pasture3DMound.FlankMode.FIXED_WIDTH])
	if pond.flank_mode != Pasture3DMound.FlankMode.FIXED_WIDTH:
		_fail += 1
		print("    !! Pond should default to FIXED_WIDTH so falloff_width governs bank run")

	var pond_fw_editor := _has_editor_usage(pond, "falloff_width")
	print("    Pond falloff_width editor-visible: %s (want true)" % pond_fw_editor)
	if not pond_fw_editor:
		_fail += 1
		print("    !! Pond falloff_width is hidden from editor")
	if not is_equal_approx(pond.falloff_width, 8.0):
		_fail += 1
		print("    !! Pond falloff_width should default to 8.0, got %.1f" % pond.falloff_width)

	# Plow & Splat visibility
	if not _has_editor_usage(plow, "falloff_width"):
		_fail += 1
		print("    !! Plow falloff_width is missing from editor")
	if not _has_editor_usage(splat, "falloff_width"):
		_fail += 1
		print("    !! Splat falloff_width is missing from editor")

	# Pasture3DNodeGraph feather_mode visibility
	var mod_graph := Pasture3DNodeGraph.new()
	print("    Pasture3DNodeGraph default feather_mode: %s (want USE_BRUSH_MASK=0)" % mod_graph.feather_mode)
	if mod_graph.feather_mode != Pasture3DNodeGraph.FeatherMode.USE_BRUSH_MASK:
		_fail += 1
		print("    !! Pasture3DNodeGraph should default to USE_BRUSH_MASK")

	var custom_fw_hidden := not _has_editor_usage(mod_graph, "custom_falloff_width")
	print("    custom_falloff_width hidden under USE_BRUSH_MASK: %s (want true)" % custom_fw_hidden)
	if not custom_fw_hidden:
		_fail += 1
		print("    !! custom_falloff_width should be hidden when feather_mode != CUSTOM")

	mod_graph.feather_mode = Pasture3DNodeGraph.FeatherMode.CUSTOM
	var custom_fw_shown := _has_editor_usage(mod_graph, "custom_falloff_width")
	print("    custom_falloff_width visible under CUSTOM: %s (want true)" % custom_fw_shown)
	if not custom_fw_shown:
		_fail += 1
		print("    !! custom_falloff_width should be visible when feather_mode == CUSTOM")


func _audit_graph_feather_modes() -> void:
	print("\n[2] Pasture3DNodeGraph feathering modes (USE_BRUSH_MASK, CUSTOM, OFF):")
	var brush := Pasture3DMound.new()
	add_child(brush)

	# Graph: Input + Constant 20m offset
	var g := Pasture3DTerrainGraph.new()
	var n_in := Pasture3DGraphNodeInput.new()
	var n_const := Pasture3DGraphNodeConst.new(); n_const.value = 20.0
	var n_add := Pasture3DGraphNodeBlend.new(); n_add.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var n_out := Pasture3DGraphNodeOutput.new()
	var typed: Array[Pasture3DGraphNode] = [n_in, n_const, n_add, n_out]
	g.nodes = typed
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]),
		PackedInt32Array([1, 0, 2, 1]),
		PackedInt32Array([2, 0, 3, 0]),
	]

	var node_mod := Pasture3DNodeGraph.new()
	node_mod.graph = g
	node_mod.strength = 1.0

	# 1D radial distance field across 50x50 grid: centre at (25, 25), radius 20m
	var sdf := PackedFloat32Array()
	sdf.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var rx := float(ix - 25) * VS
			var rz := float(iz - 25) * VS
			var dist := sqrt(rx * rx + rz * rz)
			sdf[iz * GW + ix] = 20.0 - dist # positive inside, 0 at radius 20, negative outside

	var basey := PackedFloat32Array(); basey.resize(GW * GH)
	var amp := PackedFloat64Array(); amp.resize(GW * GH)
	var prof := PackedFloat64Array(); prof.resize(GW * GH); prof.fill(1.0)

	var ctx := {
		"gw": GW, "gh": GH, "vs": VS, "min_x": X0, "min_z": Z0,
		"add": true, "sdf": sdf, "edge_offset": 0.0,
		"falloff_width": 10.0, "falloff_curve": null,
	}

	# Mode A: USE_BRUSH_MASK (10m falloff)
	node_mod.feather_mode = Pasture3DNodeGraph.FeatherMode.USE_BRUSH_MASK
	var res_brush := brush._run_modifier_stack([_step(node_mod)], amp.duplicate(), prof, basey, ctx)

	# Mode B: CUSTOM (5m falloff)
	node_mod.feather_mode = Pasture3DNodeGraph.FeatherMode.CUSTOM
	node_mod.custom_falloff_width = 5.0
	var res_custom := brush._run_modifier_stack([_step(node_mod)], amp.duplicate(), prof, basey, ctx)

	# Mode C: OFF (unfeathered inside)
	node_mod.feather_mode = Pasture3DNodeGraph.FeatherMode.OFF
	var res_off := brush._run_modifier_stack([_step(node_mod)], amp.duplicate(), prof, basey, ctx)

	# Check cell at centre: dist = 0, signed_d = 20 > 10m -> all modes should be full 20m
	var c_idx := 25 * GW + 25
	print("    centre (d=20m): brush=%.2f custom=%.2f off=%.2f (want 20.00)" % [res_brush[c_idx], res_custom[c_idx], res_off[c_idx]])
	if absf(res_brush[c_idx] - 20.0) > EPS or absf(res_custom[c_idx] - 20.0) > EPS or absf(res_off[c_idx] - 20.0) > EPS:
		_fail += 1
		print("    !! centre cells should reach full graph amplitude in all modes")

	# Check cell at signed_d = 5m (ix = 40, iz = 25 -> dist = 15m -> d = 5m):
	# In USE_BRUSH_MASK (fw=10): u = 5/10 = 0.5 -> smoothstep(0.5) = 0.5 -> 10.0m
	# In CUSTOM (fw=5): u = 5/5 = 1.0 -> 20.0m
	# In OFF: 20.0m
	var mid_idx := 25 * GW + 40
	print("    mid-point d=5m: brush=%.2f (want ~10.00), custom=%.2f (want 20.00), off=%.2f (want 20.00)"
		% [res_brush[mid_idx], res_custom[mid_idx], res_off[mid_idx]])
	if absf(res_brush[mid_idx] - 10.0) > 0.5:
		_fail += 1
		print("    !! USE_BRUSH_MASK did not feather at d=5m (got %.2f, want ~10.0)" % res_brush[mid_idx])
	if absf(res_custom[mid_idx] - 20.0) > EPS:
		_fail += 1
		print("    !! CUSTOM should have reached full strength at d=5m")
	if absf(res_off[mid_idx] - 20.0) > EPS:
		_fail += 1
		print("    !! OFF should be unattenuated inside loop")


func _audit_boundary_continuity() -> void:
	print("\n[3] Boundary continuity (zero delta at loop rim):")
	var brush := Pasture3DMound.new()
	add_child(brush)

	var g := Pasture3DTerrainGraph.new()
	var n_in := Pasture3DGraphNodeInput.new()
	var n_const := Pasture3DGraphNodeConst.new(); n_const.value = 50.0
	var n_add := Pasture3DGraphNodeBlend.new(); n_add.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var n_out := Pasture3DGraphNodeOutput.new()
	g.nodes = [n_in, n_const, n_add, n_out]
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]),
		PackedInt32Array([1, 0, 2, 1]),
		PackedInt32Array([2, 0, 3, 0]),
	]

	var node_mod := Pasture3DNodeGraph.new()
	node_mod.graph = g
	node_mod.strength = 1.0
	node_mod.feather_mode = Pasture3DNodeGraph.FeatherMode.USE_BRUSH_MASK

	var sdf := PackedFloat32Array(); sdf.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var rx := float(ix - 25) * VS
			var rz := float(iz - 25) * VS
			sdf[iz * GW + ix] = 20.0 - sqrt(rx * rx + rz * rz)

	var basey := PackedFloat32Array(); basey.resize(GW * GH)
	var amp := PackedFloat64Array(); amp.resize(GW * GH)
	var prof := PackedFloat64Array(); prof.resize(GW * GH); prof.fill(1.0)

	var ctx := {
		"gw": GW, "gh": GH, "vs": VS, "min_x": X0, "min_z": Z0,
		"add": true, "sdf": sdf, "edge_offset": 0.0,
		"falloff_width": 10.0, "falloff_curve": null,
	}

	var res := brush._run_modifier_stack([_step(node_mod)], amp, prof, basey, ctx)

	# Cell at rim: dist = 20m -> ix = 45, iz = 25 -> signed_d = 0.0
	var rim_idx := 25 * GW + 45
	var rim_val := res[rim_idx]
	print("    rim cell (d=0.0m): delta = %.6f m (want 0.000000)" % rim_val)
	if absf(rim_val) > EPS:
		_fail += 1
		print("    !! boundary cliff detected: rim cell has non-zero displacement %.4f m" % rim_val)

	# Cell 1m inside rim: signed_d = 1.0m, u = 0.1 -> smoothstep(0.1) = 0.028 -> ~1.4m displacement
	var near_idx := 25 * GW + 44 # dist = 19m -> d = 1m
	var near_val := res[near_idx]
	print("    near-rim cell (d=1.0m): delta = %.4f m (want ~1.4m)" % near_val)
	if near_val < 0.5 or near_val > 3.0:
		_fail += 1
		print("    !! near-rim cell did not feather smoothly")


func _audit_mound_reach_capping() -> void:
	print("\n[4] Mound SLOPE_ANGLE capped reach governed by falloff_width:")
	var mound := Pasture3DMound.new()
	mound.height = 20.0
	mound.capped = true
	mound.flank_mode = Pasture3DMound.FlankMode.SLOPE_ANGLE
	mound.slope_angle = 30.0 # tan(30) = 0.57735 -> unconstrained run = 20 / 0.57735 = 34.64m
	mound.falloff_width = 15.0 # should cap run to 15.0m

	var c_run := 20.0 / tan(deg_to_rad(30.0))
	var capped_run := minf(c_run, mound.falloff_width)
	print("    unconstrained slope run = %.2f m, capped run = %.2f m" % [c_run, capped_run])
	if not is_equal_approx(capped_run, 15.0):
		_fail += 1
		print("    !! falloff_width did not cap the slope run")


func _step(p_node: Pasture3DNodeGraph) -> Dictionary:
	return {"mod": p_node, "op": p_node.op(), "grid": p_node.needs_grid()}


func _has_editor_usage(p_obj: Object, p_prop: String) -> bool:
	for p in p_obj.get_property_list():
		if p.get("name", "") == p_prop:
			return (int(p.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
	return false
