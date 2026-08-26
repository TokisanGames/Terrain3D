# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates CT, CU and CV — THE INSPECTOR MUST NOT REBUILD ITSELF UNDER THE CURSOR.
#
# A Godot node can publish properties from `_get_property_list()`, and `notify_property_list_changed()`
# is how it tells the editor to re-read them. That call TEARS DOWN AND REBUILDS the whole inspector for
# the node, which collapses every expanded sub-resource and destroys any text field being typed into.
# So the rule this suite exists to enforce is:
#
#   A PROPERTY LIST MAY DEPEND ON STRUCTURE. IT MAY NEVER DEPEND ON A VALUE OR ON A NAME.
#
# Structure — which resources are assigned, what class they are, how many layers a stack has — changes
# discretely, on one edit, and a rebuild there is what the artist asked for. A value and a name change
# CONTINUOUSLY: a slider sweeps through every number between where it was and where it is going, and a
# name arrives one keystroke at a time. Rebuilding on those is how `Pasture3DMound`'s modifier folded
# shut mid-drag, and how a modifier ended up named "Cr" because the rename field closed after two
# characters.
#
# WHY THIS SUITE BREAKS THE HOUSE RULE, AND WHAT IT DOES INSTEAD. Every other gate here measures a HEIGHT
# DELTA at probe points, never a configuration flag, precisely so that a passing gate cannot be a gate
# that measured nothing. This one cannot: the defect IS a property list, and a property list is what has
# to be read. The compensation is that every criterion is paired with a CONTROL that changes the same
# observable through a structural edit, so "it never moves" and "it moves only when it should" are told
# apart — plus CT's last criterion, which IS a height delta, because decoupling the Mask Preview dropdown
# from `is_active()` is a change that could plausibly have leaked into the bake.
#
# NOTHING IS SAVED. The one bake writes into the terrain's in-memory layer.
#
# CV covers the one other place in the plugin with the same shape. It lives here rather than with the
# water suites because those need a real rendering device for their GPU-parity arms and cannot be run
# headless at all, so this is the only coverage that shape gets.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/InspectorStabilityGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## One site, probed finite before use. Only CT's last criterion bakes at all.
const SITE := Vector3(180.0, 0.0, 120.0)
const HALF := 50.0
const PROBE_STRIDE := 2

var _fail := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== Inspector stability (gates CT, CU, CV) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	_gate_ct_values_do_not_rebuild()
	_gate_cu_names_do_not_rebuild()
	await _gate_cv_water_profile_hint()

	print("\n=== %s (%d failures) ===\n"
		% ["INSPECTOR STABILITY PASS" if _fail == 0 else "INSPECTOR STABILITY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- CT: the property list is not a function of a value ---------------------------------------------
#
# The reported symptom was that setting Strength ON THE MODIFIER collapsed it, while setting Strength on
# the material or the selector nested inside it did not — even though both arrive at the host through the
# same `changed` signal and the same handler. The asymmetry was the clue: the two nested resources have
# no bearing on the host's property list, and the modifier's Strength had one. `Pasture3DMound`'s
# `_preview_relief_material()` returned the first ACTIVE Relief modifier, `is_active()` is false at
# `strength == 0`, and so the Mask Preview group APPEARED as the slider crossed zero. Measured before the
# fix: the list at 0.0 held 5 entries and at 1.0 held 8.
#
# So the criterion sweeps a value across exactly the boundary that used to matter, and back.
func _gate_ct_values_do_not_rebuild() -> void:
	print("\n[CT] editing a value never rebuilds the inspector:")
	var mound = _make_mound("CT", SITE)
	if mound == null:
		return
	var layer := _fractal(5)
	var stack := Pasture3DReliefStack.new()
	stack.layers = [layer]
	var relief := Pasture3DNodeRelief.new()
	relief.label = "Crags"
	relief.material = stack
	relief.strength = 0.0
	var noise := Pasture3DNodeNoise.new()
	noise.noise = FastNoiseLite.new()
	var erosion := Pasture3DNodeErosion.new()
	# LIVE, though the shipped default is Frozen — the last criterion below bakes. A Frozen erosion
	# serves its cached SURFACE, which is the whole grid, so the Relief modifier above it is overwritten
	# by the solve from before its Strength was raised and the control reads 0.000 m for entirely the
	# right reason. Same trap as gates CA and CE.
	erosion.evaluation = Pasture3DNode.Evaluation.LIVE
	var mods: Array[Pasture3DNode] = [relief, noise, erosion]
	mound.modifiers = mods

	var rebuilds := _watch(mound)
	var base := _props(mound)
	var moved := PackedStringArray()
	# Across zero and back — the boundary `is_active()` used to put in the property list — then a value
	# that never goes near it, on each of the three modifier kinds.
	for step in [["Relief Strength 1.0", func(): relief.strength = 1.0],
			["Relief Strength 2.0", func(): relief.strength = 2.0],
			["Relief Strength back to 0", func(): relief.strength = 0.0],
			["Relief Strength 8.0", func(): relief.strength = 8.0],
			["Relief disabled", func(): relief.enabled = false],
			["Relief enabled", func(): relief.enabled = true],
			["material Strength", func(): stack.strength = 3.0],
			["Noise Strength", func(): noise.strength = 4.0],
			["Erosion Rate", func(): erosion.erosion_rate = 0.2],
			["Erosion Iterations", func(): erosion.iterations = 12]]:
		(step[1] as Callable).call()
		if _props(mound) != base:
			moved.append(String(step[0]))
	print("    10 value edits across 3 modifier kinds: %d inspector rebuilds%s"
		% [rebuilds[0], "" if moved.is_empty() else " (published list moved on %s)" % ", ".join(moved)])
	if rebuilds[0] > 0:
		_fail += 1
		print("    !! the inspector rebuilds — and so collapses whatever is expanded — while a slider is "
			+ "being dragged, which is the defect this gate exists for")

	# --- CONTROL 1: a STRUCTURAL edit must move the same observable ---
	var had := _props(mound)
	var mark: int = rebuilds[0]
	relief.material = null
	var on_clear: int = rebuilds[0] - mark
	var cleared := _props(mound)
	mark = rebuilds[0]
	relief.material = stack
	var on_assign: int = rebuilds[0] - mark
	var restored := _props(mound)
	print("    control: clearing the Relief Material rebuilt %d time(s) and moved the list (%s); "
		% [on_clear, cleared != had] + "reassigning rebuilt %d and moved it back (%s)"
		% [on_assign, restored == had])
	if on_clear == 0 or on_assign == 0 or cleared == had or restored != had:
		_fail += 1
		print("    !! the inspector does not respond to a structural change either, so '0 rebuilds' "
			+ "above is a dead measurement rather than a fix")

	# --- CONTROL 2: the dropdown's CONTENTS, not just its existence ---
	var one := _props(mound)
	mark = rebuilds[0]
	stack.layers = [layer, _fractal(9)]
	var two := _props(mound)
	print("    control: a second layer in the stack rebuilt %d time(s) and moved the list (%s)"
		% [rebuilds[0] - mark, two != one])
	if two == one or rebuilds[0] == mark:
		_fail += 1
		print("    !! adding a Mask Preview Source entry did not re-hint the dropdown, so the list is now "
			+ "too inert and the source picker will go stale")
	stack.layers = [layer]

	# --- CONTROL 3, AND A REAL RISK: the preview rule must not have leaked into the BAKE ---
	#
	# `_preview_relief_material()` no longer asks `is_active()`. `is_active()` is also what decides
	# whether the modifier's relief program is compiled at all, and if the two had been the same test the
	# fix could have started stamping a modifier the artist had turned off. Measured as a height delta,
	# bitwise: a zero-strength Relief modifier must bake exactly what NO Relief modifier bakes.
	var probes := _lattice(SITE)
	relief.strength = 0.0
	relief.enabled = true
	var with_inactive := _bake(mound, probes)
	var without: Array[Pasture3DNode] = [noise, erosion]
	mound.modifiers = without
	var absent := _bake(mound, probes)
	var at := _first_difference(with_inactive, absent)
	print("    control: a zero-strength Relief modifier bakes what no Relief modifier bakes: %s"
		% ["bitwise identical" if at < 0 else "DIFFERS at probe %d" % at])
	if at >= 0:
		_fail += 1
		print("    !! decoupling the preview from `is_active()` reached the bake — a modifier at 0 m is "
			+ "stamping")
	# ...and the probe must be able to see a Relief modifier at all, or "identical" is about nothing.
	relief.strength = 8.0
	var back: Array[Pasture3DNode] = [relief, noise, erosion]
	mound.modifiers = back
	var active := _bake(mound, probes)
	var reach := _max_abs_diff(absent, active)
	print("             (the same modifier at 8 m moves the same probes %.3f m)" % reach)
	if reach < 0.5:
		_fail += 1
		print("    !! this Relief modifier does not reach the probes even when active, so 'inactive "
			+ "changes nothing' is not evidence")


# --- CU: an inspector rebuild is not triggered by a NAME --------------------------------------------
#
# Renaming was fixed once already, for the modifier's own `label`: `Resource.set_name` emits `changed`
# like any setter, so the host's handler ran per keystroke and its `notify_property_list_changed()` shut
# the field. `_on_modifier_changed` now leaves early on a rename.
#
# THE SAME BUG SURVIVED ONE LEVEL DOWN. The Mask Preview Source dropdown labels a stack layer as
# "Layer 0 (Fractal)", falling back to the layer's `resource_name` when it has one — so naming a LAYER
# changed the labels, the labels were the rebuild trigger, and the field closed exactly as before.
#
# Measured on the TRIGGER rather than on the published list, deliberately. The published list still
# changes on a rename — the dropdown's text is derived from the name and there is no way for it not to
# be. What must not happen is that the change is ACTED ON while the artist is still typing.
func _gate_cu_names_do_not_rebuild() -> void:
	print("\n[CU] renaming never triggers a rebuild, at either level:")
	var mound = _make_mound("CU", SITE + Vector3(300.0, 0.0, 0.0))
	if mound == null:
		return
	var layer := _fractal(5)
	var stack := Pasture3DReliefStack.new()
	stack.layers = [layer]
	var relief := Pasture3DNodeRelief.new()
	relief.material = stack
	relief.strength = 8.0
	var mods: Array[Pasture3DNode] = [relief]
	mound.modifiers = mods

	# Typed one character at a time, which is how the bug arrived and the only way to catch a guard that
	# holds for a whole-string assignment but not for the growing prefix.
	var rebuilds := _watch(mound)
	for target in [["the modifier", func(s): relief.label = s],
			["a stack layer", func(s): layer.resource_name = s]]:
		var at: int = rebuilds[0]
		var typed := ""
		var broke := ""
		for ch in "Hardpan":
			typed += ch
			(target[1] as Callable).call(typed)
			if broke == "" and rebuilds[0] > at:
				broke = typed
		print("    naming %s '%s': %d rebuilds over %d keystrokes%s"
			% [target[0], typed, rebuilds[0] - at, typed.length(),
				"" if broke == "" else ", the first after '%s'" % broke])
		if rebuilds[0] > at:
			_fail += 1
			print("    !! the text field is torn down mid-word, which is what produced a modifier named "
				+ "'Cr'")

	# The renames must have LANDED, or the loop above measured a no-op. Both names have to be readable
	# where the editor reads them, and the layer's has to have reached the dropdown text — that label is
	# what used to move the trigger.
	var named := relief.display_name() == "Hardpan" and String(relief.resource_name) == "Hardpan"
	var labels := PackedStringArray()
	for e in mound._preview_selector_sources(stack):
		labels.append(String(e[0]))
	var in_label := String(labels[1] if labels.size() > 1 else "").contains("Hardpan")
	print("    control: the names landed — modifier reads '%s', the dropdown reads '%s'"
		% [relief.display_name(), labels[1] if labels.size() > 1 else "<none>"])
	if not named or not in_label:
		_fail += 1
		print("    !! a rename did not take effect, so 'renaming triggers nothing' is trivially true and "
			+ "says nothing about the guard")

	# --- CONTROL: a STRUCTURAL edit to the same entries must move the trigger ---
	var at2: int = rebuilds[0]
	stack.layers = [Pasture3DReliefTerraces.new()]
	var on_class: int = rebuilds[0] - at2
	stack.layers = [layer]
	at2 = rebuilds[0]
	layer.selector = Pasture3DTerrainMask.new()
	var on_selector: int = rebuilds[0] - at2
	print("    control: swapping the layer's CLASS rebuilt %d time(s); giving it a Selector rebuilt %d"
		% [on_class, on_selector])
	if on_class == 0 or on_selector == 0:
		_fail += 1
		print("    !! the host does not rebuild for structure either, so the dropdown will keep showing "
			+ "entries that no longer describe the stack")



# --- CV: the same rule, in the one other place the plugin breaks it ----------------------------------
#
# `Pasture3DWaterBody.wave_profile` is re-hinted into a dropdown of the manager's live profile names, so
# it has to be rebuilt when a profile is added or renamed. It was being rebuilt on `profiles_changed` —
# which the manager also emits for every knob on every profile. Dragging a wave amplitude on the manager
# therefore rebuilt the inspector of every water body in the scene, folding up whatever a selected one
# had expanded. Exactly CT's defect, in a different file.
#
# MEASURED THROUGH THE LATCH, not through the notify: `_profile_names_moved()` writes its cache on
# precisely the branch that re-hints, so a cache that did not move is a re-hint that did not happen.
func _gate_cv_water_profile_hint() -> void:
	print("
[CV] a water body re-hints its profile dropdown only when the NAME list moves:")
	var mgr = ClassDB.instantiate("Pasture3DPoolManager")
	_root.add_child(mgr)
	var calm = ClassDB.instantiate("Pasture3DWaveProfile")
	calm.profile_name = &"lake_calm"
	var fast = ClassDB.instantiate("Pasture3DWaveProfile")
	fast.profile_name = &"river_fast"
	mgr.profiles = [calm, fast]
	var pool := Pasture3DPool.new()
	pool.name = "CV"
	_root.add_child(pool)
	# The body finds its manager from _physics_process, not from _ready — one frame is what it takes.
	await get_tree().process_frame
	await get_tree().physics_frame

	# TWO counters. `heard` is what the manager broadcast, `rebuilds` is what the body did about it —
	# and it is the difference between them that this gate is about. Without the first, "it did not
	# rebuild" cannot be told from "it was never asked".
	var heard := [0]
	mgr.profiles_changed.connect(func(): heard[0] += 1)
	var rebuilds := _watch(pool)

	var at_heard: int = heard[0]
	var at_rebuilt: int = rebuilds[0]
	for amp in [1.5, 2.5, 3.5]:
		calm.amplitude = amp
	print("    3 amplitude edits reached it as %d emissions and caused %d rebuilds"
		% [heard[0] - at_heard, rebuilds[0] - at_rebuilt])
	if heard[0] == at_heard:
		_fail += 1
		print("    !! the manager never emitted, so the body was never asked and '0 rebuilds' is a dead "
			+ "measurement")
	elif rebuilds[0] > at_rebuilt:
		_fail += 1
		print("    !! every water body in the scene rebuilds its inspector while a wave slider is dragged")

	# --- CONTROL: the two edits that MUST re-hint, or the dropdown goes stale ---
	at_rebuilt = rebuilds[0]
	fast.profile_name = &"river_slow"
	mgr.profiles = [calm, fast]
	var on_rename: int = rebuilds[0] - at_rebuilt
	at_rebuilt = rebuilds[0]
	var sea = ClassDB.instantiate("Pasture3DWaveProfile")
	sea.profile_name = &"sea"
	mgr.profiles = [calm, fast, sea]
	var on_add: int = rebuilds[0] - at_rebuilt
	print("    control: renaming a profile rebuilt %d time(s); adding one rebuilt %d"
		% [on_rename, on_add])
	if on_rename == 0 or on_add == 0:
		_fail += 1
		print("    !! the guard is too tight — the dropdown will keep offering names that no longer exist")

	var hint := ""
	for d in pool.get_property_list():
		if d.name == "wave_profile":
			hint = String(d.hint_string)
	print("    control: the dropdown itself still lists every live profile: '%s'" % hint)
	if hint != "lake_calm,river_slow,sea":
		_fail += 1
		print("    !! the hint is not what the manager holds, so the re-hint path is broken outright")


# ---- fixtures --------------------------------------------------------------------------------------


func _fractal(p_seed: int) -> Pasture3DReliefFractal:
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 22.0
	mat.seed = p_seed
	return mat


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
	mound.height = 55.0
	# ADD, not the MAX default: at this site the demo terrain is already tall, and MAX would clamp away
	# exactly the contribution CT's last control needs to see.
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
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


# ---- measurement -----------------------------------------------------------------------------------


## THE OBSERVABLE. `Object.notify_property_list_changed()` emits `property_list_changed`, and that call
## IS the inspector rebuild — so counting the signal counts the rebuilds, rather than counting something
## that correlates with them. An earlier draft compared the published property list before and after
## each edit, and it was too weak in exactly the way that matters: a host that computed the right answer
## and then rebuilt anyway would have passed it.
##
## Returns a one-element Array used as a mutable counter (an int captured by a lambda would not be).
func _watch(p_object: Object) -> Array:
	var hits := [0]
	p_object.property_list_changed.connect(func(): hits[0] += 1)
	return hits


## Everything the node publishes from `_get_property_list()`, canonicalised — what a rebuild would even
## be FOR. Reported alongside the rebuild count as supporting evidence, never as the criterion.
func _props(p_brush) -> String:
	var parts := PackedStringArray()
	for d in p_brush._get_property_list():
		parts.append("%s|%d|%d|%s|%d" % [d.get("name", ""), int(d.get("type", 0)),
			int(d.get("hint", 0)), d.get("hint_string", ""), int(d.get("usage", 0))])
	return "\n".join(parts)


func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF - _vs * 3.0
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
	var out: Array[float] = []
	for p in p_probes:
		out.append(_height(p))
	return out


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


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))
