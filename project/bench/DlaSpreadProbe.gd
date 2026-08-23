# Not a gate, and it has no verdict. Answers one editor question: which knob actually decides how much of
# a brush's loop carries DLA relief.
#
# The obvious answer is `coverage`, and the obvious answer is wrong. Coverage decides where the FIELD
# ends; what decides where the relief is still visible is how much of that field sits above the noise
# floor, which is `profile_power`. Measured on a 300 m loop, relief reaching 5 % of its own peak:
#
#   coverage 0.90 → 0.98            reach 0.65 → 0.68
#   profile_power 1.0 → 0.6        reach 0.68 → 0.74
#   profile_power 0.6 → 0.35       reach 0.74 → 0.79
#   blur_growth 1.6 → 3.0          no measurable change
#
# And separately from reach, AMPLITUDE: a modifier's relief is multiplied by the brush's own 0..1 interior
# profile, so an uncapped dome spends most of its relief on the flanks. Capping the mound took the same
# material from 9.4 m of peak relief to 14.1 m without touching the material at all.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/DlaSpreadProbe.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SITE := Vector3(400.0, 0.0, 400.0)
const HALF := 150.0

var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	print("\n=== how much of a %d m loop carries DLA relief? ===\n" % int(HALF * 2))
	print("  reach = furthest probe carrying >5%% of peak relief, as a fraction of the loop half-width\n")
	var k := 0
	for e in [
			["dome, slope 30deg, cov 0.90, power 1.0 (today) ", false, 1, 0.90, 1.0, 1.6],
			["dome, slope 30deg, cov 0.98, power 1.0         ", false, 1, 0.98, 1.0, 1.6],
			["dome, slope 30deg, cov 0.98, POWER 0.6         ", false, 1, 0.98, 0.6, 1.6],
			["dome, slope 30deg, cov 0.98, POWER 0.35        ", false, 1, 0.98, 0.35, 1.6],
			["dome, slope 30deg, cov 0.98, power 0.6, GROWTH 3", false, 1, 0.98, 0.6, 3.0],
			["CAPPED, fixed 15 m, cov 0.98, power 0.6        ", true, 0, 0.98, 0.6, 1.6]]:
		k += 1
		_run("P%d" % k, e[0], e[1], e[2], e[3], e[4], e[5])
	get_tree().quit(0)


func _run(p_name: String, p_label: String, p_capped: bool, p_flank: int, p_coverage: float,
		p_power: float, p_growth: float) -> void:
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = SITE
	mound.height = 50.0
	mound.capped = p_capped
	mound.flank_mode = p_flank
	mound.falloff_width = 15.0
	mound.slope_angle = 30.0
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	var path := Path3D.new()
	path.name = "Loop1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	mound._set_layer_owner(Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX + p_name)

	var mat := Pasture3DReliefDLA.new()
	mat.resolution = 256
	mat.coverage = p_coverage
	mat.profile_power = p_power
	mat.blur_growth = p_growth
	mat.seed = 5
	# LIVE: the sweep varies growth inputs and reads the mountain each one produces.
	mat.evaluation = Pasture3DReliefDLA.Evaluation.LIVE
	var shape := Pasture3DModRelief.new()
	shape.material = mat
	shape.strength = 15.0
	var stack: Array[Pasture3DBrushModifier] = [shape]
	mound.modifiers = stack

	# A radial fan of probes, so "how far out does relief survive" is a direct reading.
	var probes: Array[Vector3] = []
	for ang in range(24):
		var a := float(ang) * TAU / 24.0
		for r in range(1, 30):
			var t := float(r) / 29.0 * (HALF - _vs * 2.0)
			probes.append(Vector3(snappedf(SITE.x + cos(a) * t, _vs), 0.0, snappedf(SITE.z + sin(a) * t, _vs)))

	mound._refresh_owner(mound._layer_owner, false, [])
	var with_relief := _snap(probes)
	shape.strength = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var without := _snap(probes)

	var peak := 0.0
	for i in range(probes.size()):
		if is_finite(with_relief[i]) and is_finite(without[i]):
			peak = maxf(peak, absf(with_relief[i] - without[i]))
	var reach := 0.0
	var live := 0
	for i in range(probes.size()):
		if not (is_finite(with_relief[i]) and is_finite(without[i])):
			continue
		if absf(with_relief[i] - without[i]) > peak * 0.05:
			live += 1
			var d := Vector2(probes[i].x - SITE.x, probes[i].z - SITE.z).length()
			reach = maxf(reach, d)
	print("  %s  peak relief %5.2f m   reach %.2f   %.0f%% of the loop carries it"
			% [p_label, peak, reach / HALF, 100.0 * float(live) / float(probes.size())])
	mound.queue_free()


func _snap(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_terrain.data.get_height(Vector3(p.x, 0.0, p.z)))
	return out
