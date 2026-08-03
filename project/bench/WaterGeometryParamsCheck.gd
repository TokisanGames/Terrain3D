# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The mesh-generation knobs on the two water bodies actually reach their range, and the
# inspector agrees with the code about what that range is.
#
# The bug this pins down: Phase 2 extracted the ocean's geometry properties out of
# Pasture3D and narrowed two of them -- mesh_size 256 -> 64, tessellation_level 6 -> 3 --
# in the clamp AND in the slider hint, with no comment and no log line. From the inspector
# that is indistinguishable from a knob that has stopped working: the slider reaches its
# end and the water stays coarse.
#
# So the hint is checked against the clamp, not just the clamp against itself. A hint
# narrower than the clamp is the actual failure mode; a test that only round-trips values
# through the setter would pass while the slider still stopped short.
#
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path project \
#       --script res://bench/WaterGeometryParamsCheck.gd
extends SceneTree

const LAKE_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_lake.tres"

var _fail := 0


func _initialize() -> void:
	print("\n=== Water geometry parameter check ===\n")
	# A node added to the root during _initialize() is NOT inside the tree yet -- it
	# becomes so on the first frame. Pasture3DPool.rebuild() refuses outright when it is not
	# ("not in tree"), so section B would report a failure that is entirely this script's.
	await process_frame
	_check_a_ocean_ranges()
	_check_b_pool_dials()
	print("\n=== %s (%d failures) ===\n" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(0 if _fail == 0 else 1)


func _hint_of(p_node: Object, p_name: String) -> String:
	for p in p_node.get_property_list():
		if p.get("name", "") == p_name:
			return str(p.get("hint_string", ""))
	return "<not found>"


func _expect(p_label: String, p_got, p_want) -> void:
	var ok: bool = p_got == p_want
	print("    %-46s %s (want %s%s)" % [
			p_label, p_got, p_want, "" if ok else " -- MISMATCH"])
	if not ok:
		_fail += 1


# ---- A: the ocean's geometry range -------------------------------------------
func _check_a_ocean_ranges() -> void:
	print("A. Pasture3DOcean geometry knobs reach their documented range")
	var ocean := Pasture3DOcean.new()

	ocean.mesh_size = 256
	_expect("mesh_size = 256 (was capped at 64)", ocean.mesh_size, 256)
	ocean.tessellation_level = 6
	_expect("tessellation_level = 6 (was capped at 3)", ocean.tessellation_level, 6)

	# CONTROL -- the ceiling still exists. Without this the check would pass just as well
	# against a setter that had no clamp at all, which is a different bug.
	ocean.mesh_size = 4096
	_expect("CONTROL, mesh_size = 4096 still clamps", ocean.mesh_size, 256)
	ocean.tessellation_level = 99
	_expect("CONTROL, tessellation_level = 99 still clamps", ocean.tessellation_level, 6)
	ocean.mesh_size = 2
	_expect("CONTROL, mesh_size = 2 clamps up to the floor", ocean.mesh_size, 8)

	# CONTROL -- even-forcing. The LOD0 geomorph is a vertex-parity test, so an odd tile
	# misaligns the seam with the next ring. The step-2 inspector hint hides this; a value
	# set from code does not go through the hint, which is exactly this call.
	ocean.mesh_size = 65
	_expect("CONTROL, mesh_size = 65 forced even", ocean.mesh_size, 64)

	# THE ONE THAT MATTERS -- the slider must reach as far as the setter does.
	print("    -- inspector hints must match the clamps --")
	_expect("mesh_size hint", _hint_of(ocean, "mesh_size"), "8,256,2")
	_expect("tessellation_level hint", _hint_of(ocean, "tessellation_level"), "0,6,1")
	_expect("mesh_lods hint (unchanged by this work)", _hint_of(ocean, "mesh_lods"), "1,10,1")

	ocean.free()


# ---- B: the water body's dials ------------------------------------------------
# max_vertices was a const, so water that needed to be denser than the guard allowed had
# no way to say so -- the ocean's problem in a different file. fill_offset had no setter at
# all, so on a RIBBON (where it positions every row of the mesh) changing it did nothing
# until some unrelated edit happened to trigger a rebuild.
#
# Both dials now live on Pasture3DWaterBody, shared by the pool and the stream. Measured on the
# STREAM because that is where fill_offset reaches the mesh: on a pool it is only read by the Fit
# to Curve button, so a pool fixture would pass this criterion without exercising anything. The
# stream is built WITHOUT terrain in the scene, which is the path where fill_offset is still the
# level -- with a Pasture3D present the banks decide it, and this would be measuring bank
# sampling instead.
func _check_b_pool_dials() -> void:
	print("\nB. Pasture3DWaterBody dials take effect (on a Pasture3DStream)")
	var root := Node3D.new()
	get_root().add_child(root)
	var manager := Pasture3DPoolManager.new()
	root.add_child(manager)

	var pool = load("res://addons/pasture_3d/connectors/stream.gd").new()
	pool.material = load(LAKE_MAT)
	pool.wave_profile = &"lake_calm"
	pool.vertex_spacing = 1.0
	pool.underwater_enabled = false
	root.add_child(pool)

	var c := Curve3D.new()
	for i in 12:
		c.add_point(Vector3(i * 8.0, 0.0, 0.0))
	pool.curve = c
	pool.fill_offset = 0.0
	var stats: Dictionary = pool.rebuild()
	print("    ribbon built: ok=%s ribbon=%s vertices=%d reason=%s" % [
			stats.get("ok", false), stats.get("ribbon", false), stats.get("vertices", 0),
			stats.get("reason", "")])
	print("    (curve points=%d closed=%s, is_ribbon=%s, spacing=%.2f)" % [
			c.point_count, c.closed, pool.is_ribbon(), stats.get("spacing", -1.0)])
	if not stats.get("ok", false) or not stats.get("ribbon", false):
		_fail += 1
		print("    !! the ribbon did not build; the rest of B proves nothing")
		root.queue_free()
		return

	# -- fill_offset reaches the mesh --
	var probe := Vector2(40.0, 0.0)
	var before: float = pool.get_water_height(probe)
	pool.fill_offset = -3.0
	pool.rebuild()
	var after: float = pool.get_water_height(probe)
	print("    fill_offset 0 -> -3: surface %.3f -> %.3f (delta %.3f, want -3.000)" % [
			before, after, after - before])
	if not is_equal_approx(after - before, -3.0):
		_fail += 1
		print("    !! fill_offset did not move the ribbon surface")
	# CONTROL -- "measured nothing" guard.
	if is_equal_approx(before, after):
		_fail += 1
		print("    !! CONTROL: the surface did not move at all")

	# -- max_vertices is a real gate, in both directions --
	var needed: int = pool.get_build_stats().get("vertices", 0)
	pool.max_vertices = maxi(needed / 2, 4)
	var refused: Dictionary = pool.rebuild()
	print("    max_vertices %d (needs %d) -> ok=%s, reason: %s" % [
			pool.max_vertices, needed, refused.get("ok", false), refused.get("reason", "")])
	if refused.get("ok", false) or not str(refused.get("reason", "")).contains("max_vertices"):
		_fail += 1
		print("    !! lowering max_vertices did not stop the build, or did not say why")

	# CONTROL -- and raising it lets the same pool through, so the gate is the dial and
	# not some other failure that happened to appear at the same moment.
	pool.max_vertices = needed * 4
	var allowed: Dictionary = pool.rebuild()
	print("    CONTROL, max_vertices %d -> ok=%s, vertices=%d" % [
			pool.max_vertices, allowed.get("ok", false), allowed.get("vertices", 0)])
	if not allowed.get("ok", false):
		_fail += 1
		print("    !! raising max_vertices did not let the pool build")

	root.queue_free()
