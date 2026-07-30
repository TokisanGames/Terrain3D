# Pasture3D Water Bodies — Phase 4 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 4 is the button: Pasture3DTerrainBrush gains "Add Water", which fills the loop the brush
# already drew with a Pasture3DPool bound to that brush's Path3D. It is the phase the whole feature
# was asked for — everything before it was machinery for this one press.
#
# Gate criteria, from the spec's phase table ("button on each of Mound/Plow/Splat/Ridge/Trough
# produces a correctly bound pool; additive warning fires on raise-configured brushes and stays
# silent on carve-configured ones"):
#
#   A. one press on each of the five brush types produces a correctly bound pool — sibling
#      placement, source_spline identity, seeded level, real geometry — and the binding is LIVE:
#      moving the brush moves the water. Control: a brush whose curve is OPEN produces no pool,
#      so "a pool appeared" is not merely "this button always makes a node"
#   B. idempotency: pressing twice on a three-spline brush gives three pools, not six.
#      Control: adding a fourth spline and pressing again gives exactly one more
#   C. the raise check over the whole §7.8 matrix, both signs. Control: the carve rows, which
#      must come back false — if every row were true the check would be vacuous
#   D. a raise-configured brush DEFERS to a confirmation dialog instead of creating anything, and
#      "Add Anyway" completes the creation with a permanent warning naming the brush and its
#      blend mode. Control: a carve-configured brush creates immediately and puts up no dialog
#   E. the undo action's do/undo pair: apply -> revert -> redo restores the SAME pool instances
#      and leaves the manager's body registry where it started. Control: the same absence
#      assertions run BEFORE the revert, where they must all report present
#   F. the manager is ensured, not assumed: a press into a manager-less scene creates one carrying
#      the four shipped profiles, and a second press does not create a second manager. The
#      profiles' generated tables are compared against the shipped .tres materials byte for byte,
#      so the defaults cannot be numbers someone invented
#
# No timing criteria — this phase adds no per-frame or per-build cost worth measuring, and the
# machine is shared with another engine (see the session's standing instruction).
#
# Every criterion carries a control that must fail; criteria that ran to completion are counted,
# so a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase4Gate.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const POND_MAT := WATER_DIR + "M_water_pond.tres"

## Blend mode ints, matching Pasture3DTerrainBrush's constants and every subclass's BlendMode enum.
const B_REPLACE := 0
const B_ADD := 1
const B_MAX := 2
const B_MIN := 3

var _fail := 0
var _completed := 0
const CRITERIA := 7


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 600.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	Engine.physics_ticks_per_second = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	print("=== Pasture3D Water Bodies — Phase 4 gate ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _gate_a_button_binds()
	await _gate_b_idempotent()
	await _gate_c_raise_matrix()
	await _gate_d_dialog()
	await _gate_e_undo_pair()
	await _gate_f_manager()
	await _gate_g_transform()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	print("=== PHASE 4 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: one press per brush type, and the binding is live ----------------------
#
# The spec's own wording for this phase. Five brush types, five presses, and each resulting pool
# checked against what §7.8 says the press does: sibling of the brush, source_spline pointing at
# the brush's own Path3D (not a copy of its curve), level seeded from the loop, and a mesh with
# actual geometry in it.
#
# Then the part a creation-time check would miss entirely: MOVING the brush. The pool reads its
# polygon through source_spline.global_transform, and a pool that binds correctly at creation and
# then sits still while its basin walks away is not bound in any useful sense.
func _gate_a_button_binds() -> void:
	print("[A] one press per brush type produces a correctly bound pool:")
	for kind in ["Pasture3DMound", "Pasture3DPlow", "Pasture3DSplat", "Pasture3DRidge",
			"Pasture3DTrough"]:
		var root := _make_world()
		_make_manager(root)
		var brush := _make_brush(kind, root, [[30.0, true]])
		# Configure each brush to CARVE. A Mound, Plow and Ridge all default to raising, so an
		# unconfigured one correctly defers to the dialog — that is criterion D's subject, not
		# this one's, and a basin is what someone adding a lake has actually drawn.
		_make_carve(brush)
		await _settle()

		var pools: Array = brush.add_pool()
		await _settle()
		if pools.size() != 1:
			_fail += 1
			print("    !! %s: %d pools created, expected 1" % [kind, pools.size()])
			root.queue_free()
			await _settle()
			continue
		var pool = pools[0]
		var spline: Path3D = brush.get_children().filter(func(c): return c is Path3D)[0]
		var problems := PackedStringArray()
		if pool.get_parent() != brush.get_parent():
			problems.append("not a sibling of the brush")
		if pool.source_spline != spline:
			problems.append("source_spline is not the brush's Path3D")
		if String(pool.name) != "%sWater" % brush.name:
			problems.append("named '%s'" % pool.name)
		var stats: Dictionary = pool.get_build_stats()
		if not stats.get("ok", false) or int(stats.get("vertices", 0)) < 100:
			problems.append("mesh has %d vertices (%s)" % [
				int(stats.get("vertices", 0)), stats.get("reason", "")])
		# Level: the loop sits at y = 0 in brush space, and fill_offset is -0.5 by default.
		var want_y: float = spline.global_position.y + pool.fill_offset
		if absf(pool.global_position.y - want_y) > 1e-3:
			problems.append("level %.3f, expected %.3f" % [pool.global_position.y, want_y])

		# The live binding. Move the brush 200 m and the water must follow: inside before at the
		# old centre and not after, inside after at the new centre and not before.
		#
		# Probe 5 m DOWN, not at the surface: contains_point is a wave-surface test, so a point at
		# exactly the still level is inside or outside depending on where the crest is that frame,
		# and this criterion is about the polygon, not the clock.
		var probe_y: float = pool.global_position.y - 5.0
		var old_centre := Vector3(0, probe_y, 0)
		var here_before: bool = pool.contains_point(old_centre)
		brush.position += Vector3(200, 0, 0)
		await _settle()
		await _settle()
		var new_centre := Vector3(200, probe_y, 0)
		var here_after: bool = pool.contains_point(old_centre)
		var there_after: bool = pool.contains_point(new_centre)
		if not here_before:
			problems.append("the point at the loop's centre was not inside it to begin with")
		elif here_after or not there_after:
			problems.append("the water did not follow the brush (old %s, new %s)" % [
				here_after, there_after])

		if problems.is_empty():
			print("    %-18s ok — %s, %d verts, level %.2f, follows the brush" % [
				kind, pool.name, int(stats.get("vertices", 0)), pool.global_position.y])
		else:
			_fail += 1
			print("    !! %s: %s" % [kind, "; ".join(problems)])
		root.queue_free()
		await _settle()

	# Control: an OPEN curve is a river, and ribbon water is Phase 7. If this also produced a pool
	# then everything above is measuring "the button always makes a node".
	var croot := _make_world()
	_make_manager(croot)
	var open_brush := _make_brush("Pasture3DRidge", croot, [[30.0, false]])
	_make_carve(open_brush)
	await _settle()
	var open_pools: Array = open_brush.add_pool()
	await _settle()
	if open_pools.is_empty():
		print("    control (open curve -> no pool): fires")
	else:
		_fail += 1
		print("    !! control did NOT fire: an open spline produced %d pool(s)" % open_pools.size())
	croot.queue_free()
	await _settle()
	_completed += 1


# ---- B: idempotency ------------------------------------------------------------
#
# §7.8 step 1. The button is a button, so it will be pressed twice — by someone checking whether
# it worked, or by someone who reopened the scene. Six pools stacked on three splines is not a
# visible failure, it is a doubled draw call and a z-fight.
func _gate_b_idempotent() -> void:
	print("[B] pressing twice on a three-spline brush gives three pools, not six:")
	var root := _make_world()
	_make_manager(root)
	var brush := _make_brush("Pasture3DMound", root,
		[[20.0, true], [20.0, true], [20.0, true]])
	_make_carve(brush)
	# Splines share a parent, so spread them out or the loops overlap.
	var splines: Array = brush.get_children().filter(func(c): return c is Path3D)
	splines[1].position = Vector3(120, 0, 0)
	splines[2].position = Vector3(240, 0, 0)
	await _settle()

	var first: Array = brush.add_pool()
	await _settle()
	var second: Array = brush.add_pool()
	await _settle()
	var total := _count_pools(root)
	if first.size() == 3 and second.is_empty() and total == 3:
		print("    first press 3, second press 0, %d pools in the scene" % total)
	else:
		_fail += 1
		print("    !! first %d, second %d, %d in the scene" % [
			first.size(), second.size(), total])

	# Control: the guard has to be per-spline, not "never create anything again". A fourth spline
	# must get water on the next press, and exactly one pool's worth.
	var extra := _add_spline(brush, 20.0, true)
	extra.position = Vector3(360, 0, 0)
	await _settle()
	var third: Array = brush.add_pool()
	await _settle()
	if third.size() == 1 and _count_pools(root) == 4:
		print("    control (a new spline still gets water): fires — 1 more pool, 4 total")
	else:
		_fail += 1
		print("    !! control did NOT fire: %d new pool(s), %d total" % [
			third.size(), _count_pools(root)])
	root.queue_free()
	await _settle()
	_completed += 1


# ---- C: the raise matrix -------------------------------------------------------
#
# Spec §7.8's table, both signs. The check has to be on the brush's EFFECTIVE sign rather than its
# class: Pasture3DRidge is the raise tool but a MIN-blended one carves, Pasture3DTrough is the carve
# tool but a MAX-blended one raises, and Pasture3DPlow keeps its inversion on its material rather
# than on itself. A per-class list would be wrong for every one of those rows.
func _gate_c_raise_matrix() -> void:
	print("[C] the raise check over the §7.8 matrix:")
	var root := _make_world()
	# [class, {property: value, ...}, expected]
	var rows := [
		["Pasture3DMound", {"blend_mode": B_MAX, "invert": false}, true],
		["Pasture3DMound", {"blend_mode": B_ADD, "invert": false}, true],
		["Pasture3DMound", {"blend_mode": B_MAX, "invert": true}, false],
		["Pasture3DMound", {"blend_mode": B_MIN, "invert": false}, false],
		["Pasture3DMound", {"blend_mode": B_REPLACE, "invert": false}, false],
		["Pasture3DRidge", {"blend_mode": B_MAX, "invert": false}, true],
		["Pasture3DRidge", {"blend_mode": B_MIN, "invert": false}, false],
		["Pasture3DRidge", {"blend_mode": B_MAX, "invert": true}, false],
		["Pasture3DTrough", {"blend_mode": B_MIN}, false],
		["Pasture3DTrough", {"blend_mode": B_MAX}, true],
		["Pasture3DPlow", {"blend_mode": B_ADD}, true],
		["Pasture3DPlow", {"blend_mode": B_MIN}, false],
		["Pasture3DSplat", {}, false],
	]
	var bad := 0
	var trues := 0
	var falses := 0
	for r in rows:
		var brush := _make_brush(r[0], root, [])
		for k in r[1]:
			brush.set(k, r[1][k])
		var got: bool = brush.brush_raises()
		if got != r[2]:
			bad += 1
			print("    !! %s %s -> %s, expected %s" % [r[0], r[1], got, r[2]])
		if r[2]:
			trues += 1
		else:
			falses += 1
		brush.queue_free()

	# Pasture3DPlow's inversion lives on its material and only in MATERIAL mode — the one row a
	# generic get("invert") gets wrong, and the reason _raise_inverted() is overridable.
	var plow := _make_brush("Pasture3DPlow", root, [])
	plow.blend_mode = B_ADD
	plow.source = 2 # Source.MATERIAL
	var pm := Pasture3DPlowMaterial.new()
	pm.invert = true
	plow.plow_material = pm
	var plow_inverted: bool = plow.brush_raises()
	pm.invert = false
	var plow_upright: bool = plow.brush_raises()
	plow.queue_free()
	if plow_inverted or not plow_upright:
		bad += 1
		print("    !! Plow material invert: inverted -> %s (want false), upright -> %s (want true)"
			% [plow_inverted, plow_upright])

	if bad == 0:
		print("    %d rows, all as specified (%d raise, %d carve) + the Plow material rows" % [
			rows.size(), trues, falses])
	else:
		_fail += 1
	# The control is the carve half of the matrix: a check hardwired to true would pass every
	# raising row and is only caught by rows that must come back false.
	if falses >= 5 and trues >= 4:
		print("    control (rows that must be false): %d of them, all silent" % falses)
	else:
		_fail += 1
		print("    !! the matrix is one-sided (%d true, %d false), so it proves little" % [
			trues, falses])
	root.queue_free()
	await _settle()
	_completed += 1


# ---- D: the confirmation dialog ------------------------------------------------
#
# §7.8: water on a raised landform is hidden inside it, but a raised pool on a plateau is a real
# thing to author. So the press ASKS rather than refuses — and the resulting pool keeps a permanent
# configuration warning, because the case a creation-time dialog misses is the blend mode being
# changed a week later, and that is the more likely one.
func _gate_d_dialog() -> void:
	print("[D] a raising brush defers to a dialog; 'Add Anyway' completes:")
	var root := _make_world()
	_make_manager(root)
	var brush := _make_brush("Pasture3DMound", root, [[30.0, true]])
	brush.blend_mode = B_MAX
	brush.invert = false
	await _clear_dialogs()

	var returned: Array = brush.add_pool()
	await _settle()
	var dlg := _find_dialog()
	if not returned.is_empty():
		_fail += 1
		print("    !! the press created %d pool(s) without asking" % returned.size())
	elif dlg == null:
		_fail += 1
		print("    !! nothing was created AND no dialog appeared — the press did nothing")
	elif _count_pools(root) != 0:
		_fail += 1
		print("    !! a pool exists while the dialog is still up")
	else:
		print("    deferred: 0 pools, dialog '%s' on screen" % dlg.title)

	if dlg != null:
		dlg.emit_signal("confirmed")
		await _settle()
		var pools := _find_pools(root)
		if pools.size() != 1:
			_fail += 1
			print("    !! 'Add Anyway' produced %d pools" % pools.size())
		else:
			var warns: PackedStringArray = pools[0]._get_configuration_warnings()
			var named := false
			for w in warns:
				if w.contains(String(brush.name)) and w.contains("MAX"):
					named = true
			if named:
				print("    'Add Anyway' created 1 pool carrying a permanent warning naming the")
				print("      brush and its blend mode")
			else:
				_fail += 1
				print("    !! the pool carries no warning naming the brush: %s" % warns)
		dlg.hide()
	root.queue_free()
	await _clear_dialogs()

	# Control: a carve-configured brush must not put a dialog up at all. Without this, "a dialog
	# appeared" could just mean the button always shows one.
	var croot := _make_world()
	_make_manager(croot)
	var carver := _make_brush("Pasture3DMound", croot, [[30.0, true]])
	carver.blend_mode = B_MIN
	await _settle()
	var direct: Array = carver.add_pool()
	await _settle()
	if direct.size() == 1 and _find_dialog() == null:
		print("    control (carve brush -> no dialog): fires — created immediately")
	else:
		_fail += 1
		print("    !! control did NOT fire: %d pools, dialog %s" % [
			direct.size(), _find_dialog()])
	croot.queue_free()
	await _settle()
	_completed += 1


# ---- E: the undo pair ----------------------------------------------------------
#
# EditorUndoRedoManager does not exist in a headless run, so the ACTION cannot be exercised here.
# What can be — and what is where the bugs live — is the do/undo pair it is built from. The button
# registers exactly one _apply_add_water / _revert_add_water pair, so driving that pair directly
# tests the same code Ctrl+Z runs, including the ordering that matters: the manager enters before
# the pools and leaves after them, or a pool registers with nothing / unregisters from nothing.
func _gate_e_undo_pair() -> void:
	print("[E] apply / revert / redo restores the same instances:")
	var root := _make_world()
	var manager := _make_manager(root)
	var brush := _make_brush("Pasture3DMound", root, [[30.0, true]])
	_make_carve(brush)
	await _settle()
	var bodies_before: int = manager.get_bodies().size()

	var pools: Array = brush.add_pool()
	await _settle()
	if pools.size() != 1:
		_fail += 1
		print("    !! setup produced %d pools" % pools.size())
		root.queue_free()
		await _settle()
		_completed += 1
		return
	var pool = pools[0]
	var id: int = pool.get_instance_id()
	var bodies_applied: int = manager.get_bodies().size()

	# Control, run BEFORE the revert: the same assertions the revert is checked with, against a
	# scene where nothing has been undone. They must all report the opposite.
	var control_ok := _count_pools(root) == 1 and pool.get_parent() != null \
		and bodies_applied == bodies_before + 1
	if control_ok:
		print("    control (pre-revert state): fires — 1 pool in the tree, %d bodies (was %d)" % [
			bodies_applied, bodies_before])
	else:
		_fail += 1
		print("    !! control did NOT fire: %d pools, parent %s, %d bodies (was %d)" % [
			_count_pools(root), pool.get_parent(), bodies_applied, bodies_before])

	brush._revert_add_water(pools, brush.get_parent(), null)
	await _settle()
	var reverted_ok := _count_pools(root) == 0 and pool.get_parent() == null \
		and manager.get_bodies().size() == bodies_before
	if reverted_ok:
		print("    revert: 0 pools in the tree, registry back to %d, node still alive" % bodies_before)
	else:
		_fail += 1
		print("    !! revert left %d pools, parent %s, %d bodies" % [
			_count_pools(root), pool.get_parent(), manager.get_bodies().size()])

	brush._apply_add_water(pools, brush.get_parent(), root, null)
	await _settle()
	var redone := _find_pools(root)
	if redone.size() == 1 and redone[0].get_instance_id() == id \
			and manager.get_bodies().size() == bodies_applied:
		print("    redo: the SAME pool instance is back and re-registered")
	else:
		_fail += 1
		print("    !! redo produced %d pools, same instance %s, %d bodies" % [
			redone.size(), redone.size() == 1 and redone[0].get_instance_id() == id,
			manager.get_bodies().size()])
	root.queue_free()
	await _settle()
	_completed += 1


# ---- F: the manager is ensured, and its defaults are not invented --------------
#
# §7.8 step 7. Water with no manager has no clock and no wave table, so the button has to be able
# to produce a working pool in a scene that has never heard of water. And the profiles it arrives
# with have to be the same water the shipped preset materials draw, or "lake_calm" and
# M_water_lake.tres are two different lakes with one name.
func _gate_f_manager() -> void:
	print("[F] the manager is ensured, and its shipped profiles are the shipped materials:")
	var root := _make_world() # deliberately NO manager
	var big := _make_brush("Pasture3DMound", root, [[30.0, true]])   # 60 m span -> lake
	var small := _make_brush("Pasture3DMound", root, [[8.0, true]])  # 16 m span -> pond
	_make_carve(big)
	_make_carve(small)
	small.position = Vector3(300, 0, 0)
	await _settle()
	if _find_managers().size() != 0:
		_fail += 1
		print("    !! the scene already has a manager, so 'created one' proves nothing")

	var lake_pools: Array = big.add_pool()
	await _settle()
	var managers := _find_managers()
	if managers.size() != 1:
		_fail += 1
		print("    !! %d managers after the first press, expected 1" % managers.size())
		root.queue_free()
		await _settle()
		_completed += 1
		return
	var manager = managers[0]
	if manager.get_parent() != get_tree().current_scene:
		_fail += 1
		print("    !! the manager was parented to %s, not the scene root" % manager.get_parent())
	print("    a press into a manager-less scene created 1 manager with %d profiles: %s" % [
		manager.get_profile_names().size(), ", ".join(manager.get_profile_names())])

	var want_names := ["ocean_default", "lake_calm", "pond_still", "river_flow"]
	for n in want_names:
		if not manager.has_profile(n):
			_fail += 1
			print("    !! the shipped manager has no '%s' profile (§5.2)" % n)

	# Profile seeded from the loop's size, not from a fixed default.
	var pond_pools: Array = small.add_pool()
	await _settle()
	if lake_pools.size() == 1 and pond_pools.size() == 1:
		var lake_profile: StringName = lake_pools[0].wave_profile
		var pond_profile: StringName = pond_pools[0].wave_profile
		if lake_profile == &"lake_calm" and pond_profile == &"pond_still":
			print("    a 60 m loop seeded '%s', a 16 m loop seeded '%s'" % [
				lake_profile, pond_profile])
		else:
			_fail += 1
			print("    !! 60 m loop -> '%s', 16 m loop -> '%s'" % [lake_profile, pond_profile])
	else:
		_fail += 1
		print("    !! %d lake pools, %d pond pools" % [lake_pools.size(), pond_pools.size()])

	# Control: the second press must NOT create a second manager.
	if _find_managers().size() == 1:
		print("    control (second press reuses the manager): fires — still 1")
	else:
		_fail += 1
		print("    !! control did NOT fire: %d managers" % _find_managers().size())

	# The defaults are the shipped materials. Generated table vs the .tres on disk, exactly.
	for pair in [["lake_calm", LAKE_MAT], ["pond_still", POND_MAT]]:
		var profile = manager.get_profile(pair[0])
		var mat: ShaderMaterial = load(pair[1])
		var shipped: PackedVector4Array = mat.get_shader_parameter("_waves")
		var generated: PackedVector4Array = profile.get_shader_table()
		var worst := 0.0
		var n: int = mini(shipped.size(), generated.size())
		for i in n:
			var d: Vector4 = shipped[i] - generated[i]
			worst = maxf(worst, maxf(maxf(absf(d.x), absf(d.y)), maxf(absf(d.z), absf(d.w))))
		# The .tres stores 5 decimals, so anything at that scale is the file format and not a
		# different sea state.
		if n == 0 or shipped.size() != generated.size() or worst > 1e-5:
			_fail += 1
			print("    !! '%s' does not match %s: %d vs %d entries, worst delta %.8f" % [
				pair[0], pair[1].get_file(), shipped.size(), generated.size(), worst])
		else:
			print("    '%s' == %s across %d waves (worst delta %.8f)" % [
				pair[0], pair[1].get_file(), n, worst])
		# Control for that comparison: the OTHER profile must not match, or the test would pass
		# on any two tables of the same length.
		var other = manager.get_profile("pond_still" if pair[0] == "lake_calm" else "lake_calm")
		var other_table: PackedVector4Array = other.get_shader_table()
		var other_worst := 0.0
		for i in mini(shipped.size(), other_table.size()):
			var d: Vector4 = shipped[i] - other_table[i]
			other_worst = maxf(other_worst, maxf(maxf(absf(d.x), absf(d.y)),
				maxf(absf(d.z), absf(d.w))))
		if other_worst <= 1e-5:
			_fail += 1
			print("    !! the wrong profile ALSO matches %s — the comparison is vacuous"
				% pair[1].get_file())
	root.queue_free()
	manager.queue_free() # created at the scene root, so it does not go with the fixture
	await _settle()
	_completed += 1


# ---- G: the pool's own transform -----------------------------------------------
#
# A created pool used to be left at the world origin with only its Y seeded, which drew correctly —
# the polygon is read in world space and expressed relative to the node — but left a transform that
# said nothing about which brush the water belonged to, a selection handle nowhere near the water,
# and a `_water_domain_origin` of (0,0,0). That last one matters: the instance uniform exists so
# wave phase stays precise far from the world origin, and a pool pinned at the origin switches it
# off exactly where it is needed.
#
# The other half of the claim is that an XZ move of the POOL must not move the water, because the
# spline decides where the water is. That needs a rebuild to compensate, and the control is the
# bare-`curve` mode, where the points ARE in the node's space and moving it genuinely should move
# the water.
func _gate_g_transform() -> void:
	print("[G] the pool's transform is its brush's, and moving it does not move the water:")
	var root := _make_world()
	_make_manager(root)
	var brush := _make_brush("Pasture3DMound", root, [[30.0, true]])
	_make_carve(brush)
	# Deliberately far from the world origin, or "the pool sits on its spline" is satisfied by
	# everything being at zero and the criterion measures nothing.
	brush.position = Vector3(1200, 0, -800)
	await _settle()

	var pools: Array = brush.add_pool()
	await _settle()
	if pools.size() != 1:
		_fail += 1
		print("    !! setup produced %d pools" % pools.size())
		root.queue_free()
		await _settle()
		_completed += 1
		return
	var pool = pools[0]
	var spline: Path3D = brush.get_children().filter(func(c): return c is Path3D)[0]
	var origin_err := Vector2(pool.global_position.x - spline.global_position.x,
		pool.global_position.z - spline.global_position.z).length()
	var from_world_origin := Vector2(pool.global_position.x, pool.global_position.z).length()
	if origin_err > 1e-3:
		_fail += 1
		print("    !! the pool sits %.3f m from its spline's origin in XZ" % origin_err)
	elif from_world_origin < 100.0:
		_fail += 1
		print("    !! the fixture is too close to the world origin (%.1f m) to prove anything"
			% from_world_origin)
	else:
		print("    pool origin (%.1f, %.1f) == spline origin, %.0f m from the world origin" % [
			pool.global_position.x, pool.global_position.z, from_world_origin])

	# The payoff: the domain origin follows the node, so the wave field is evaluated near zero
	# rather than out at kilometre-scale coordinates.
	var surface: MeshInstance3D = null
	for c in pool.get_children():
		if c is MeshInstance3D:
			surface = c
	var domain = surface.get_instance_shader_parameter("_water_domain_origin") if surface else null
	if domain != null and (domain as Vector3).distance_to(pool.global_position) < 1e-3:
		print("    _water_domain_origin tracks the node: %s" % [domain])
	else:
		_fail += 1
		print("    !! _water_domain_origin is %s, node is %s" % [domain, pool.global_position])

	# Moving the POOL in XZ must not move the water: the spline decides where it is.
	var probe_y: float = pool.global_position.y - 5.0
	var centre := Vector3(spline.global_position.x, probe_y, spline.global_position.z)
	pool.position += Vector3(37, 0, 0)
	await _settle()
	await _settle()
	if pool.contains_point(centre) and not pool.contains_point(centre + Vector3(37, 0, 0)):
		print("    dragging the pool 37 m left the water on its spline")
	else:
		_fail += 1
		print("    !! the water moved with the pool node (centre %s, shifted %s)" % [
			pool.contains_point(centre), pool.contains_point(centre + Vector3(37, 0, 0))])
	root.queue_free()
	await _settle()

	# Control: a pool driven by a bare Curve3D has its points in its OWN space, so moving it MUST
	# move the water. Without this, "the water stayed put" could just mean the mesh never moves.
	var croot := _make_world()
	_make_manager(croot)
	var bare = load("res://addons/pasture_3d/connectors/pool.gd").new()
	bare.name = "BareCurvePool"
	bare.curve = _square_curve(30.0)
	bare.material = load(LAKE_MAT)
	croot.add_child(bare)
	await _settle()
	var bprobe := Vector3(0, bare.global_position.y - 5.0, 0)
	var before: bool = bare.contains_point(bprobe)
	bare.position += Vector3(300, 0, 0)
	await _settle()
	await _settle()
	var after_here: bool = bare.contains_point(bprobe)
	var after_there: bool = bare.contains_point(bprobe + Vector3(300, 0, 0))
	if before and not after_here and after_there:
		print("    control (bare curve moves with its node): fires")
	else:
		_fail += 1
		print("    !! control did NOT fire: before %s, here %s, there %s" % [
			before, after_here, after_there])
	croot.queue_free()
	await _settle()
	_completed += 1


# ---- helpers -------------------------------------------------------------------

## A closed square loop of the given half-extent, in the node's own space.
func _square_curve(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


func _make_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	return root


func _make_manager(p_root: Node3D) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	p_root.add_child(m)
	m.sun_light = p_root.get_node("Sun")
	return m


## A brush of the given class with one closed-square spline per entry in p_splines
## ([half_extent, closed]). No terrain: Add Water reads splines, never the heightmap, and a brush
## with no terrain is the harshest version of that claim.
func _make_brush(p_class: String, p_parent: Node, p_splines: Array) -> Node3D:
	var brush: Node3D = _new_brush(p_class)
	brush.name = p_class.replace("Pasture3D", "") + "Test%d" % (p_parent.get_child_count())
	brush.auto_refresh = false
	p_parent.add_child(brush)
	for s in p_splines:
		_add_spline(brush, s[0], s[1])
	return brush


func _new_brush(p_class: String) -> Node3D:
	match p_class:
		"Pasture3DMound": return Pasture3DMound.new()
		"Pasture3DPlow": return Pasture3DPlow.new()
		"Pasture3DSplat": return Pasture3DSplat.new()
		"Pasture3DRidge": return Pasture3DRidge.new()
		"Pasture3DTrough": return Pasture3DTrough.new()
	push_error("unknown brush class %s" % p_class)
	return null


## Configure a brush to CARVE, so Add Water creates immediately rather than asking. Mound, Plow and
## Ridge all default to raising; Trough already defaults to MIN and Splat never writes height.
func _make_carve(p_brush: Node3D) -> void:
	if p_brush.get("blend_mode") != null:
		p_brush.blend_mode = B_MIN
	if p_brush.get("invert") != null:
		p_brush.invert = false


## Dismiss any confirmation dialog left on screen. Criteria that assert "no dialog appeared" have to
## start from a clean window, and a dialog nobody answered stays up forever by design.
func _clear_dialogs() -> void:
	for n in _all_nodes(get_tree().root):
		if n is ConfirmationDialog:
			n.hide()
	await _settle()


func _add_spline(p_brush: Node3D, p_r: float, p_closed: bool) -> Path3D:
	var path := Path3D.new()
	path.name = "Spline%d" % (p_brush.get_child_count() + 1)
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = p_closed
	path.curve = c
	p_brush.add_child(path)
	return path


func _find_pools(p_root: Node) -> Array:
	var out: Array = []
	for n in _all_nodes(p_root):
		if n.is_in_group(&"pasture3d_pool"):
			out.append(n)
	return out


func _count_pools(p_root: Node) -> int:
	return _find_pools(p_root).size()


## Searched from the WHOLE tree, not a fixture sub-root: a manager the button creates is parented to
## the scene root (it is the scene's water authority, not one water body's), so looking for it under
## the brush's own world node would find nothing and blame the button for it.
func _find_managers() -> Array:
	var out: Array = []
	for n in _all_nodes(get_tree().root):
		if n is Pasture3DPoolManager:
			out.append(n)
	return out


## The confirmation dialog the button parents to the window root outside the editor.
func _find_dialog() -> ConfirmationDialog:
	for n in _all_nodes(get_tree().root):
		if n is ConfirmationDialog:
			return n
	return null


func _all_nodes(p_root: Node) -> Array:
	var out: Array = [p_root]
	for c in p_root.get_children():
		out.append_array(_all_nodes(c))
	return out


func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		await RenderingServer.frame_post_draw
