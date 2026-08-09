# Diagnostic, not a gate: renders what the stream-power solver actually produces, so the phase-1 gates
# and the shipped defaults are calibrated against a picture and not only against numbers. Sweeps a few
# initial surfaces and rates, and writes a hillshade of the result, the log drainage area, and the
# incision field for each.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimFieldProbe.tscn
extends Node

const OUT_DIR := "user://sim_probe"
const SG := 128
const SCELL := 4.0
const BASE_Z := 200.0

var _data


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var t = ClassDB.instantiate("Pasture3D")
	add_child(t)
	_data = t.data
	print("writing to %s" % ProjectSettings.globalize_path(OUT_DIR))

	# (rate, diffusion) sweep on one rolling hillside. That PAIR is what decides whether the result
	# reads as a valley network or as a smoothing pass: diffusion fills the channels incision cuts, so
	# too much of it and the surface comes back rounder than it went in.
	var z := _slope_field(0.02, 20.0, 0.003, 3)
	_save_shade(z, SG, "%s/shade_before.png" % OUT_DIR)
	print("  %-12s %8s %8s %10s %8s" % ["tag", "incRMS", "incMax", "chan-ridge", "share"])
	for rate: float in [0.05, 0.2, 1.0]:
		for diff: float in [0.0, 0.5, 2.0]:
			var p := {"gw": SG, "gh": SG, "cell_size": SCELL, "iterations": 40,
					"erosion_rate": rate, "area_exponent": 0.45, "diffusion": diff,
					"want_diagnostics": true}
			var r: Dictionary = _data.erode_heightfield(z, p, PackedFloat32Array())
			var zo: PackedFloat32Array = r["z"]
			var inc := _delta(zo, z)
			var tag := "r%s_d%s" % [str(rate).replace(".", ""), str(diff).replace(".", "")]
			_save_shade(zo, SG, "%s/shade_%s.png" % [OUT_DIR, tag])
			_save(inc, SG, "%s/inc_%s.png" % [OUT_DIR, tag])
			print("  %-12s %8.2f %8.2f %+10.2f %8.4f | slope-area beta %+.3f r %+.3f" % [
					tag, _rms(inc), _max(inc),
					_channel_ratio(z, r), _max(r["flow"]) / (float(SG * SG) * SCELL * SCELL),
					_sa_beta(zo, r)[0], _sa_beta(zo, r)[1]])

	print("\n  preview vs build (the pair gate J compares), 'rolling' fixture:")
	var zr := _slope_field(0.02, 20.0, 0.003, 3)
	for diff in [0.0, 2.0]:
		var p2 := {"gw": SG, "gh": SG, "cell_size": SCELL, "iterations": 40,
				"erosion_rate": 0.01, "area_exponent": 0.45, "diffusion": diff}
		var build: Dictionary = _data.erode_heightfield(zr, p2, PackedFloat32Array())
		var db := _delta(build["z"], zr)
		var cn := (SG - 1) / 4 + 1
		var zc: PackedFloat32Array = _data.resample_grid(zr, SG, SG, cn, cn)
		var pc := p2.duplicate()
		pc["gw"] = cn
		pc["gh"] = cn
		pc["cell_size"] = SCELL * float(SG - 1) / float(cn - 1)
		var prev: Dictionary = _data.erode_heightfield(zc, pc, PackedFloat32Array())
		var dc := _delta(prev["z"], zc)
		var dp: PackedFloat32Array = _data.resample_grid(dc, cn, cn, SG, SG)
		print("    diffusion %.1f: build RMS %.3f | preview RMS %.3f (x%.2f)" % [
				diff, _rms(db), _rms(dp), _rms(dp) / maxf(_rms(db), 1e-9)])
		for div: int in [1, 4, 8, 16]:
			var m: int = (SG - 1) / div + 1
			var a: PackedFloat32Array = _data.resample_grid(db, SG, SG, m, m)
			var b: PackedFloat32Array = _data.resample_grid(dp, SG, SG, m, m)
			print("      1/%-2d pearson %.3f  relRMS %.3f  (RMS %.3f vs %.3f)" % [
					div, _pearson(a, b), _rel(a, b), _rms(a), _rms(b)])
		if diff == 2.0:
			_save(db, SG, "%s/j_build.png" % OUT_DIR)
			_save(dp, SG, "%s/j_preview.png" % OUT_DIR)

	var z0res: Dictionary = _data.erode_heightfield(z, {"gw": SG, "gh": SG, "cell_size": SCELL,
			"iterations": 0, "want_diagnostics": true}, PackedFloat32Array())
	var b0 := _sa_beta(z, z0res)
	print("  BEFORE erosion: slope-area beta %+.3f r %+.3f | share %.4f" % [
			b0[0], b0[1], _max(z0res["flow"]) / (float(SG * SG) * SCELL * SCELL)])
	var pl := _slope_field(0.25, 0.0, 0.003, 3)
	var plres: Dictionary = _data.erode_heightfield(pl, {"gw": SG, "gh": SG, "cell_size": SCELL,
			"iterations": 1, "erosion_rate": 0.2, "area_exponent": 0.45, "diffusion": 0.5,
			"want_diagnostics": true}, PackedFloat32Array())
	var bp := _sa_beta(plres["z"], plres)
	print("  CONTROL uniform plane 1 iter: slope-area beta %+.3f r %+.3f" % [bp[0], bp[1]])

	_demo_sweep()
	get_tree().quit(0)


# --- the same question on the real demo terrain ----------------------------------------------------
#
# The synthetic sweep above says which (rate, diffusion) pair carves valleys on a rolling hillside. It
# cannot say what the SHIPPED defaults should be, because the answer depends on how far the terrain
# already sits above its graded profile — and the demo's mountains sit a long way above it. This runs a
# real Pasture3DSim over a real loop and writes the before/after hillshade of the composite.
const DEMO_DATA := "res://demo/data"
const DEMO_AT := Vector3(512.0, 0.0, 200.0)
const DEMO_HALF := 250.0
const DEMO_MARGIN := 128.0


func _demo_sweep() -> void:
	print("\n  demo terrain, %.0f m loop + %.0f m margin:" % [DEMO_HALF * 2.0, DEMO_MARGIN])
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	var data = terrain.data
	if not is_finite(data.get_height(DEMO_AT)):
		print("    !! no demo terrain at %s" % DEMO_AT)
		return

	var sim := Pasture3DSim.new()
	sim.name = "DemoProbe"
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

	var vs: float = terrain.vertex_spacing
	var layer_id: int = sim._ensure_layer_for(sim._layer_owner, true)
	var b: Array = sim._snapped_bounds(sim._spline_footprint_aabb(path), vs)
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	var before: PackedFloat32Array = data.composite_height_below(layer_id, b[0], b[2], vs, gw, gh)
	_save_shade_vs(before, gw, gh, vs, "%s/demo_before.png" % OUT_DIR)
	print("    grid %dx%d, layer %d" % [gw, gh, layer_id])

	var top: int = data.get_layer_stack_size()
	# The shipped defaults first, then the neighbours that show what moving them costs.
	for spec in [{"r": sim.erosion_rate, "d": sim.hillslope_diffusion},
			{"r": 0.0, "d": 0.0}, {"r": 0.02, "d": 0.15}, {"r": 0.5, "d": 0.15}]:
		sim.erosion_rate = spec["r"]
		sim.iterations = 30
		sim.hillslope_diffusion = spec["d"]
		var t0 := Time.get_ticks_msec()
		var rep: Dictionary = sim.simulate_now(1, false)
		if not bool(rep.get("ok", false)):
			print("    !! rate %.4f did not run: %s" % [spec["r"], rep.get("reason", "?")])
			continue
		var after: PackedFloat32Array = data.composite_height_below(top, b[0], b[2], vs, gw, gh)
		var d := _delta(after, before) # before - after, i.e. positive where the ground was LOWERED
		var tag := "demo_r%s_d%s" % [str(spec["r"]).replace(".", ""), str(spec["d"]).replace(".", "")]
		_save_shade_vs(after, gw, gh, vs, "%s/%s.png" % [OUT_DIR, tag])
		print("    rate %-7.4f diff %-5.2f: %5d ms | delta RMS %6.2f m  max drop %7.2f m  max rise %6.2f m" % [
				spec["r"], spec["d"], Time.get_ticks_msec() - t0, _rms(d), _max(d), -_min(d)])
	sim.clear_simulation()


## Hillshade of a grid whose cell size is p_vs (the synthetic one hardcodes SCELL).
func _save_shade_vs(f: PackedFloat32Array, w: int, h: int, p_vs: float, path: String) -> void:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in range(h):
		for x in range(w):
			var xm := maxi(x - 1, 0)
			var xp := mini(x + 1, w - 1)
			var ym := maxi(y - 1, 0) * w
			var yp := mini(y + 1, h - 1) * w
			var a: float = f[y * w + xp]
			var bb: float = f[y * w + xm]
			var cc: float = f[yp + x]
			var dd: float = f[ym + x]
			if not (is_finite(a) and is_finite(bb) and is_finite(cc) and is_finite(dd)):
				img.set_pixel(x, y, Color(1.0, 0.0, 0.0)) # no data — must not read as flat ground
				continue
			var gx := (a - bb) / (2.0 * p_vs)
			var gz := (cc - dd) / (2.0 * p_vs)
			var nl := 1.0 / sqrt(gx * gx + gz * gz + 1.0)
			var s := clampf((gx * 0.5 + gz * 0.5 + 0.7071) * nl, 0.0, 1.0)
			img.set_pixel(x, y, Color(s, s, s))
	img.save_png(path)


func _min(a: PackedFloat32Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, v)
	return m


func _slope_field(p_slope: float, p_amp: float, p_freq: float, p_oct: int) -> PackedFloat32Array:
	var n := FastNoiseLite.new()
	n.seed = 1234
	n.frequency = p_freq
	n.fractal_octaves = p_oct
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	for iz in range(SG):
		for ix in range(SG):
			z[iz * SG + ix] = BASE_Z - p_slope * iz * SCELL + p_amp * n.get_noise_2d(ix * SCELL, iz * SCELL)
	return z


func _channel_ratio(p_before: PackedFloat32Array, p_res: Dictionary) -> float:
	var flow: PackedFloat32Array = p_res["flow"]
	var bnd: PackedByteArray = p_res["boundary"]
	var after: PackedFloat32Array = p_res["z"]
	var interior := PackedFloat32Array()
	for i in range(flow.size()):
		if bnd[i] == 0:
			interior.append(flow[i])
	var sorted := interior.duplicate()
	sorted.sort()
	var hi: float = sorted[int(float(sorted.size()) * 0.99)]
	var mid: float = sorted[sorted.size() / 2]
	var ts := 0.0
	var tn := 0
	var ls := 0.0
	var ln := 0
	for i in range(flow.size()):
		if bnd[i] != 0:
			continue
		var inc: float = p_before[i] - after[i]
		if flow[i] >= hi:
			ts += inc
			tn += 1
		elif flow[i] <= mid:
			ls += inc
			ln += 1
	if tn == 0 or ln == 0:
		return 0.0
	return (ts / float(tn)) - (ls / float(ln))


## Regression of log(slope) on log(drainage area) over the interior: [beta, pearson r]. A fluvially
## graded landscape obeys S ~ A^(-m/n), so beta should approach -m and r should be strongly negative.
func _sa_beta(f: PackedFloat32Array, r: Dictionary) -> Array:
	var flow: PackedFloat32Array = r["flow"]
	var bnd: PackedByteArray = r["boundary"]
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	for iz in range(1, SG - 1):
		for ix in range(1, SG - 1):
			var i := iz * SG + ix
			if bnd[i] != 0:
				continue
			var gx := (f[i + 1] - f[i - 1]) / (2.0 * SCELL)
			var gz := (f[i + SG] - f[i - SG]) / (2.0 * SCELL)
			var sl := sqrt(gx * gx + gz * gz)
			if sl < 1e-6 or flow[i] <= 0.0:
				continue
			xs.append(log(flow[i]))
			ys.append(log(sl))
	if xs.size() < 100:
		return [0.0, 0.0]
	var n := float(xs.size())
	var mx := 0.0
	var my := 0.0
	for i in range(xs.size()):
		mx += xs[i]
		my += ys[i]
	mx /= n
	my /= n
	var sxy := 0.0
	var sxx := 0.0
	var syy := 0.0
	for i in range(xs.size()):
		var dx := xs[i] - mx
		var dy := ys[i] - my
		sxy += dx * dy
		sxx += dx * dx
		syy += dy * dy
	return [sxy / maxf(sxx, 1e-9), sxy / maxf(sqrt(sxx * syy), 1e-9)]


## Peak-to-trough relief of a field, in metres.
func _relief(f: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in f:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _delta(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(a.size())
	for i in range(a.size()):
		o[i] = b[i] - a[i]
	return o


func _save(f: PackedFloat32Array, w: int, path: String) -> void:
	var lo := INF
	var hi := -INF
	for v in f:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var img := Image.create(w, f.size() / w, false, Image.FORMAT_RGB8)
	for y in range(f.size() / w):
		for x in range(w):
			var t := (f[y * w + x] - lo) / maxf(hi - lo, 1e-9)
			img.set_pixel(x, y, Color(t, t, t))
	img.save_png(path)


## Lambert hillshade from a light at 315°, 45° — the readout that actually shows whether the result
## looks like a landscape. A greyscale height ramp hides valleys; a shaded relief does not.
func _save_shade(f: PackedFloat32Array, w: int, path: String) -> void:
	var h := f.size() / w
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var lx := -0.7071 * 0.7071
	var lz := -0.7071 * 0.7071
	var ly := 0.7071
	for y in range(h):
		for x in range(w):
			var xm := maxi(x - 1, 0)
			var xp := mini(x + 1, w - 1)
			var ym := maxi(y - 1, 0) * w
			var yp := mini(y + 1, h - 1) * w
			var gx := (f[y * w + xp] - f[y * w + xm]) / (2.0 * SCELL)
			var gz := (f[yp + x] - f[ym + x]) / (2.0 * SCELL)
			var nl := 1.0 / sqrt(gx * gx + gz * gz + 1.0)
			var d := clampf((-gx * lx - gz * lz + ly) * nl, 0.0, 1.0)
			img.set_pixel(x, y, Color(d, d, d))
	img.save_png(path)


func _rms(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v * v
	return sqrt(s / maxf(float(a.size()), 1.0))


func _max(a: PackedFloat32Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m


func _rel(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var d := PackedFloat32Array()
	d.resize(a.size())
	for i in range(a.size()):
		d[i] = a[i] - b[i]
	return _rms(d) / maxf(_rms(a), 1e-9)


func _pearson(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := float(a.size())
	var ma := 0.0
	var mb := 0.0
	for i in range(a.size()):
		ma += a[i]
		mb += b[i]
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in range(a.size()):
		var da := a[i] - ma
		var db := b[i] - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	return sab / maxf(sqrt(saa * sbb), 1e-9)
