# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNodeRelief — a Pasture3DReliefMaterial applied to the brush's own surface, as a modifier stack
# step. The point-operator replacement for Pasture3DMound's `relief` / `relief_strength` pair.
#
#   amp += strength * material.eval(...) * profile * material.strength
#
# THE RELIEF SYSTEM IS UNTOUCHED BY THIS. A modifier is a host for a material, the same way the Mound
# became a second host in PASTURE3D_MOUND_RELIEF_SPEC.md — the op program, the selectors, the host-profile
# field and the GDScript oracle all work exactly as they already do. What changes is that a brush can now
# carry MORE THAN ONE of them, in an order it chooses, with field modifiers in between.
#
# That is the workflow phase 3b is for: shape the mountain with one relief modifier, erode it, then gate a
# second relief modifier's detail on the flow the erosion published — three steps on one node, where today
# it takes a Mound, a Pasture3DSim, a Pasture3DSimResult on disk and a second brush on a higher layer.
#
# Mapping is always TILE: the ops are evaluated in world XZ so relief stays continuous where two brushes
# meet, while radial ops (Crater) read the loop-normalised coordinates and so remain sized and oriented to
# the host's own footprint.
@tool
class_name Pasture3DNodeRelief
extends Pasture3DNode

## The landform material to stamp — craggy fractal, strata, terraces, dunes, scree, craters, or a stack
## of them.
@export var material: Pasture3DReliefMaterial:
	set(v):
		# Live re-bake: the material emits `changed` on every property setter, including its selectors'.
		if material != null and material.changed.is_connected(_touch):
			material.changed.disconnect(_touch)
		material = v
		if material != null and not material.changed.is_connected(_touch):
			material.changed.connect(_touch)
		_touch()

## Metres of relief at the material's full output, masked by the brush's interior profile so the rim
## stays clean. Deliberately separate from the host brush's own height: relief describes the surface
## texture of the landform, and tying its amplitude to the peak would rescale every detail whenever the
## brush was made taller.
@export var strength: float = 0.0:
	set(v):
		strength = v
		_touch()

var _cache: Dictionary = {}
var _stale: bool = false


func _supports_freezing() -> bool:
	return true


func clear_cache() -> void:
	if _cache.is_empty() and not _stale:
		return
	_cache.clear()
	_stale = false
	_touch()


func cache_bytes() -> int:
	var n := 0
	for k in _cache:
		n += (_cache[k].get("grid", PackedFloat32Array()) as PackedFloat32Array).size() * 4
	return n


func cache_for(p_extent: String) -> Dictionary:
	return _cache.get(p_extent, {})


func store_cache(p_extent: String, p_entry: Dictionary) -> void:
	_cache[p_extent] = p_entry


func set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


func op() -> StringName:
	return &"relief"


## An unassigned material or a zero strength is exactly the test the legacy path used to decide whether
## to compile the program at all, and it has to stay that test: it is what keeps the O(cells) terrain and
## host-profile field grids from being built for a modifier that would contribute nothing.
func is_active() -> bool:
	return enabled and material != null and not is_zero_approx(strength)


## `ops` / `op_params` / `op_luts` / `op_fields` are added by the host, which compiles the material once
## per bake and rebases the selector ids into the stack-wide selector block.
func to_params() -> Dictionary:
	return {"strength": strength, "mat_strength": material.strength if material != null else 1.0}


func modifier_warnings(p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if material != null and is_zero_approx(strength) and enabled:
		w.append("%s: a Relief Material is assigned but Strength is 0 m, so it stamps " % display_name()
			+ "nothing. Set Strength to the depth of detail you want, in metres.")
	# The material's own complaint plus the shared sim-selector and periodic-resolution diagnostics. The
	# host owns those because two of the three need the terrain and the splines to answer.
	if p_host != null and material != null:
		w.append_array(p_host._relief_warnings(material))
	return w
