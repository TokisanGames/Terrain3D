# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DOcean warns when its wave profile asks for more waves than its material can draw.
#
# The number in that warning used to be inferred from SUBSTRINGS OF THE SHADER'S FILE PATH:
# "_low" meant 4, "water_body" meant 4 or 2, everything else meant 8. It was wrong for
# water_river.gdshader — reported 8, where a river evaluates the Gerstner table not at all —
# and wrong for any shader an author renamed, in whichever direction the new name happened to
# fall. Both failures are silent, and both are the wrong kind: the warning exists to say "you
# will not see what get_water_height() is telling you", so a bad guess either invents that
# sentence or suppresses it.
#
# The count now comes from _wave_variant_count, a uniform water_common.gdshaderinc declares
# for the purpose. This checks the warning that reads it.
#
# WINDOWED, NOT HEADLESS. RenderingServer.shader_get_parameter_default() returns nil under the
# dummy renderer for every uniform however the shader is written, so headless every variant
# looks undeclared and every criterion here passes vacuously. Criterion D is the guard against
# that being missed.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterVariantWarningCheck.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"

var _fail := 0


func _ready() -> void:
	print("\n=== ocean wave-count warning reads the shader, not the filename ===\n")
	_check_undersized("M_water_pond.tres", 2)
	_check_river()
	_check_matching()
	_check_renderer_is_real()

	print("")
	if _fail == 0:
		print("=== VARIANT WARNING CHECK PASS ===")
	else:
		print("=== VARIANT WARNING CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## An 8-wave profile against a 2-wave variant. The warning must name 2 — the number the
## shader actually compiles — and not 8, which is what the old path-substring guess produced
## for any filename without "_low" or "water_body" in it.
func _check_undersized(p_preset: String, p_expected: int) -> void:
	print("[A] 8-wave profile on %s (compiles %d):" % [p_preset, p_expected])
	var w := _warnings_for(p_preset, 8)
	var hit := _first_containing(w, "waves but")
	print("    %s" % (hit if hit != "" else "<no wave-count warning>"))
	if hit == "":
		_fail += 1
		print("    !! no warning at all — an 8-wave profile on a %d-wave variant is exactly the case" % p_expected)
		return
	if not hit.contains("compiles %d" % p_expected):
		_fail += 1
		print("    !! does not name %d as the compiled count" % p_expected)
	if not hit.contains("has 8 waves"):
		_fail += 1
		print("    !! does not name the profile's 8")


## The case the old inference got wrong. A river variant evaluates NO Gerstner waves, so the
## honest warning is not "it compiles 3" — the table is inert — but that the profile describes
## a surface this material will not draw at all.
func _check_river() -> void:
	print("\n[B] the case the filename guess got wrong — a river material on an ocean:")
	var w := _warnings_for("M_water_river.tres", 8)
	var hit := _first_containing(w, "no Gerstner waves")
	print("    %s" % (hit if hit != "" else "<no stream-variant warning>"))
	if hit == "":
		_fail += 1
		print("    !! silent — the old code reported 'compiles 8' here, which is doubly wrong")
	# And it must NOT also emit the counting warning, which would be incoherent alongside it.
	if _first_containing(w, "waves but") != "":
		_fail += 1
		print("    !! also emitted a wave-count warning; the table is inert, there is nothing to count")


## CONTROL. A profile inside the variant's budget must say nothing, or the warning is noise
## and every criterion above passes for the wrong reason.
func _check_matching() -> void:
	print("\n[C] CONTROL, a 2-wave profile on the same 2-wave variant:")
	var w := _warnings_for("M_water_pond.tres", 2)
	var hit := _first_containing(w, "waves but")
	print("    wave-count warning: %s" % (hit if hit != "" else "<none, as required>"))
	if hit != "":
		_fail += 1
		print("    !! warns about a profile that fits")


## CONTROL for the harness itself. Everything above reads the count through
## shader_get_parameter_default(), which returns nil headless — where A, B and C would all
## pass by saying nothing. This fails in that case, so a vacuous run cannot look like a good
## one. (bench-gate practice: tell "measured nothing" from "measured well".)
func _check_renderer_is_real() -> void:
	print("\n[D] CONTROL, the count is actually readable in this run:")
	var sh: Shader = load(WATER_DIR + "water_ocean.gdshader")
	var declared: Variant = RenderingServer.shader_get_parameter_default(
		sh.get_rid(), &"_wave_variant_count")
	print("    water_ocean.gdshader _wave_variant_count = %s (must be 8)" % str(declared))
	if typeof(declared) != TYPE_INT:
		_fail += 1
		print("    !! nil — this is a headless run, so A/B/C proved nothing. Run it windowed.")
	elif int(declared) != 8:
		_fail += 1
		print("    !! the ocean variant does not report 8")


# ---- fixtures ----------------------------------------------------------------

## An ocean carrying p_preset, on a manager whose profile has p_wave_count waves.
func _warnings_for(p_preset: String, p_wave_count: int) -> PackedStringArray:
	var root := Node3D.new()
	add_child(root)
	var m := Pasture3DPoolManager.new()
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = "test_profile"
	profile.wave_count = p_wave_count
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	m.profiles = profiles
	root.add_child(m)

	var ocean := Pasture3DOcean.new()
	ocean.material = load(WATER_DIR + p_preset)
	ocean.wave_profile = &"test_profile"
	root.add_child(ocean)

	var w: PackedStringArray = ocean.get_ocean_warnings()
	# free(), NOT queue_free(). Every criterion here runs synchronously inside _ready, and a
	# queue_free'd node stays in the tree until the frame ends — so the previous fixture's
	# manager was still registered when the next one asked, and Pasture3DPoolManager's
	# get_active_manager() hands back _managers[0], the FIRST one in. Criterion C then read
	# criterion A's 8-wave profile through its own 2-wave one and reported a warning that was
	# correct about a manager it did not create. Caught by that control, which is what it is
	# for.
	root.free()
	return w


func _first_containing(p_warnings: PackedStringArray, p_needle: String) -> String:
	for s in p_warnings:
		if s.contains(p_needle):
			return s
	return ""
