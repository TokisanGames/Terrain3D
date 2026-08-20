# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DBrushModifier — abstract base for one step of a landscape brush's modifier stack: an ordered,
# saveable list of operations applied to the brush's OWN output grid, after its profile is rasterised and
# BEFORE that grid is composited into the terrain layer.
#
# The stack is not a new idea in this plugin so much as an existing one made visible. `stamp_mound_loop`
# already runs `profile -> +noise -> +relief -> blur -> composite` with a fixed order, no repeats and no
# way to insert anything between the steps. Phase 3a of PASTURE3D_BRUSH_EROSION_SPEC.md turns that fixed
# pipeline into this list; the three modifiers shipped with it reproduce it exactly.
#
# ---- POINT vs FIELD, the distinction the whole design rests on (spec §6.1) ----
#
# A POINT modifier sees one cell and its own coordinates. It contributes metres to the brush's amplitude
# at that cell and can be evaluated inside the rasteriser's own loop, in double precision, alongside the
# profile. Noise and Relief are point modifiers, and so is every relief op.
#
# A FIELD modifier needs the whole grid: a blur reads neighbours, an erosion solve routes water across
# the entire footprint. It cannot be expressed as a relief op — `relief_eval(u, v)` has no grid to look
# at — which is the structural reason this stack has to exist at all rather than erosion becoming
# another entry in the relief op catalogue.
#
# The host rasteriser exploits the split: a maximal RUN of point modifiers is folded into one cell loop,
# and only a field modifier forces the working grid to be materialised. A stack of `Noise -> Relief ->
# Smooth` therefore executes as one cell loop plus one blur — which is, instruction for instruction, the
# pipeline it replaces. That is what makes gate BW's "bitwise identical" claim reachable rather than
# aspirational.
@tool
class_name Pasture3DBrushModifier
extends Resource

## The name on this modifier's ROW in the brush's Modifiers list. Without it a stack of three Relief
## steps reads as three identical `Pasture3DModRelief` rows and the only way to find the one you want is
## to open each in turn.
##
## It is a VIEW ONTO `resource_name`, not a second field. Godot's resource picker already prefers
## `resource_name` over the class name when it draws the row, so the storage and the wiring both exist —
## it is just buried at the bottom of the built-in Resource section where nobody looks. Declaring a
## second string would only give the two a way to disagree, so this one is EDITOR-usage only: it is not
## saved, because `resource_name` already is.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var label: String:
	set(v):
		# `Resource.set_name` emits `changed` itself, which is what relabels the row: the host brush
		# rebuilds its property list when — and only when — a modifier's name or the mask-preview list
		# moves (see Pasture3DTerrainBrush._on_modifier_changed).
		resource_name = v
	get:
		return resource_name

## LIVE recomputes on every refresh; FROZEN caches its output and re-solves only when it has nothing
## cached, or on an explicit Bake.
##
## Hidden on the modifiers that do not support it — see `_supports_freezing`. Shipping a control that
## silently does nothing is worse than not shipping it.
enum Evaluation { LIVE, FROZEN }

## Off leaves the modifier in the list, and in the inspector, without applying it. The point is A/B
## comparison: the alternative is deleting a configured modifier to see what it was doing, and then
## rebuilding it.
@export var enabled: bool = true:
	set(v):
		enabled = v
		_touch()


## Whether this modifier recomputes on every refresh, or caches. See `_supports_freezing` for why it is
## only meaningful on some of them.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		_touch()


## True when this modifier is expensive enough that caching its output is worth a staleness problem.
##
## FALSE by default, and the property is hidden when it is. `auto_refresh` re-bakes on every spline drag,
## which is fine for noise, relief and a blur — they cost microseconds. Freezing one of those would be a
## cache for something cheaper than the cache, plus a way for the viewport to disagree with the inspector.
func _supports_freezing() -> bool:
	return false


func _validate_property(property: Dictionary) -> void:
	if property.name == "evaluation" and not _supports_freezing():
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Invalidate and notify the host brush to re-bake. Every exported setter must call this. Mirrors
## Pasture3DReliefMaterial._touch, and for the same reason: the brush listens to `changed` and has no
## other way to learn that a nested resource moved.
func _touch() -> void:
	emit_changed()


## True when this step needs the whole grid rather than one cell. See the header.
func is_field_operator() -> bool:
	return false


## Wire tag the native rasteriser dispatches on. MUST match the string the C++ side tests in
## `brush_mod_kind` (src/pasture_3d_brush_raster.cpp).
func kind() -> StringName:
	return &""


## False when the modifier is present but would contribute nothing — disabled, or configured to zero.
## The host skips it entirely rather than paying for a no-op pass, and, more to the point, a stack whose
## only relief modifier is inactive must not make the brush build the O(cells) field grids for it.
func is_active() -> bool:
	return enabled


## The per-modifier block handed to the native rasteriser. `kind` is added by the caller, and so is the
## cache plumbing for a modifier that supports freezing.
func to_params() -> Dictionary:
	return {}


## Drop every cached output. The host calls this on an explicit Bake; a modifier that caches nothing has
## nothing to do.
func clear_cache() -> void:
	pass


## Cached bytes currently held, so the brush can report a budget nobody would otherwise see.
func cache_bytes() -> int:
	return 0


## Problems worth telling the user about, in the host brush's configuration warnings. `p_host` is the
## Pasture3DTerrainBrush this modifier is mounted on — some complaints are only true for a given host
## (a Host Profile selector under a Plow, say), so the modifier has to be able to ask.
func modifier_warnings(_p_host) -> PackedStringArray:
	return PackedStringArray()


## Human-readable name for warnings: the label the user gave this modifier, or the class name with the
## Pasture3DMod prefix stripped. Warnings say which modifier they are about, and in a stack with three
## Relief steps "Relief modifier" on its own does not.
func display_name() -> String:
	if not resource_name.is_empty():
		return resource_name
	return String(get_script().get_global_name()).trim_prefix("Pasture3DMod")
