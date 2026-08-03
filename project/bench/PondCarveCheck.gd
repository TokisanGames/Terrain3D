# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Does a Pasture3DPond actually take height OUT of the terrain?
#
# PondBrushCheck proves the pond is CONFIGURED to carve -- invert on, blend MIN, its own layer.
# That is not the same claim as "the ground goes down", and the two came apart in practice: the
# brush reported every correct setting and left the surface untouched.
#
# refresh() early-returns outside the editor (Engine.is_editor_hint()), so this drives the bake
# path underneath it -- _refresh_owner is the function refresh() calls once past that guard.
#
# NOTHING IS SAVED. The bake writes into the terrain's in-memory layer and pushes to the GPU;
# demo/data on disk is only touched by an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PondCarveCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
## Inside the loaded regions -- get_height() returns NAN outside them and every reading would be
## a fixture bug rather than a result.
const CENTRE := Vector3(180.0, 0.0, 100.0)
const LOOP_HALF := 24.0

var _fail := 0


func _ready() -> void:
	print("\n=== Pasture3DPond carves ===\n")
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA

	var before := _h(terrain, CENTRE)
	print("  ground before: %.3f m" % before)
	if not is_finite(before):
		_fail += 1
		print("  !! no terrain at %s; the fixture is outside demo/data" % CENTRE)
		_done()
		return

	var pond := Pasture3DPond.new()
	pond.name = "TestPond"
	pond.auto_add_water = false # water is PondBrushCheck's subject, not this one's
	root.add_child(pond)
	pond.terrain = terrain
	pond.global_position = CENTRE
	_give_loop(pond)
	print("  pond: layer_owner='%s' blend=%d invert=%s height=%.1f splines=%d configured=%s" % [
			pond._layer_owner, pond._get_blend_mode(), pond.invert, pond.height,
			pond._get_splines().size(), pond.is_configured()])

	# The bake, under refresh()'s editor guard.
	pond._refresh_owner(pond._layer_owner, false, [])
	var after := _h(terrain, CENTRE)
	var delta := after - before
	print("\n  ground after:  %.3f m   delta %+.3f m" % [after, delta])

	print("\nA. the pond removed height")
	if delta < -0.5:
		print("  carved %.2f m -- ok" % -delta)
	else:
		_fail += 1
		print("  !! the surface did not go down (delta %+.3f)" % delta)

	# CONTROL -- a plain Mound in the same place with the same loop must RAISE it. If this also
	# fails, the bake path is not running at all and A's failure says nothing about the Pond.
	print("\nB. CONTROL, a Mound in the same place raises instead")
	var mound := Pasture3DMound.new()
	mound.name = "TestMound"
	root.add_child(mound)
	mound.terrain = terrain
	mound.global_position = CENTRE + Vector3(200.0, 0.0, 0.0)
	_give_loop(mound)
	var m_before := _h(terrain, CENTRE + Vector3(200.0, 0.0, 0.0))
	mound._refresh_owner(mound._layer_owner, false, [])
	var m_after := _h(terrain, CENTRE + Vector3(200.0, 0.0, 0.0))
	print("  mound %.3f -> %.3f (delta %+.3f)" % [m_before, m_after, m_after - m_before])
	if m_after - m_before <= 0.5:
		_fail += 1
		print("  !! CONTROL failed: the bake path is not running, so A proves nothing")

	# --- C: the reported bug ------------------------------------------------
	# A Pond added through Add Child Node arrives with NO spline. The Place-Brush tool builds one
	# for whatever it drops; Add Child Node does not. A brush with no spline paints nothing and
	# reports "Add at least one spline", which reads as "the pond brush does not work".
	#
	# is_editor_hint() is false here, so _seed_setup() -- the automatic entry point -- correctly
	# refuses. The gate drives the primitives underneath it, which is exactly why the editor guard
	# sits on _seed_setup and not inside them.
	print("
C. a pond added with no spline gives itself one")
	var bare := Pasture3DPond.new()
	bare.name = "BarePond"
	bare.auto_add_water = false
	root.add_child(bare)
	bare.terrain = terrain
	bare.global_position = CENTRE + Vector3(0.0, 0.0, 200.0)
	print("  splines on arrival: %d" % bare._get_splines().size())
	var c_before := _h(terrain, CENTRE + Vector3(0.0, 0.0, 200.0))
	bare._try_seed_loop()
	print("  splines after seeding: %d (loop_seeded=%s)" % [
			bare._get_splines().size(), bare._loop_seeded])
	if bare._get_splines().is_empty():
		_fail += 1
		print("  !! still no spline; the pond would carve nothing")
	else:
		bare._refresh_owner(bare._layer_owner, false, [])
		var c_after := _h(terrain, CENTRE + Vector3(0.0, 0.0, 200.0))
		print("  ground %.3f -> %.3f (delta %+.3f)" % [c_before, c_after, c_after - c_before])
		if c_after - c_before >= -0.5:
			_fail += 1
			print("  !! the self-seeded loop did not carve")

	# CONTROL -- seeding must not run twice. A pond whose loop the user deleted on purpose must
	# not be handed a new one on every scene load.
	var n_before := bare._get_splines().size()
	bare._try_seed_loop()
	print("  CONTROL, second seed adds nothing: %s (%d -> %d splines)" % [
			bare._get_splines().size() == n_before, n_before, bare._get_splines().size()])
	if bare._get_splines().size() != n_before:
		_fail += 1
		print("  !! seeding repeats; a deleted loop would come back forever")

	_done()


func _give_loop(p_brush: Node) -> void:
	var path := Path3D.new()
	path.name = "Loop1"
	var c := Curve3D.new()
	c.add_point(Vector3(-LOOP_HALF, 0.0, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, 0.0, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, 0.0, LOOP_HALF))
	c.add_point(Vector3(-LOOP_HALF, 0.0, LOOP_HALF))
	c.closed = true
	path.curve = c
	p_brush.add_child(path)


func _h(p_terrain, p_pos: Vector3) -> float:
	return p_terrain.data.get_height(p_pos)


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)
