# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPond is a Mound configured to carve, so every check here is against a plain
# Pasture3DMound. A default that happens to match the parent proves nothing about this class, and
# "it carves" is exactly the kind of claim that looks true until someone reads the blend table.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PondBrushCheck.tscn
extends Node

var _fail := 0


func _ready() -> void:
	print("\n=== Pasture3DPond ===\n")
	var pond := Pasture3DPond.new()
	var mound := Pasture3DMound.new()
	add_child(pond)
	add_child(mound)

	print("  %-24s %-14s %-14s" % ["", "pond", "mound (control)"])
	_cmp("invert", pond.invert, mound.invert, true)
	_cmp("blend_mode", pond.blend_mode, mound.blend_mode, Pasture3DMound.BlendMode.MIN)
	_cmp("capped", pond.capped, mound.capped, true)
	_cmp("height (depth)", pond.height, mound.height, 4.0)

	# The pair that actually decides whether it cuts. MIN alone keeps the LOWER of stamp and
	# ground, so an un-inverted dome sitting above the terrain is discarded entirely and the brush
	# silently does nothing -- the failure this check exists to catch.
	print("\n  carving pair (invert AND MIN, either alone is wrong):")
	var carves: bool = pond.invert and pond.blend_mode == Pasture3DMound.BlendMode.MIN
	print("    pond carves: %s" % carves)
	if not carves:
		_fail += 1
		print("    !! the pond is not configured to carve")

	# brush_raises() drives the Add Water confirmation. A pond must not trip it -- being asked
	# "this raises terrain, add anyway?" on a tool whose whole job is to dig is the prompt that
	# teaches people to click through prompts.
	print("\n  brush_raises() -- the Add Water prompt trigger:")
	print("    pond  %s (want false)" % pond.brush_raises())
	print("    mound %s (want true -- the control)" % mound.brush_raises())
	if pond.brush_raises():
		_fail += 1
		print("    !! the pond would prompt before adding its own water")
	if not mound.brush_raises():
		_fail += 1
		print("    !! CONTROL failed: a plain Mound does not report raising, so the pond's"
			+ " 'false' means nothing")

	# A tool layer carries ONE blend mode. Sharing would put MIN ponds and MAX hills in the same
	# composite, and the first pond added to a scene with hills would break one of them.
	print("\n  layer ownership:")
	print("    pond  '%s'" % pond._default_layer_name())
	print("    mound '%s'" % mound._default_layer_name())
	if pond._default_layer_name() == mound._default_layer_name():
		_fail += 1
		print("    !! ponds and mounds would share a layer, and a layer has one blend mode")

	# Persisted but not shown: it records that water was seeded, so reopening a scene does not
	# re-add water the user deleted.
	print("\n  _water_seeded is stored but hidden:")
	var stored := false
	var shown := false
	for p in pond.get_property_list():
		if p.get("name", "") == "_water_seeded":
			stored = (int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE) != 0
			shown = (int(p.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
	print("    storage=%s editor=%s (want true/false)" % [stored, shown])
	if not stored:
		_fail += 1
		print("    !! not persisted -- deleted water would come back on every scene load")
	if shown:
		_fail += 1
		print("    !! shown in the inspector; it is bookkeeping, not a setting")

	print("\n=== %s (%d failures) ===\n" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _cmp(p_name: String, p_pond, p_mound, p_want) -> void:
	var ok: bool = p_pond == p_want
	print("  %-24s %-14s %-14s %s" % [p_name, str(p_pond), str(p_mound),
			"" if ok else "<-- want %s" % p_want])
	if not ok:
		_fail += 1
	# A default that matches the parent is not this class configuring anything.
	if p_pond == p_mound:
		_fail += 1
		print("    !! same as the Mound default; this class changed nothing here")
