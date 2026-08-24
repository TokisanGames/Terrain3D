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


@export_group("Water")

## Metres from the loop's lowest rim point to the water surface. Negative sits the water below the
## rim, which is where a basin's water actually is; 0 is brim-full and anything above spills.
##
## This IS the pool's `fill_offset` -- same frame, same sign, same number -- pushed onto whatever
## Pasture3DPool this pond owns, and used again as the seed when Add Water next fires. Reading it on
## the pool is reading this value back. There is no conversion anywhere, which is the whole reason
## the rim was chosen as the reference: the brush dial and the pool dial cannot disagree.
##
## The useful band is [-height, 0]. Past -height the surface is under the basin floor and the pond is
## dry; above 0 it is over the rim and will pour out of the low side. Both are WARNED about rather
## than clamped -- a pond being deepened passes through the dry band on the way, and a dial that eats
## the number you typed is worse than one that tells you what you did.
##
## Does nothing on a pond whose loop has been OPENED. An open curve becomes a Pasture3DStream, whose
## surface comes from the banks it flows between and whose `fill_offset` is only the no-terrain
## fallback -- pasture3d_stream.gd greys it out for exactly this reason.
##
## See PASTURE3D_POND_WATER_OFFSET_SPEC.md.
@export var water_offset: float = -0.5:
	set(v):
		water_offset = v
		_apply_water_offset()
		update_configuration_warnings()

## Re-level this pond's water on `water_offset`, now.
##
## For the two cases the on-change push deliberately does not chase: the terrain under the rim has
## moved, or the pool was edited by hand. See _apply_water_offset.
@export_tool_button("Level Water") var _level_btn = level_water

## Fill the basin with water automatically, once, as soon as it has a usable loop.
##
## Off does not remove water that is already there -- it stops this pond seeding any more. The
## Add Water button on the brush stays available either way.
@export var auto_add_water: bool = true:
	set(v):
		auto_add_water = v
		if v:
			_seed_setup.call_deferred()

@export_group("")

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


## ---- the water level (PASTURE3D_POND_WATER_OFFSET_SPEC.md) ----

## The fill_offset a pool created by this pond starts with. The base class applies it in
## _build_pool_for, before the node is in the tree, so the seeded level is right on the first press.
func _pool_fill_offset() -> float:
	return water_offset


## Push `water_offset` onto the pools this pond owns, and re-level them.
##
## ONE-WAY, and ONLY ON CHANGE. Called from the setter and from level_water(), and deliberately NOT
## from _ready(): on load there is nothing to fix -- the pool has its own saved fill_offset and its
## own saved transform, both already whatever the last edit made them -- and a push on load would
## instead re-derive the level from the CURRENT rim every time the scene opens. The brushes re-snap
## their spline points to the terrain surface, so that rim moves. That is exactly the drift
## fit_to_curve()'s "never automatic" note exists to prevent, reintroduced through a side door and
## firing on scene load rather than on a button. When the two have drifted apart the configuration
## warning says so and the Level Water button fixes it.
##
## DERIVED, NEVER ACCUMULATED, and that is load-bearing rather than stylistic. An inspector edit to
## water_offset gets Godot's own undo action over that one property; these pool writes are not in it
## and do not need to be, because the level is a pure function of water_offset and the rim. Undo
## restores the property, this runs again, the water moves back. A version that did
## `fill_offset += delta`, or that remembered what it pushed last, would break Ctrl+Z silently --
## the property would revert and the water would not.
func _apply_water_offset() -> void:
	# The setter runs during deserialisation too, before any child exists. Not merely defensive:
	# this is the guard that keeps a load from being a push.
	if not is_inside_tree() or not is_configured():
		return
	for s in _get_splines():
		var p := pool_for_spline(s)
		if p == null:
			continue
		# A Pasture3DStream's fill_offset is only the fallback its banks override, and read-only
		# whenever there is terrain to sample. Writing it would look like it worked.
		if _is_stream(p):
			continue
		if not is_equal_approx(p.fill_offset, water_offset):
			p.fill_offset = water_offset
		# Y only. fit_to_curve() would re-seat XZ as well, and its own note says it is never
		# automatic; a water_offset edit should move the level and nothing else.
		p.level_to_spline()


## The Level Water button. Same push, on demand, for after the rim moved or the pool was hand-edited.
func level_water() -> void:
	_apply_water_offset()
	update_configuration_warnings()


## The Pasture3DPools this pond owns, skipping streams. Shared by the push and the warnings so the
## two cannot disagree about which bodies this pond is speaking for.
func _owned_pools() -> Array:
	var out: Array = []
	if not is_inside_tree():
		return out
	for s in _get_splines():
		var p := pool_for_spline(s)
		if p != null and not _is_stream(p):
			out.append(p)
	return out


## True when this water body is a river ribbon rather than a filled loop.
##
## By SCRIPT PATH and not `body is Pasture3DStream`, for the reason STREAM_SCRIPT itself is a path:
## a class_name reference is a parse-time dependency, and a syntax error in stream.gd — or an
## install without it — would stop this file compiling and take every pond in the scene down with
## it. Walks the base chain so a project's own subclass of Pasture3DStream still counts as one.
func _is_stream(p_body: Node) -> bool:
	var s := p_body.get_script() as Script
	while s != null:
		if s.resource_path == STREAM_SCRIPT:
			return true
		s = s.get_base_script()
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

	# The water level, out of its band in either direction. Warned rather than clamped -- see the
	# water_offset docstring.
	if water_offset > 0.0:
		warnings.append(("The water surface is %.2f m ABOVE the loop's lowest rim point, so it is "
			+ "over the edge of the basin — it will pour out of the low side and read as a plane "
			+ "clipping through the bank. Lower `water_offset` below 0.") % water_offset)
	elif height > 0.0 and water_offset <= -height:
		# Guarded on a positive height: a pond with height <= 0 carves no basin at all, and
		# "raise water_offset above -(-4.00)" is not advice.
		#
		# Approximate on purpose: the floor is at per-pixel terrain minus `height`, while
		# water_offset is measured from the lowest baked RIM point. Those coincide on flat ground
		# and diverge on a slope, so this is "you have gone past the depth you asked for", not a
		# geometric proof — hence "implied by".
		warnings.append(("The water surface is at or below the basin floor implied by `height` "
			+ "(%.2f m), so this pond is dry — the mesh is buried and nothing will be visible. "
			+ "Raise `water_offset` above -%.2f.") % [height, height])

	# The pond and its water disagreeing. This is what pays for the push being on-change only: a
	# hand edit on the pool is kept, and without this the disagreement would be silent.
	for p in _owned_pools():
		var fo: float = p.fill_offset
		if absf(fo - water_offset) > 0.001:
			warnings.append(("'%s' sits at fill_offset %.2f but this pond's `water_offset` is "
				+ "%.2f. The brush pushes only when the value changes, so a hand edit on the pool "
				+ "stays. Press Level Water to re-apply, or set `water_offset` to %.2f.")
				% [p.name, fo, water_offset, fo])

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
