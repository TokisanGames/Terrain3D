# Runs the C++ unit suites selected by PASTURE3D_UNIT_TESTS, then quits.
#
# The suites live in Pasture3D's NOTIFICATION_READY, so all this has to do is put
# a Pasture3D in the tree and get out of the way. No data, no material, no
# viewport: the water suite is CPU-only and touches nothing a scene provides.
#
# Run: PASTURE3D_UNIT_TESTS=water Godot ... --path project bench/UnitTestRunner.tscn
extends Node


func _ready() -> void:
	var suites := OS.get_environment("PASTURE3D_UNIT_TESTS")
	if suites == "":
		push_error("PASTURE3D_UNIT_TESTS is unset; nothing to run")
		get_tree().quit(2)
		return
	print("=== Pasture3D unit test runner: %s ===" % suites)
	add_child(Pasture3D.new())
	# One idle frame so anything the suite printed is flushed before the quit.
	await get_tree().process_frame
	get_tree().quit(0)
