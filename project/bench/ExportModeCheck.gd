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
	var expect := _extent_px()
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


## The stitched image spans the region bounding box -- which export_image anchors at the origin,
## so the box always includes (0,0) whether or not a region sits there.
func _extent_px() -> Vector2i:
	var top_left := Vector2i.ZERO
	var bottom_right := Vector2i.ZERO
	for loc in _terrain.data.region_locations:
		top_left.x = mini(top_left.x, loc.x)
		top_left.y = mini(top_left.y, loc.y)
		bottom_right.x = maxi(bottom_right.x, loc.x)
		bottom_right.y = maxi(bottom_right.y, loc.y)
	return Vector2i(1 + bottom_right.x - top_left.x, 1 + bottom_right.y - top_left.y) * _region_px


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
