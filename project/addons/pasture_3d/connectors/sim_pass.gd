# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSimPass — ONE pass of a Pasture3DSimManager's chain, made of SEVERAL Pasture3DSim members.
# See PASTURE3D_SIM_NODE_SPEC.md §21.2.
#
# WHY THIS EXISTS. Phase 6 made a pass and a Sim the same node, so everything except the loop — rate,
# diffusion, iterations, falloff, masks — was shared across every loop that pass owned. Several areas
# needing different SETTINGS could then only be expressed as several PASSES, which forces a chain order
# onto things that were never meant to be ordered. This node is the missing middle: many settings, one
# position in the chain.
#
# THE ONE RULE THAT MAKES IT A PASS RATHER THAN A FOLDER — every member reads the same input surface:
#
#     z_out = z_in + Σ  gate_i · ( solve_i(z_in) − z_in )
#
# Members do not see each other; the next pass sees all of them. Two consequences, both load-bearing:
#
#   * A pass is ORDER-INDEPENDENT. Shuffling members in the dock changes nothing (gate BA), which is why
#     member order means nothing while PASS order means everything.
#   * Overlapping members ADD. Where two members' loops overlap their deltas sum and the ground is cut
#     twice as deep — the same thing two overlapping stamp brushes on one ADD layer have always done here.
#     Deliberately NOT the saturating 1 − (1−g₁)(1−g₂) combine one Sim's own several loops use (§19.9
#     departure 6): that exists because those loops share ONE solved surface, and these do not.
#
# NOT a Pasture3DTerrainBrush. It owns no layer, draws no spline, has no footprint and never paints —
# extending the brush base would inherit a layer binding, an Add Spline button and an Add Water button
# that all have to be suppressed again. It extends Node3D and holds the two things a pass genuinely owns:
# its masks (§21.3) and its build-through buttons (§21.4).
#
# ONE LEVEL, NO NESTING. A container inside a container is not a pass of passes, it is a second way to
# spell the same thing, and the dock would stop showing the stack order at a glance — the property §19.2
# chose the scene tree for in the first place. `members()` returns direct Pasture3DSim children only, and
# a nested container warns.
@tool
@icon("res://addons/pasture_3d/icons/brush_sim.svg")
class_name Pasture3DSimPass
extends Node3D

@export_group("Masks")
## Keep this pass's own drainage masks after a build (§21.3): flow, erosion, deposition and wetness over
## the surface as it stood WHEN THIS PASS FINISHED, not after the whole chain.
##
## On by default, because tuning a chain you cannot inspect between its steps is the thing this phase
## exists to fix. It costs one extra fill+route per pass — about a thirtieth of a solve — plus four float
## grids over the cluster; press Plan Clusters to see what that is for the current stack before a build.
##
## In memory only. Nothing reaches disk until you press Save Masks.
@export var store_masks: bool = true:
	set(v):
		store_masks = v
		update_configuration_warnings()
## This pass's masks. Written by the manager's build, one per pass, describing THIS pass's output.
##
## `erosion` and `deposition` here are what this pass alone moved — its output minus its input — while
## `flow` and `wetness` are the whole routed surface at that moment, because drainage area and standing
## water are properties of the entire grid and belong to no single member (§21.3).
@export var sim_result: Pasture3DSimResult:
	set(v):
		sim_result = v
		update_configuration_warnings()
## Give this pass's masks a .res of their own, so a Plow's or Mound's relief selector can point at a FILE.
@export_tool_button("Save Masks") var _save_masks_btn = save_masks

@export_group("Bake")
## Run passes 1…this one at Preview Resolution and write (§21.4). NOT this pass alone: pass 2's input is
## pass 1's output, so a solo solve would calibrate something that never runs.
@export_tool_button("Preview To Here") var _preview_here_btn = preview_to_here
## Run passes 1…this one at Build Resolution and write. The layer then holds a PARTIAL chain, and the
## manager says so until you Simulate the whole thing.
@export_tool_button("Simulate To Here") var _simulate_here_btn = simulate_to_here


# ---- Where this node sits ---------------------------------------------------------------------------

## The Pasture3DSimManager this container is a pass of, or null when it is parked outside one.
func manager() -> Pasture3DSimManager:
	var p := get_parent()
	return p as Pasture3DSimManager if p is Pasture3DSimManager else null


## The Sims this pass runs, in dock order. Direct children only — see the header on nesting.
func members() -> Array:
	var out: Array = []
	for c in get_children():
		if c is Pasture3DSim:
			out.append(c)
	return out


## The members that will actually solve. A disabled member is skipped before its solve, so it costs
## nothing and contributes nothing — the one-click "is it this one?" gesture tuning a container needs.
func enabled_members() -> Array:
	return members().filter(func(s: Pasture3DSim): return s.enabled)


## This container's position in its manager's chain, 0-based, or -1 when it has no manager.
func pass_index() -> int:
	var mgr := manager()
	return mgr.pass_index_of(self) if mgr != null else -1


# ---- The buttons ------------------------------------------------------------------------------------

## §21.3, through the shared implementation on Pasture3DSimBase so a pass, a manager and a standalone Sim
## all write the same file the same way.
func save_masks() -> String:
	var mgr := manager()
	var dir := "res://"
	if mgr != null and mgr.is_configured() and String(mgr.terrain.data_directory) != "":
		dir = String(mgr.terrain.data_directory)
	var path := Pasture3DSimBase.save_masks_to(sim_result, _sim_label(), dir, String(name))
	if path != "":
		update_configuration_warnings()
	return path


func preview_to_here() -> void:
	await _run_to_here(true)


func simulate_to_here() -> void:
	await _run_to_here(false)


func _run_to_here(p_preview: bool) -> void:
	var mgr := manager()
	if mgr == null:
		push_warning(("%s: this container is not under a Pasture3DSimManager, so there is no chain to run "
			+ "to here. Drag it under one.") % _sim_label())
		return
	await mgr.simulate_to_pass(pass_index(), p_preview)


# ---- Hooks the manager calls on a pass, whichever kind it is ----------------------------------------
#
# A bare Pasture3DSim and this node are both "a pass" to the manager, and it reaches both through these
# four names. They are the same names Pasture3DSimBase uses, so the manager's per-pass mask writer is one
# piece of code rather than a branch on node type.

func _sim_label() -> String:
	return "Pasture3DSimPass '%s'" % name


func _sim_result_res() -> Pasture3DSimResult:
	return sim_result


func _set_sim_result_res(p_r: Pasture3DSimResult) -> void:
	sim_result = p_r


func _save_result(p_result: Pasture3DSimResult) -> void:
	Pasture3DSimBase.save_result_file(p_result, _sim_label())


# ---- Warnings ---------------------------------------------------------------------------------------

func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if get_parent() is Pasture3DSimPass:
		out.append(("A Pasture3DSimPass inside another one is not a pass of passes — it is a second way to "
			+ "spell the same thing, and it is not run. Drag it up to be a direct child of the manager."))
		return out
	var mgr := manager()
	if mgr == null:
		out.append(("This container is not a child of a Pasture3DSimManager, so nothing runs it. Drag it "
			+ "under one — its position among the manager's children is its position in the chain."))
		return out
	var all := members()
	var live := enabled_members()
	if all.is_empty():
		out.append(("This pass has no Pasture3DSim members, so it contributes nothing. Add Sim children — "
			+ "they all read the same input surface and their deltas are summed, so their order here does "
			+ "not matter (unlike the order of passes, which does)."))
		return out
	out.append(("This is pass %d of %d in '%s', with %d member(s)%s. Every member solves the SAME input "
		+ "surface and their masked deltas are added, so where two members' loops overlap the ground is "
		+ "cut by both.") % [pass_index() + 1, mgr.passes().size(), mgr.name, all.size(),
		"" if live.size() == all.size() else ", %d of them disabled" % (all.size() - live.size())])
	if live.is_empty():
		out.append("Every member of this pass is disabled, so the pass runs nothing at all.")
	var loopless: Array = []
	for s: Pasture3DSim in live:
		if s._get_splines().filter(func(p): return s._spline_paintable(p)).is_empty():
			loopless.append(s.name)
	if not loopless.is_empty():
		out.append("These members have no usable loop and contribute nothing: %s." % ", ".join(loopless))
	var nested: Array = []
	for c in get_children():
		if c is Pasture3DSimPass:
			nested.append(c.name)
	if not nested.is_empty():
		out.append(("These children are Pasture3DSimPass containers and are NOT run — one level only: %s."
			% ", ".join(nested)))
	if not store_masks and sim_result != null:
		out.append(("Store Masks is off but a Sim Result is still assigned here. It will not be rewritten "
			+ "by a build, so it describes whatever chain last wrote it."))
	out.append_array(Pasture3DSimBase.result_warnings_for(sim_result, mgr.pass_bake_hash()))
	return out
