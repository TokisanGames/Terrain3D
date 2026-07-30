# Loads every water shader variant headless and reports its uniform list.
#
# The fast edit loop for the .gdshaderinc files. Godot reports shader parse
# errors to stdout on load, and get_shader_uniform_list() forces the parse, so a
# broken include shows up here in about four seconds instead of after a full gate
# run -- and without a Godot window that has to be killed when a scene fails.
#
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path project \
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
		print("  %-24s %2d uniforms: %s" % [name, names.size(), ", ".join(names)])
	quit()
