# Diagnostic, not a gate: renders the four Pasture3DSimResult channels a real Pasture3DSim writes over
# the demo terrain, so "the masks hold the right fields" is something looked at rather than inferred from
# a number being non-zero. The companion to bench/SimFieldProbe.tscn, which does the same job for the
# height the solver produces.
#
# Writes, per run: the before/after hillshade, one greyscale image per channel, and a composite where
# erosion is red, deposition green and wetness blue — that last one is the readout that shows the three
# occupy DIFFERENT ground, which no per-channel image can.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimResultProbe.tscn
extends Node

const OUT_DIR := "user://sim_result_probe"
const DEMO_DATA := "res://demo/data"
const DEMO_AT := Vector3(512.0, 0.0, 200.0)
const DEMO_HALF := 250.0
const DEMO_MARGIN := 128.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("writing to %s" % ProjectSettings.globalize_path(OUT_DIR))
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	var data = terrain.data
	if not is_finite(data.get_height(DEMO_AT)):
		print("!! no demo terrain at %s" % DEMO_AT)
		get_tree().quit(1)
		return

	var sim := Pasture3DSim.new()
	sim.name = "MaskProbe"
	root.add_child(sim)
	sim.terrain = terrain
	sim.global_position = DEMO_AT
	sim.catchment_margin = DEMO_MARGIN
	sim.snap_to_surface = false
	sim.falloff_width = 40.0
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-DEMO_HALF, 0.0, -DEMO_HALF))
	c.add_point(Vector3(DEMO_HALF, 0.0, -DEMO_HALF))
	c.add_point(Vector3(DEMO_HALF, 0.0, DEMO_HALF))
	c.add_point(Vector3(-DEMO_HALF, 0.0, DEMO_HALF))
	c.closed = true
	path.curve = c
	sim.add_child(path)

	# The simulated grid, which is what the masks cover — the loop grown by the catchment margin.
	var vs: float = terrain.vertex_spacing
	var layer_id: int = sim._ensure_layer_for(sim._layer_owner, true)
	var sb: Array = sim._snapped_bounds(sim._spline_footprint_aabb(path).grow(DEMO_MARGIN), vs)
	var tw := int(round((sb[1] - sb[0]) / vs)) + 1
	var th := int(round((sb[3] - sb[2]) / vs)) + 1
	var before: PackedFloat32Array = data.composite_height_below(layer_id, sb[0], sb[2], vs, tw, th)
	_shade(before, tw, th, vs, "%s/00_before.png" % OUT_DIR)

	# What the ground was ALREADY doing, before a single iteration. Authored terrain is not
	# hydrologically conditioned, so a large `wetness` on the eroded surface may be the demo's own closed
	# basins rather than anything the sim made — and those are two very different readings of the same
	# picture. Same routing-only pass the node uses for its masks.
	var base: Dictionary = data.erode_heightfield(before, {"gw": tw, "gh": th, "cell_size": vs,
			"iterations": 0, "want_diagnostics": true}, PackedFloat32Array())
	if bool(base.get("ok", false)):
		print("  BEFORE any erosion: max standing water %.1f m over %d of %d cells" % [
				_max(base["lake_depth"]), _count(base["lake_depth"]), tw * th])
		_grey(base["lake_depth"], tw, th, "%s/07_wetness_before.png" % OUT_DIR)

	print("\n  shipped defaults: K %.3f, D %.3f, %d iterations, %.0f m loop + %.0f m margin" % [
			sim.erosion_rate, sim.hillslope_diffusion, sim.iterations, DEMO_HALF * 2.0, DEMO_MARGIN])
	var rep: Dictionary = sim.simulate_now(1, false)
	if not bool(rep.get("ok", false)):
		print("  !! the simulation did not run: %s" % rep.get("reason", "?"))
		get_tree().quit(1)
		return
	var top: int = data.get_layer_stack_size()
	var after: PackedFloat32Array = data.composite_height_below(top, sb[0], sb[2], vs, tw, th)
	_shade(after, tw, th, vs, "%s/01_after.png" % OUT_DIR)

	var r: Pasture3DSimResult = sim.sim_result
	if r == null or not r.is_valid():
		print("  !! no masks were written")
		get_tree().quit(1)
		return
	print("  %s" % r.describe())
	var b := r.world_bounds()
	print("  the masks cover X %.0f..%.0f, the LOOP is X %.0f..%.0f — the extent includes the margin" % [
			b[0], b[1], DEMO_AT.x - DEMO_HALF, DEMO_AT.x + DEMO_HALF])

	# Flow is stored log-scaled, so its image is already the readable one; label it in m² anyway.
	print("\n  %-11s %12s %12s   %s" % ["channel", "min", "max", "note"])
	print("  %-11s %12.3f %12.3f   exp() -> %.0f .. %.0f m2 of catchment" % [
			"flow", _min(r.flow), _max(r.flow), exp(_min(r.flow)), exp(_max(r.flow))])
	print("  %-11s %12.3f %12.3f   metres removed" % ["erosion", _min(r.erosion), _max(r.erosion)])
	print("  %-11s %12.3f %12.3f   metres gained (diffusion only, phase 2)" % [
			"deposition", _min(r.deposition), _max(r.deposition)])
	print("  %-11s %12.3f %12.3f   metres of standing water" % ["wetness", _min(r.wetness), _max(r.wetness)])
	var drop := -_min(r.erosion)
	var rise := _max(r.deposition)
	print("\n  scale check: %.1f m of drop against %.1f m of rise (deposition is 1/%.0f of the incision)" % [
			drop, rise, drop / maxf(rise, 1e-6)])
	print("  cells: %d eroded, %d deposited, %d wet, of %d" % [
			_count(r.erosion), _count(r.deposition), _count(r.wetness), r.width * r.height])

	_grey(r.flow, r.width, r.height, "%s/02_flow_log.png" % OUT_DIR)
	_grey(r.erosion, r.width, r.height, "%s/03_erosion.png" % OUT_DIR)
	_grey(r.deposition, r.width, r.height, "%s/04_deposition.png" % OUT_DIR)
	_grey(r.wetness, r.width, r.height, "%s/05_wetness.png" % OUT_DIR)
	_rgb(r, "%s/06_erosion_deposition_wetness_rgb.png" % OUT_DIR)
	sim.clear_simulation()
	print("\n  done.")
	get_tree().quit(0)


## Erosion red, deposition green, wetness blue, each on its own scale. The point of this image is not
## any one channel but that the three light up DIFFERENT ground: red in the channel network, green in
## the hollows beside it, blue only in closed basins.
func _rgb(p_r: Pasture3DSimResult, p_path: String) -> void:
	var img := Image.create(p_r.width, p_r.height, false, Image.FORMAT_RGB8)
	var e := maxf(-_min(p_r.erosion), 1e-6)
	var d := maxf(_max(p_r.deposition), 1e-6)
	var w := maxf(_max(p_r.wetness), 1e-6)
	for y in range(p_r.height):
		for x in range(p_r.width):
			var i := y * p_r.width + x
			img.set_pixel(x, y, Color(sqrt(clampf(-p_r.erosion[i] / e, 0.0, 1.0)),
					sqrt(clampf(p_r.deposition[i] / d, 0.0, 1.0)),
					sqrt(clampf(p_r.wetness[i] / w, 0.0, 1.0))))
	img.save_png(p_path)


## Greyscale over the field's own range, black = min. Prints nothing: the numbers are tabulated above.
func _grey(p_f: PackedFloat32Array, p_w: int, p_h: int, p_path: String) -> void:
	var lo := _min(p_f)
	var hi := _max(p_f)
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RGB8)
	for y in range(p_h):
		for x in range(p_w):
			var t: float = (p_f[y * p_w + x] - lo) / maxf(hi - lo, 1e-9)
			img.set_pixel(x, y, Color(t, t, t))
	img.save_png(p_path)


## Lambert hillshade, 315°/45° — a greyscale height ramp hides valleys, a shaded relief does not.
func _shade(p_f: PackedFloat32Array, p_w: int, p_h: int, p_vs: float, p_path: String) -> void:
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RGB8)
	for y in range(p_h):
		for x in range(p_w):
			var xm := maxi(x - 1, 0)
			var xp := mini(x + 1, p_w - 1)
			var ym := maxi(y - 1, 0) * p_w
			var yp := mini(y + 1, p_h - 1) * p_w
			var a: float = p_f[y * p_w + xp]
			var bb: float = p_f[y * p_w + xm]
			var cc: float = p_f[yp + x]
			var dd: float = p_f[ym + x]
			if not (is_finite(a) and is_finite(bb) and is_finite(cc) and is_finite(dd)):
				img.set_pixel(x, y, Color(1.0, 0.0, 0.0)) # no data must not read as flat ground
				continue
			var gx := (a - bb) / (2.0 * p_vs)
			var gz := (cc - dd) / (2.0 * p_vs)
			var nl := 1.0 / sqrt(gx * gx + gz * gz + 1.0)
			var s := clampf((gx * 0.5 + gz * 0.5 + 0.7071) * nl, 0.0, 1.0)
			img.set_pixel(x, y, Color(s, s, s))
	img.save_png(p_path)


func _min(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m


func _max(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		m = maxf(m, v)
	return m


func _count(p_a: PackedFloat32Array) -> int:
	var n := 0
	for v in p_a:
		if v != 0.0:
			n += 1
	return n
