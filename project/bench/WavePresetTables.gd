# Pasture3D Water — prints the wave table for each preset's knobs (spec §6).
#
# The lake and pond presets ship an explicit `_waves` array, because nothing runs
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
# Run:  Godot_v4.7-stable_win64_console.exe --headless --path project bench/WavePresetTables.tscn
extends Node

# name, count, direction_deg, spread_deg, amplitude, length_max
const PRESETS := [
	["ocean", 8, 20.0, 28.0, 1.6, 137.0],
	["lake", 4, 35.0, 40.0, 0.25, 25.0],
	["pond", 2, 55.0, 50.0, 0.05, 12.0],
]


func _ready() -> void:
	var terrain := Pasture3D.new()
	add_child(terrain)

	for p in PRESETS:
		terrain.ocean_wave_count = p[1]
		terrain.ocean_wave_direction = p[2]
		terrain.ocean_wave_spread = p[3]
		terrain.ocean_wave_amplitude = p[4]
		terrain.ocean_wave_length_max = p[5]

		var mat := ShaderMaterial.new()
		mat.shader = load("res://addons/pasture_3d/extras/shaders/water/water_ocean.gdshader")
		terrain.ocean_material = mat
		terrain.ocean_enabled = true
		terrain.ocean_enabled = false

		var table: PackedVector4Array = mat.get_shader_parameter("_waves")
		var sum_amp := 0.0
		var l_min := INF
		var lines: PackedStringArray = []
		for i in p[1]:
			var w: Vector4 = table[i]
			sum_amp += w.z
			l_min = minf(l_min, w.w)
			lines.append("Vector4(%.4f, %.4f, %.4f, %.4f)" % [w.x, w.y, w.z, w.w])

		print("--- %s: count %d, dir %.0f, spread %.0f, amp %.2f, L_max %.0f ---" % [
			p[0], p[1], p[2], p[3], p[4], p[5]])
		print("  L_min %.2f m | amplitude sum %.3f m" % [l_min, sum_amp])
		if l_min <= 10.001:
			print("  NOTE: L_min is at the 10 m floor (WaterWaves::MIN_WAVELENGTH), so the")
			print("    series was clamped and the requested L_max does not produce the")
			print("    geometric spacing asked for. Raise L_max or lower the count.")
		# .tres wants a flat float list, and always WATER_MAX_WAVES entries -- the
		# shader's array is declared at 8 whatever the variant reads (§4.2).
		var flat: PackedStringArray = []
		for i in 8:
			var w: Vector4 = table[i] if i < table.size() else Vector4.ZERO
			flat.append("%.5f, %.5f, %.5f, %.5f" % [w.x, w.y, w.z, w.w])
		print("  tres: PackedVector4Array(" + ", ".join(flat) + ")")
		print("")

	get_tree().quit()
