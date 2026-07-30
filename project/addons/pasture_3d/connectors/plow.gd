# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPlow — closed-loop spline HEIGHT brush driven by a "material" (a displacement source). The
# loop is an area mask with falloff; inside it the chosen source's relief is stamped into the height
# map, tiling across the area and feathering back to the existing ground at the rim. Drop it on flat
# ground to generate small hills, dunes, or a craggy surface. It is the height-map twin of
# Pasture3DSplat (which paints WHICH texture shows) and the Pasture3D analogue of how UE5 Landmass
# custom brushes render a material into the landscape heightmap. See PASTURE3D_PLOW_BRUSH_SPEC.md.
#
# Paints non-destructively into a reserved HEIGHT layer via the Pasture3DTerrainBrush base, so it gets
# layer-sharing, undo, surface-snap and the clear-then-snap climbing-fix for free.
@tool
@icon("res://addons/pasture_3d/icons/brush_plow.svg")
class_name Pasture3DPlow
extends Pasture3DTerrainBrush

enum Source { NOISE, TEXTURE, MATERIAL }
enum BlendMode { REPLACE, ADD, MAX, MIN }

# A height source is normalised to [0,1] then biased by `height_offset` so mid-grey = no change and the
# relief goes up AND down. Cap the LUT resolution: terrain relief never needs more than this per tile,
# and it keeps the per-bake image read fast regardless of source texture size.
const _LUT_MAX := 256

@export_group("Relief")
## Which displacement source deforms the ground (see spec §3). The matching input appears just below.
@export var source: Source = Source.NOISE:
	set(v):
		source = v
		notify_property_list_changed() # show only the active source's input
		_schedule_refresh()
## Source.NOISE — procedural relief (ridged/cellular = craggy, Perlin/Simplex = rolling hills).
@export var noise: FastNoiseLite:
	set(v):
		noise = v
		_schedule_refresh()
## Source.TEXTURE — a tiling grayscale heightmap (red channel). Prefer a Lossless/uncompressed import.
@export var height_texture: Texture2D:
	set(v):
		height_texture = v
		_schedule_refresh()
## Source.MATERIAL — a dedicated Pasture3DPlowMaterial (a reusable brush material, independent of the
## terrain's surface textures). Create or load one here, then set its height map.
@export var plow_material: Pasture3DPlowMaterial:
	set(v):
		if plow_material != null and plow_material.changed.is_connected(_schedule_refresh):
			plow_material.changed.disconnect(_schedule_refresh)
		plow_material = v
		if plow_material != null and not plow_material.changed.is_connected(_schedule_refresh):
			plow_material.changed.connect(_schedule_refresh)
		_schedule_refresh()
## Metres of relief across the source's range (peak-to-trough at full mask).
@export var height_scale: float = 8.0:
	set(v):
		height_scale = v
		_schedule_refresh()
## Sample value treated as "no change". 0.5 = mid-grey neutral → relief rises and sinks symmetrically.
@export_range(0.0, 1.0) var height_offset: float = 0.5:
	set(v):
		height_offset = clampf(v, 0.0, 1.0)
		_schedule_refresh()
## Metres per repeat when tiling a TEXTURE / MATERIAL source across the area.
@export var tile_size: float = 16.0:
	set(v):
		tile_size = maxf(v, 0.01)
		_schedule_refresh()
## true = stamp relief onto the existing per-pixel ground; false = relative to the node's Y plane.
@export var relative_to_terrain: bool = true:
	set(v):
		relative_to_terrain = v
		_schedule_refresh()
## How the relief composites: ADD = stamp on top; MAX/MIN = raise/lower-only; REPLACE = absolute pad.
@export var blend_mode: BlendMode = BlendMode.ADD:
	set(v):
		blend_mode = v
		_schedule_refresh()

@export_group("Mask")
## Metres from the loop edge inward over which the relief fades to flat (seamless with the surrounds).
@export var falloff_width: float = 10.0:
	set(v):
		falloff_width = v
		_schedule_refresh()
## Optional 0→1 falloff shape (default = smoothstep).
@export var falloff_curve: Curve:
	set(v):
		falloff_curve = v
		_schedule_refresh()
## Expand (+) / contract (−) the masked area off the spline, in metres.
@export var edge_offset: float = 0.0:
	set(v):
		edge_offset = v
		_schedule_refresh()

@export_group("Smoothing")
## Passes of NaN-aware separable Gaussian blur applied after rasterisation, to soften the stamped relief
## and any chamfer-DT faceting. 0 = off (no cost), 1-2 = subtle, 3+ = heavy rounding.
@export_range(0, 5) var smooth_passes: int = 0:
	set(v):
		smooth_passes = v
		_schedule_refresh()


func _default_layer_name() -> String:
	return "Plow"


func _get_blend_mode() -> int:
	return int(blend_mode)


## Pasture3DPlow has no `invert` of its own — the stamp's sign lives on the material it renders, and
## only in MATERIAL mode (NOISE and TEXTURE have no inversion to read). Drives the Add Water button's
## raise check; see PASTURE3D_WATER_BODIES_SPEC.md §7.8.
func _raise_inverted() -> bool:
	return source == Source.MATERIAL and plow_material != null and plow_material.invert


func _min_points() -> int:
	return 3


func _spline_basename() -> String:
	return "Area"


func _padding() -> float:
	return maxf(edge_offset, 0.0) + 2.0


## Show only the input that belongs to the active Source, and hide tile_size for procedural noise.
func _validate_property(property: Dictionary) -> void:
	match property.name:
		"noise":
			if source != Source.NOISE:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"height_texture":
			if source != Source.TEXTURE:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"plow_material":
			if source != Source.MATERIAL:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		"tile_size":
			if source == Source.NOISE: # noise tiles via its own frequency
				property.usage &= ~PROPERTY_USAGE_EDITOR


## Starter shape: a closed square loop in local space (same as Splat/Mound).
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	var r := 20.0
	c.add_point(Vector3(-r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, r))
	c.add_point(Vector3(-r, 0.0, r))
	return c


func _polygon_xz(path: Path3D) -> PackedVector2Array:
	var raw := PackedVector2Array()
	for p in _baked_world_points(path):
		raw.append(Vector2(p.x, p.z))
	return _decimate(raw, maxf(terrain.vertex_spacing, 0.25))


func _paint_spline(path: Path3D) -> void:
	var poly := _polygon_xz(path)
	if poly.size() < 3:
		return
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var min_x: float = b[0]
	var min_z: float = b[2]
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	if gw < 1 or gh < 1:
		return

	# Resolve the height source ONCE (decompress + cache the LUT for TEXTURE/MATERIAL). Bail if the
	# active source has nothing to read — nothing to stamp. Shared by the native path and the fallback.
	var lut := _load_height_lut()
	var lut_w: int = lut[1]
	var lut_h: int = lut[2]
	var data: PackedFloat32Array = lut[0]
	if source == Source.NOISE:
		if noise == null:
			return
	elif data.is_empty():
		return

	# A plow material can carry its own relief multiplier on top of Height Scale.
	var src_strength := 1.0
	if source == Source.MATERIAL and plow_material != null:
		src_strength = plow_material.strength

	# Native rasteriser (Round 2): same SDF + source-sample + relief math in C++.
	if _native_raster("stamp_plow_loop"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"height_scale": height_scale, "height_offset": height_offset,
			"edge_offset": edge_offset, "falloff_width": falloff_width,
			"relative_to_terrain": relative_to_terrain, "plane_y": global_position.y,
			"blend": _blend, "composite": not _defer_composite,
			"src_strength": src_strength, "tile_size": tile_size, "source": int(source),
			"data_w": lut_w, "data_h": lut_h, "noise": noise,
			"smooth_passes": smooth_passes,
		}
		if relative_to_terrain:
			params["base_below"] = _base_below_grid(min_x, min_z, vs, gw, gh)
		terrain.data.stamp_plow_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve), data)
		return

	# Same O(cells) area mask as Splat/Mound.
	var sdf := _signed_distance_field(poly, min_x, min_z, vs, gw, gh)
	var field: PackedFloat32Array = sdf[0]
	var ramp_denom := maxf(falloff_width, 0.001)
	# Buffer per-cell write values (NaN = no write) so the optional smoothing pass can run before writing.
	# value = delta (ADD) or absolute target (else), matching _paint_height + the C++ path for A/B parity.
	var add := _blend == BLEND_ADD
	var vals := PackedFloat32Array()
	vals.resize(gw * gh)
	vals.fill(NAN)

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var signed_d := field[row + ix] + edge_offset
			if signed_d <= 0.0:
				continue
			var mask := _ramp(falloff_curve, signed_d / ramp_denom)
			if mask <= 0.0:
				continue
			var x := min_x + ix * vs
			var v := _sample01(x, z, data, lut_w, lut_h)
			var amp := height_scale * (v - height_offset) * mask * src_strength
			if absf(amp) < 0.0001:
				continue
			var pos := Vector3(x, 0.0, z)
			var base_y: float = _base_height_below(pos) if relative_to_terrain else global_position.y
			vals[row + ix] = amp if add else base_y + amp

	vals = _blur_grid(vals, gw, gh, smooth_passes)

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var wv := vals[row + ix]
			if not is_finite(wv):
				continue
			var pos := Vector3(min_x + ix * vs, 0.0, z)
			if add:
				_paint_height(pos, 0.0, wv)
			else:
				_paint_height(pos, wv, 0.0)


## Sample the active source at world XZ, normalised to [0,1]. NOISE maps [-1,1]→[0,1]; TEXTURE/MATERIAL
## read the cached LUT tiled by `tile_size`.
func _sample01(x: float, z: float, data: PackedFloat32Array, w: int, h: int) -> float:
	if source == Source.NOISE:
		return clampf(noise.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
	if data.is_empty() or w <= 0 or h <= 0:
		return height_offset # neutral → no change
	var u := fposmod(x / tile_size, 1.0)
	var t := fposmod(z / tile_size, 1.0)
	var px := clampi(int(u * w), 0, w - 1)
	var py := clampi(int(t * h), 0, h - 1)
	return data[py * w + px]


## Build a [0,1] grayscale-height lookup table once per bake from the assigned source texture (TEXTURE →
## height_texture, MATERIAL → plow_material.height_map; both read luminance). Returns
## [PackedFloat32Array, w, h]; empty array when the source is NOISE or nothing is assigned.
func _load_height_lut() -> Array:
	var empty: Array = [PackedFloat32Array(), 0, 0]
	var tex: Texture2D = null
	var invert := false
	if source == Source.TEXTURE:
		tex = height_texture
	elif source == Source.MATERIAL:
		if plow_material == null:
			return empty
		tex = plow_material.height_map
		invert = plow_material.invert
	else:
		return empty
	if tex == null:
		return empty

	var img := tex.get_image()
	if img == null:
		return empty
	img = img.duplicate() # don't mutate the shared resource image
	if img.is_compressed():
		if img.decompress() != OK:
			push_warning("Pasture3DPlow: could not decompress height source image; skipping.")
			return empty
	if img.has_mipmaps():
		img.clear_mipmaps()
	# Cap resolution for a fast, bounded per-bake read.
	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) > _LUT_MAX:
		var s := float(_LUT_MAX) / float(maxi(w, h))
		w = maxi(1, int(round(w * s)))
		h = maxi(1, int(round(h * s)))
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)

	var data := PackedFloat32Array()
	data.resize(w * h)
	for yy in range(h):
		var rowy := yy * w
		for xx in range(w):
			var v := img.get_pixel(xx, yy).get_luminance()
			data[rowy + xx] = (1.0 - v) if invert else v
	return [data, w, h]
