# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPond — a Mound turned upside down, that fills itself.
#
# Making a pond was already possible: drop a Pasture3DMound, set invert, set blend_mode to MIN,
# press Add Water. Three non-obvious steps, two of which are the same decision stated twice, and
# the first one is a brush named after the opposite of what you want. This is that sequence with
# a name on it.
#
# WHAT MAKES IT CARVE. `invert` flips the stamp (mound.gd: `sign = -1.0 if invert else 1.0`) so
# `height` measures DOWN from the terrain, and MIN keeps the lower of stamp and ground so the
# basin cuts in without the rim ever rising. Either alone is wrong: MIN with an un-inverted dome
# sits above the ground and MIN discards it entirely, which reads as "the brush does nothing".
#
# See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §4 for the Mound this inherits, and
# PASTURE3D_WATER_BODIES_SPEC.md §7.8 for the Add Water button it presses.
@tool
@icon("res://addons/pasture_3d/icons/brush_mound.svg")
class_name Pasture3DPond
extends Pasture3DMound


## Fill the basin with water automatically, once, as soon as it has a usable loop.
##
## Off does not remove water that is already there -- it stops this pond seeding any more. The
## Add Water button on the brush stays available either way.
@export var auto_add_water: bool = true:
	set(v):
		auto_add_water = v
		if v:
			_seed_setup.call_deferred()

## Give a freshly added pond its starter loop, so dropping one in carves a basin immediately.
##
## The Place-Brush tool builds a spline for whatever it drops, but Add Child Node does not -- and a
## brush with no spline paints nothing, reports "Add at least one spline", and reads as a broken
## tool. Every other brush has that behaviour too; a Pond wears it worst, because "add a pond" is
## meant to be the whole interaction.
@export var auto_add_loop: bool = true

## Bookkeeping: this pond has already seeded its loop / its water.
##
## PERSISTED, and that is the whole point of them. Without these, reopening a scene would re-add a
## loop and re-add water that the user had deliberately deleted, every time, and the only way to
## keep a dry or empty pond would be to remember to turn the toggles off first. Hidden from the
## inspector by _validate_property -- they record something that happened, they are not settings.
@export var _water_seeded: bool = false
@export var _loop_seeded: bool = false


func _init() -> void:
	# The inverted-MIN pair that makes this a basin rather than a hill. Set here rather than
	# documented as "remember to change these two", which is the tool this replaces.
	invert = true
	blend_mode = BlendMode.MIN
	# Depth, now that the stamp points down. A Mound's 20 m is a hill you can see from the next
	# valley; as a pond it is a quarry.
	height = 4.0
	# Flat floor. An uncapped cone bottoms out at a point, so the water over it would be 4 m deep
	# in the middle and paper-thin everywhere else -- and depth is what the shader's colour and
	# shore foam read, so a cone reads as a stain rather than a pond.
	capped = true
	falloff_width = 8.0


func _ready() -> void:
	super()
	if not Engine.is_editor_hint():
		return
	# A pond placed by the Place-Brush tool has its spline attached AFTER _ready, so water seeding
	# has to be attempted again when one turns up rather than only here.
	if not child_entered_tree.is_connected(_on_child_added_for_seed):
		child_entered_tree.connect(_on_child_added_for_seed)
	_seed_setup.call_deferred()


func _on_child_added_for_seed(_child: Node) -> void:
	_seed_setup.call_deferred()


## Loop first, then water, in one deferred pass so the order is guaranteed: _try_seed_water needs a
## fillable loop to exist, and seeding them from two independent deferred calls would race.
##
## THE EDITOR GUARD LIVES HERE, not in the two primitives below. This is the automatic entry point
## -- the one a running game must never trip, because spawning splines and water nodes at runtime
## is authoring, not gameplay. Keeping it out of _try_seed_loop / _try_seed_water leaves those
## callable by a gate, which is the difference between this behaviour being tested and being
## asserted: the first version guarded inside them and the check could not reach the feature at all.
func _seed_setup() -> void:
	if not Engine.is_editor_hint():
		return
	_try_seed_loop()
	_try_seed_water()


## Give this pond a starter loop if it has none.
##
## Guarded on _loop_seeded and not merely on "has no splines": otherwise deleting the loop of a
## pond you wanted to keep dry would hand it a new one on the next scene load, forever.
func _try_seed_loop() -> void:
	if _loop_seeded or not auto_add_loop:
		return
	if not is_inside_tree() or not is_configured():
		return
	if not _get_splines().is_empty():
		# Placed by the tool, or the user added a Path3D. Nothing to seed, but record it so this
		# never fires later if that spline is removed.
		_loop_seeded = true
		return
	_loop_seeded = true
	add_spline() # _new_spline() + refresh(), so the basin is carved rather than merely outlined


## Press Add Water once, when there is something to fill.
##
## Deferred by every caller: a spline that has just entered the tree has not necessarily had its
## curve assigned yet, and add_pool_now() reads the curve to decide loop-versus-ribbon.
##
## add_pool_now() is itself idempotent per spline (it skips any spline that already has a pool),
## so the _water_seeded flag is not what prevents duplicates -- it prevents the RE-seed after a
## user deletes the water, which idempotency cannot see.
func _try_seed_water() -> void:
	if _water_seeded or not auto_add_water:
		return
	if not is_inside_tree() or not is_configured():
		return
	if not _has_fillable_loop():
		return
	var made := add_pool_now()
	if not made.is_empty():
		_water_seeded = true


## A closed loop with enough points to enclose an area. Checked before calling add_pool_now()
## rather than letting it decide, because its own answer for "nothing usable" is a push_warning,
## and a pond that has simply not been given its loop yet has done nothing to warn about.
func _has_fillable_loop() -> bool:
	for s in _get_splines():
		if s.curve != null and s.curve.closed and s.curve.point_count >= _min_points():
			return true
	return false


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := super()
	# A basin that reaches past the built world carves only the covered part, silently: the rasteriser
	# drops cells with no region under them and says nothing. A pond is where this bites first, because
	# a lake is the brush people scale up — at the 256 m default a 2 km loop spans 121 regions — and a
	# half-carved basin filled with water reads as a broken brush rather than a missing region.
	var cov := _region_coverage()
	var missing: int = cov[0]
	if missing > 0:
		warnings.append(("This pond reaches into %d region(s) of the %d it spans that do not exist yet. "
			+ "The basin will not be carved there — the rasteriser only writes where there is terrain — "
			+ "so the water will sit on unbuilt ground. Add the regions with the Region tool, or move "
			+ "or shrink the loop.") % [missing, cov[1]])
	return warnings


func _validate_property(property: Dictionary) -> void:
	super(property)
	if property.name in ["_water_seeded", "_loop_seeded"]:
		# Stored, never shown. See the properties' own note.
		property.usage = PROPERTY_USAGE_STORAGE


## Ponds get their own tool layer, and this is not cosmetic: a layer carries ONE blend mode, and
## sharing "Mounds" would put MIN ponds and MAX hills into the same composite. The first pond
## added to a scene with hills in it would either stop carving or start flattening them.
func _default_layer_name() -> String:
	return "Ponds"
