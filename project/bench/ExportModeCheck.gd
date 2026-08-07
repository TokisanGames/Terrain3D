# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DData.export_image writes the files it says it writes, in both modes.
#
# Ported from upstream Terrain3D c9780af. export_image() used to build one image covering every
# region and hand it to save_png/save_exr/... Past 16384 px on a side that is larger than most
# image formats and every GPU will accept, so a big terrain produced a file nothing could open.
# SLICED cuts the output into 16k tiles; PER_REGION writes one file per region instead.
#
# What makes this worth a gate rather than an eyeball: the failure is silent and delayed. Export
# returns OK, files appear on disk, and the problem only surfaces in whatever tool the user opens
# them in, possibly days later. So the criteria assert the things the caller cannot see from the
# return code -- how many files, and what size each one is.
#
# Criterion C is the control. A and B both assert "the right files exist", which a stub that wrote
# every extension unconditionally would also satisfy. C requires a rejected extension to actually
# fail and to leave nothing behind.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/ExportModeCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const OUT_DIR := "user://export_check"
## Region size for the synthetic terrains in [D-G]. Set explicitly on each one so the expected
## image sizes there are literals rather than a multiple of whatever the default happens to be.
const SYNTH_REGION_PX := 256

var _fail := 0
var _terrain: Pasture3D
var _region_px := 0
var _region_count := 0


func _ready() -> void:
	print("\n=== Pasture3DData.export_image modes ===\n")
	_build()
	_gate_a_sliced()
	_gate_b_per_region()
	_gate_c_bad_extension()
	await _gate_bounds()

	print("")
	if _fail == 0:
		print("=== EXPORT MODE CHECK PASS ===")
	else:
		print("=== EXPORT MODE CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## The demo terrain is far below 16384 px, so SLICED must emit exactly ONE file and it must carry
## no _00_00 suffix -- upstream only suffixes when it actually sliced. The image must cover the
## full region extent, which is what proves the chunk rect maths did not crop it.
func _gate_a_sliced() -> void:
	print("[A] SLICED writes one unsuffixed file covering the whole terrain:")
	var path := OUT_DIR + "/sliced.exr"
	var err: int = _terrain.data.export_image(path, Pasture3DRegion.TYPE_HEIGHT,
		Pasture3DData.EXPORT_SLICED)
	var files := _list(OUT_DIR)
	var img := _load_exr(path)
	var expect := _demo_extent_px()
	var ok: bool = err == OK and files.size() == 1 and img != null and img.get_size() == expect
	print("    err=%d files=%s size=%s expected=%s %s" % [
		err, str(files), str(img.get_size()) if img else "<none>", str(expect),
		"ok" if ok else "!! FAIL"])
	if not ok:
		_fail += 1
	_clear(OUT_DIR)


## One file per region, each exactly region_size square. A region's own map is written directly,
## so a wrong size here means the per-region branch is going through the stitched path.
func _gate_b_per_region() -> void:
	print("\n[B] PER_REGION writes one region-sized file per region:")
	var err: int = _terrain.data.export_image(OUT_DIR + "/per.exr", Pasture3DRegion.TYPE_HEIGHT,
		Pasture3DData.EXPORT_PER_REGION)
	var files := _list(OUT_DIR)
	var want := Vector2i(_region_px, _region_px)
	var sizes_ok := true
	for f in files:
		var img := _load_exr(OUT_DIR + "/" + f)
		if img == null or img.get_size() != want:
			sizes_ok = false
	var ok: bool = err == OK and files.size() == _region_count and sizes_ok
	print("    err=%d files=%d expected=%d each %s: %s %s" % [
		err, files.size(), _region_count, str(want), str(sizes_ok),
		"ok" if ok else "!! FAIL"])
	print("    names: %s" % str(files))
	if not ok:
		_fail += 1
	_clear(OUT_DIR)


## CONTROL for A and B. Both assert files appear; neither would notice a writer that accepted
## anything. An extension the exporter does not support must fail AND write nothing.
func _gate_c_bad_extension() -> void:
	print("\n[C] CONTROL, an unsupported extension is refused:")
	var err: int = _terrain.data.export_image(OUT_DIR + "/nope.tiff", Pasture3DRegion.TYPE_HEIGHT,
		Pasture3DData.EXPORT_SLICED)
	var files := _list(OUT_DIR)
	var ok: bool = err != OK and files.is_empty()
	print("    err=%d (must be non-zero) files=%d (must be 0) %s" % [
		err, files.size(), "ok" if ok else "!! FAIL (A and B prove nothing)"])
	if not ok:
		_fail += 1
	_clear(OUT_DIR)


## The bounding box is the box containing the regions -- not that box unioned with the world
## origin, which is what it used to be. Each case is a separate way the old code went wrong, so a
## partial fix cannot pass all four.
##
## Every terrain here is built from add_region_blank() rather than the demo data, because the demo
## regions straddle the origin and the buggy answer and the correct one are identical on them.
## That is precisely why this defect survived.
func _gate_bounds() -> void:
	print("\n[D-G] region bounds are the regions, not the regions plus the origin:")
	var cases := [
		# name, region locations, expected image size in regions, what it isolates
		["D offset from origin", [Vector2i(3, 3), Vector2i(4, 4)], Vector2i(2, 2),
			"box was pinned to (0,0)..(4,4) = 5x5"],
		["E single region", [Vector2i(4, 4)], Vector2i(1, 1),
			"one region must set BOTH corners; the else-if let it set only one"],
		["F negative only", [Vector2i(-5, 0), Vector2i(-3, 0)], Vector2i(3, 1),
			"bottom_right never left 0, so the box ran to the origin"],
		["G CONTROL touches origin", [Vector2i(0, 0), Vector2i(1, 1)], Vector2i(2, 2),
			"old and new answers AGREE here; fails if the fix over-corrects"],
	]
	for case in cases:
		var name: String = case[0]
		var locs: Array = case[1]
		var want: Vector2i = case[2] * SYNTH_REGION_PX
		var isolates: String = case[3]
		var terrain := _synthetic(locs)
		var path := OUT_DIR + "/bounds.exr"
		var err: int = terrain.data.export_image(path, Pasture3DRegion.TYPE_HEIGHT,
			Pasture3DData.EXPORT_SLICED)
		var files := _list(OUT_DIR)
		var img := _load_exr(path)
		var got: Vector2i = img.get_size() if img else Vector2i(-1, -1)
		# One unsuffixed file: an inflated box can push a small terrain over the 16384 px slice
		# ceiling and produce suffixed chunks where one plain file was correct.
		var ok: bool = err == OK and got == want and files == PackedStringArray(["bounds.exr"])
		print("    %-28s got %-13s want %-13s files=%s %s" % [
			name, str(got), str(want), str(files), "ok" if ok else "!! FAIL"])
		if not ok:
			print("        isolates: %s" % isolates)
			_fail += 1
		_clear(OUT_DIR)
		terrain.queue_free()
		await get_tree().process_frame


## A terrain with blank regions at the given locations and no data directory, so nothing is read
## from or written to demo data.
##
## Region size is set explicitly rather than left at the default, so the expected sizes above stay
## literals that do not move if the default changes. It must be set before the regions are added.
func _synthetic(p_locs: Array) -> Pasture3D:
	var terrain := Pasture3D.new()
	add_child(terrain)
	terrain.region_size = SYNTH_REGION_PX
	for loc in p_locs:
		terrain.data.add_region_blank(loc, false)
	terrain.data.update_maps(Pasture3DRegion.TYPE_MAX, true, false)
	return terrain


# ---- fixtures ----------------------------------------------------------------

func _build() -> void:
	_terrain = Pasture3D.new()
	add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_region_px = _terrain.region_size
	_region_count = _terrain.data.region_locations.size()
	_clear(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	print("regions=%d  region_size=%d px" % [_region_count, _region_px])


## The demo terrain's regions are (0,0), (0,-1), (0,-2): one column, three tall.
##
## This is a LITERAL, not a computation. It used to call the same bounding-box algorithm the
## exporter uses, which meant the check asserted only that the implementation agreed with itself --
## it passed just as happily while that algorithm was wrong. Criteria D-G below are literals for
## the same reason.
func _demo_extent_px() -> Vector2i:
	return Vector2i(_region_px, 3 * _region_px)


func _load_exr(p_path: String) -> Image:
	var img := Image.new()
	if img.load(p_path) != OK:
		return null
	return img


func _list(p_dir: String) -> PackedStringArray:
	var d := DirAccess.open(p_dir)
	if d == null:
		return PackedStringArray()
	var out := PackedStringArray()
	for f in d.get_files():
		out.append(f)
	out.sort()
	return out


func _clear(p_dir: String) -> void:
	var d := DirAccess.open(p_dir)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
