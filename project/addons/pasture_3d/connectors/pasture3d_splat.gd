# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSplat — closed-loop spline MATERIAL/TEXTURE brush (the splat-map analogue of Mound). The
# loop is an area mask with falloff; inside it the chosen terrain material is applied, tiling naturally
# and feathering out at the edge. Paints non-destructively into a CONTROL layer (which texture + how
# much), so it stacks above the height brush layers and is great for adding texture variation/detail
# over an area. See PASTURE3D_MATERIAL_BRUSH_SPEC.md.
#
# Control composites topmost-covered-wins (REPLACE), so the soft edge lives in the control's 8-bit
# BLEND field (base→overlay in the shader), not in layer coverage: inside the loop blend = 255 (full
# material), feathering to 0 at the rim where the underlying base texture shows.
@tool
@icon("res://addons/pasture_3d/icons/brush_splat.svg")
class_name Pasture3DSplat
extends Pasture3DTerrainBrush

@export_group("Material")
## Overlay texture id to apply inside the loop (dropdown of the terrain's textures via _validate_property).
@export var material: int = 0:
	set(v):
		material = maxi(0, v)
		_schedule_refresh()
## Maximum material strength at the centre (0..1 → control blend 0..255).
@export_range(0.0, 1.0) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		_schedule_refresh()
## Feather to the underlying base texture (true) or to the material itself (false).
@export var preserve_base: bool = true:
	set(v):
		preserve_base = v
		_schedule_refresh()
## Control uv-scale / uv-rotation buckets (texture tiling density / rotation). 0 = default.
@export var uv_scale: int = 0:
	set(v):
		uv_scale = clampi(v, 0, 7)
		_schedule_refresh()
@export var uv_rotation: int = 0:
	set(v):
		uv_rotation = clampi(v, 0, 15)
		_schedule_refresh()

@export_group("Mask")
## Metres from the loop edge inward over which the material fades in.
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

@export_group("Mask Noise")
@export var noise: FastNoiseLite
## Jitter on the mask coverage for natural patchy edges.
@export var noise_strength: float = 0.0:
	set(v):
		noise_strength = v
		_schedule_refresh()


func _default_layer_name() -> String:
	return "Detail"


func _map_type() -> int:
	return PASTURE_3D_MAPTYPE_CONTROL


func _min_points() -> int:
	return 3


func _spline_basename() -> String:
	return "Area"


func _padding() -> float:
	return maxf(edge_offset, 0.0) + 2.0


## Make `material` a dropdown of the terrain's texture slots when assets are available.
func _validate_property(property: Dictionary) -> void:
	if property.name == "material":
		var names := _texture_names()
		if names != "":
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = names


func _texture_names() -> String:
	if not is_instance_valid(terrain) or terrain.assets == null:
		return ""
	if not terrain.assets.has_method("get_texture_count"):
		return ""
	var n: int = terrain.assets.get_texture_count()
	if n <= 0:
		return ""
	var out := PackedStringArray()
	for i in range(n):
		# Show the actual texture-asset name ("Grass", "Noise", …) so picking a material is obvious,
		# falling back to the slot index for empty/unnamed slots.
		var label := "Texture %d" % i
		var ta = terrain.assets.get_texture_asset(i)
		if ta != null:
			var nm: String = ta.get_name()
			if nm != "":
				label = "%s (%d)" % [nm, i]
		out.append(label)
	return ",".join(out)


## Starter shape: a closed square loop in local space (same as Mound).
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

	var uv_bits := Pasture3DUtil.enc_uv_scale(uv_scale) | Pasture3DUtil.enc_uv_rotation(uv_rotation)

	# Native rasteriser (Round 2): same SDF + control encode in C++. GDScript reference below.
	if _native_raster("stamp_splat_loop"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"strength": strength, "edge_offset": edge_offset, "falloff_width": falloff_width,
			"material": material, "preserve_base": preserve_base, "uv_bits": uv_bits,
			"composite": not _defer_composite, "noise": noise, "noise_strength": noise_strength,
		}
		terrain.data.stamp_splat_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve))
		return

	# Same O(cells) signed distance field as Mound — gives the area mask + falloff for free.
	var sdf := _signed_distance_field(poly, min_x, min_z, vs, gw, gh)
	var field: PackedFloat32Array = sdf[0]
	var ramp_denom := maxf(falloff_width, 0.001)

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var signed_d := field[row + ix] + edge_offset
			if signed_d <= 0.0:
				continue
			var x := min_x + ix * vs
			var t := _ramp(falloff_curve, signed_d / ramp_denom) * strength
			if noise:
				t += noise_strength * noise.get_noise_2d(x, z)
			t = clampf(t, 0.0, 1.0)
			var blend_int := int(round(t * 255.0))
			if blend_int <= 0:
				continue
			var pos := Vector3(x, 0.0, z)
			# Read the underlying control (the base refresh cleared our footprint first, so this is what
			# is actually beneath us) and feather base→material via the control's blend field.
			var cur: int = terrain.data.get_control(pos)
			var base_id: int = Pasture3DUtil.get_base(cur) if preserve_base else material
			var ctrl: int = Pasture3DUtil.enc_base(base_id) | Pasture3DUtil.enc_overlay(material) \
				| Pasture3DUtil.enc_blend(blend_int) | uv_bits | (cur & 0x6)  # preserve nav + hole bits
			_paint_control(pos, ctrl, 1.0)
