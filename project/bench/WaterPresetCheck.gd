# Pasture3D Water — preset integrity check (spec §6).
#
# A ShaderMaterial stores whatever parameter name you give it. Godot does not
# complain about `shader_parameter/absorbtion`; it keeps it, never reads it, and
# the water quietly renders with the shader's default. So "the preset loads" is
# not evidence of anything. This checks the three things that can actually be
# wrong:
#
#   1. every name the preset sets exists as a uniform on its shader
#   2. the shader compiles (a broken include shows up as an empty uniform list)
#   3. the preset's declared feature set matches the variant it points at --
#      scattering parameters on a shader with no WATER_SCATTER are a preset that
#      was copied rather than authored
#
# Reports the wave table's amplitude sum too, because that is the number a cull
# margin has to be sized off and it is NOT the amplitude knob (§4.5).
#
# Run:  Godot_v4.7-stable_win64_console.exe --headless --path project bench/WaterPresetCheck.tscn
extends Node

const DIR := "res://addons/pasture_3d/extras/shaders/water/"

# preset, and the uniforms its variant MUST declare, as a check that the .tres is
# pointing at the shader its parameters were written for.
const PRESETS := [
	["M_water_ocean.tres", ["sea_level", "foam_crest_threshold", "scatter_strength", "detail_scale1"]],
	["M_water_ocean_low.tres", ["sea_level", "foam_shore_depth"]],
	["M_water_lake.tres", ["scatter_strength", "detail_scale1", "foam_shore_depth"]],
	["M_water_pond.tres", ["foam_shore_depth"]],
]
# Uniforms a variant must NOT declare, so a low tier that quietly compiled the
# high tier's work is caught rather than merely looking correct.
const ABSENT := {
	"M_water_ocean_low.tres": ["scatter_strength", "foam_crest_threshold"],
	"M_water_lake.tres": ["sea_level"],
	"M_water_pond.tres": ["scatter_strength", "foam_crest_threshold", "sea_level"],
}

var _fail := 0


func _ready() -> void:
	print("=== Pasture3D water preset check (spec §6) ===")
	for entry in PRESETS:
		_check(entry[0], entry[1])
	print("")
	if _fail == 0:
		print("=== PRESET CHECK PASS ===")
	else:
		print("=== PRESET CHECK FAIL: %d problem(s) ===" % _fail)
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_file: String, p_required: Array) -> void:
	print("")
	print("--- %s ---" % p_file)
	var mat: ShaderMaterial = load(DIR + p_file)
	if mat == null:
		_fail += 1
		print("  !! failed to load")
		return

	var declared: Dictionary = {}
	for u in mat.shader.get_shader_uniform_list():
		declared[u["name"]] = u["type"]
	if declared.is_empty():
		_fail += 1
		print("  !! the shader declares no uniforms at all, which means it did not compile")
		return
	print("  shader %s declares %d uniforms" % [mat.shader.resource_path.get_file(), declared.size()])

	# 1. Every name the preset sets must exist.
	var unknown: PackedStringArray = []
	var set_count := 0
	for prop in mat.get_property_list():
		var name: String = prop["name"]
		if not name.begins_with("shader_parameter/"):
			continue
		var uniform := name.trim_prefix("shader_parameter/")
		# A ShaderMaterial advertises every uniform its shader declares, whether or
		# not the .tres set one, so the property list alone cannot tell them apart.
		# The stored dictionary can.
		if not (uniform in declared):
			unknown.append(uniform)
	# get_property_list() is filtered by the shader, so a genuinely misspelled name
	# never appears there -- it has to be read off the file.
	var text := FileAccess.get_file_as_string(DIR + p_file)
	for line in text.split("\n"):
		if not line.begins_with("shader_parameter/"):
			continue
		var uniform: String = line.split(" = ")[0].trim_prefix("shader_parameter/")
		set_count += 1
		if not (uniform in declared) and not (uniform in unknown):
			unknown.append(uniform)
	print("  sets %d parameters" % set_count)
	if unknown.is_empty():
		print("  every parameter it sets exists on the shader")
	else:
		_fail += 1
		print("  !! %d parameter(s) set that the shader does not declare: %s" % [
			unknown.size(), ", ".join(unknown)])
		print("     these are stored and never read; the water renders with defaults")

	# 2. The variant is the one these parameters were written for.
	var missing: PackedStringArray = []
	for u in p_required:
		if not (u in declared):
			missing.append(u)
	if missing.is_empty():
		print("  variant declares all %d expected feature uniforms" % p_required.size())
	else:
		_fail += 1
		print("  !! variant is missing: %s -- wrong shader for this preset" % ", ".join(missing))

	# 3. A low tier must actually be a low tier.
	if p_file in ABSENT:
		var present: PackedStringArray = []
		for u in ABSENT[p_file]:
			if u in declared:
				present.append(u)
		if present.is_empty():
			print("  and correctly declares none of: %s" % ", ".join(ABSENT[p_file]))
		else:
			_fail += 1
			print("  !! declares %s, which this tier is supposed to compile out" % ", ".join(present))

	# The amplitude sum, for anyone sizing a cull margin.
	var table = mat.get_shader_parameter("_waves")
	if table is PackedVector4Array and not table.is_empty():
		var sum_amp := 0.0
		var l_min := INF
		var n := 0
		for w in table:
			if w.z > 0.0:
				sum_amp += w.z
				l_min = minf(l_min, w.w)
				n += 1
		print("  ships a table: %d waves, shortest %.2f m, amplitude sum %.3f m" % [
			n, l_min, sum_amp])
	else:
		print("  ships no table (waves come from the Pasture3D node)")
