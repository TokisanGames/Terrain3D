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
const WAVES_INC := "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
const DEMO_DATA := "res://demo/data"

## The shoal fixture (H, I). Two constraints, both learned the hard way.
##
## INSIDE demo/data's loaded regions: get_height() returns NAN outside them, and a fixture in the
## void fails for reasons that have nothing to do with the code.
##
## LATERALLY LEVEL, which is the one that bit. A stream takes its surface from the LOWER bank, so a
## run across a slope has its water level set by the downhill side and the bed clamp then leaves
## most rows bone dry -- the first version of this fixture ran along x = 180 and produced 0.06 m of
## water where it wanted half a metre, so H compared two dry reaches and reported a difference it
## had no business finding. Along x = 40 the ground 12 m to either side is never below the
## centreline, over the whole run, so the depth the spline asks for is the depth it gets.
const RUN_FROM := Vector3(40.0, 0.0, -100.0)
const RUN_TO := Vector3(40.0, 0.0, 100.0)
const SHOAL_ROWS := 21
## Flow speed for the standing-wave fixture, and it is fast on purpose. The stationary wavelength
## is 2*pi*v^2/g, so slow water wants a wavelength no affordable mesh can carry: 1.4 m at 1.5 m/s,
## against 10.2 m at 4. Testing the term at a speed where the resolution fade is doing the work
## would be testing the fade, and there is a separate reason to trust that one -- it is arithmetic.
const SHOAL_SPEED := 4.0
const SHOAL_SPACING := 1.0

## Physics frames between the two samples. ~1 s at 60 Hz, which at the shipped
## 1.5 m/s moves a crest about six rows -- comfortably more than the one-row
## quantisation of sampling at row positions, and well under half a wavelength so
## the correlation cannot alias onto the next crest.
const SETTLE_FRAMES := 60
## Rows either side to search when correlating. Must exceed the real shift.
const MAX_LAG := 20

var _fail := 0
var _completed := 0
const CRITERIA := 9


func _ready() -> void:
	_run()


func _run() -> void:
	print("\n=== Stream surface motion ===")
	await _a_downstream_on_every_reach()
	await _b_bank_fade()
	await _c_speed_drives_amplitude()
	await _d_flow_reverse()
	_e_constants_match_the_shader()
	await _f_chop_varies_across_the_channel()
	await _g_chop_buys_columns_not_rows()
	await _h_standing_waves_pick_their_own_reach()
	await _i_standing_waves_hold_station()

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
		"WATER_STREAM_CHOP_FREQ_MUL": Pasture3DStream.CHOP_FREQ_MUL,
		"WATER_STREAM_CHOP_AMP_MUL": Pasture3DStream.CHOP_AMP_MUL,
		"WATER_STREAM_CHOP_LAT_MUL": Pasture3DStream.CHOP_LAT_MUL,
		"WATER_STREAM_CHOP_PHASE": Pasture3DStream.CHOP_PHASE,
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
	# The scalars carry the same duplication risk as the tables and were originally
	# left as bare literals on both sides, which is the version of this that drifts
	# silently. WATER_GRAVITY lives in water_waves.gdshaderinc and is a #define
	# rather than a const, so it is read out of the other file in the other form.
	var waves_src := _read(WAVES_INC)
	var scalars := [
		["WATER_STREAM_SPEED_FLOOR", Pasture3DStream.TAU_SPEED_FLOOR, _parse_scalar(src,
			"WATER_STREAM_SPEED_FLOOR")],
		["WATER_STREAM_FROUDE_WIDTH", Pasture3DStream.FROUDE_WIDTH, _parse_scalar(src,
			"WATER_STREAM_FROUDE_WIDTH")],
		["WATER_GRAVITY", Pasture3DStream.GRAVITY, _parse_define(waves_src, "WATER_GRAVITY")],
	]
	for row in scalars:
		var agree: bool = is_finite(row[2]) and absf(row[2] - float(row[1])) < 1e-6
		checked += 1
		print("    %-26s shader %s | stream.gd %s%s" % [
				row[0], row[2], row[1], "" if agree else "   <-- DRIFTED"])
		if not agree:
			_fail += 1

	# CONTROL: the parser finds nothing for a name nobody declared, so a pass above
	# cannot be "it read no values from either side and called them equal". Both
	# parsers, because they are separate code paths and only one of them was ever
	# controlled.
	var bogus := _parse_const(src, "WATER_STREAM_NOT_A_CONST")
	var bogus_scalar := _parse_scalar(src, "WATER_STREAM_NOT_A_SCALAR")
	if bogus.is_empty() and not is_finite(bogus_scalar):
		print("    control (fabricated const and scalar names): fires — both parsed as nothing, "
				+ "%d real ones read" % checked)
	else:
		_fail += 1
		print("    !! CONTROL did not fire: the parser invented %s / %s" % [bogus, bogus_scalar])

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


# ---- F ------------------------------------------------------------------------

## THE DISCRIMINATOR IS MIRROR SYMMETRY, and it was chosen because it is exact.
##
## Every other term on this surface is a function of coordinates that are constant across the
## channel -- travel time, stationary phase, depth -- so two points at equal distance either side of
## the centreline agree on all of them. They also agree on the shore fraction, which is UNSIGNED.
## So without chop the two heights are not merely close, they are the same float.
##
## Chop is the only term that reads a SIGNED lateral offset, so it is the only thing that can break
## that, and any non-zero asymmetry is chop and cannot be anything else. Measuring "the surface
## varies across the channel" instead would have been much weaker: the bank fade does that already.
func _f_chop_varies_across_the_channel() -> void:
	print("\nF. chop breaks the mirror symmetry across the channel")
	var root := _world()
	var stream = _make_stream(root)
	stream.curve = _straight_curve()
	stream.rebuild()
	await _settle(2)

	var rows: PackedVector3Array = stream.get_centreline()
	if rows.size() < 8:
		_fail += 1
		print("    !! no channel to sample; F proves nothing")
		root.queue_free()
		_completed += 1
		return

	var with_chop := await _mirror_gap(stream)
	# CONTROL: the same points, the same clock, chop switched off at its own amplitude. The gap
	# must go to EXACTLY zero -- not small, zero -- because nothing else in the evaluator can tell
	# the two sides apart.
	stream.material = _probe_material({"chop_amplitude": 0.0})
	stream.rebuild()
	await _settle(2)
	var without_chop := await _mirror_gap(stream)

	print("    largest |h(+d) - h(-d)| across the strip: %.4f m with chop, %.6f m without" % [
			with_chop, without_chop])
	if with_chop < 0.002:
		_fail += 1
		print("    !! chop does not vary across the channel; the surface is still a rolling carpet")
	if without_chop > 1e-5:
		_fail += 1
		print("    !! CONTROL did not fire: the two banks differ with chop off, so something")
		print("       other than chop is reading a signed lateral offset and F is not isolating it")
	else:
		print("    control fires: with chop_amplitude 0 the two banks are identical to the float")
	root.queue_free()
	_completed += 1


## Largest height difference between mirrored pairs across the middle row, sampled over a second so
## a pair that happens to be in phase at one instant cannot pass this by luck.
func _mirror_gap(p_stream: Node) -> float:
	var rows: PackedVector3Array = p_stream.get_centreline()
	var r := rows.size() / 2
	var c: Vector3 = rows[r]
	var half: float = p_stream._row_half(r, false)
	var worst := 0.0
	for i in 20:
		for frac in [0.25, 0.5, 0.75]:
			var d: float = half * frac
			# The straight fixture runs along +X, so the perpendicular is Z.
			var lo: float = p_stream._wave_offset(Vector2(c.x, c.z - d))
			var hi: float = p_stream._wave_offset(Vector2(c.x, c.z + d))
			worst = maxf(worst, absf(hi - lo))
		await _settle(3)
	return worst


# ---- G ------------------------------------------------------------------------

## The cost model, stated as a testable claim: chop is paid for in COLUMNS.
##
## This is the criterion that would have caught the mistake made once already on this surface --
## shipping a wave whose vertex bill arrives in both axes at once. Rows are set by the ripple
## wavelength and columns by the chop wavelength, and turning chop off has to give the whole
## column budget back rather than leaving the mesh permanently denser.
func _g_chop_buys_columns_not_rows() -> void:
	print("\nG. chop costs columns, not rows, and costs nothing when it is off")
	var root := _world()
	var stream = _make_stream(root)
	# Automatic spacing, unlike every criterion above: the point here IS the spacing rule.
	stream.vertex_spacing = 0.0
	stream.curve = _straight_curve()
	stream.material = _probe_material({"chop_amplitude": 0.03, "chop_wavelength": 2.5})
	var on: Dictionary = stream.rebuild()
	stream.material = _probe_material({"chop_amplitude": 0.0, "chop_wavelength": 2.5})
	var off: Dictionary = stream.rebuild()

	print("    chop on : %d rows x %d cols = %d verts (rows %.2f m, cols %.2f m)" % [
			on.get("rows", 0), on.get("columns", 0), on.get("vertices", 0),
			on.get("spacing", 0.0), on.get("column_spacing", 0.0)])
	print("    chop off: %d rows x %d cols = %d verts (rows %.2f m, cols %.2f m)" % [
			off.get("rows", 0), off.get("columns", 0), off.get("vertices", 0),
			off.get("spacing", 0.0), off.get("column_spacing", 0.0)])

	if not on.get("ok", false) or not off.get("ok", false):
		_fail += 1
		print("    !! a build failed; G proves nothing")
	elif on.get("rows", 0) != off.get("rows", 0):
		_fail += 1
		print("    !! chop changed the ROW count, so it is billing in both axes")
	elif on.get("columns", 0) <= off.get("columns", 0):
		_fail += 1
		print("    !! CONTROL did not fire: chop bought no extra columns either, so the mesh")
		print("       cannot be carrying it and F is measuring something the GPU will not draw")
	else:
		print("    control fires: switching chop off returns the columns (%d -> %d) and leaves"
				% [on.get("columns", 0), off.get("columns", 0)])
		print("    the rows alone (%d both ways)" % on.get("rows", 0))
	root.queue_free()
	_completed += 1


# ---- H ------------------------------------------------------------------------

## Standing waves must choose their own reach.
##
## Nobody authors where rapids are: the Froude number does, out of the depth and speed already in
## the mesh. So the test is that the SAME river, with the same settings, has them over a shoal and
## not in the deep reach below it -- and that flattening the shoal takes them away.
##
## Isolated by amplitude: the probe material has the ripples and the chop at zero, so what
## _wave_offset returns here IS the standing term and nothing else.
func _h_standing_waves_pick_their_own_reach() -> void:
	print("\nH. standing waves appear over a shoal and nowhere else")
	var fix := _shoal_world(true)
	if fix.is_empty():
		_completed += 1
		return
	var stream = fix["stream"]
	print("    depth: %.2f m over the shoal, %.2f m in the deep reach; %d supercritical rows, "
			% [fix["shoal_depth"], fix["deep_depth"], fix["stats"].get("standing_rows", 0)]
			+ "%d of them too fine for the mesh" % fix["stats"].get("standing_suppressed", 0))

	var shoal := absf(stream._wave_offset(fix["shoal_xz"]))
	var deep := absf(stream._wave_offset(fix["deep_xz"]))
	# Not one sample: a sine crosses zero, and a probe that landed on a node would read flat water
	# over a reach that is anything but. The largest displacement along the reach is the honest
	# measure of whether a wave train is there at all.
	var shoal_peak := _peak_along(stream, fix["shoal_rows"])
	var deep_peak := _peak_along(stream, fix["deep_rows"])
	print("    standing displacement, largest along the reach: shoal %.4f m, deep %.4f m"
			% [shoal_peak, deep_peak])
	print("    (at the single probe points: shoal %.4f m, deep %.4f m)" % [shoal, deep])

	if shoal_peak < 0.005:
		_fail += 1
		print("    !! no standing waves over the shoal; the Froude gate never opened")
	if deep_peak > shoal_peak * 0.2:
		_fail += 1
		print("    !! the deep reach has them too, so depth is not what is deciding")

	# CONTROL: the identical river with the shoal dug out. Same terrain, same banks, same speed --
	# the ONLY thing that changed is the bed, and the waves have to go with it.
	var flat := _shoal_world(false)
	if flat.is_empty():
		_completed += 1
		return
	var flat_peak := _peak_along(flat["stream"], flat["shoal_rows"])
	print("    CONTROL, the same reach dug out to %.2f m: %.4f m" % [
			flat["shoal_depth"], flat_peak])
	if flat_peak > maxf(shoal_peak * 0.2, 0.002):
		_fail += 1
		print("    !! CONTROL did not fire: deepening the reach left the waves in place, so they")
		print("       are not responding to depth and H proves nothing")
	else:
		print("    control fires: dig the shoal out and the rapids go with it")
	fix["root"].queue_free()
	flat["root"].queue_free()
	_completed += 1


# ---- I ------------------------------------------------------------------------

## The defining property, and the one that separates this term from every other on the surface: a
## standing wave does not move. Its phase is a function of position and of nothing else, so a fixed
## point in the world must read the same height however long the clock runs.
func _i_standing_waves_hold_station() -> void:
	print("\nI. standing waves hold station while the water runs through them")
	var fix := _shoal_world(true)
	if fix.is_empty():
		_completed += 1
		return
	var stream = fix["stream"]
	var probe: Vector2 = fix["shoal_xz"]

	# THE PRECONDITION, and it is not a formality: "this height did not change" is also true of
	# water that is perfectly flat, which is what a Froude gate stuck shut would give. Establish
	# that there is a wave standing at this point before claiming it stands still.
	var present := absf(stream._wave_offset(probe))
	print("    standing displacement at the probe: %.4f m" % present)
	if present < 0.005:
		_fail += 1
		print("    !! there is no standing wave at the probe, so 'it did not move' is a statement")
		print("       about flat water and I proves nothing")

	var still := await _swing(stream, probe)
	# CONTROL: the same point, the same fixture, with the ripples switched back on. If THAT does not
	# move either, the fixture's clock is not running and "it did not move" was never a measurement.
	stream.material = _probe_material({"chop_amplitude": 0.0})
	stream.rebuild()
	await _settle(2)
	var moving := await _swing(stream, probe)

	print("    peak-to-peak over 1 s at a fixed point: %.6f m standing only, %.4f m with ripples"
			% [still, moving])
	if still > 1e-5:
		_fail += 1
		print("    !! the standing waves move; their phase is reading the clock somewhere")
	if moving < 0.005:
		_fail += 1
		print("    !! CONTROL did not fire: nothing moved at this point even with ripples on,")
		print("       so I measured a stopped clock rather than a stationary wave")
	else:
		print("    control fires: the ripples at the same point move %.4f m, so the clock runs"
				% moving)
	fix["root"].queue_free()
	_completed += 1


# ---- the shoal fixture ---------------------------------------------------------

## A river on the demo terrain whose BED rises into a shoal halfway down, or does not.
##
## The shoal is made by lifting the SPLINE, not by editing terrain. The surface of a stream comes
## from its banks and the bed comes from the spline, so raising the spline thins the water without
## moving the waterline, the width, or anything else the other criteria depend on. That makes the
## control -- p_shoal false -- a one-variable change in the truest sense available here.
func _shoal_world(p_shoal: bool) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	var manager = ClassDB.instantiate("Pasture3DPoolManager")
	manager.name = "Pasture3DPoolManager"
	root.add_child(manager)

	var stream = load(STREAM_SCRIPT).new()
	# Ripples and chop at zero, so _wave_offset returns the standing term alone.
	stream.material = _probe_material({"ripple_amplitude": 0.0, "chop_amplitude": 0.0})
	stream.wave_profile = &"river_flow"
	stream.underwater_enabled = false
	stream.vertex_spacing = SHOAL_SPACING
	stream.flow_speed = SHOAL_SPEED
	# Uniform speed down the channel: a slope-driven speed change would move the Froude number for
	# a reason other than the one under test.
	stream.flow_slope_gain = 0.0
	stream.bank_height = 0.5
	stream.bank_search_width = 12.0
	stream.manager = manager
	root.add_child(stream)

	var c := Curve3D.new()
	for i in SHOAL_ROWS:
		var t := float(i) / float(SHOAL_ROWS - 1)
		var p: Vector3 = RUN_FROM.lerp(RUN_TO, t)
		var g: float = terrain.data.get_height(p)
		if not is_finite(g):
			_fail += 1
			print("    !! no terrain at %s; the shoal fixture is outside demo/data" % p)
			root.queue_free()
			return {}
		# Deep for the first half. Then, with a shoal, the bed climbs to just under the surface and
		# stays there; without one it carries straight on. Ramped over four rows rather than
		# stepped: a cliff in the bed would be smoothed by bank_smoothing into something neither
		# case actually describes.
		var below := 6.0
		if p_shoal:
			below = lerpf(6.0, 0.8, clampf((t - 0.4) / 0.2, 0.0, 1.0))
		p.y = g - below
		c.add_point(p)
	stream.curve = c

	var stats: Dictionary = stream.rebuild()
	if not stats.get("ok", false):
		_fail += 1
		print("    !! the shoal fixture did not build (%s)" % stats.get("reason", ""))
		root.queue_free()
		return {}

	var rows: PackedVector3Array = stream.get_centreline()
	var shoal_rows := PackedInt32Array()
	var deep_rows := PackedInt32Array()
	for r in rows.size():
		var t := float(r) / float(maxi(rows.size() - 1, 1))
		if t > 0.7:
			shoal_rows.append(r)
		elif t < 0.3:
			deep_rows.append(r)
	# The probe point is the row with the LARGEST standing displacement, not the middle one. A
	# standing wave is a sine and a sine has nodes: a probe that landed on one would read flat water
	# over a reach full of rapids, and criterion I -- which asserts a height does not change --
	# would then pass on water that was never there. Picking the crest makes I's subject exist.
	return {
		"root": root, "stream": stream, "stats": stats,
		"shoal_rows": shoal_rows, "deep_rows": deep_rows,
		"shoal_xz": _row_xz(stream, _crest_row(stream, shoal_rows)),
		"deep_xz": _row_xz(stream, deep_rows[deep_rows.size() / 2]),
		"shoal_depth": _mean_depth(stream, shoal_rows),
		"deep_depth": _mean_depth(stream, deep_rows),
	}


## The row of a reach carrying the largest wave offset right now.
func _crest_row(p_stream: Node, p_rows: PackedInt32Array) -> int:
	var best: int = p_rows[0]
	var best_h := -1.0
	for r in p_rows:
		var h: float = absf(p_stream._wave_offset(_row_xz(p_stream, r)))
		if h > best_h:
			best_h = h
			best = r
	return best


func _row_xz(p_stream: Node, p_row: int) -> Vector2:
	var rows: PackedVector3Array = p_stream.get_centreline()
	var w: Vector3 = p_stream.global_transform * rows[p_row]
	return Vector2(w.x, w.z)


func _mean_depth(p_stream: Node, p_rows: PackedInt32Array) -> float:
	var total := 0.0
	for r in p_rows:
		total += p_stream.get_water_depth(_row_xz(p_stream, r))
	return total / maxf(float(p_rows.size()), 1.0)


## Largest absolute wave offset anywhere along a reach, at one instant.
func _peak_along(p_stream: Node, p_rows: PackedInt32Array) -> float:
	var peak := 0.0
	for r in p_rows:
		peak = maxf(peak, absf(p_stream._wave_offset(_row_xz(p_stream, r))))
	return peak


## The river material with some parameters overridden, as an independent copy.
##
## A copy and not the loaded resource: load() is cached, so setting a parameter on it would leak
## into every criterion that ran afterwards -- and the one that noticed would be whichever ran
## last, which is the worst possible place for that to surface.
func _probe_material(p_overrides: Dictionary) -> ShaderMaterial:
	var m: ShaderMaterial = load(RIVER_MAT).duplicate()
	for k in p_overrides:
		m.set_shader_parameter(k, p_overrides[k])
	return m


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


## The float out of a `const float NAME = 0.35;` declaration, or NAN when there is none.
func _parse_scalar(p_src: String, p_name: String) -> float:
	var re := RegEx.new()
	# The `[^\[]` guard keeps this off the array declarations: without it,
	# `const float WATER_STREAM_PHASE[2] = {0.0, ...}` would match a request for a
	# scalar of that name and hand back its first element.
	re.compile("const\\s+float\\s+" + p_name + "\\s*=\\s*([-+0-9.eE]+)\\s*;")
	var m := re.search(p_src)
	return m.get_string(1).to_float() if m != null else NAN


## The float out of a `#define NAME 9.81`, or NAN. A separate form because the
## shader's gravity is a preprocessor define and not a const.
func _parse_define(p_src: String, p_name: String) -> float:
	var re := RegEx.new()
	re.compile("#define\\s+" + p_name + "\\s+([-+0-9.eE]+)")
	var m := re.search(p_src)
	return m.get_string(1).to_float() if m != null else NAN


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
