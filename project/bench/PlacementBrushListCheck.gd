# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Every entry in toolbar.PLACEABLE_BRUSHES is actually placeable.
#
# The list is the only thing that decides what the Place-Brush picker offers, and adding a
# class_name does not reach it. This walks each entry the way the editor does: OptionButton
# needs the icon, and _instantiate_placement_brush() needs the script to produce a Node3D.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PlacementBrushListCheck.tscn
extends Node

const TOOLBAR := "res://addons/pasture_3d/src/toolbar.gd"
## Every brush that must be offerable. Named here rather than derived from the list, or this
## check would happily pass on a list that had lost an entry.
const REQUIRED := ["Mound", "Pond", "Ridge", "Trough", "Plow", "Splat"]

var _fail := 0


func _ready() -> void:
	print("\n=== Place-Brush list ===\n")
	var toolbar: GDScript = load(TOOLBAR)
	if toolbar == null:
		_fail += 1
		print("  !! could not load %s" % TOOLBAR)
		_done()
		return
	var entries: Array = toolbar.PLACEABLE_BRUSHES
	print("  %d entries\n" % entries.size())
	print("  %-8s %-34s %-8s %-8s %s" % ["label", "script", "script?", "icon?", "instantiates as"])

	var labels := PackedStringArray()
	for e in entries:
		var label := str(e.get("label", ""))
		var script_path := str(e.get("script", ""))
		labels.append(label)
		var scr: Variant = load(script_path)
		var icon: Variant = load(str(e.get("icon", "")))
		# What _instantiate_placement_brush() does, and what it rejects: anything that is not a
		# Node3D is pushed as an error and the placement silently does nothing.
		var made: Variant = scr.new() if scr is GDScript else null
		var kind := "-"
		if made != null:
			kind = made.get_class()
			if made is Node3D:
				kind += " (Node3D ok)"
			else:
				kind += " NOT A Node3D"
				_fail += 1
			(made as Object).free()
		else:
			_fail += 1
		print("  %-8s %-34s %-8s %-8s %s" % [
				label, script_path.get_file(), scr != null, icon != null, kind])
		if scr == null:
			_fail += 1
			print("    !! script missing -- placement would push an error")
		if icon == null:
			_fail += 1
			print("    !! icon missing -- add_icon_item would get null")

	print("\n  required entries present:")
	for want in REQUIRED:
		var ok: bool = labels.has(want)
		print("    %-8s %s" % [want, ok])
		if not ok:
			_fail += 1
			print("    !! '%s' is not in PLACEABLE_BRUSHES; the picker cannot offer it" % want)

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)
