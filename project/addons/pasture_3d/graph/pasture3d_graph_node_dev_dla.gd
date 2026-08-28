# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevDLA — pure GDScript reference oracle for DLA massif generation.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevDLA
extends Pasture3DGraphNode

const ReliefDLA = preload("res://addons/pasture_3d/connectors/pasture3d_relief_dla.gd")

enum Evaluation { LIVE, FROZEN }

@export_range(0.0, 4000.0, 1.0, "or_greater") var amplitude: float = 400.0:
	set(v):
		amplitude = maxf(v, 0.0)
		_param_changed()

@export_group("Shape")
@export_range(0.2, 1.0, 0.01) var coverage: float = 0.95:
	set(v):
		coverage = clampf(v, 0.2, 1.0)
		_param_changed()

@export_range(0.03, 0.50, 0.005) var detail_size: float = 0.12:
	set(v):
		detail_size = clampf(v, 0.03, 0.50)
		_param_changed()

@export_range(0.0, 1.0, 0.05) var wander: float = 0.5:
	set(v):
		wander = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(1, 6, 1) var hierarchy_levels: int = 4:
	set(v):
		hierarchy_levels = clampi(v, 1, 6)
		_param_changed()

@export_group("Profile")
@export_range(0.5, 4.0, 0.1) var profile_power: float = 1.6:
	set(v):
		profile_power = clampf(v, 0.5, 4.0)
		_param_changed()

@export_range(2, 8, 1) var blur_levels: int = 5:
	set(v):
		blur_levels = clampi(v, 2, 8)
		_param_changed()

@export_range(1.4, 2.5, 0.05) var blur_growth: float = 1.8:
	set(v):
		blur_growth = clampf(v, 1.4, 2.5)
		_param_changed()

@export_group("Seeding")
@export var ridge_seeding: bool = false:
	set(v):
		ridge_seeding = v
		_param_changed()

@export_range(0.0, 1.0, 0.05) var ridge_amount: float = 0.5:
	set(v):
		ridge_amount = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Generation")
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_range(64, 512, 32) var resolution: int = 256:
	set(v):
		resolution = clampi(v, 64, 512)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.FROZEN:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake DLA Massif") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_dla"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] DLA"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["seed_surface"])


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve(surface, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve(surface, p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()


func _set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var engine := _make_engine(p_surface, p_gw, p_gh, p_rect)
	var state := {}
	engine.grow_into(state)
	var field: PackedFloat32Array = state.get("field", PackedFloat32Array())
	var grown_n: int = int(state.get("n", 0))
	var dims: Vector2i = state.get("dims", Vector2i.ZERO)
	var height := PackedFloat32Array(); height.resize(n)
	var mask := PackedFloat32Array(); mask.resize(n)
	if field.is_empty() or grown_n <= 0 or dims.x <= 0 or dims.y <= 0:
		return [height, mask]

	var cropped: PackedFloat32Array = engine._crop(field, grown_n, dims.x, dims.y)
	var w := dims.x
	var h := dims.y
	var input_wired := _is_input_wired(p_surface)
	for iz in range(p_gh):
		var row := iz * p_gw
		var v := (float(iz) + 0.5) / float(p_gh)
		var fy := v * float(h - 1)
		for ix in range(p_gw):
			var i := row + ix
			if input_wired and is_nan(p_surface[i]):
				height[i] = NAN
				mask[i] = 0.0
				continue
			var u := (float(ix) + 0.5) / float(p_gw)
			var fx := u * float(w - 1)
			var s := _bilinear01(cropped, w, h, fx, fy)
			mask[i] = s
			height[i] = amplitude * s
	return [height, mask]


func _make_engine(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Object:
	var e = ReliefDLA.new()
	e.coverage = coverage
	e.resolution = resolution
	e.hierarchy_levels = hierarchy_levels
	e.detail_size = detail_size
	e.wander = wander
	e.seed = seed
	e.blur_levels = blur_levels
	e.blur_growth = blur_growth
	e.profile_power = profile_power
	e.ridge_seeding = ridge_seeding
	e.ridge_amount = ridge_amount
	e._host_ex = maxf(p_rect.size.x * 0.5, 0.001)
	e._host_ez = maxf(p_rect.size.y * 0.5, 0.001)
	if ridge_seeding and _is_input_wired(p_surface):
		var dx := p_rect.size.x / float(maxi(p_gw, 1))
		var dz := p_rect.size.y / float(maxi(p_gh, 1))
		var ex := p_rect.size.x * 0.5
		var ez := p_rect.size.y * 0.5
		var frame := [p_rect.position.x + ex, p_rect.position.y + ez, 1.0, 0.0, ex, ez,
				p_rect.position.x + 0.5 * dx, p_rect.position.y + 0.5 * dz, dx]
		e._seed = {"surface": p_surface, "gw": p_gw, "gh": p_gh, "frame": frame}
		e._seed_hash = hash(p_surface) ^ (hash(p_gw) * 31)
	return e


func _is_input_wired(p_surface: PackedFloat32Array) -> bool:
	for v in p_surface:
		if v != 0.0:
			return true
	return false


func _bilinear01(g: PackedFloat32Array, w: int, h: int, fx: float, fy: float) -> float:
	var x0 := clampi(int(fx), 0, w - 1)
	var y0 := clampi(int(fy), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var a := g[y0 * w + x0]
	var b := g[y0 * w + x1]
	var c := g[y1 * w + x0]
	var d := g[y1 * w + x1]
	return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h
