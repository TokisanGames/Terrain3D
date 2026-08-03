# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# River motion: crests that run downstream on every reach. Spec §10.2.
#
# THE BUG THIS GATES. A Gerstner wave carries one world-space heading. A river
# bends. So on any reach heading against that heading, the crests travel
# UPSTREAM. No amplitude, steepness or direction setting fixes it -- the model has
# one direction and the river has many -- and the only setting that hides it is
# amplitude 0, which is what sculpting_2.tscn shipped and why this work exists.
#
# Criterion A's CONTROL IS THAT BUG, reproduced: the same geometry, the same
# clock, evaluated through the manager's Gerstner table exactly as
# Pasture3DWaterBody._wave_offset still does for a lake. It must show upstream
# travel on the returning leg. If it does not, the fixture is not asking the
# question and A proves nothing.
#
# The fixture is a U: one leg running +X, one running -X. Whatever heading the
# wave table happens to carry, one of those two opposes it.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/StreamRippleCheck.tscn
extends Node

const STREAM_SCRIPT := "res://addons/pasture_3d/connectors/stream.gd"
const RIVER_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_river.tres"
const STREAM_INC := "res://addons/pasture_3d/extras/shaders/water/water_stream.gdshaderinc"

## Physics frames between the two samples. ~1 s at 60 Hz, which at the shipped
## 1.5 m/s moves a crest about six rows -- comfortably more than the one-row
## quantisation of sampling at row positions, and well under half a wavelength so
## the correlation cannot alias onto the next crest.
const SETTLE_FRAMES := 60
## Rows either side to search when correlating. Must exceed the real shift.
const MAX_LAG := 20

var _fail := 0
var _completed := 0
const CRITERIA := 5


func _ready() -> void:
	_run()


func _run() -> void:
	print("\n=== Stream ripples ===")
	await _a_downstream_on_every_reach()
	await _b_bank_fade()
	await _c_speed_drives_amplitude()
	await _d_flow_reverse()
	_e_constants_match_the_shader()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	print("=== %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A ------------------------------------------------------------------------

func _a_downstream_on_every_reach() -> void:
	print("\nA. crests run downstream on BOTH legs of a U")
	var root := _world()
	var stream = _make_stream(root)
	stream.curve = _u_curve()
	stream.rebuild()
	await _settle(2)

	var legs := _legs(stream)
	if legs["out"].is_empty() or legs["back"].is_empty():
		_fail += 1
		print("    !! the fixture produced no usable legs (%d rows); A proves nothing"
				% stream.get_centreline().size())
		root.queue_free()
		_completed += 1
		return
	print("    rows: %d out (+X), %d back (-X), spacing %.2f m" % [
			legs["out"].size(), legs["back"].size(), stream.get_build_stats().get("spacing", 0.0)])

	var before := {}
	for name in ["out", "back"]:
		before[name] = _heights(stream, legs[name])
	var gerstner_before := {}
	for name in ["out", "back"]:
		gerstner_before[name] = _gerstner(stream, legs[name])
	await _settle(SETTLE_FRAMES)

	var ok := true
	for name in ["out", "back"]:
		var lag := _lag(before[name], _heights(stream, legs[name]))
		print("    %-5s leg: ripple crests moved %+d rows (downstream is positive)" % [name, lag])
		if lag <= 0:
			ok = false
	if not ok:
		_fail += 1
		print("    !! crests do not run downstream on every reach")

	# CONTROL: the Gerstner path on the identical points and the identical clock.
	var upstream_legs := PackedStringArray()
	for name in ["out", "back"]:
		var glag := _lag(gerstner_before[name], _gerstner(stream, legs[name]))
		print("    CONTROL %-5s leg, the wave table: %+d rows" % [name, glag])
		if glag < 0:
			upstream_legs.append(name)
	if upstream_legs.is_empty():
		_fail += 1
		print("    !! CONTROL did not fire: the wave table ran downstream on both legs too,")
		print("       so this fixture never reproduced the bug and A is unproven")
	else:
		print("    control fires: the wave table runs UPSTREAM on the %s leg — the bug"
				% ", ".join(upstream_legs))
	root.queue_free()
	_completed += 1


# ---- B ------------------------------------------------------------------------

func _b_bank_fade() -> void:
	print("\nB. ripples fade to nothing at the waterline")
	var root := _world()
	var stream = _make_stream(root)
	stream.curve = _straight_curve()
	stream.rebuild()
	await _settle(2)

	var rows: PackedVector3Array = stream.get_centreline()
	if rows.size() < 8:
		_fail += 1
		print("    !! no channel to sample; B proves nothing")
		root.queue_free()
		_completed += 1
		return
	var r := rows.size() / 2
	var c: Vector3 = rows[r]
	var half: float = stream._row_half(r, false)
	# Across the strip: mid-channel, and just inside the mesh edge. The perpendicular
	# is +Z here because the straight fixture runs along +X.
	var mid := Vector2(c.x, c.z)
	var edge := Vector2(c.x, c.z + half * 0.97)

	var swing_mid := await _swing(stream, mid)
	var swing_edge := await _swing(stream, edge)
	print("    peak-to-peak over 1 s: mid-channel %.4f m, at the waterline %.4f m" % [
			swing_mid, swing_edge])
	# CONTROL FIRST, because "the edge is flat" is trivially true of water that is
	# flat everywhere -- which is exactly what a broken amplitude gate would give.
	if swing_mid < 0.005:
		_fail += 1
		print("    !! CONTROL did not fire: mid-channel is flat too, so B measured nothing")
	elif swing_edge > swing_mid * 0.1:
		_fail += 1
		print("    !! the waterline still moves %.0f%% as much as mid-channel"
				% (100.0 * swing_edge / swing_mid))
	root.queue_free()
	_completed += 1


# ---- C ------------------------------------------------------------------------

func _c_speed_drives_amplitude() -> void:
	print("\nC. faster water gets bigger ripples; still water is glass")
	var root := _world()
	var stream = _make_stream(root)
	stream.curve = _straight_curve()
	stream.rebuild()
	await _settle(2)
	var probe := _mid_probe(stream)

	var readings := {}
	for speed in [0.0, 0.5, 3.0]:
		stream.flow_speed = speed
		stream.rebuild()
		await _settle(2)
		readings[speed] = await _swing(stream, probe)
		print("    flow_speed %.1f m/s -> peak-to-peak %.4f m" % [speed, readings[speed]])

	if readings[3.0] <= readings[0.5]:
		_fail += 1
		print("    !! amplitude does not grow with speed")
	# CONTROL: the gate is the SPEED and not merely "some setting changes it".
	if readings[0.0] > 0.001:
		_fail += 1
		print("    !! CONTROL did not fire: still water still ripples")
	else:
		print("    control fires: at flow_speed 0 the surface is flat")
	root.queue_free()
	_completed += 1


# ---- D ------------------------------------------------------------------------

func _d_flow_reverse() -> void:
	print("\nD. flow_reverse turns the crests around")
	var root := _world()
	var stream = _make_stream(root)
	stream.curve = _straight_curve()
	stream.flow_reverse = true
	stream.rebuild()
	await _settle(2)

	var legs := _legs(stream)
	var run: PackedInt32Array = legs["out"]
	if run.is_empty():
		_fail += 1
		print("    !! no usable run; D proves nothing")
		root.queue_free()
		_completed += 1
		return
	var before := _heights(stream, run)
	await _settle(SETTLE_FRAMES)
	var lag := _lag(before, _heights(stream, run))
	print("    reversed: crests moved %+d rows along the spline (spline order is positive)" % lag)
	if lag >= 0:
		_fail += 1
		print("    !! reversing the flow did not reverse the ripples")
	else:
		print("    -> they run against spline order, which is what reversed means")
	root.queue_free()
	_completed += 1


# ---- E ------------------------------------------------------------------------

func _e_constants_match_the_shader() -> void:
	print("\nE. the octave tables in stream.gd match water_stream.gdshaderinc")
	# The octaves are compile-time consts in GLSL, so they cannot be uploaded and
	# the GDScript transcription has to hold its own copy. A duplicate is only
	# honest if something fails when the two drift, which is this.
	var src := _read(STREAM_INC)
	if src.is_empty():
		_fail += 1
		print("    !! could not read %s; E proves nothing" % STREAM_INC)
		_completed += 1
		return
	var script_consts := {
		"WATER_STREAM_FREQ_MUL": Pasture3DStream.RIPPLE_FREQ_MUL,
		"WATER_STREAM_AMP_MUL": Pasture3DStream.RIPPLE_AMP_MUL,
		"WATER_STREAM_PHASE": Pasture3DStream.RIPPLE_PHASE,
	}
	var checked := 0
	for key in script_consts:
		var shader_vals := _parse_const(src, key)
		var gd_vals: Array = script_consts[key]
		var agree := shader_vals.size() == gd_vals.size() and not shader_vals.is_empty()
		if agree:
			for i in shader_vals.size():
				if absf(shader_vals[i] - float(gd_vals[i])) > 1e-6:
					agree = false
		checked += 1
		print("    %-24s shader %s | stream.gd %s%s" % [
				key, shader_vals, gd_vals, "" if agree else "   <-- DRIFTED"])
		if not agree:
			_fail += 1
	# CONTROL: the parser finds nothing for a name nobody declared, so a pass above
	# cannot be "it read no values from either side and called them equal".
	var bogus := _parse_const(src, "WATER_STREAM_NOT_A_CONST")
	if bogus.is_empty():
		print("    control (a fabricated const name): fires — parsed as empty, %d real ones read"
				% checked)
	else:
		_fail += 1
		print("    !! CONTROL did not fire: the parser invented %s" % [bogus])

	# The other half of the no-duplicate-defaults claim: an unset parameter has to
	# come back as the SHADER's declared default, not as a GDScript fallback.
	var mat: ShaderMaterial = load(RIVER_MAT)
	var probe := ShaderMaterial.new()
	probe.shader = mat.shader
	var body = load(STREAM_SCRIPT).new()
	body.material = probe
	var declared = body.shader_param(&"ripple_amplitude", -999.0)
	print("    an unset ripple_amplitude reads back as %s (the shader's default, not -999)"
			% declared)
	if typeof(declared) not in [TYPE_FLOAT, TYPE_INT] or is_equal_approx(float(declared), -999.0):
		_fail += 1
		print("    !! shader_param fell through to its fallback; the defaults are duplicated")
	body.free()
	_completed += 1


# ---- measurement ---------------------------------------------------------------

## Row indices of the outbound (+X) and returning (-X) reaches, skipping the bend.
func _legs(p_stream: Node) -> Dictionary:
	var rows: PackedVector3Array = p_stream.get_centreline()
	var out := PackedInt32Array()
	var back := PackedInt32Array()
	for r in rows.size():
		var t: Vector2 = p_stream._ribbon_tangent(rows, r)
		# Well clear of the bend, where the tangent is turning and neighbouring rows
		# are not collinear -- a correlation across it would be measuring the corner.
		if t.x > 0.98:
			out.append(r)
		elif t.x < -0.98:
			back.append(r)
	return {"out": out, "back": back}


## Wave offset (still surface removed) at each row's own XZ, in row order.
func _heights(p_stream: Node, p_rows: PackedInt32Array) -> PackedFloat32Array:
	var rows: PackedVector3Array = p_stream.get_centreline()
	var out := PackedFloat32Array()
	for r in p_rows:
		var w: Vector3 = p_stream.global_transform * rows[r]
		out.append(p_stream._wave_offset(Vector2(w.x, w.z)))
	return out


## The same points through the manager's Gerstner table -- the pre-fix behaviour,
## and criterion A's control. This is Pasture3DWaterBody._wave_offset verbatim.
func _gerstner(p_stream: Node, p_rows: PackedInt32Array) -> PackedFloat32Array:
	var rows: PackedVector3Array = p_stream.get_centreline()
	var m = p_stream._resolve_manager()
	var out := PackedFloat32Array()
	if m == null or not m.has_method("solve_domain"):
		return out
	var origin: Vector3 = p_stream.global_position
	for r in p_rows:
		var w: Vector3 = p_stream.global_transform * rows[r]
		var target := Vector2(w.x, w.z) - Vector2(origin.x, origin.z)
		out.append(m.evaluate_height(&"river_flow", m.solve_domain(&"river_flow", target)))
	return out


## Shift in rows that best carries p_before onto p_after. Positive = the pattern
## moved toward higher row indices, which is downstream.
##
## Plain sum-of-squares over the overlap rather than a normalised correlation: the
## two samples are the same signal one second apart, so their scale is identical
## and normalising would only hide an amplitude that had collapsed.
func _lag(p_before: PackedFloat32Array, p_after: PackedFloat32Array) -> int:
	var n := mini(p_before.size(), p_after.size())
	if n < MAX_LAG * 3:
		return 0
	var best := 0
	var best_err := INF
	for lag in range(-MAX_LAG, MAX_LAG + 1):
		var err := 0.0
		var count := 0
		for i in range(MAX_LAG, n - MAX_LAG):
			var d: float = p_after[i] - p_before[i - lag]
			err += d * d
			count += 1
		err /= maxf(float(count), 1.0)
		if err < best_err:
			best_err = err
			best = lag
	return best


## Peak-to-peak of the wave offset at one point over a second of clock.
func _swing(p_stream: Node, p_xz: Vector2) -> float:
	var lo := INF
	var hi := -INF
	for i in 30:
		var h: float = p_stream._wave_offset(p_xz)
		lo = minf(lo, h)
		hi = maxf(hi, h)
		await _settle(2)
	return hi - lo


func _mid_probe(p_stream: Node) -> Vector2:
	var rows: PackedVector3Array = p_stream.get_centreline()
	var c: Vector3 = rows[rows.size() / 2]
	var w: Vector3 = p_stream.global_transform * c
	return Vector2(w.x, w.z)


# ---- fixtures ------------------------------------------------------------------

func _world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var m = ClassDB.instantiate("Pasture3DPoolManager")
	m.name = "Pasture3DPoolManager"
	root.add_child(m)
	return root


func _make_stream(p_root: Node3D) -> Node:
	var n: Node = load(STREAM_SCRIPT).new()
	n.material = load(RIVER_MAT)
	n.wave_profile = &"river_flow"
	n.underwater_enabled = false
	# Explicit, so every criterion samples the same lattice and a change to the
	# automatic-spacing rule cannot silently re-scale the lags reported here.
	n.vertex_spacing = 0.25
	n.flow_speed = 1.5
	p_root.add_child(n)
	return n


## A U: 60 m out along +X, a bend, 60 m back along -X. Descending throughout, so
## the reaches differ in speed and the fixture is not accidentally uniform.
func _u_curve() -> Curve3D:
	var c := Curve3D.new()
	var pts: Array[Vector3] = []
	for i in 13:
		pts.append(Vector3(-60.0 + i * 10.0, -i * 0.4, -20.0))
	for i in 5:
		var a := lerpf(-PI * 0.5, PI * 0.5, float(i) / 4.0)
		pts.append(Vector3(60.0 + cos(a) * 20.0, -5.2 - i * 0.4, -20.0 + (sin(a) + 1.0) * 20.0))
	for i in 13:
		pts.append(Vector3(60.0 - i * 10.0, -7.2 - i * 0.4, 20.0))
	for p in pts:
		c.add_point(p)
	return c


func _straight_curve() -> Curve3D:
	var c := Curve3D.new()
	for i in 17:
		c.add_point(Vector3(-60.0 + i * 7.5, -i * 0.3, 0.0))
	return c


func _settle(p_frames: int) -> void:
	for i in p_frames:
		await get_tree().physics_frame


func _read(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


## The floats out of a `const float NAME[n] = {a, b, ...};` declaration.
func _parse_const(p_src: String, p_name: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var at := p_src.find(p_name)
	if at < 0:
		return out
	var open_brace := p_src.find("{", at)
	var close_brace := p_src.find("}", open_brace)
	if open_brace < 0 or close_brace < 0:
		return out
	for piece in p_src.substr(open_brace + 1, close_brace - open_brace - 1).split(","):
		var s := piece.strip_edges()
		if s.is_valid_float():
			out.append(s.to_float())
	return out
