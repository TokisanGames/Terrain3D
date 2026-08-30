# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFrozenSolverGate — every solver that owns a FROZEN cache honours it, on the path the graph
# actually takes.
#
# WHY THIS EXISTS. A FROZEN solver serves its own cached solve and flags itself stale when the ground
# underneath it changes. That machinery lives in GDScript, on the node. `evaluate` tries the native
# whole-graph path FIRST, and a natively-lowered graph never calls the node at all — so for every solver
# whose op is in the native allow-list, freezing silently did nothing: it re-solved every time and never
# reported itself stale. Worse than slow, because it looked like it worked.
#
# Three gates already covered Scree, Erosion and DLA one at a time, each written against its own node.
# DLA's passed by accident — its op was never added to the allow-list, so it kept falling to GDScript. The
# other eight solvers with the same cache had no gate at all. This one sweeps the whole family from the
# REGISTRY, so a solver that grows a cache tomorrow is covered the day it appears rather than the day
# someone remembers to write a gate for it.
#
# The claim, per solver:
#   [A] FROZEN declines the native path and LIVE does not, so freezing is what moves it — with a census
#       control proving these ops really are natively supported when LIVE, since otherwise "declines
#       native" would be true of everything and prove nothing.
#   [B] FROZEN serves the cached solve against a CHANGED surface and reports itself stale; Bake re-solves
#       and clears stale; and LIVE tracks the surface and never goes stale (the moving control).
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const EPS := 1.0e-5

var _fail := 0
var _live_native := 0


func _ready() -> void:
	print("=== GraphFrozenSolverGate: every FROZEN solver honours its cache on the real path ===\n")
	var ops := _frozen_capable_ops()
	print("[sweep] %d solvers expose a FROZEN evaluation: %s\n" % [ops.size(), ops])
	if ops.size() < 8:
		_fail += 1
		print("!! found only %d frozen-capable solvers; this sweep has stopped finding them" % ops.size())

	_a_frozen_declines_native(ops)
	_b_frozen_serves_cache(ops)

	print("\n=== %s (%d failures) ===\n" % ["GRAPH FROZEN SOLVER PASS" if _fail == 0 else "GRAPH FROZEN SOLVER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- [A] ---------------------------------------------------------------------------------------------

func _a_frozen_declines_native(p_ops: Array) -> void:
	print("[A] FROZEN takes the graph off the native path; LIVE leaves it on")
	for op in p_ops:
		var frozen_blocks: bool = _make(op, true).blocks_native()
		var live_blocks: bool = _make(op, false).blocks_native()
		var frozen_native: bool = _graph(op, true).native_supported()
		var live_native: bool = _graph(op, false).native_supported()
		if live_native:
			_live_native += 1
		var ok: bool = frozen_blocks and not live_blocks and not frozen_native
		print("    %-22s blocks_native FROZEN=%s LIVE=%s | native_supported FROZEN=%s LIVE=%s"
			% [op, frozen_blocks, live_blocks, frozen_native, live_native])
		if not ok:
			_fail += 1
			print("      !! %s does not decline the native path when FROZEN" % op)

	# CONTROL. "FROZEN declines native" is worthless if nothing here reaches the native path to begin with
	# — that is exactly the state DLA was in, passing its own gate for the wrong reason. Most of the family
	# must lower when LIVE, or this section is measuring an empty set.
	print("    control: %d of %d solvers lower to native when LIVE (want > half)" % [_live_native, p_ops.size()])
	if _live_native * 2 <= p_ops.size():
		_fail += 1
		print("    !! control dead: these ops barely reach native at all, so declining it proves nothing")


# ---- [B] ---------------------------------------------------------------------------------------------

func _b_frozen_serves_cache(p_ops: Array) -> void:
	print("\n[B] FROZEN serves the cache over a changed surface and reports stale; Bake re-solves")
	var surf_a := _mound()
	var surf_b := PackedFloat32Array()
	surf_b.resize(GW * GH) # flat 0 — nothing for any of these solvers to work on

	var surface_tracking := 0
	for op in p_ops:
		# Which stimulus is the right one is decided by the solver, not by a list of names here. A solver
		# whose LIVE output follows the surface must notice a surface change; one that does not read the
		# surface at all (DLA grows from a seed, and with Ridge Seeding off the input is irrelevant) can
		# only be stimulated through a parameter. Asking DLA to notice a surface it never reads would be
		# testing the fixture, not the freeze.
		var probe := _make(op, false)
		var pg := _graph_with(probe)
		var la := pg.evaluate(GW, GH, RECT, null, surf_a)
		var lb := pg.evaluate(GW, GH, RECT, null, surf_b)
		var reads_surface: bool = _max_abs_diff(la, lb) > EPS
		var live_ok: bool = not probe._stale
		if reads_surface:
			surface_tracking += 1

		var node := _make(op, true)
		var g := _graph_with(node)
		var r1 := g.evaluate(GW, GH, RECT, null, surf_a)
		# Staleness is the `_stale` flag, not the warning count: node_warnings() also carries a benign
		# "holds N MB of frozen solve" notice, so counting warnings would read as stale when it is not.
		var stale_fresh: bool = node._stale

		var r2: PackedFloat32Array
		var r3: PackedFloat32Array
		var stimulus := ""
		# `_stale` is sampled between the stimulus and the Bake, not after: clearing the cache re-solves and
		# clears the flag, so a read taken below the Bake would report every solver as never having gone
		# stale — which is what it did until this line moved up here.
		var went_stale := false
		if reads_surface:
			stimulus = "surface"
			r2 = g.evaluate(GW, GH, RECT, null, surf_b)
			went_stale = node._stale
			node.clear_cache()
			r3 = g.evaluate(GW, GH, RECT, null, surf_b)
		else:
			stimulus = "seed"
			if not _has_property(node, "seed"):
				_fail += 1
				print("      !! %s reads neither the surface nor a seed; this gate cannot stimulate it" % op)
				continue
			node.set("seed", int(node.get("seed")) + 7919)
			r2 = g.evaluate(GW, GH, RECT, null, surf_a)
			went_stale = node._stale
			node.clear_cache()
			r3 = g.evaluate(GW, GH, RECT, null, surf_a)

		var served: bool = _max_abs_diff(r1, r2) < EPS
		var rebaked: bool = _max_abs_diff(r1, r3) > EPS
		var stale_cleared: bool = not node._stale

		var ok: bool = not stale_fresh and served and went_stale and rebaked and stale_cleared and live_ok
		print("    %-22s stimulus=%-7s fresh-not-stale=%s served=%s stale=%s rebaked=%s cleared=%s | LIVE never stale=%s"
			% [op, stimulus, not stale_fresh, served, went_stale, rebaked, stale_cleared, live_ok])
		if not ok:
			_fail += 1
			print("      !! %s did not honour its frozen cache" % op)

	# CONTROL: the surface branch must be the one most solvers take. If they all fell through to the seed
	# branch, this section would no longer be testing the thing that actually broke — a solver failing to
	# notice that the ground under it moved.
	print("    control: %d of %d solvers track the surface and took the surface stimulus (want > half)"
		% [surface_tracking, p_ops.size()])
	if surface_tracking * 2 <= p_ops.size():
		_fail += 1
		print("    !! control dead: almost nothing here reads its surface, so the surface path went untested")


# ---- helpers -----------------------------------------------------------------------------------------

## Every registered op whose node exposes a FROZEN evaluation and a cache to go with it. Read from the
## REGISTRY rather than a hand-written list, so this gate cannot fall behind the node set.
func _frozen_capable_ops() -> Array:
	var out: Array = []
	for entry in Pasture3DGraphNodeRegistry.entries():
		var op: StringName = entry["op"] if entry.has("op") else &""
		if op == &"" or String(op).begins_with("dev_"):
			continue
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n == null or not n.has_method("clear_cache"):
			continue
		for p in n.get_property_list():
			if String(p.get("name", "")) == "evaluation":
				out.append(op)
				break
	out.sort()
	return out


func _make(p_op: StringName, p_frozen: bool) -> Pasture3DGraphNode:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
	# Each node declares its own `Evaluation` enum, but all of them are {LIVE = 0, FROZEN = 1}; setting by
	# value keeps this sweep from needing a reference to eleven different scripts. Section [A] would catch
	# the day that stops being true, because blocks_native() would disagree with the value set here.
	n.set("evaluation", 1 if p_frozen else 0)
	return n


func _graph(p_op: StringName, p_frozen: bool) -> Pasture3DTerrainGraph:
	return _graph_with(_make(p_op, p_frozen))


## Input -> solver -> Output. The Input node matters: these are filters over a surface, and a graph that
## reads no surface would let a solver look correct while ignoring the thing it is meant to act on.
func _graph_with(p_node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var i_in := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var i_n := g.add_node(p_node)
	var i_out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(i_in, 0, i_n, 0)
	g.connect_ports(i_n, 0, i_out, 0)
	return g


## A smooth mound, so every solver in the family has real relief and real slope to act on.
func _mound() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	var cx := float(GW - 1) * 0.5
	var cz := float(GH - 1) * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var ddx := (float(ix) - cx) / cx
			var ddz := (float(iz) - cz) / cx
			var d2 := ddx * ddx + ddz * ddz
			s[iz * GW + ix] = 90.0 * maxf(0.0, 1.0 - d2)
	return s


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		var d := absf(p_a[i] - p_b[i])
		if is_finite(d):
			m = maxf(m, d)
	return m


## Whether a node exposes a given property, so the gate can pick a stimulus without knowing the script.
func _has_property(p_node: Pasture3DGraphNode, p_name: String) -> bool:
	for prop in p_node.get_property_list():
		if String(prop.get("name", "")) == p_name:
			return true
	return false
