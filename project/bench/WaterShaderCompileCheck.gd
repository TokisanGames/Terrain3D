# Loads every water shader variant headless and reports its uniform list.
#
# The fast edit loop for the .gdshaderinc files. Godot reports shader parse
# errors to stdout on load, and get_shader_uniform_list() forces the parse, so a
# broken include shows up here in about four seconds instead of after a full gate
# run -- and without a Godot window that has to be killed when a scene fails.
#
# RUN IT WINDOWED if you care about the waves= column. Shader PARSING works headless, so
# the uniform list and any parse error show up either way -- but the dummy renderer returns
# nil from shader_get_parameter_default() for every uniform however the shader was written,
# so every variant reports "-" and the column tells you nothing. Pasture3DOcean reads the
# same value the same way and takes the same silence, which is fine there because
# configuration warnings are an editor thing.
#
# Run:
#   Godot_v4.7-stable_win64_console.exe --path project \
#       --script res://bench/WaterShaderCompileCheck.gd
extends SceneTree

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const VARIANTS := [
	"water_ocean.gdshader",
	"water_ocean_low.gdshader",
	"water_body.gdshader",
	"water_body_low.gdshader",
	# canvas_item rather than spatial, and it shares no include with the others -- but it is a
	# water shader that ships, so it belongs in the four-second check like the rest.
	"water_river.gdshader",
	"water_underwater.gdshader",
]


func _initialize() -> void:
	print("=== water shader variants ===")
	for name: String in VARIANTS:
		var sh: Shader = load(WATER_DIR + name)
		if sh == null:
			print("  %-24s LOAD FAILED" % name)
			continue
		var uniforms: Array = sh.get_shader_uniform_list(true)
		var names: PackedStringArray = []
		for u: Dictionary in uniforms:
			names.append(u["name"])
		names.sort()
		# The wave count this variant compiles, read the way Pasture3DOcean reads it. Printed
		# because it is the one uniform whose VALUE is an interface rather than a knob: the
		# ocean's configuration warning is built on it, and a variant that reports the wrong
		# number here invents that warning or hides it. "-" means the shader does not declare
		# it, which is correct for water_underwater and a bug for anything else in this list.
		var declared: Variant = RenderingServer.shader_get_parameter_default(
			sh.get_rid(), &"_wave_variant_count")
		var count := "-" if typeof(declared) != TYPE_INT else str(declared)
		print("  %-24s waves=%-2s %2d uniforms: %s" % [name, count, names.size(), ", ".join(names)])
	quit()
