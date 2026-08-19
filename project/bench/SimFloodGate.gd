# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate BI — the monotone bucket queue floods identically to the binary heap it replaces.
# See PASTURE3D_SIM_NODE_SPEC.md §11.
#
# §11's profiling pass put the priority-flood at 61% of the whole solve, so the heap was replaced with a
# radix-style monotone bucket queue. THE ONLY THING THAT MAKES THAT SAFE is that it pops in exactly the
# order the heap did, and the hard half of that is TIES: two cells can share a `zf_route` and still carry
# different `zf_true`, so whichever is processed first decides a shared neighbour's lake depth. The
# argument that insertion order survives bucketing is written out in pasture_3d_erosion.cpp; this gate is
# what stops it from being merely an argument.
#
# `legacy_flood` runs the old heap. It exists for this gate and is not exposed on the node — it is slower
# and identical, so there is nothing for a user to choose.
#
# NOTHING IS SAVED. The fixtures are arrays, not bakes.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimFloodGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSim flood queue (spec §11, gate BI) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("erode_heightfield"):
		_fail += 1
		print("!! this build has no solver")
		_done()
		return

	_gate_bi()
	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM FLOOD PASS" if _fail == 0 else "SIM FLOOD FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BI: bitwise identical to the heap it replaces --------------------------------------------------
#
# Five fixtures, chosen for what each can break rather than for coverage's sake:
#   real        — demo terrain, the case that actually ships;
#   quantised   — the same terrain rounded to 0.5 m, so exact elevation TIES are everywhere. This is the
#                 fixture that can catch a broken tie-break; the others mostly cannot;
#   plateau+pit — a dead-flat plane with one hole: every boundary cell enters the queue at one elevation
#                 and the whole flood is one enormous tie;
#   nodata      — NaN holes, which are pushed at `zmin - 1` and so all share a key AND are boundary;
#   bowl        — a smooth depression with no ties at all, the control on the fixtures themselves.
func _gate_bi() -> void:
	print("[BI] the bucket queue floods bitwise identically to the binary heap:")
	var fixtures := [
		["real demo terrain", _real_grid(Vector3(500.0, 0.0, 500.0), 256)],
		["the same, quantised to 0.5 m (ties everywhere)", _quantise(_real_grid(Vector3(500.0, 0.0, 500.0), 256), 0.5)],
		["flat plateau with one pit (one huge tie)", _plateau_pit(192)],
		["terrain with NaN no-data holes", _holes(_real_grid(Vector3(300.0, 0.0, 300.0), 192), 192)],
		["a smooth bowl (no ties)", _bowl(192)],
	]
	var checked := 0
	for f in fixtures:
		var label: String = f[0]
		var z: PackedFloat32Array = f[1]
		var g := int(sqrt(float(z.size())))
		var params := {"gw": g, "gh": g, "cell_size": 1.0, "time_step": 1.0, "iterations": 12,
				"erosion_rate": 0.15, "area_exponent": 0.45, "diffusion": 0.15, "want_diagnostics": true}

		var fast: Dictionary = _data.erode_heightfield(z, params, PackedFloat32Array())
		var legacy_params: Dictionary = params.duplicate()
		legacy_params["legacy_flood"] = true
		var slow: Dictionary = _data.erode_heightfield(z, legacy_params, PackedFloat32Array())
		if not bool(fast.get("ok", false)) or not bool(slow.get("ok", false)):
			_fail += 1
			print("    !! %s did not solve" % label)
			continue

		# PRECONDITION. A fixture with nothing to fill would agree on any two implementations, and a
		# fixture the solver did not move would agree on the untouched input. Both are reported, not
		# assumed, because either one silently turns this gate into a comparison of two no-ops.
		var ponded := _count_over(slow["lake_depth"], 1.0e-6)
		var moved := _max_abs_diff(z, slow["z"])
		print("    %s — %dx%d, %d ponded cell(s), ground moved %.3f m" % [label, g, g, ponded, moved])
		if ponded == 0:
			_fail += 1
			print("        !! nothing ponded here: the depression fill did no work, so BI proves nothing")
			continue
		if moved <= 0.0:
			_fail += 1
			print("        !! the solve moved nothing: this fixture cannot tell the two floods apart")
			continue

		var bad := PackedStringArray()
		for k in ["z", "flow", "lake_depth"]:
			if not _same_f32(fast[k], slow[k]):
				bad.append("%s (first difference at cell %d)" % [k, _first_diff_f32(fast[k], slow[k])])
		for k in ["receiver", "stack"]:
			if Array(fast[k]) != Array(slow[k]):
				bad.append(k)
		if bad.is_empty():
			print("        bitwise identical: z, flow, lake_depth, receiver, stack")
			checked += 1
		else:
			_fail += 1
			print("        !! DIFFERS in %s" % ", ".join(bad))

	# CONTROL. The comparison above only means something if it CAN see a difference. Turning the fill off
	# must change every one of those fields on the same fixture — if it does not, the comparison is
	# reading something that does not depend on the flood and every PASS above is vacuous.
	var z: PackedFloat32Array = _quantise(_real_grid(Vector3(500.0, 0.0, 500.0), 256), 0.5)
	var g := int(sqrt(float(z.size())))
	var base := {"gw": g, "gh": g, "cell_size": 1.0, "time_step": 1.0, "iterations": 12,
			"erosion_rate": 0.15, "area_exponent": 0.45, "diffusion": 0.15, "want_diagnostics": true}
	var filled: Dictionary = _data.erode_heightfield(z, base, PackedFloat32Array())
	var unfilled_params: Dictionary = base.duplicate()
	unfilled_params["fill_depressions"] = false
	var unfilled: Dictionary = _data.erode_heightfield(z, unfilled_params, PackedFloat32Array())
	var seen := PackedStringArray()
	for k in ["z", "flow", "lake_depth"]:
		if not _same_f32(filled[k], unfilled[k]):
			seen.append(k)
	for k in ["receiver", "stack"]:
		if Array(filled[k]) != Array(unfilled[k]):
			seen.append(k)
	print("    CONTROL fill_depressions = false changes: %s (want all five)" % (
			", ".join(seen) if not seen.is_empty() else "NOTHING"))
	if seen.size() < 5:
		_fail += 1
		print("    !! the comparison cannot see a flood change in every field; BI is partly vacuous")
	print("    %d of %d fixtures compared" % [checked, fixtures.size()])


# --- fixtures --------------------------------------------------------------------------------------

func _real_grid(p_at: Vector3, p_g: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_g * p_g)
	var half := float(p_g) * 0.5
	for iz in range(p_g):
		for ix in range(p_g):
			out[iz * p_g + ix] = _data.get_height(
					Vector3(p_at.x - half + float(ix), 0.0, p_at.z - half + float(iz)))
	return out


## Rounded to a step, so exactly equal elevations are everywhere — the tie-break's stress case.
func _quantise(p_z: PackedFloat32Array, p_step: float) -> PackedFloat32Array:
	var out := p_z.duplicate()
	for i in range(out.size()):
		if is_finite(out[i]):
			out[i] = roundf(out[i] / p_step) * p_step
	return out


## Dead flat with a single square hole: every boundary cell enters at one elevation, so the entire flood
## is one tie from the first pop to the last.
func _plateau_pit(p_g: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_g * p_g)
	out.fill(100.0)
	var lo := p_g / 3
	var hi := p_g * 2 / 3
	for iz in range(lo, hi):
		for ix in range(lo, hi):
			out[iz * p_g + ix] = 88.0
	return out


## NaN holes. Those cells become boundary at `zmin - 1`, so they all share one key and all enter the
## queue in the seeding loop — a second, different tie population.
func _holes(p_z: PackedFloat32Array, p_g: int) -> PackedFloat32Array:
	var out := p_z.duplicate()
	for iz in range(20, 60):
		for ix in range(20, 60):
			out[iz * p_g + ix] = NAN
	for iz in range(120, 150):
		for ix in range(90, 140):
			out[iz * p_g + ix] = NAN
	return out


## A smooth paraboloid basin: strictly varying, so essentially no ties. The control on the fixtures —
## if this one passed and the quantised one failed, the tie-break would be the thing at fault.
func _bowl(p_g: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_g * p_g)
	var c := float(p_g - 1) * 0.5
	for iz in range(p_g):
		for ix in range(p_g):
			var dx := (float(ix) - c) / c
			var dz := (float(iz) - c) / c
			out[iz * p_g + ix] = 50.0 + 30.0 * (dx * dx + dz * dz) + 0.37 * sin(float(ix) * 0.31) \
					+ 0.29 * cos(float(iz) * 0.27)
	return out


# --- helpers ---------------------------------------------------------------------------------------

## Bitwise, not approximate: compared as raw bytes, so a NaN equals a NaN and +0 does not equal -0.
func _same_f32(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> bool:
	if p_a.size() != p_b.size():
		return false
	return p_a.to_byte_array() == p_b.to_byte_array()


func _first_diff_f32(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> int:
	if p_a.size() != p_b.size():
		return -1
	var ba := p_a.to_byte_array()
	var bb := p_b.to_byte_array()
	for i in range(p_a.size()):
		if ba.decode_u32(i * 4) != bb.decode_u32(i * 4):
			return i
	return -1


func _count_over(p_a: PackedFloat32Array, p_t: float) -> int:
	var n := 0
	for v in p_a:
		if is_finite(v) and v > p_t:
			n += 1
	return n


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
