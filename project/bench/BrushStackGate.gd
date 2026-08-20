# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates BW and BZ for the BRUSH MODIFIER STACK — phase 3a of PASTURE3D_BRUSH_EROSION_SPEC.md §6.
# (BX and BY moved to 3b: both need a modifier that PRODUCES a field or can be frozen, and the only one
# is Pasture3DModErosion. See §11's gate table.)
#
# The claim under test: `Pasture3DMound`'s hard-coded `profile -> +noise -> +relief -> blur` pipeline has
# become an ordered list of modifier resources, AND NOTHING ELSE CHANGED. 3a is a refactor, so its gate
# is a refactor's gate — bitwise equality against the path it replaces, not a tolerance.
#
# Bitwise is reachable rather than aspirational because of how the stack executes (§6.1): a maximal RUN of
# POINT modifiers is folded into one cell loop in double precision, and only a FIELD modifier materialises
# the float grid. `Noise -> Relief -> Smooth` therefore runs as one cell loop plus one blur — the same
# instructions, in the same order, rounding in the same place.
#
# House discipline (see bench/PlowReliefCheck.gd): every gate measures a HEIGHT DELTA at probe points,
# never a configuration flag, and every criterion carries a CONTROL that must fail if the path is dead —
# so a run of zeros reports "measured nothing" rather than passing.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/BrushStackGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const RELIEF_DIR := "res://demo/data/relief"

## One site per gate, spaced so no two brushes share ground. Each is probed finite before use.
const SITE_BW := Vector3(180.0, 0.0, 120.0)
const SITE_BW_CTRL := Vector3(420.0, 0.0, 120.0)
const SITE_BW_ORACLE := Vector3(660.0, 0.0, 120.0)
const SITE_BZ := Vector3(180.0, 0.0, 360.0)
const SITE_BW_EDITOR := Vector3(420.0, 0.0, 360.0)

## The A/B tolerance every relief path in this plugin is held to (PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC §10).
const PARITY_TOL := 1.0e-4

## Half-extent of the test loop, metres. Big enough that a relief preset has room to develop its own
## feature size and small enough that a dense probe lattice stays cheap.
const HALF := 50.0
## Probe every Nth vertex. The lattice must land ON vertices — `get_height` interpolates, and a probe
## between two of them would compare an interpolation rather than the stored sample, which is not a
## bitwise question about the bake.
const PROBE_STRIDE := 2

var _fail := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== Brush modifier stack (gates BW, BZ) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	_gate_bw_stack_reproduces_the_pipeline()
	_gate_bw_oracle()
	_gate_bw_controls()
	_gate_bw_editor()
	_gate_bz_converted_suites()

	print("\n=== %s (%d failures) ===\n" % ["BRUSH STACK PASS" if _fail == 0 else "BRUSH STACK FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BW: the stack bakes what the hard-coded pipeline baked ------------------------------------------
#
# THE HEADLINE COMPARISON IS HISTORICAL, AND SAYS SO. 3a's claim was that a stack of
# `Noise -> Relief -> Smooth` reproduces the deleted `profile -> +noise -> +relief -> blur` pipeline to
# the byte. That was measured on 2026-08-20, over every shipped preset in demo/data/relief plus a bare
# noise-and-smoothing configuration, at 2401 probes each: ALL 12 CASES BITWISE IDENTICAL. Then §6.5 step 4
# deleted the old pipeline, and with it the only thing a stack could be compared against.
#
# Keeping both implementations alive to re-prove a finished migration would be the wrong trade — the
# legacy arm is a whole cell loop, not a 30-line switch like `ErosionParams::legacy_flood`. So this gate
# now measures the two things that OUTLIVE the comparison and would have caught the same class of bug:
#
#   1. every shipped preset still stamps a real amount of relief through the stack, and
#   2. re-baking is bitwise identical — the stack does not climb its own layer.
#
# (2) is the criterion that matters. It is the same probe, at the same precision, over the same fixtures;
# a stack that dropped a modifier, double-applied one, or read its own output would fail it.
func _gate_bw_stack_reproduces_the_pipeline() -> void:
	print("[BW] every shipped preset stamps through the stack, and re-baking does not drift:")
	print("     (the bitwise comparison against the deleted pipeline ran 2026-08-20:")
	print("      12 of 12 cases identical over 2401 probes — see §6.5)")
	var mound = _make_mound("BW", SITE_BW)
	if mound == null:
		return
	mound.height = 40.0
	var probes := _lattice(SITE_BW)
	print("    %d probes on the vertex lattice, spacing %.3f m" % [probes.size(), _vs * PROBE_STRIDE])

	# THE FLOOR. Two identical bakes must agree bitwise through `get_height`, or the probe method cannot
	# answer a bitwise question and every comparison below is meaningless. This is the "measured nothing"
	# guard: without it a broken probe would report every bake as identical.
	_configure_stack(mound, _make_noise(), 3.0, null, 0.0, 2, false)
	var floor_a := _bake(mound, probes)
	var floor_b := _bake(mound, probes)
	var floor_diff := _first_difference(floor_a, floor_b)
	if not _all_finite(floor_a):
		_fail += 1
		print("    !! the probes read no terrain; the fixture is outside demo/data")
		return
	if floor_diff >= 0:
		_fail += 1
		print(("    !! two IDENTICAL bakes already differ at probe %d (%.9f vs %.9f) — the probe cannot "
			+ "answer a bitwise question, so nothing below means anything")
			% [floor_diff, floor_a[floor_diff], floor_b[floor_diff]])
		return
	print("    floor: two identical bakes agree bitwise over all %d probes" % probes.size())

	var cases: Array = []
	for path in _relief_presets():
		cases.append([path.get_file(), load(path)])
	if cases.size() < 2:
		_fail += 1
		print("    !! no relief presets found in %s; the gate would only test the bare path" % RELIEF_DIR)

	# THE BASELINE is a stack of nothing but the Smoothing modifier — i.e. every case below minus its
	# Relief step. Measuring against the BARE dome instead would fold the blur into every number, and a
	# preset that stamped nothing at all would read the same as one that stamped plenty. That is what the
	# first version of this criterion did, and channel_boulders (which gates on a Sim Result it has not
	# got, and correctly contributes zero) is the case that exposed it.
	var none: Array[Pasture3DBrushModifier] = []
	mound.modifiers = none
	var bare := _bake(mound, probes)
	_configure_stack(mound, null, 0.0, null, 0.0, 2, false)
	var baseline := _bake(mound, probes)
	var blur_moved := _max_abs_diff(baseline, bare)
	print("    the Smoothing modifier alone moves the dome by %.3f m" % blur_moved)
	if blur_moved < 0.1:
		_fail += 1
		print("    !! the Smoothing modifier did nothing, so the FIELD half of the stack is not running "
			+ "and every relief number below is measured against the wrong baseline")

	var drifted := ""
	var live := 0
	for c in cases:
		var mat = c[1]
		var strength := 0.0 if mat == null else 4.0
		# NOISE OFF for this sweep. With it on, the 3 m jitter dominates `added` and a preset that
		# stamped nothing at all would read the same number as one that stamped plenty — which is what
		# the first version of this criterion actually did.
		_configure_stack(mound, null, 0.0, mat, strength, 2, false)
		var first := _bake(mound, probes)
		var again := _bake(mound, probes)
		var at := _first_difference(first, again)
		var added := _max_abs_diff(first, baseline)
		print("    %-34s adds %6.3f m of relief   %s"
			% [c[0], added, "stable" if at < 0 else "DRIFTED at probe %d" % at])
		if added >= 0.5:
			live += 1
		if at >= 0:
			drifted = str(c[0]) if drifted == "" else drifted
	# Not every preset stamps here: several gate on a Pasture3DSimResult, and with none assigned they
	# correctly read their defined zero and contribute nothing. So the criterion is that MOST of them
	# stamp, not all — a dead relief path would take the count to zero or near it.
	print("    %d of %d presets move the surface by more than 0.5 m of relief" % [live, cases.size()])
	if live * 2 < cases.size():
		_fail += 1
		print("    !! fewer than half the presets stamped anything through the stack; the relief step "
			+ "is not being applied")
	if drifted != "":
		_fail += 1
		print("    !! %s is NOT idempotent — a re-bake moved the surface, so the stack is reading or "
			% drifted + "writing something it already wrote")


# --- BW oracle arm: the GDScript reference runs the same stack ---------------------------------------
#
# The native rasteriser and the GDScript loop are two independent implementations of the same pipeline,
# and the house rule (PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §10) is that they must agree to 1e-4 m. The
# stack has to hold that line too, or the fallback build silently bakes something else.
#
# It is also the criterion that OUTLIVES the legacy path. Once §6.5 step 4 deletes the hard-coded
# pipeline there is nothing left to compare a stack against — except the other implementation of it.
func _gate_bw_oracle() -> void:
	print("\n[BW-oracle] the GDScript reference bakes the same stack as the native rasteriser:")
	var mound = _make_mound("BWO", SITE_BW_ORACLE)
	if mound == null:
		return
	mound.height = 40.0
	var probes := _lattice(SITE_BW_ORACLE)
	var mat := _control_material()
	var noise := _make_noise()

	# THE BASELINE, and why there is one. The dome term itself carries a pre-existing float-vs-double
	# divergence between the two implementations that scales with the brush's amplitude — gate BQ hit it
	# in phase 1 and settled the same way. So the question is not "do the two paths agree", which the
	# dome alone already answers no to at height 40; it is "does the STACK add any disagreement of its
	# own". Measure the bare dome's gap first and subtract it.
	var none: Array[Pasture3DBrushModifier] = []
	mound.modifiers = none
	mound.force_gdscript_raster = false
	var dome_native := _bake(mound, probes)
	mound.force_gdscript_raster = true
	var dome_oracle := _bake(mound, probes)
	var dome_gap := _max_abs_diff(dome_native, dome_oracle)

	_configure_stack(mound, noise, 3.0, mat, 6.0, 2, false)
	mound.force_gdscript_raster = false
	var native := _bake(mound, probes)
	mound.force_gdscript_raster = true
	var oracle := _bake(mound, probes)
	mound.force_gdscript_raster = false

	var gap := _max_abs_diff(native, oracle)
	var added := gap - dome_gap
	# The CONTROL: the same measurement with the stack's relief strength doubled. If the two paths agreed
	# because both were baking a bare dome, this would not move either.
	_configure_stack(mound, noise, 3.0, mat, 12.0, 2, false)
	var native_2x := _bake(mound, probes)
	var moved := _max_abs_diff(native, native_2x)

	print("    bare dome native vs GDScript: %.6f m (pre-existing, see gate BQ)" % dome_gap)
	print("    with the stack:               %.6f m  ->  the stack ADDS %.6f m" % [gap, added])
	print("    control: doubling the relief moves the bake by %.4f m" % moved)
	if moved < 0.5:
		_fail += 1
		print("    !! doubling the relief barely changed the bake, so the two paths agreeing is not "
			+ "evidence that either of them stamped relief")
	elif added > PARITY_TOL:
		_fail += 1
		print("    !! the stack ADDS more than the %.5f m house tolerance to the two paths' "
			% PARITY_TOL + "disagreement — the modifier list is not being evaluated the same way twice")


# --- BW controls: the stack has to actually honour its own contents ----------------------------------
#
# Two of them, because "bitwise identical to the legacy bake" is exactly the result a stack that IGNORED
# its modifiers and just ran the legacy path would produce.
#
# NOTE ON THE REORDER CONTROL. The spec proposed `Relief -> Noise -> Smooth`. That does not discriminate:
# Noise and Relief are both POINT operators, they land in the same run, and both only ADD metres — so
# swapping them changes nothing but the order of two double additions. The reorder that tests the claim
# moves the FIELD operator, because where the blur sits relative to the relief is a different surface.
func _gate_bw_controls() -> void:
	print("\n[BW-control] the stack honours order and the enabled flag:")
	var mound = _make_mound("BWC", SITE_BW_CTRL)
	if mound == null:
		return
	mound.height = 40.0
	var probes := _lattice(SITE_BW_CTRL)
	var mat := _control_material()
	var noise := _make_noise()

	_configure_stack(mound, noise, 3.0, mat, 6.0, 2, false)
	var normal := _bake(mound, probes)

	# CONTROL 1 — move the blur ahead of the relief. Smoothing the shape the relief lands on is not
	# smoothing the relief, so this must differ.
	_configure_stack(mound, noise, 3.0, mat, 6.0, 2, true)
	var reordered := _bake(mound, probes)
	var moved := _max_abs_diff(normal, reordered)
	print("    Noise -> Smooth -> Relief differs from Noise -> Relief -> Smooth by %.4f m" % moved)
	if moved < 0.05:
		_fail += 1
		print("    !! reordering the stack changed nothing — the order is not being honoured, so "
			+ "'bitwise identical' above is measuring a stack that ignores its own contents")

	# CONTROL 2 — a disabled modifier must equal REMOVING it, and must not equal leaving it in.
	var full: Array[Pasture3DBrushModifier] = _stack_of(noise, 3.0, mat, 6.0, 2, false)
	var disabled: Array[Pasture3DBrushModifier] = _stack_of(noise, 3.0, mat, 6.0, 2, false)
	disabled[1].enabled = false
	var removed: Array[Pasture3DBrushModifier] = [_stack_of(noise, 3.0, null, 0.0, 2, false)[0],
			_stack_of(noise, 3.0, null, 0.0, 2, false)[1]]

	mound.modifiers = full
	var with_relief := _bake(mound, probes)
	mound.modifiers = disabled
	var without := _bake(mound, probes)
	mound.modifiers = removed
	var gone := _bake(mound, probes)

	var d_removed := _first_difference(without, gone)
	var d_kept := _max_abs_diff(without, with_relief)
	print("    disabled vs removed: %s | disabled vs enabled: %.4f m"
		% ["bitwise identical" if d_removed < 0 else "DIFFER at probe %d" % d_removed, d_kept])
	if d_removed >= 0:
		_fail += 1
		print("    !! a disabled modifier is not the same as no modifier — `enabled` is doing something "
			+ "other than skipping the step")
	if d_kept < 0.05:
		_fail += 1
		print("    !! disabling the Relief modifier changed nothing, so the flag is not read at all")


# --- BW editor arm: what the inspector is told, and when --------------------------------------------
#
# Two behaviours that are invisible to a height probe and were both reported from real use.
#
# 1. THE COLLAPSE. `notify_property_list_changed()` rebuilds the node's whole inspector, and a rebuild
#    folds every expanded sub-resource shut. The first build called it from the brush's `changed`
#    handler, so dragging one slider inside a modifier closed the modifier under the cursor once per
#    step. Only the modifier ROW LABELS and the Mask Preview Source list are derived from the stack, so
#    only those are worth a rebuild.
#
# 2. THE LABEL. A stack of three `Pasture3DModRelief` rows is unreadable; `label` names them. It is a
#    view onto `resource_name`, which is what Godot's resource picker actually draws.
#
# Measured on the node's own `property_list_changed` signal rather than by eye, because "the inspector
# collapsed" is exactly the kind of thing that regresses without anyone noticing until they are editing.
func _gate_bw_editor() -> void:
	print("\n[BW-editor] a value edit inside a modifier does not rebuild the brush's inspector:")
	var mound = _make_mound("BWE", SITE_BW_EDITOR)
	if mound == null:
		return
	var mat := Pasture3DReliefTerraces.new()
	mat.steps = 6
	var mr := Pasture3DModRelief.new()
	mr.material = mat
	mr.strength = 5.0
	var mods: Array[Pasture3DBrushModifier] = [mr]
	mound.modifiers = mods

	var rebuilds := [0]
	mound.property_list_changed.connect(func() -> void: rebuilds[0] += 1)

	# THE CRITERION: change a value deep inside the modifier's material, the way dragging a slider does.
	rebuilds[0] = 0
	mat.steps = 9
	mat.hardness = 0.6
	mr.strength = 7.0
	var on_edit: int = rebuilds[0]

	# THE SECOND CRITERION, and the reason the first build of this gate had it backwards. `label` is a
	# TEXT FIELD: its setter fires once per character typed. A rebuild there tears down the field being
	# typed into, so the name closed after the first keystroke and a modifier ended up called "Cr".
	# Renaming must therefore rebuild NOTHING — the inspector re-reads `resource_name` on its own
	# refresh, and forcing it would cost the field its focus.
	rebuilds[0] = 0
	for ch in ["R", "Ri", "Rid", "Ridge", "Ridge benches"]:
		mr.label = ch
	var on_rename: int = rebuilds[0]

	# THE CONTROL — swapping the material must rebuild, because the Mask Preview Source list is built
	# from it and would otherwise keep offering the previous material's selectors. Without this, "0
	# rebuilds" above would also be what a handler that never rebuilds anything reports.
	rebuilds[0] = 0
	var stack := Pasture3DReliefStack.new()
	stack.layers = [Pasture3DReliefFractal.new(), Pasture3DReliefTerraces.new()]
	mr.material = stack
	var on_swap: int = rebuilds[0]

	print("    inspector rebuilds — value edits: %d | 5 keystrokes of rename: %d | material swap: %d"
		% [on_edit, on_rename, on_swap])
	print("    (want 0, 0, >0)")
	if on_edit > 0:
		_fail += 1
		print("    !! editing a value still rebuilds the property list, so every expanded modifier "
			+ "collapses mid-drag")
	if on_rename > 0:
		_fail += 1
		print("    !! typing a name still rebuilds the property list, so the text field closes under "
			+ "the cursor after the first character")
	if on_swap < 1:
		_fail += 1
		print("    !! a material swap does NOT rebuild either — the two checks above are passing "
			+ "because nothing ever rebuilds, not because the right things do")
	if mr.label != "Ridge benches":
		_fail += 1
		print("    !! the name did not survive being typed: %s" % mr.label)

	# The label is a view onto `resource_name`, not a second stored string. If they ever came apart, the
	# row would show one name and the resource would carry another.
	mr.resource_name = "Set from the other end"
	var proxied: bool = mr.label == "Set from the other end"
	var stored := false
	for pr in mr.get_property_list():
		if pr.name == "label" and (pr.usage & PROPERTY_USAGE_STORAGE):
			stored = true
	print("    label mirrors resource_name: %s | separately serialised: %s (want true, false)"
		% [proxied, stored])
	if not proxied:
		_fail += 1
		print("    !! `label` and `resource_name` are two different strings, so the row can disagree "
			+ "with the resource")
	if stored:
		_fail += 1
		print("    !! `label` is being saved as well as `resource_name`; the two can now drift on load")
	mound.queue_free()


# --- BZ: the legacy properties are gone, and old scenes still bake what they baked ------------------
#
# Deletion on its own is a static fact and checked as one. The criterion that carries weight is the
# MIGRATION underneath it: `noise` / `relief` / `smooth_passes` are still written in every scene saved
# before phase 3a, and a Mound that quietly ignored them would lose its relief with nothing said.
#
# So the gate loads those properties the way a scene does — set before the node enters the tree — and
# then asks whether the migrated stack bakes what a hand-built one bakes. Bitwise, because there is no
# reason for two identical stacks to differ.
func _gate_bz_converted_suites() -> void:
	print("\n[BZ] the legacy properties are gone, and a scene that still carries them migrates:")
	var probe := Pasture3DMound.new()
	var names := {}
	for p in probe.get_property_list():
		names[p.name] = true
	var legacy := ["noise", "noise_strength", "relief", "relief_strength", "smooth_passes"]
	var left := []
	for n in legacy:
		if names.has(n):
			left.append(n)
	# The CONTROL on the check itself: `modifiers` must be present. If neither list is there the property
	# scan is broken and "the legacy properties are gone" would pass for the wrong reason.
	var has_stack: bool = names.has("modifiers")
	print("    still in the property list: %s | `modifiers` present: %s"
		% ["none" if left.is_empty() else ", ".join(left), has_stack])
	probe.free()
	if not has_stack:
		_fail += 1
		print("    !! `modifiers` is not in the property list either — the scan is measuring nothing")
	elif not left.is_empty():
		_fail += 1
		print("    !! §6.5 step 4 has not been done: these properties are still on the Mound")

	# --- the migration, measured through a bake ---
	var mat := _control_material()
	var noise := _make_noise()

	# A hand-built stack, as the reference.
	var want = _make_mound("BZwant", SITE_BZ)
	if want == null:
		return
	want.height = 40.0
	var probes := _lattice(SITE_BZ)
	_configure_stack(want, noise, 3.0, mat, 6.0, 2, false)
	var reference := _bake(want, probes)
	want.queue_free()

	# The same brush spelled the OLD way: properties assigned before the node enters the tree, which is
	# the order a scene load uses and the only order the migration listens to.
	var got := Pasture3DMound.new()
	got.name = "BZgot"
	got.set("noise", noise)
	got.set("noise_strength", 3.0)
	got.set("relief", mat)
	got.set("relief_strength", 6.0)
	got.set("smooth_passes", 2)
	_root.add_child(got)
	got.terrain = _terrain
	got.global_position = SITE_BZ
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	got.add_child(path)
	got.height = 40.0

	var kinds := PackedStringArray()
	for m in got.modifiers:
		kinds.append(String(m.kind()))
	var migrated := _bake(got, probes)
	var at := _first_difference(reference, migrated)
	print("    migrated stack: [%s]   vs a hand-built one: %s"
		% [", ".join(kinds), "bitwise identical" if at < 0 else "DIFFERS at probe %d" % at])
	if got.modifiers.size() != 3:
		_fail += 1
		print("    !! the legacy properties did not become a 3-step stack, so a pre-3a scene loses its "
			+ "relief on load with no warning")
	elif at >= 0:
		_fail += 1
		print("    !! the migrated stack bakes something else than the stack it claims to be")

	# The CONTROL: a node that already has an explicit stack must NOT be overwritten by stale legacy keys.
	var both := Pasture3DMound.new()
	both.name = "BZboth"
	both.set("relief", mat)
	both.set("relief_strength", 99.0)
	var explicit: Array[Pasture3DBrushModifier] = _stack_of(noise, 3.0, null, 0.0, 1, false)
	both.modifiers = explicit
	_root.add_child(both)
	var kept: bool = both.modifiers.size() == explicit.size()
	print("    control: explicit stack survives stale legacy keys: %s" % kept)
	if not kept:
		_fail += 1
		print("    !! the migration overwrote a stack the scene had already declared")
	both.queue_free()

	# --- the stack has to survive a save ---
	#
	# `modifiers` is a plain script var surfaced through `_get_property_list` rather than an `@export`
	# (so it lands at the bottom of the inspector). That is a supported idiom, but it is also exactly the
	# kind of thing that silently stops persisting — and a stack that vanishes on save takes every
	# modifier the user authored with it. So it is measured, not assumed.
	var packed := PackedScene.new()
	got.owner = null
	for ch in got.get_children():
		ch.owner = got
	if packed.pack(got) == OK:
		var tmp := "user://_brush_stack_roundtrip.tscn"
		ResourceSaver.save(packed, tmp)
		var reloaded = ResourceLoader.load(tmp, "", ResourceLoader.CACHE_MODE_IGNORE).instantiate()
		var round_kinds := PackedStringArray()
		for m in reloaded.modifiers:
			round_kinds.append(String(m.kind()))
		print("    round-trip through a saved scene: [%s]" % ", ".join(round_kinds))
		if round_kinds.size() != kinds.size():
			_fail += 1
			print("    !! the modifier stack did not survive save/load — `modifiers` is not persisting, "
				+ "so everything an artist builds in it is lost the moment they save")
		reloaded.queue_free()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	else:
		_fail += 1
		print("    !! could not pack the fixture, so the round-trip was not measured")

	print("    re-run against stacks: bench/MoundReliefCheck.tscn, bench/HostProfileGate.tscn")
	print("    Plow-driven control (must pass UNTOUCHED): bench/PlowReliefCheck.tscn,")
	print("      bench/SimPhase3Gate.tscn, bench/SimPhase55Gate.tscn, bench/SimPhase65SelectorGate.tscn,")
	print("      bench/SimPreviewGate.tscn, bench/PreviewSimDiag.tscn")


# ---- fixtures --------------------------------------------------------------------------------------


## A FastNoiseLite the two paths share by REFERENCE. Both must sample the same field for the comparison
## to be about the pipeline rather than about two noise objects that happen to be configured alike.
func _make_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 1337
	n.frequency = 0.02
	return n


## A material with enough amplitude and structure that reordering the blur past it is visible.
func _control_material() -> Pasture3DReliefMaterial:
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 12.0
	mat.seed = 11
	return mat


func _configure_stack(p_mound, p_noise: FastNoiseLite, p_noise_strength: float,
		p_mat, p_relief_strength: float, p_passes: int, p_smooth_first: bool) -> void:
	p_mound.modifiers = _stack_of(p_noise, p_noise_strength, p_mat, p_relief_strength, p_passes,
			p_smooth_first)


## `Noise -> Relief -> Smooth`, or `Noise -> Smooth -> Relief` when `p_smooth_first`. A null material
## drops the Relief step entirely rather than leaving an inactive one in, so the "no relief" case really
## is a two-step stack.
func _stack_of(p_noise: FastNoiseLite, p_noise_strength: float, p_mat, p_relief_strength: float,
		p_passes: int, p_smooth_first: bool) -> Array[Pasture3DBrushModifier]:
	var mn := Pasture3DModNoise.new()
	mn.noise = p_noise
	mn.strength = p_noise_strength
	var ms := Pasture3DModSmooth.new()
	ms.passes = p_passes
	var out: Array[Pasture3DBrushModifier] = [mn]
	if p_mat == null:
		out.append(ms)
		return out
	var mr := Pasture3DModRelief.new()
	mr.material = p_mat
	mr.strength = p_relief_strength
	if p_smooth_first:
		out.append(ms)
		out.append(mr)
	else:
		out.append(mr)
		out.append(ms)
	return out


func _make_mound(p_name: String, p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	return mound


## Probe points on the terrain's own vertex lattice, inset one stride so every probe is strictly inside
## the loop and none of them straddles the rim (where a half-cell of SDF rounding is a real difference
## between two bakes, not a bug in either).
func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF - _vs * 2.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	return _snapshot(p_probes)


# ---- measurement -----------------------------------------------------------------------------------


## Index of the first probe where two bakes differ AT ALL, or -1 when every probe is bit-identical.
## Exact `!=` on purpose: this is the one comparison in the suite that is not a tolerance.
func _first_difference(p_a: Array[float], p_b: Array[float]) -> int:
	for i in range(mini(p_a.size(), p_b.size())):
		var same := p_a[i] == p_b[i] or (not is_finite(p_a[i]) and not is_finite(p_b[i]))
		if not same:
			return i
	return -1


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


## Peak-to-trough of a bake over the probes — how much shape there is to compare at all.
func _span(p_vals: Array[float]) -> float:
	var lo := INF
	var hi := -INF
	for v in p_vals:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return hi - lo if hi > -INF else 0.0


func _all_finite(p_vals: Array[float]) -> bool:
	for v in p_vals:
		if not is_finite(v):
			return false
	return true


func _relief_presets() -> Array:
	var out: Array = []
	var d := DirAccess.open(RELIEF_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".tres"):
			out.append(RELIEF_DIR + "/" + f)
	out.sort()
	return out


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))
