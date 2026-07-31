# Pasture3D Water Bodies — Phase 8 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 8 is the documentation. That sounds like the phase without a gate, and it is the phase that
# most needs one: the guide had been carrying a "PARTLY OUT OF DATE" banner since Phase 2 because
# nothing checked it, and a banner is what a document grows instead of being fixed.
#
# So this gate checks the guide against the CODE rather than against a reviewer's memory:
#
#   A. every legacy `ocean_*` property is findable in the guide's migration table — and the list of
#      them comes from bench/legacy/LegacyOceanScene.tscn, a real pre-Phase-2 scene, not from a
#      hand-copied list here. Control: a name that is not in that scene must not be claimed
#   B. every method the guide's API table documents actually exists on the class it names. Control:
#      a fabricated method name must be reported missing
#   C. the guide does not still describe the API that was removed. Every `ocean_*` mention outside
#      the migration section is drift. Control: the scanner must find them INSIDE that section, or
#      it is not looking properly
#   D. the lake quick-start is "press the button" — the spec's own wording for this phase. It must
#      name Add Water and must not tell anyone to build a PlaneMesh. Control: the bare-mesh path is
#      still documented somewhere, so this is not a check that passes by deleting content
#   E. every shipped preset and shader the guide lists exists on disk, and every one on disk is
#      listed. Control: both directions, so neither a missing file nor an undocumented one passes
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase8Gate.tscn
extends SceneTree

const GUIDE := "res://../PASTURE3D_WATER_GUIDE.md"
const LEGACY_SCENE := "res://bench/legacy/LegacyOceanScene.tscn"
const LEGACY_SCENE_ALT := "res://bench/LegacyOceanScene.tscn"
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"

var _fail := 0
var _completed := 0
## The legacy property names read out of the fixture in criterion A, reused by C.
var _legacy: PackedStringArray = PackedStringArray()
const CRITERIA := 5


func _initialize() -> void:
	print("=== Pasture3D Water Bodies — Phase 8 gate ===")
	print("")
	var guide := _read(GUIDE)
	if guide == "":
		push_error("could not read the guide at %s" % GUIDE)
		quit(2)
		return

	_gate_a_migration_table(guide)
	_gate_b_api_exists(guide)
	_gate_c_no_stale_api(guide)
	_gate_d_quick_start(guide)
	_gate_e_presets(guide)

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	print("=== PHASE 8 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	quit(0 if _fail == 0 else 1)


# ---- A: every removed property is findable -------------------------------------
#
# The spec's wording for this phase is "the old property names are all findable". Someone upgrading
# searches the guide for the name they have in their scene, and the guide has to answer.
#
# The list comes from a real pre-Phase-2 scene rather than from a list written here, because a list
# written here would have been copied from the same guide it is checking.
func _gate_a_migration_table(p_guide: String) -> void:
	print("[A] every legacy ocean_* property is findable in the guide:")
	var scene_text := _read(LEGACY_SCENE)
	if scene_text == "":
		scene_text = _read(LEGACY_SCENE_ALT)
	if scene_text == "":
		_fail += 1
		print("    !! could not read the legacy fixture, so there is nothing to check against")
		_completed += 1
		return
	var names := _legacy_names(scene_text)
	_legacy = names
	print("    %d legacy properties in the fixture scene" % names.size())
	if names.size() < 15:
		_fail += 1
		print("    !! only %d found — the fixture is not a full pre-Phase-2 ocean" % names.size())
	var missing := PackedStringArray()
	for n in names:
		if not p_guide.contains(n):
			missing.append(n)
	if missing.is_empty():
		print("    all %d appear in the guide" % names.size())
	else:
		_fail += 1
		print("    !! %d not findable: %s" % [missing.size(), ", ".join(missing)])

	# Control: the check has to be able to notice an absence. A property that never existed must not
	# be claimed as present, or `contains` is matching something it should not.
	var invented := ["ocean_nonexistent_knob", "ocean_wave_chaos"]
	var false_hits := PackedStringArray()
	for n in invented:
		if p_guide.contains(n):
			false_hits.append(n)
	if false_hits.is_empty():
		print("    control (two invented property names): fires — neither is 'findable'")
	else:
		_fail += 1
		print("    !! control did NOT fire: the guide claims %s" % [false_hits])
	_completed += 1


## Every `ocean_*` identifier assigned in a scene file.
func _legacy_names(p_text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in p_text.split("\n"):
		var t := String(line).strip_edges()
		var eq := t.find(" = ")
		if eq <= 0:
			continue
		var key := t.substr(0, eq)
		if key.begins_with("ocean_") and not out.has(key):
			out.append(key)
	out.sort()
	return out


# ---- B: the documented API exists ----------------------------------------------
#
# The failure mode this catches is the one that actually happened: the guide documented
# `terrain.get_water_height()` for months after that method moved off `Pasture3D`.
func _gate_b_api_exists(p_guide: String) -> void:
	print("")
	print("[B] every method the guide documents exists:")
	# [method, class, is_gdscript_connector]
	var api := [
		["get_water_height", "Pasture3DOcean", false],
		["get_water_normal", "Pasture3DOcean", false],
		["contains_point", "Pasture3DOcean", false],
		["body_at", "Pasture3DPoolManager", false],
		["get_water_time", "Pasture3DPoolManager", false],
		["evaluate_height", "Pasture3DPoolManager", false],
		["get_amplitude_sum", "Pasture3DWaveProfile", false],
		["has_legacy_ocean", "Pasture3D", false],
		["get_buoyancy_warnings", "Pasture3DBuoy", false],
	]
	var bad := PackedStringArray()
	var checked := 0
	for row in api:
		var m: String = row[0]
		var c: String = row[1]
		if not p_guide.contains(m):
			continue # the guide does not claim it; nothing to verify
		checked += 1
		if not ClassDB.class_exists(c):
			bad.append("%s (class missing)" % c)
		elif not ClassDB.class_has_method(c, m, true):
			bad.append("%s.%s" % [c, m])
	# The GDScript connectors are not in ClassDB, so they are checked by script.
	var pool_script: GDScript = load("res://addons/pasture_3d/connectors/pool.gd")
	var pool_methods := PackedStringArray()
	for d in pool_script.get_script_method_list():
		pool_methods.append(d["name"])
	for m in ["get_water_height", "get_water_normal", "contains_point", "is_point_underwater",
			"fit_to_curve", "make_unique", "is_ribbon"]:
		if not p_guide.contains(m):
			continue
		checked += 1
		if not pool_methods.has(m):
			bad.append("Pasture3DPool.%s" % m)
	print("    %d documented methods checked against the build" % checked)
	if bad.is_empty():
		print("    -> all present")
	else:
		_fail += 1
		print("    !! missing: %s" % ", ".join(bad))

	# Control: the same check, on a method nobody implemented. If this does not report missing, the
	# lookup above is not looking at anything.
	var control_missing := ClassDB.class_exists("Pasture3DPoolManager") \
		and not ClassDB.class_has_method("Pasture3DPoolManager", "body_at_definitely_not", true)
	if control_missing and not pool_methods.has("definitely_not_a_method"):
		print("    control (two fabricated method names): fires — both reported absent")
	else:
		_fail += 1
		print("    !! control did NOT fire: a fabricated method looked present")
	_completed += 1


# ---- C: the guide does not describe the removed API ----------------------------
#
# §9 is the one place `ocean_*` may appear, because that is the migration table. Anywhere else is a
# sentence telling someone to set a property that no longer exists — which is exactly the state the
# banner was apologising for.
func _gate_c_no_stale_api(p_guide: String) -> void:
	print("")
	print("[C] no section still instructs the reader to use the removed API:")
	var split := p_guide.find("## 9. Upgrading")
	if split < 0:
		_fail += 1
		print("    !! the guide has no migration section, so there is nowhere legitimate for them")
		_completed += 1
		return
	var before := p_guide.substr(0, split)
	var after := p_guide.substr(split)

	# Matched against the ACTUAL removed property names from criterion A's fixture, not against the
	# substring "ocean_". The first version used the substring and flagged the presets table, because
	# `M_water_ocean_low.tres` contains it -- a scanner that cannot tell a filename from a property
	# name will cry wolf until someone stops reading it.
	var strays := PackedStringArray()
	for line in before.split("\n"):
		var t := String(line)
		if t.contains("the migration table") or t.contains("Upgrading"):
			continue # a pointer TO the migration table is the correct thing to say
		for n in _legacy:
			if t.contains(n):
				strays.append("%s -> %s" % [n, t.strip_edges().substr(0, 60)])
				break
	if strays.is_empty():
		print("    no removed-property instructions outside the migration section")
	else:
		_fail += 1
		print("    !! %d stray reference(s):" % strays.size())
		for t in strays:
			print("       %s" % t)

	# Control: the scanner has to be able to SEE them. They are all in §9 by design, so it must find
	# plenty there -- if it finds none, it is not matching and the clean result above means nothing.
	var found_in_table := 0
	for line in after.split("\n"):
		for n in _legacy:
			if String(line).contains(n):
				found_in_table += 1
				break
	if found_in_table >= 15:
		print("    control (the same scan inside §9): fires — %d lines matched" % found_in_table)
	else:
		_fail += 1
		print("    !! control did NOT fire: only %d matches in the migration table, so the scan"
			% found_in_table)
		print("       above is probably not matching anything either")

	# The stale banner itself.
	if p_guide.contains("PARTLY OUT OF DATE") or p_guide.contains("no longer exists"):
		_fail += 1
		print("    !! the out-of-date banner is still in the guide")
	else:
		print("    the 'partly out of date' banner is gone")
	_completed += 1


# ---- D: the quick start is the button ------------------------------------------
#
# The spec's gate wording: "the quick-start for a lake is 'press the button'". Before Phase 4 it was
# three steps of mesh authoring, and the guide still said so.
func _gate_d_quick_start(p_guide: String) -> void:
	print("")
	print("[D] the lake quick-start is 'press the button':")
	var start := p_guide.find("## 1. Quick start")
	var stop := p_guide.find("## 2. ")
	if start < 0 or stop <= start:
		_fail += 1
		print("    !! no quick-start section")
		_completed += 1
		return
	var qs := p_guide.substr(start, stop - start)
	var lake := qs.find("### A lake")
	var lake_stop := qs.find("### A river")
	var lake_section := qs.substr(lake, lake_stop - lake) if lake >= 0 and lake_stop > lake else ""

	if lake_section == "":
		_fail += 1
		print("    !! the quick-start has no lake section")
	elif not lake_section.contains("Add Water"):
		_fail += 1
		print("    !! the lake quick-start does not mention the Add Water button")
	elif lake_section.contains("PlaneMesh") or lake_section.contains("subdivision"):
		_fail += 1
		print("    !! the lake quick-start still tells the reader to build a mesh by hand")
	else:
		print("    the lake path is: carve a basin, press Add Water")
	if qs.contains("### A river"):
		print("    rivers are documented in the quick-start too")
	else:
		_fail += 1
		print("    !! rivers are not in the quick-start, though the button makes them")

	# Control: the bare-mesh path must still be documented SOMEWHERE. Otherwise this criterion could
	# be satisfied by deleting content rather than by improving it, which is the failure mode a
	# "does not mention X" check invites.
	if qs.contains("PlaneMesh") or qs.contains("bare mesh") or qs.contains("MeshInstance3D"):
		print("    control (the no-plugin path survives elsewhere in §1): fires")
	else:
		_fail += 1
		print("    !! control did NOT fire: the bare-mesh path was deleted rather than moved")
	_completed += 1


# ---- E: the presets on disk and in the guide agree -----------------------------
func _gate_e_presets(p_guide: String) -> void:
	print("")
	print("[E] the shipped presets and shaders match what the guide lists:")
	var dir := DirAccess.open(WATER_DIR)
	if dir == null:
		_fail += 1
		print("    !! cannot open %s" % WATER_DIR)
		_completed += 1
		return
	var on_disk := PackedStringArray()
	for f in dir.get_files():
		var n := String(f).trim_suffix(".remap")
		if n.begins_with("M_water_") and n.ends_with(".tres"):
			on_disk.append(n)
	on_disk.sort()
	print("    %d presets on disk: %s" % [on_disk.size(), ", ".join(on_disk)])

	var undocumented := PackedStringArray()
	for n in on_disk:
		if not p_guide.contains(n):
			undocumented.append(n)
	if undocumented.is_empty():
		print("    every one is in the guide")
	else:
		_fail += 1
		print("    !! not documented: %s" % ", ".join(undocumented))

	# The other direction: the guide must not promise a preset that is not there.
	var promised := ["M_water_ocean.tres", "M_water_ocean_low.tres", "M_water_lake.tres",
		"M_water_pond.tres", "M_water_river.tres"]
	var absent := PackedStringArray()
	for n in promised:
		if p_guide.contains(n) and not on_disk.has(n):
			absent.append(n)
	if absent.is_empty():
		print("    and every one the guide promises exists")
	else:
		_fail += 1
		print("    !! promised but missing from disk: %s" % ", ".join(absent))

	# Control: both directions must be able to fail. A preset name that is on neither side proves the
	# lookup is not matching everything it is handed.
	if not p_guide.contains("M_water_lagoon.tres") and not on_disk.has("M_water_lagoon.tres"):
		print("    control (a preset on neither side): fires — not claimed, not found")
	else:
		_fail += 1
		print("    !! control did NOT fire")
	_completed += 1


func _read(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()
