# Pasture3D Water — prints the wave table every shipped wave profile generates (spec §6, §5.2).
#
# The lake and pond materials ship an explicit `_waves` array, because nothing runs
# on the CPU for a material dropped on a bare MeshInstance3D (G6) and the
# compile-time fallback in water_common.gdshaderinc is a last resort rather than
# a preset. Those arrays are GENERATED here rather than hand-authored, so a
# preset cannot be a table shape WaterWaves would never produce -- which matters
# the moment someone drives a lake from C++ and expects the same surface.
#
# Also prints the amplitude sum, which is the number that decides a body's cull
# AABB and is NOT the amplitude knob: the knob is the longest wave's amplitude
# and the geometric series adds the rest.
#
# The knobs are NOT listed here. They are read off a freshly constructed
# Pasture3DPoolManager, which is where the four shipped profiles live since Phase 4
# (spec §5.2) -- so this prints what the plugin actually ships rather than a second
# copy of it that can drift. Before Phase 2 it drove Pasture3D.ocean_wave_*, which no
# longer exists; that is what this port replaces.
#
# Run:  Godot_v4.7-stable_win64_console.exe --headless --path project bench/WavePresetTables.tscn
extends Node

# The period the shipped .tres tables were quantised to, matching the water_time_period
# global's default and the manager's own. Changing it changes every table below.
const LOOP_PERIOD := 120.0
# The shader's `_waves` array is declared at this length whatever the variant reads (§4.2),
# so a .tres has to supply all of them.
const WATER_MAX_WAVES := 8


func _ready() -> void:
	var manager := Pasture3DPoolManager.new()
	manager.loop_period = LOOP_PERIOD
	add_child(manager)
	# The constructor seeds the profiles and the manager pushes the period into each; this
	# forces the tables to be rebuilt against it rather than trusting the ordering.
	manager.rebuild_tables()

	var profiles: Array = manager.profiles
	if profiles.is_empty():
		printerr("No profiles on a fresh Pasture3DPoolManager — §5.2 says four ship.")
		get_tree().quit(1)
		return
	for p in profiles:
		_report(p)
	get_tree().quit()


func _report(p_profile: Pasture3DWaveProfile) -> void:
	var table: PackedVector4Array = p_profile.get_shader_table()
	print("--- %s: count %d, dir %.0f, spread %.0f, amp %.2f, L_max %.0f, steep %.2f ---" % [
		p_profile.profile_name, p_profile.wave_count, p_profile.direction_deg,
		p_profile.spread_deg, p_profile.amplitude, p_profile.length_max, p_profile.steepness])
	# The derived getters, not a re-sum here: these are the ones Pasture3DPool sizes its cull box
	# and its vertex spacing from, so printing anything else would document the wrong numbers.
	print("  L_min %.2f m | amplitude sum %.3f m" % [
		p_profile.get_min_wavelength(), p_profile.get_amplitude_sum()])
	print("  vertex spacing at the lambda/8 rule: %.2f m" % (p_profile.get_min_wavelength() / 8.0))
	# The old note here claimed a series ending at ~10 m had been "clamped" and did not have
	# the spacing asked for. That was wrong: water_waves.cpp defines the series to run from
	# length_max DOWN TO min(MIN_WAVELENGTH, length_max/2), so ending at the floor is the
	# design and not a failure. The case actually worth flagging is the other one.
	if p_profile.get_min_wavelength() < 9.99:
		print("  NOTE: the series runs BELOW the 10 m floor (WaterWaves::MIN_WAVELENGTH).")
		print("    Deliberate — a short-wave profile needs ripples, not two copies of one")
		print("    wave — but the floor is a float-precision limit at kilometre-scale")
		print("    coordinates, so a body on this profile placed far from the world origin")
		print("    MUST have _water_domain_origin set. Pasture3DPool does that from its own")
		print("    position; a bare MeshInstance3D does not.")
	var flat: PackedStringArray = []
	for i in WATER_MAX_WAVES:
		var w: Vector4 = table[i] if i < table.size() else Vector4.ZERO
		flat.append("%.5f, %.5f, %.5f, %.5f" % [w.x, w.y, w.z, w.w])
	print("  tres: PackedVector4Array(" + ", ".join(flat) + ")")
	print("")
