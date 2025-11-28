@tool
extends Terrain3DStampAnchor
## Places a baked Terrain3D stamp from explicit payload/alpha textures.
class_name Terrain3DStampProjector

@export var stamp_texture: Texture2D:
	set(value):
		if _stamp_texture == value:
			return
		_stamp_texture = value
		_on_stamp_source_changed()
	get:
		return _stamp_texture

@export var stamp_alpha_texture: Texture2D:
	set(value):
		if _stamp_alpha_texture == value:
			return
		_stamp_alpha_texture = value
		_on_stamp_source_changed()
	get:
		return _stamp_alpha_texture

@export_range(0.0, 10.0, 0.01) var stamp_intensity := 1.0:
	set(value):
		if is_equal_approx(_stamp_intensity, value):
			return
		_stamp_intensity = value
		_redeploy_without_rebake()
	get:
		return _stamp_intensity

@export_range(0.0, 64.0, 0.01) var stamp_feather_radius := 0.0:
	set(value):
		if is_equal_approx(_stamp_feather_radius, value):
			return
		_stamp_feather_radius = maxf(value, 0.0)
		_redeploy_without_rebake()
	get:
		return _stamp_feather_radius

@export_enum("Add:0", "Subtract:1", "Replace:2") var stamp_blend_mode: int = Terrain3DLayer.BLEND_ADD:
	set(value):
		if _stamp_blend_mode == value:
			return
		_stamp_blend_mode = value
		_redeploy_without_rebake(true)
	get:
		return _stamp_blend_mode

@export var stamp_auto_alpha_enabled := true
@export var stamp_auto_alpha_from_border := true
@export_range(-1000.0, 1000.0, 0.01) var stamp_manual_neutral_value := 0.0
@export_range(0.0, 10.0, 0.01) var stamp_alpha_gain := 1.0
@export_range(0.0, 1.0, 0.0001) var stamp_alpha_min_threshold := 0.001
@export var lock_created_layers := true

var _stamp_texture: Texture2D
var _stamp_alpha_texture: Texture2D
var _stamp_intensity := 1.0
var _stamp_feather_radius := 0.0
var _stamp_blend_mode := Terrain3DLayer.BLEND_ADD
var _last_signature: Dictionary = {}
var _last_baked_map_type := Terrain3DRegion.TYPE_MAX

func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_template_ready = false

func _on_stamp_source_changed() -> void:
	_template_ready = false
	_redeploy_without_rebake(true)

func _redeploy_without_rebake(force_template_invalidate: bool = false) -> void:
	if force_template_invalidate:
		_template_ready = false
	_last_position = Vector3.INF
	if is_inside_tree():
		force_update()

func _ensure_template(force_region: bool) -> bool:
	if stamp_texture == null:
		_log("ensure_template: stamp_texture not set")
		return false
	if _terrain == null:
		_resolve_terrain()
	if _terrain == null:
		return false
	var signature := _build_signature()
	if _signature_changed(signature) or _last_baked_map_type != map_type:
		_template_ready = false
	if not _template_ready:
		if not _rebuild_template_payload(signature):
			return false
		_last_signature = signature
		_last_baked_map_type = map_type
	_template_intensity = _stamp_intensity
	_template_feather_radius = _stamp_feather_radius
	_template_blend_mode = _stamp_blend_mode
	return true

func _build_signature() -> Dictionary:
	var basis := global_transform.basis
	var scale_vec := basis.get_scale()
	var planar_scale := Vector2(absf(scale_vec.x), absf(scale_vec.z))
	var yaw := basis.get_euler().y
	var height_scale := maxf(absf(scale_vec.y), 0.0001)
	var stamp_id := stamp_texture.get_rid().get_id() if stamp_texture else 0
	var alpha_id := stamp_alpha_texture.get_rid().get_id() if stamp_alpha_texture else 0
	return {
		"scale": planar_scale,
		"yaw": yaw,
		"height_scale": height_scale,
		"stamp_id": stamp_id,
		"alpha_id": alpha_id,
		"map_type": map_type,
	}

func _signature_changed(signature: Dictionary) -> bool:
	if _last_signature.is_empty():
		return true
	if _last_signature.get("stamp_id", 0) != signature.get("stamp_id", 0):
		return true
	if _last_signature.get("alpha_id", 0) != signature.get("alpha_id", 0):
		return true
	if _last_signature.get("map_type", Terrain3DRegion.TYPE_MAX) != signature.get("map_type", Terrain3DRegion.TYPE_MAX):
		return true
	var previous_scale: Vector2 = _last_signature.get("scale", Vector2.ONE)
	var new_scale: Vector2 = signature.get("scale", Vector2.ONE)
	if previous_scale.distance_to(new_scale) > 0.001:
		return true
	var prev_height_scale := _last_signature.get("height_scale", 1.0)
	var new_height_scale := signature.get("height_scale", 1.0)
	if absf(prev_height_scale - new_height_scale) > 0.001:
		return true
	return not is_equal_approx(_last_signature.get("yaw", 0.0), signature.get("yaw", 0.0))

func _rebuild_template_payload(signature: Dictionary) -> bool:
	var payload_source := _load_payload_image()
	if payload_source == null or payload_source.is_empty():
		_log("rebuild_template: payload source missing")
		return false
	var alpha_source := _load_alpha_image()
	var src_size := payload_source.get_size()
	var bounds := _compute_rotated_bounds(src_size, signature.get("scale", Vector2.ONE), signature.get("yaw", 0.0))
	var bounds_center := bounds.position + bounds.size * 0.5
	var bounds_size_vec := bounds.size
	var dest_size := Vector2i(maxi(ceili(bounds_size_vec.x), 1), maxi(ceili(bounds_size_vec.y), 1))
	var payload_format := _payload_format_for_map(map_type)
	var payload_image := Image.create(dest_size.x, dest_size.y, false, payload_format)
	if payload_image == null:
		return false
	var base_alpha := 0.0 if payload_format == Image.FORMAT_RGBA8 else 1.0
	payload_image.fill(Color(0.0, 0.0, 0.0, base_alpha))
	var alpha_image := Image.create(dest_size.x, dest_size.y, false, Image.FORMAT_RF)
	if alpha_image == null:
		return false
	alpha_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	var cos_yaw := cos(signature.get("yaw", 0.0))
	var sin_yaw := sin(signature.get("yaw", 0.0))
	var scale_vec: Vector2 = signature.get("scale", Vector2.ONE)
	var safe_scale := Vector2(maxf(scale_vec.x, 0.0001), maxf(scale_vec.y, 0.0001))
	var inv_scale := Vector2(1.0 / safe_scale.x, 1.0 / safe_scale.y)
	var half_src := Vector2(src_size.x * 0.5, src_size.y * 0.5)
	var use_source_alpha := alpha_source != null
	var neutral_value := stamp_manual_neutral_value
	if stamp_auto_alpha_enabled and stamp_auto_alpha_from_border:
		neutral_value = _estimate_border_neutral(payload_source)
	var height_replace := map_type == Terrain3DRegion.TYPE_HEIGHT and _stamp_blend_mode == Terrain3DLayer.BLEND_REPLACE
	var baseline_height := 0.0
	if height_replace:
		var world_pos := _compute_world_position()
		baseline_height = world_pos.y
	var height_scale := maxf(signature.get("height_scale", 1.0), 0.0001)
	for y in range(dest_size.y):
		for x in range(dest_size.x):
			var sample_point := Vector2(bounds.position.x + x + 0.5, bounds.position.y + y + 0.5)
			var local_point := sample_point - bounds_center
			var src_pos := _grid_to_source(local_point, cos_yaw, sin_yaw, inv_scale, half_src)
			if src_pos.x < 0.0 or src_pos.y < 0.0 or src_pos.x >= src_size.x or src_pos.y >= src_size.y:
				continue
			var color := _sample_bilinear(payload_source, src_pos)
			var payload_value := color.r
			var height_delta := payload_value - neutral_value
			var scaled_delta := height_delta * height_scale
			if map_type == Terrain3DRegion.TYPE_HEIGHT:
				if height_replace:
					payload_value = baseline_height + scaled_delta
				else:
					payload_value = scaled_delta
				payload_image.set_pixel(x, y, Color(payload_value, 0.0, 0.0, 1.0))
			else:
				payload_image.set_pixel(x, y, color)
			var alpha_val := 1.0
			if use_source_alpha:
				alpha_val = clampf(_sample_bilinear(alpha_source, src_pos).r, 0.0, 1.0)
			elif stamp_auto_alpha_enabled:
				var alpha_sample := scaled_delta if map_type == Terrain3DRegion.TYPE_HEIGHT else (color.r - neutral_value)
				alpha_val = clampf(abs(alpha_sample) * stamp_alpha_gain, 0.0, 1.0)
			if alpha_val < stamp_alpha_min_threshold:
				alpha_val = 0.0
			alpha_image.set_pixel(x, y, Color(alpha_val, alpha_val, alpha_val, 1.0))
	_template_payload = payload_image
	_template_alpha = alpha_image
	_template_size = dest_size
	_template_ready = true
	var stamp_label := stamp_texture.resource_name if stamp_texture and stamp_texture.resource_name != "" else "Stamp"
	_set_source_summary("%s (%dx%d)" % [stamp_label, src_size.x, src_size.y])
	return true

func _payload_format_for_map(map_type_value: int) -> Image.Format:
	match map_type_value:
		Terrain3DRegion.TYPE_COLOR:
			return Image.FORMAT_RGBA8
		_:
			return Image.FORMAT_RF

func _compute_rotated_bounds(src_size: Vector2i, scale_vec: Vector2, yaw: float) -> Rect2:
	var half := Vector2(src_size.x * 0.5, src_size.y * 0.5)
	var corners := [
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(-half.x, half.y),
		Vector2(half.x, half.y),
	]
	var cos_yaw := cos(yaw)
	var sin_yaw := sin(yaw)
	var min_pt := Vector2(1e12, 1e12)
	var max_pt := Vector2(-1e12, -1e12)
	for corner in corners:
		var scaled := Vector2(corner.x * scale_vec.x, corner.y * scale_vec.y)
		var rotated := Vector2(
			scaled.x * cos_yaw - scaled.y * sin_yaw,
			scaled.x * sin_yaw + scaled.y * cos_yaw
		)
		min_pt.x = min(min_pt.x, rotated.x)
		min_pt.y = min(min_pt.y, rotated.y)
		max_pt.x = max(max_pt.x, rotated.x)
		max_pt.y = max(max_pt.y, rotated.y)
	return Rect2(min_pt, max_pt - min_pt)

func _estimate_border_neutral(image: Image) -> float:
	if image == null or image.is_empty():
		return stamp_manual_neutral_value
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return stamp_manual_neutral_value
	var total := 0.0
	var count := 0
	for x in range(width):
		total += image.get_pixel(x, 0).r
		count += 1
		if height > 1:
			total += image.get_pixel(x, height - 1).r
			count += 1
	for y in range(1, max(height - 1, 1)):
		total += image.get_pixel(0, y).r
		count += 1
		if width > 1:
			total += image.get_pixel(width - 1, y).r
			count += 1
	return total / max(count, 1)

func _grid_to_source(local_point: Vector2, cos_yaw: float, sin_yaw: float, inv_scale: Vector2, half_src: Vector2) -> Vector2:
	var unrotated_x := local_point.x * cos_yaw + local_point.y * sin_yaw
	var unrotated_y := -local_point.x * sin_yaw + local_point.y * cos_yaw
	var scaled := Vector2(unrotated_x * inv_scale.x, unrotated_y * inv_scale.y)
	return scaled + half_src

func _sample_bilinear(image: Image, uv: Vector2) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	var x0 := clampi(int(floor(uv.x)), 0, width - 1)
	var y0 := clampi(int(floor(uv.y)), 0, height - 1)
	var x1 := min(x0 + 1, width - 1)
	var y1 := min(y0 + 1, height - 1)
	var fx := clampf(uv.x - float(x0), 0.0, 1.0)
	var fy := clampf(uv.y - float(y0), 0.0, 1.0)
	var c00 := image.get_pixel(x0, y0)
	var c10 := image.get_pixel(x1, y0)
	var c01 := image.get_pixel(x0, y1)
	var c11 := image.get_pixel(x1, y1)
	var cx0 := c00.lerp(c10, fx)
	var cx1 := c01.lerp(c11, fx)
	return cx0.lerp(cx1, fy)

func _load_payload_image() -> Image:
	if stamp_texture == null:
		return null
	var image := stamp_texture.get_image()
	if image == null or image.is_empty():
		return null
	var duplicate := image.duplicate()
	if duplicate:
		image = duplicate
	var desired := _payload_format_for_map(map_type)
	if image.get_format() != desired and desired != Image.FORMAT_MAX:
		image.convert(desired)
	return image

func _load_alpha_image() -> Image:
	if stamp_alpha_texture == null:
		return null
	var image := stamp_alpha_texture.get_image()
	if image == null or image.is_empty():
		return null
	var duplicate := image.duplicate()
	if duplicate:
		image = duplicate
	if image.get_format() != Image.FORMAT_RF:
		image.convert(Image.FORMAT_RF)
	return image

func _create_slice_layer(region_loc: Vector2i, payload: Image, alpha: Image, coverage: Rect2i) -> Terrain3DStampLayer:
	var layer := super._create_slice_layer(region_loc, payload, alpha, coverage)
	if layer and lock_created_layers and layer.has_method("set_user_editable"):
		layer.set_user_editable(false)
	return layer

func _update_slice_layer(layer: Terrain3DStampLayer, payload: Image, alpha: Image, coverage: Rect2i) -> void:
	super._update_slice_layer(layer, payload, alpha, coverage)
	if layer and lock_created_layers and layer.has_method("set_user_editable"):
		layer.set_user_editable(false)

func set_target_layer(_region_loc: Vector2i, _map_type_in: int, _index: int, _layer_ref: Terrain3DLayer = null) -> void:
	_log("Terrain3DStampProjector manages its own layer; set_target_layer is ignored")
