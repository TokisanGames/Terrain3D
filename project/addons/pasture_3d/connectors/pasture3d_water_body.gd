# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DWaterBody — everything a body of water does that is not its shape.
# See PASTURE3D_WATER_BODIES_SPEC.md §7.
#
# A lake and a river disagree about almost nothing. Both read a brush's spline, both debounce their
# rebuilds, both take their waves and their clock and their material from the Pasture3DPoolManager,
# both raise an Area3D and tint the screen when the camera goes under, and both answer
# get_water_height() so a buoy does not have to know which it is floating on. What they disagree
# about is the SHEET: a lake is a flat polygon at one level, a river is a strip that runs downhill
# between banks it has to go and measure.
#
# That disagreement used to be an `if` in the middle of a 1900-line file, and it leaked -- ribbon
# state that a loop pool carried and never filled, exports that were live in one mode and dead in
# the other, and a `_is_ribbon` flag that every query had to re-check. This class is the agreement;
# Pasture3DPool and Pasture3DStream are the two disagreements, and each is only as long as what it
# actually does differently.
#
# ABSTRACT BY CONVENTION, not by keyword. GDScript has no abstract class, so the hooks below are
# real methods with honest defaults and a body of this class alone builds nothing. Instantiate a
# Pasture3DPool or a Pasture3DStream.
#
# GDScript, deliberately (spec §4.3): these are authoring nodes, and they live next to the brushes
# whose idioms they borrow -- debounced refresh, internal children that never serialise,
# configuration warnings that name the fix.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DWaterBody
extends Node3D

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
## Group every water body joins, so tools can find them without a tree walk. Named for the pool
## because it predates the split and is written into saved scenes; Pasture3DStream joins the SAME
## group, which is what keeps the selection gizmo, the brush's idempotence check and the Phase 4
## gate working across both without any of them learning about the new class.
const POOL_GROUP: StringName = &"pasture3d_pool"
## Debounce for rebuilds while a spline is being dragged (seconds). Matches the brushes.
const REFRESH_DELAY: float = 0.1

## Default ceiling on generated vertices, and the value `max_vertices` starts at. A body whose
## spacing would exceed this is usually a mistake -- a metre-scale spacing over a kilometre-scale
## loop -- and silently building it locks the editor for minutes.
const DEFAULT_MAX_VERTICES: int = 400000
## The speed ARRAY_COLOR.b == 1 means, in m/s. Must match water_river.gdshader's flow_speed_scale
## default: the mesh normalises against this and the shader multiplies back by it, so a disagreement
## is a river that flows at the wrong rate with nothing to point at.
##
## Here rather than on Pasture3DStream, with FLOW_NEUTRAL below, because the two halves of the flow
## encoding have to be read together: the neutral colour is only "no flow" because it decodes to
## zero under this scale.
const FLOW_SPEED_REF: float = 8.0
## Vertex colour for water that does not flow. Decodes to a zero direction and zero speed, so the
## river shader on a lake stands still rather than sliding diagonally.
const FLOW_NEUTRAL := Color(0.5, 0.5, 0.0, 1.0)

# --- Source -------------------------------------------------------------------

## The spline this body is filled from. Normally a brush's child Path3D: it carries the
## curve AND its world transform, so moving the brush moves the water.
@export var source_spline: Path3D:
	set(v):
		_disconnect_source()
		source_spline = v
		_connect_source()
		_schedule_rebuild()
		update_configuration_warnings()

## Overrides source_spline when set. A Curve3D carries no transform, so its points are
## read in THIS node's space — a curve lifted from a brush whose Path3D is offset will
## land offset. Use source_spline unless you are authoring water with no brush.
@export var curve: Curve3D:
	set(v):
		if curve and curve.changed.is_connected(_on_curve_changed):
			curve.changed.disconnect(_on_curve_changed)
		curve = v
		if curve and not curve.changed.is_connected(_on_curve_changed):
			curve.changed.connect(_on_curve_changed)
		_schedule_rebuild()
		update_configuration_warnings()

@export_tool_button("Rebuild") var _rebuild_btn = rebuild
## Re-seed this node's Y from the curve's lowest point + fill_offset. Never automatic:
## the brushes re-snap their spline points to the terrain surface, so an automatic fit
## would move the water level whenever the ground under the rim changed.
@export_tool_button("Fit to Curve") var _fit_btn = fit_to_curve

# --- Shape --------------------------------------------------------------------

@export_group("Shape")
## Metres the mesh is grown outward past the curve, so its rim is buried in the bank
## rather than ending in open air. The shader's shore foam and depth fade then dissolve
## the intersection. Negative contracts.
@export var edge_offset: float = 2.0:
	set(v):
		edge_offset = v
		_schedule_rebuild()
## Metres added to the surface height when the level is taken from the spline. Negative sits the
## water below the rim, which is where a basin's water actually is.
##
## Applied by Fit to Curve, and on every rebuild when `level_from_spline` is on -- which is what
## makes this a live dial rather than a number that only means something the moment a button is
## pressed.
##
## On a Pasture3DStream this is the FALLBACK level rather than the level: the surface comes from
## the banks whenever there is terrain to sample, and this is what a stream over a bare mesh gets
## instead. See Pasture3DStream._apply_bank_surface.
@export var fill_offset: float = -0.5:
	set(v):
		fill_offset = v
		_schedule_rebuild()
## Take the water level from the spline on every rebuild, instead of only when Fit to Curve is
## pressed. `fill_offset` then becomes a live dial: type a depth and the water moves.
##
## OFF BY DEFAULT, and the reason is worth reading before turning it on. The brushes re-snap their
## spline points to the terrain surface, so with this on the water level follows the GROUND under
## the rim -- sculpt the basin deeper and the water goes down with it. That is either exactly what
## you want or a level that will not hold still, depending on whether the spline is the thing you
## are authoring the level with. Fit to Curve stays the one-shot version for the other case.
##
## Needs a `source_spline`. A bare `curve` is authored in this node's own space, so its rim travels
## with the node and there is no level to solve for -- see fit_to_curve().
@export var level_from_spline: bool = false:
	set(v):
		level_from_spline = v
		_schedule_rebuild()
		update_configuration_warnings()
## Ceiling on generated vertices, for when a body genuinely needs to be denser than the
## default guard allows. This is the water body's frame-time dial in the same sense mesh_size is
## the ocean's: raise it to buy resolution on a large body, lower it to catch a spacing
## mistake sooner. The build refuses to run past it and says so in the configuration
## warnings rather than locking the editor.
@export var max_vertices: int = DEFAULT_MAX_VERTICES:
	set(v):
		max_vertices = maxi(v, 4)
		_schedule_rebuild()
## Metres between surface vertices. 0 = automatic, at a eighth of the wave profile's
## shortest wavelength — the ratio the water guide §7 requires. Waves are a VERTEX
## effect, so this is correctness, not taste: too coarse and the drawn surface cuts the
## corners off crests and drifts from what get_water_height() reports.
@export var vertex_spacing: float = 0.0:
	set(v):
		vertex_spacing = maxf(v, 0.0)
		_schedule_rebuild()
## Force the GDScript reference mesher even when the native one is available. The two are
## transcriptions of each other and are meant to agree exactly, so this is the A/B switch —
## toggle it and compare shape and timing on the same body. Same idea, and the same name shape,
## as Pasture3DTerrainBrush.force_gdscript_raster. Leave off in normal use.
##
## Only Pasture3DPool has a native path to switch away from; on a Pasture3DStream this is inert
## and stays visible so it does not read as a property that went missing.
@export var force_gdscript_mesh: bool = false:
	set(v):
		force_gdscript_mesh = v
		_schedule_rebuild()

# --- Water --------------------------------------------------------------------

@export_group("Water")
## Which wave profile on the Pasture3DPoolManager drives this body. Shown as a dropdown
## of the live profile names; see _validate_property.
@export var wave_profile: StringName = &"lake_calm":
	set(v):
		wave_profile = v
		_apply_material()
		update_configuration_warnings()
## Which shipped preset to use, or Custom to keep `material` as given. The ENTRIES come from the
## subclass (_preset_names / _preset_paths) -- a lake and a river are not the same list, and a
## dropdown offering "Pond" on a river would be offering something that does not work: the river
## preset reads a flow direction out of ARRAY_COLOR that only a stream's mesh writes.
##
## Declared as a plain int and re-hinted in _validate_property, for the same reason wave_profile is:
## an @export_enum here would be a second, fixed list that the subclasses could not replace.
@export var water_preset: int = 0:
	set(v):
		water_preset = clampi(v, 0, _custom_preset())
		var paths := _preset_paths()
		if paths.has(water_preset):
			material = load(paths[water_preset])
		_apply_material()
		notify_property_list_changed()
@export var material: Material:
	set(v):
		material = v
		_apply_material()
		update_configuration_warnings()
## Duplicate the resolved material into this scene so tuning it cannot be overwritten
## by a plugin update, and switch to Custom.
@export_tool_button("Make Unique") var _unique_btn = make_unique
## Write the scene-local material to a .tres and re-point at it, so tuned water becomes
## a reusable project asset instead of being trapped in one scene.
@export_tool_button("Save Unique Material") var _save_btn = save_unique_material
## Explicit manager, for a scene with more than one. Empty = the scene's active one.
@export var manager: Node

# --- Underwater (spec §8) -----------------------------------------------------

@export_group("Underwater")
## Build the submersion volume at all. Off = no Area3D, no fog, no overlay, no camera poll —
## for water that is scenery and will never be swum in.
@export var underwater_enabled: bool = true:
	set(v):
		underwater_enabled = v
		_rebuild_volume()
		update_configuration_warnings()
## Metres the volume extends BELOW the surface. Not a depth measurement of the basin — it is how
## far down "in this water" reaches, and a body below it has sunk out of this water's care.
@export var volume_depth: float = 20.0:
	set(v):
		volume_depth = maxf(v, 0.1)
		_rebuild_volume()
## Spawn a FogVolume matching the box, tinted from the water material. Needs
## Environment.volumetric_fog_enabled; the body warns when that is off rather than doing nothing.
@export var underwater_fog: bool = true:
	set(v):
		underwater_fog = v
		_rebuild_volume()
		update_configuration_warnings()
## Multiplies the fog density derived from the material's `absorption`. Absorption is a per-metre
## extinction in the surface shader's Beer-Lambert term; fog wants a density, and this is the
## conversion factor between them.
@export var underwater_density_scale: float = 0.15:
	set(v):
		underwater_density_scale = maxf(v, 0.0)
		_apply_fog_material()
## Spawn the screen effect when the camera goes under. Runtime only — a plugin that tints the
## EDITOR viewport because the camera dipped below a plane is a bug report waiting to happen.
@export var underwater_overlay: bool = true
## CanvasLayer index for that overlay. Raise it above your HUD if the HUD should be tinted too.
@export var overlay_canvas_layer: int = 1
## Seconds to ramp the overlay in and out across the surface crossing, so it is not a single-frame
## pop. Independent of the wave clock.
@export var overlay_transition: float = 0.25

# --- Signals ------------------------------------------------------------------

## A physics body's origin crossed into / out of this water. Emitted from the Area3D's own
## signals, re-filtered through is_point_underwater() so a concave lake does not claim a peninsula.
signal body_submerged(body: Node3D)
signal body_surfaced(body: Node3D)
## The active camera crossed the surface. A Camera3D is not a physics body and generates no area
## signals at all, so this comes from a poll (see _poll_camera).
signal camera_submerged(submerged: bool)

# --- Internals ----------------------------------------------------------------

var _surface: MeshInstance3D = null
var _timer: SceneTreeTimer = null
var _dirty := false
var _last_stats := {}
## World transform of source_spline as of the last rebuild. See _process.
var _source_xform := Transform3D()
## This node's own world XZ as of the last transform notification, so a Y-only move can be told
## from one that slides the body off its spline. See _notification.
var _last_xz := Vector2.INF
## Last resolved manager. See _resolve_manager.
var _manager_cache: Node = null
## LOCAL XZ bounds of whatever was last built. The broad phase for every containment query and the
## footprint the underwater volume spans, so both subclasses have to set it -- a body that builds a
## mesh and leaves this empty is a body nothing can be inside of.
var _poly_bounds := Rect2()

var _volume: Area3D = null
var _volume_shape: CollisionShape3D = null
var _fog: FogVolume = null
## Bodies currently inside the Area3D box -> whether they were last reported as submerged. The box
## is the broad phase; the polygon test that refines it has to be re-run as they move, which is why
## this is a set and not just a pair of signal handlers.
var _bodies_in_box := {}
var _camera_under := false
## One-entry memo for get_water_height(); see the docstring there. Vector2.INF cannot be a
## real query, so the first call in any frame misses.
var _height_cache_xz := Vector2.INF
var _height_cache_frame := -1
var _height_cache_y := 0.0
## Physics frame on which the group scan in _resolve_manager() last came back empty, so the
## scan is attempted at most once a frame rather than once a call.
var _manager_miss_frame := -1
## Has this body handed itself to a manager yet? Drives the retry in _physics_process; see
## _register() for why registration cannot be a once-only act.
var _manager_registered := false
var _overlay_layer: CanvasLayer = null
var _overlay_rect: ColorRect = null
var _overlay_amount := 0.0


# ==== the subclass contract ===================================================
#
# Eight hooks. The first four are the shape; the rest are the trimmings. Gathered here rather than
# scattered through the file so that adding a third kind of water -- a waterfall, a canal -- is a
# matter of reading one block and answering it.

## Build the surface mesh at this spacing, and fill in `_last_stats` and `_poly_bounds`.
##
## Called from rebuild(), which has already reset the stats dict, baselined the spline watcher and
## started the clock -- so an implementation sets "ok", the counts and any "reason", and does not
## time itself. Must call _ensure_surface()/_apply_material()/_apply_cull_box()/_rebuild_volume()
## on success and _clear_surface() on failure.
func _build_surface(_p_spacing: float) -> void:
	_last_stats["reason"] = "Pasture3DWaterBody is abstract; use Pasture3DPool or Pasture3DStream"


## Is this LOCAL XZ point over the water, ignoring height? Called after the _poly_bounds broad
## phase has already said yes, so it is the exact test and may be as expensive as the shape needs.
func _contains_local(_p_local_xz: Vector2) -> bool:
	return false


## Is there a built surface to be inside of at all? Cheaper than asking the mesh, and it is what
## makes is_point_underwater() return false rather than walking an empty structure.
func _has_surface() -> bool:
	return false


## The STILL water level at a world XZ, before waves. The node's own Y for a flat sheet; a stream
## overrides it because a river runs downhill and has no single level.
##
## Kept separate from _contains_local, rather than folded into one query returning both, because
## this is on the physics tick for every buoy in the scene and a flat body must be able to answer
## it without touching its geometry.
func _still_surface_y(_p_global_xz: Vector2) -> float:
	return global_position.y


## Entries for the water_preset dropdown. The LAST one is Custom by convention (see _custom_preset).
func _preset_names() -> PackedStringArray:
	return PackedStringArray(["Custom"])


## preset index -> material path, for the entries that have one. Custom is absent by construction:
## it is the entry that means "leave `material` alone".
func _preset_paths() -> Dictionary:
	return {}


## Shape-specific configuration warnings, appended to the shared ones.
func _shape_warnings() -> PackedStringArray:
	return PackedStringArray()


## True when this water is a strip following an open curve rather than a filled outline. Public
## because the guide and the gates ask it; answered by the CLASS now rather than by re-reading the
## curve's closed flag on every rebuild, which is the whole point of the split.
func is_ribbon() -> bool:
	return false


# ==== lifecycle ===============================================================

func _ready() -> void:
	add_to_group(POOL_GROUP)
	set_notify_transform(true)
	_connect_source()
	if curve and not curve.changed.is_connected(_on_curve_changed):
		curve.changed.connect(_on_curve_changed)
	_register()
	rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		add_to_group(POOL_GROUP)
		_register()
	elif what == NOTIFICATION_EXIT_TREE:
		remove_from_group(POOL_GROUP)
		_unregister()
		_manager_cache = null # water moved between scenes must re-resolve, not keep the old scene's
		_manager_miss_frame = -1 # ...and must not inherit a "there is none" from the old scene either
		# Re-attempted on the next enter: this water may come back under a different manager,
		# or under one that does not exist yet.
		_manager_registered = false
		_height_cache_frame = -1
		# The overlay is a CanvasLayer: leaving it up after the water has gone would tint a scene
		# with no water in it.
		_drop_overlay()
		_camera_under = false
		_overlay_amount = 0.0
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		# The surface height IS this node's Y, so moving it in Y moves the water level and
		# the mesh (built flat, in local space) needs nothing.
		#
		# XZ is not symmetric with that. With a source_spline the geometry is read in WORLD
		# space and then expressed relative to this node, so an XZ move has to be compensated
		# by a rebuild — otherwise the mesh slides off its spline and stays there until the
		# next curve edit silently snaps it back. With a bare `curve` the points are in this
		# node's space and genuinely travel with it, so there is nothing to recompute.
		# XZ, specifically. The comment above already says a Y move needs nothing, but this used
		# to fire on ANY transform change -- harmless while nothing wrote the transform from inside
		# a build, and an endless debounced rebuild loop the moment level_from_spline does.
		var pos := global_position
		var moved_xz := not (is_equal_approx(pos.x, _last_xz.x) and is_equal_approx(pos.z, _last_xz.y))
		_last_xz = Vector2(pos.x, pos.z)
		if moved_xz and curve == null and source_spline != null and is_instance_valid(source_spline):
			_schedule_rebuild()
		# The domain origin is this node's position — it is what keeps wave phase precise far
		# from the world origin — so it follows the node, not just a material assignment.
		_update_domain_origin()
		# get_water_height()'s memo is keyed on world XZ, but the answer also depends on
		# this node's position through _wave_domain(). Moving the water inside a frame
		# would otherwise hand back the pre-move height for the rest of it.
		_height_cache_frame = -1
		update_gizmos()
	elif what == NOTIFICATION_PREDELETE:
		_unregister()


# ---- source plumbing ---------------------------------------------------------

func _connect_source() -> void:
	if source_spline == null or not is_instance_valid(source_spline):
		return
	if not source_spline.curve_changed.is_connected(_on_curve_changed):
		source_spline.curve_changed.connect(_on_curve_changed)
	if source_spline.curve and not source_spline.curve.changed.is_connected(_on_curve_changed):
		source_spline.curve.changed.connect(_on_curve_changed)


func _disconnect_source() -> void:
	if source_spline == null or not is_instance_valid(source_spline):
		return
	if source_spline.curve_changed.is_connected(_on_curve_changed):
		source_spline.curve_changed.disconnect(_on_curve_changed)
	if source_spline.curve and source_spline.curve.changed.is_connected(_on_curve_changed):
		source_spline.curve.changed.disconnect(_on_curve_changed)


func _on_curve_changed() -> void:
	_schedule_rebuild()


## Follow the source spline when it MOVES, as opposed to when its points change.
##
## The body reads its geometry through `source_spline.global_transform`, so dragging the
## brush -- or the Path3D under it, or any ancestor of either -- changes where the water
## is, and its shape if there is any rotation or scale. None of that emits a signal the
## water could connect to: Node3D transform notifications reach the node that moved and
## its children, and a water body is a SIBLING of its brush by design (§7.7), so it is in
## neither set. A once-per-frame Transform3D comparison is the honest way to see it.
##
## The transform watch costs one is_equal_approx per body per frame and a debounced rebuild
## only when the answer changes, which is why it is not gated to the editor: a runtime scene
## that moves a brush should move its water too, and paying microseconds to make that true
## everywhere is better than an editor-only behaviour that surprises someone at runtime.
##
## It is not the only thing here, though, and it is by far the cheapest — the two calls above
## it are the ones to watch. _poll_camera() ends in a full wave solve for any body the camera
## is over, and both it and _update_overlay() bail immediately when their feature is off, so
## the "microseconds" claim holds only for a body that is not using them. Anything added here
## is on the render frame of every water body in the scene.
func _process(p_delta: float) -> void:
	_poll_camera()
	_update_overlay(p_delta)
	if source_spline == null or not is_instance_valid(source_spline):
		return
	var xf := source_spline.global_transform
	if not xf.is_equal_approx(_source_xform):
		_source_xform = xf
		_schedule_rebuild()


## Debounced, because dragging one spline handle emits `changed` every mouse move and a
## 500 m lake is not a per-frame rebuild. Same idiom as Pasture3DTerrainBrush.
func _schedule_rebuild() -> void:
	if not is_inside_tree():
		return
	_dirty = true
	if _timer != null:
		return
	_timer = get_tree().create_timer(REFRESH_DELAY)
	_timer.timeout.connect(func():
		_timer = null
		if _dirty:
			_dirty = false
			rebuild())


# ---- the manager -------------------------------------------------------------

## The manager driving this water, cached.
##
## The cache is not premature. get_water_height() calls this, and Phase 6 puts that on the physics
## tick for every buoy in the scene — 64 buoys is 64 calls, each of which was allocating an Array
## from get_nodes_in_group() and throwing it away. Held by instance id rather than by reference so a
## freed manager cannot be resurrected by the cache, and re-resolved whenever it goes invalid.
func _resolve_manager() -> Node:
	if manager != null and is_instance_valid(manager):
		return manager
	if _manager_cache != null and is_instance_valid(_manager_cache) \
			and _manager_cache.is_inside_tree():
		return _manager_cache
	if not is_inside_tree():
		return null
	# The MISS is throttled too, not just the hit. With no manager in the scene
	# _manager_cache stays null, so without this the group scan below ran on every call —
	# allocating and discarding an Array per buoy per physics tick, which is the exact cost
	# the cache was added to remove, surviving in the one case nothing else covers. A scene
	# whose manager was forgotten is precisely the misconfiguration the node warns about,
	# so it is not a rare path.
	var frame := Engine.get_physics_frames()
	if _manager_miss_frame == frame:
		return null
	var found := get_tree().get_nodes_in_group(&"pasture3d_water_manager")
	if found.is_empty():
		_manager_cache = null
		_manager_miss_frame = frame
		return null
	_manager_cache = found[0]
	return _manager_cache


## Manager profile names the `wave_profile` hint was last built from. A comparison cache only —
## a stale one after a scene load costs at most one extra re-hint.
var _profile_names_cache: PackedStringArray = PackedStringArray()


## Join the manager's registry and its profiles_changed signal, if there is a manager yet.
##
## RETRIED from _physics_process, not attempted once. This used to run only in _ready and
## ENTER_TREE, which made sibling order decide it: a body that enters the tree above its
## Pasture3DPoolManager saw an empty group, registered with nothing, and nothing ever looked
## again. It then stayed invisible to body_at() for the life of the scene — a buoy floating
## on it got no body and fell through — and missed every profile change, all decided by
## which node happens to sit higher in the inspector. Pasture3DOcean had the identical bug
## and the identical fix; see Pasture3DOcean::_try_register_with_manager().
##
## Cheap once it lands: the flag makes it one bool test per body per tick. Before it lands
## it costs at most one group scan per frame, because _resolve_manager() throttles the miss
## — which is why this no longer forces a fresh scan. It used to, on the reasoning that a
## once-only registration must never read a stale miss; retrying every tick inverts that,
## and the throttle becomes the thing that keeps the retry affordable.
func _register() -> void:
	if _manager_registered:
		return
	var m := _resolve_manager()
	if m == null or not m.has_method("register_body"):
		return
	m.register_body(self)
	if m.has_signal("profiles_changed") and not m.profiles_changed.is_connected(_on_profiles_changed):
		m.profiles_changed.connect(_on_profiles_changed)
		# Prime the name cache HERE, where the hint this node is carrying was in fact built from the
		# list the manager holds right now. Left cold, the very first `profiles_changed` — whatever
		# caused it — would read as "the names moved" and rebuild the inspector once for nothing.
		_profile_names_moved()
	_manager_registered = true
	# A body that built before the manager existed chose its vertex spacing from the 1.0
	# fallback and its cull box from an assumed amplitude, because both read the profile
	# through the manager. Now that there is one, the wavelength rule can actually apply.
	#
	# Guarded on _has_surface() so this does not fire during _ready, where _register() runs
	# just ahead of the rebuild() that would satisfy it anyway — scheduling there would set
	# _dirty and buy a second, redundant rebuild a moment later.
	if vertex_spacing <= 0.0 and _has_surface():
		_schedule_rebuild()


func _unregister() -> void:
	var m := _resolve_manager()
	if m and m.has_method("unregister_body"):
		m.unregister_body(self)


func _on_profiles_changed() -> void:
	# The dropdown is built from the manager's live names (see _validate_property), so a
	# profile added or renamed has to re-hint the property or the list goes stale.
	#
	# ONLY THEN, though. `profiles_changed` also fires for every knob on every profile, and
	# re-hinting is an inspector rebuild, which collapses every expanded sub-resource on this
	# node — so dragging an amplitude slider on the manager folded up whatever a selected
	# water body had open. Same rule as the brush stack's `_inspector_rebuild_signature`: the
	# property list may depend on structure, never on a value.
	if _profile_names_moved():
		notify_property_list_changed()
	# A profile knob moved. The table is re-uploaded by the manager into the shared
	# material, but the wavelength may have changed, and vertex spacing is derived
	# from it — so the MESH may now be too coarse for the waves it carries.
	if vertex_spacing <= 0.0:
		_schedule_rebuild()


## True when the manager's profile NAME list differs from the one the current hint was built from,
## and latches the new list. Shared with Pasture3DStream, which overrides `_on_profiles_changed`.
func _profile_names_moved() -> bool:
	var names := PackedStringArray()
	var m := _resolve_manager()
	if m and m.has_method("get_profile_names"):
		names = m.get_profile_names()
	if names == _profile_names_cache:
		return false
	_profile_names_cache = names
	return true


# ---- building ----------------------------------------------------------------

## Build the surface. Returns a stats dictionary (also kept in _last_stats) so a gate can assert on
## it without re-deriving anything.
##
## The shape is the subclass's; the bookkeeping around it is not. Resetting the stats, baselining
## the spline-move watcher, choosing the spacing, timing the build and re-raising the warnings and
## the gizmo happen once here rather than being repeated -- and drifting -- in each mesher.
func rebuild() -> Dictionary:
	_last_stats = {"ok": false, "reason": "", "vertices": 0, "triangles": 0,
		"spacing": 0.0, "ms": 0.0, "ribbon": is_ribbon()}
	if not is_inside_tree():
		_last_stats["reason"] = "not in tree"
		return _last_stats
	# BEFORE the baseline and before the build: the level is part of the pose this build reflects,
	# and a stream reads its banks relative to it.
	_apply_spline_level()
	# Baseline the spline-move watcher (_process) against the pose this build reflects, so a
	# rebuild triggered by anything else does not leave it looking like a move.
	if source_spline != null and is_instance_valid(source_spline):
		_source_xform = source_spline.global_transform
	var t0 := Time.get_ticks_usec()
	var spacing := _effective_spacing()
	_last_stats["spacing"] = spacing
	_build_surface(spacing)
	_last_stats["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	update_configuration_warnings()
	update_gizmos() # the selection marker floats over the surface, so it moves with it
	return _last_stats


## Refuse a build that would exceed max_vertices, with a reason that says what it would have taken.
##
## One message for both meshers: the number is the user's dial and the fix is the same either way,
## and a budget that reported differently depending on the shape would read as two different limits.
func _budget_exceeded(p_needed: int, p_spacing: float) -> bool:
	if p_needed <= max_vertices:
		return false
	_build_failed("would exceed max_vertices (%d) at %.2f m spacing; it needs %d" % [
		max_vertices, p_spacing, p_needed])
	return true


## Abandon a build: drop the mesh, drop the geometry it would have been queried through, and say
## why.
##
## The second half is the one that bites. A body that fails to build but keeps the polygon or the
## rows from the LAST successful one still answers is_point_underwater() from them -- so a lake
## whose loop was just deleted goes on reporting a swimmer as submerged in water nobody can see.
## Every failure path goes through here so that cannot be forgotten in one of them.
func _build_failed(p_reason: String) -> void:
	_clear_surface()
	_forget_surface()
	_last_stats["reason"] = p_reason


## Clear whatever the subclass answers containment from. Extended, not replaced: an override calls
## super() and then drops its own caches.
func _forget_surface() -> void:
	_poly_bounds = Rect2()


## Vertex spacing actually used: the explicit value, or a eighth of the profile's
## shortest wavelength. Clamped so a pathological profile cannot author a mesh that
## takes minutes or one that is a single quad.
func _effective_spacing() -> float:
	if vertex_spacing > 0.0:
		return vertex_spacing
	var m := _resolve_manager()
	if m and m.has_method("get_profile"):
		var profile = m.get_profile(wave_profile)
		if profile != null:
			var l_min: float = profile.get_min_wavelength()
			if l_min > 0.0:
				return clampf(l_min / 8.0, 0.25, 8.0)
	return 1.0


## The waves displace the surface well outside the flat mesh's own bounds, so the mesh
## AABB would cull the water the moment a crest was the only thing on screen. Grown by
## the profile's amplitude sum, which is what the surface ACTUALLY reaches — the same
## mistake water spec §4.5 documents for the ocean.
func _apply_cull_box(p_min: Vector2, p_max: Vector2) -> void:
	if _surface == null:
		return
	var amp := _wave_amplitude_sum()
	var size := Vector3(p_max.x - p_min.x, amp * 2.0, p_max.y - p_min.y)
	_surface.custom_aabb = AABB(Vector3(p_min.x, -amp, p_min.y), size)
	# Cleared, because this box already accounts for the displacement the margin would. A body that
	# had been built the other way round (see Pasture3DPool's masked path) must not keep both.
	_surface.extra_cull_margin = 0.0


## The height the surface actually reaches: the profile's amplitude sum, not the `amplitude` knob,
## which is only the longest wave's. At the ocean defaults the knob reads 1.6 m and the surface
## reaches 4.9 m — see the water guide §3.
##
## Floored, so a body with no manager still has something to grow a cull volume by rather than
## collapsing it to the flat sheet and culling itself whenever a crest is the only thing on screen.
func _wave_amplitude_sum() -> float:
	var m := _resolve_manager()
	if m and m.has_method("get_profile"):
		var profile = m.get_profile(wave_profile)
		if profile != null:
			return maxf(profile.get_amplitude_sum(), 0.1)
	return 1.0


## Vertex and triangle counts of a built surface, as a Vector2i. Read back off the mesh rather than
## tracked alongside it, so the number reported is the number that was actually uploaded whichever
## mesher produced it.
func _count_mesh(p_mesh: ArrayMesh) -> Vector2i:
	if p_mesh == null or p_mesh.get_surface_count() == 0:
		return Vector2i.ZERO
	var arrays := p_mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var i: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	return Vector2i(v.size(), i.size() / 3)


## A flow colour that decodes to "no flow", one per vertex. Still water writes this so the river
## shader is inert on a lake instead of sliding its texture diagonally (§10).
func _neutral_colours(p_count: int) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(p_count)
	out.fill(FLOW_NEUTRAL)
	return out


# ---- surface child -----------------------------------------------------------

## Created at runtime with no owner, so it never serialises: the scene stores the water body
## and its exports, and the mesh is derived data rebuilt on _ready. Same internal-child
## idiom the brushes use for their nameplate.
func _ensure_surface() -> void:
	if _surface != null and is_instance_valid(_surface):
		return
	_surface = MeshInstance3D.new()
	_surface.name = "Surface"
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_surface)


func _clear_surface() -> void:
	if _surface != null and is_instance_valid(_surface):
		_surface.mesh = null


func _apply_material() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var base := material
	if base == null:
		return
	var m := _resolve_manager()
	# The manager hands back a shared duplicate per (base material, profile) pair and
	# uploads the wave table into it, so ten ponds on one profile cost one material.
	# Without a manager the base is used as-is: it still renders, with whatever
	# compile-time table its variant carries.
	var resolved: Material = base
	if m and m.has_method("get_material_for"):
		var got = m.get_material_for(base, wave_profile)
		if got != null:
			resolved = got
	_surface.material_override = resolved
	_update_domain_origin()


## Per-body, and an INSTANCE uniform since Phase 1 precisely so the shared material can be
## shared. Keeps wave phase precise for water far from the world origin, which is why it
## has to track the node's position rather than being written once at material time.
func _update_domain_origin() -> void:
	if _surface != null and is_instance_valid(_surface):
		_surface.set_instance_shader_parameter("_water_domain_origin", global_position)


# ---- the underwater volume (spec §8) -----------------------------------------

## Build (or drop) the Area3D + FogVolume that span this body's footprint.
##
## Both are internal children with no owner, like Surface: they are derived from the geometry and
## are rebuilt whenever it is, so serialising them would only let a stale copy load from a scene.
##
## The box is the BROAD phase and nothing more. A lake outline is frequently concave, and a box says
## "in the water" for a peninsula between two arms — which is why every signal it raises is
## re-filtered through is_point_underwater() before it reaches anyone (§8.2).
func _rebuild_volume() -> void:
	if not is_inside_tree():
		return
	if not underwater_enabled or not _has_surface():
		_drop_volume()
		return

	if _volume == null or not is_instance_valid(_volume):
		_volume = Area3D.new()
		_volume.name = "Volume"
		# The water answers "is this point in it", it does not push anything.
		_volume.monitorable = false
		# NOTE: Godot 4.4+ defaults 3D physics to Jolt, and a Jolt Area3D does NOT report
		# StaticBody3D unless physics/jolt_physics_3d/simulation/areas_detect_static_bodies is
		# turned on. So body_submerged never fires for static props — which is usually what you
		# want (a rock does not swim) but is surprising the first time. Rigid, character and
		# kinematic bodies are detected normally. is_point_underwater() has no such limit; it is
		# geometry, not physics, so anything can be asked about it directly.
		_volume_shape = CollisionShape3D.new()
		_volume_shape.name = "VolumeShape"
		_volume.add_child(_volume_shape)
		add_child(_volume)
		_volume.body_entered.connect(_on_body_entered)
		_volume.body_exited.connect(_on_body_exited)

	var shape: BoxShape3D = _volume_shape.shape as BoxShape3D
	if shape == null:
		shape = BoxShape3D.new()
		_volume_shape.shape = shape
	# Spans the footprint in XZ and volume_depth downward from the surface. The top is the still
	# level: a crest above it is handled by the exact test, which reads the wave surface, and
	# growing the box upward would only widen the broad phase for no gain.
	var centre := _poly_bounds.get_center()
	shape.size = Vector3(_poly_bounds.size.x, volume_depth, _poly_bounds.size.y)
	_volume_shape.position = Vector3(centre.x, -volume_depth * 0.5, centre.y)

	if underwater_fog:
		if _fog == null or not is_instance_valid(_fog):
			_fog = FogVolume.new()
			_fog.name = "Fog"
			add_child(_fog)
		_fog.size = shape.size
		_fog.position = _volume_shape.position
		_apply_fog_material()
	elif _fog != null and is_instance_valid(_fog):
		_fog.queue_free()
		_fog = null


func _drop_volume() -> void:
	if _volume != null and is_instance_valid(_volume):
		_volume.queue_free()
	_volume = null
	_volume_shape = null
	if _fog != null and is_instance_valid(_fog):
		_fog.queue_free()
	_fog = null
	_bodies_in_box.clear()


## Tint the fog from the WATER material rather than from a second set of knobs.
##
## `deep_color` and `absorption` are the two uniforms that already make an ocean an ocean and a pond
## a pond, so deriving from them is what makes the view from under the surface agree with the view
## from above it. Density is the luminance of absorption (a per-metre extinction in the shader's
## Beer-Lambert term) scaled into fog units.
func _apply_fog_material() -> void:
	if _fog == null or not is_instance_valid(_fog):
		return
	var mat: FogMaterial = _fog.material as FogMaterial
	if mat == null:
		mat = FogMaterial.new()
		_fog.material = mat
	var albedo := Color(0.1, 0.2, 0.25)
	var density := 0.05
	var shader_mat := material as ShaderMaterial
	if shader_mat != null:
		var deep = shader_mat.get_shader_parameter("deep_color")
		if deep is Color:
			albedo = deep
		var absorption = shader_mat.get_shader_parameter("absorption")
		if absorption is Vector3:
			# Rec. 709 luminance of the per-channel extinction — one number for a scalar density.
			density = 0.2126 * absorption.x + 0.7152 * absorption.y + 0.0722 * absorption.z
	mat.albedo = albedo
	mat.density = maxf(density * underwater_density_scale, 0.0)


func _on_body_entered(p_body: Node3D) -> void:
	_bodies_in_box[p_body] = false
	_refilter_bodies()


func _on_body_exited(p_body: Node3D) -> void:
	if _bodies_in_box.get(p_body, false):
		body_surfaced.emit(p_body)
	_bodies_in_box.erase(p_body)


## Re-run the exact test for every body the box currently holds, emitting only on a change.
##
## The Area3D signals alone are not enough: they fire on the BOX, so a body that walks onto a
## peninsula between two arms of a lake never leaves the box and never fires anything, while
## remaining very much out of the water. Bodies in the box are few, and this runs on the physics
## tick, so the cost is bounded by how many things are actually near this water.
func _refilter_bodies() -> void:
	for body in _bodies_in_box.keys():
		if not is_instance_valid(body):
			_bodies_in_box.erase(body)
			continue
		var now := is_point_underwater(body.global_position)
		if now != _bodies_in_box[body]:
			_bodies_in_box[body] = now
			if now:
				body_submerged.emit(body)
			else:
				body_surfaced.emit(body)


func _physics_process(_delta: float) -> void:
	# Retried here rather than attempted once on entering the tree; see _register(). The
	# physics tick and not _process, because the registry is what the buoys query on the
	# physics tick, and because no subclass overrides this hook — Pasture3DStream overrides
	# _process, and a retry that depended on a subclass remembering to call super() would be
	# a bug waiting for the next kind of water.
	_register()
	if underwater_enabled and not _bodies_in_box.is_empty():
		_refilter_bodies()


## Poll the active camera against the surface (spec §8.2).
##
## A Camera3D is not a physics body, has no collision shape, and generates no area signals whatever
## — so there is no event to listen for and polling is the whole of the technique, not a shortcut.
## One rectangle test per body per frame in the common case; the exact test and the wave solve only
## run for a camera actually over this water.
func _poll_camera() -> void:
	# Out before _active_camera(), not just before the test. This runs once per body per
	# RENDERED frame, and both halves of it are expensive: _active_camera() costs an
	# EditorInterface round-trip in the editor, and is_point_underwater() ends in
	# get_water_height(), i.e. a 16-iteration wave solve, for every body the camera is
	# standing over. A body with the feature switched off was paying both for a flag
	# nothing reads.
	if not underwater_enabled:
		# Still report the falling edge, so turning the feature off while submerged does
		# not leave a listener believing it is underwater forever.
		if _camera_under:
			_camera_under = false
			camera_submerged.emit(false)
		return
	var cam := _active_camera()
	if cam == null:
		return
	var under := is_point_underwater(cam.global_position)
	if under != _camera_under:
		_camera_under = under
		camera_submerged.emit(under)


## The camera to test. In a running scene that is the viewport's; in the editor it is the 3D
## editor's own, so the Volume gizmo and the warnings can be checked without pressing play.
func _active_camera() -> Camera3D:
	if Engine.is_editor_hint():
		var vp := EditorInterface.get_editor_viewport_3d(0)
		return vp.get_camera_3d() if vp else null
	if not is_inside_tree():
		return null
	var vp2 := get_viewport()
	return vp2.get_camera_3d() if vp2 else null


## ---- the screen overlay (spec §8.4) ----
##
## Runtime only, and built lazily the first time the camera actually goes under: water that is
## never swum in should cost nothing, and in the editor tinting the viewport because the camera
## dipped below a plane would be a bug report rather than a feature.

func _update_overlay(p_delta: float) -> void:
	if Engine.is_editor_hint() or not underwater_overlay:
		return
	var target := 1.0 if _camera_under else 0.0
	if is_equal_approx(_overlay_amount, target) and _overlay_rect == null:
		return
	# A step, not a lerp: a fixed-duration ramp crosses in overlay_transition seconds regardless of
	# frame rate, where a lerp's speed depends on it.
	var step := p_delta / maxf(overlay_transition, 0.001)
	_overlay_amount = move_toward(_overlay_amount, target, step)
	if _overlay_amount <= 0.0:
		_drop_overlay()
		return
	_ensure_overlay()
	var mat := _overlay_rect.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("amount", _overlay_amount)
	var shader_mat := material as ShaderMaterial
	if shader_mat != null:
		var absorption = shader_mat.get_shader_parameter("absorption")
		if absorption is Vector3:
			mat.set_shader_parameter("absorption", absorption)
		var deep = shader_mat.get_shader_parameter("deep_color")
		if deep is Color:
			mat.set_shader_parameter("deep_color", deep)


func _ensure_overlay() -> void:
	if _overlay_rect != null and is_instance_valid(_overlay_rect):
		return
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "UnderwaterOverlay"
	_overlay_layer.layer = overlay_canvas_layer
	_overlay_rect = ColorRect.new()
	_overlay_rect.name = "Effect"
	_overlay_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	# It samples the screen; it must never eat a click meant for the game.
	_overlay_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(WATER_DIR + "water_underwater.gdshader")
	# The SAME derivative texture the surface shader already has resident, so the ripple under the
	# water matches the ripple on it and this costs no new VRAM (guide G3).
	mat.set_shader_parameter("detail_deriv", load(WATER_DIR + "T_water_deriv.png"))
	_overlay_rect.material = mat
	_overlay_layer.add_child(_overlay_rect)
	add_child(_overlay_layer)


func _drop_overlay() -> void:
	if _overlay_layer != null and is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()
	_overlay_layer = null
	_overlay_rect = null


# ---- public API --------------------------------------------------------------

## Surface height at a world XZ, including waves. The still level plus the wave
## displacement, so it agrees with what the shader draws.
## Memoised per (world XZ, physics frame).
##
## Not a speculative cache. Pasture3DBuoy asks this question TWICE per buoy per tick at the
## same position, and the second ask is invisible from here: _resolve_body() calls
## contains_point() to check the buoy has not left the body, contains_point() is
## is_point_underwater(), and its last line is this function. apply_buoyancy() then calls it
## directly. Each pass runs solve_domain() -- a 16-iteration Gerstner inverse over the whole
## wave table -- so the pair cost twice what the physics budget was written against, and
## `sample_interval`, the knob documented for relieving crowds of buoys, throttled only the
## second of them.
##
## Keyed on the physics FRAME rather than on water_time: the manager advances the clock in
## its own physics tick, so water_time is constant across a frame by construction, and the
## frame counter is an integer compare instead of a float one. The transform notification
## drops the entry, because the answer also depends on this node's position through
## _wave_domain().
func get_water_height(p_global_xz: Vector2) -> float:
	var frame := Engine.get_physics_frames()
	if frame == _height_cache_frame and p_global_xz == _height_cache_xz:
		return _height_cache_y
	_height_cache_y = _still_surface_y(p_global_xz) + _wave_offset(p_global_xz)
	_height_cache_xz = p_global_xz
	_height_cache_frame = frame
	return _height_cache_y


func get_water_normal(p_global_xz: Vector2) -> Vector3:
	return _wave_normal(p_global_xz)


## Wave displacement above the still surface, in metres.
##
## Split out of get_water_height as a hook because the two kinds of water do not
## make waves the same way. A pool takes the manager's Gerstner table, which is
## the transcription of water_eval_waves() the whole parity apparatus is built
## around; a Pasture3DStream cannot use that table at all -- see
## water_stream.gdshaderinc -- and overrides this with its own transcription.
##
## Whatever answers it, it has to agree with the SHADER, because a buoy floats on
## what this returns and a player sees what the shader drew. Phase 7 criterion D
## puts a 400 kg boat on a river and requires the two within 0.009 m.
func _wave_offset(p_global_xz: Vector2) -> float:
	var m := _resolve_manager()
	if m == null or not m.has_method("solve_domain"):
		return 0.0
	var domain: Vector2 = m.solve_domain(wave_profile, _wave_domain(p_global_xz))
	return m.evaluate_height(wave_profile, domain)


func _wave_normal(p_global_xz: Vector2) -> Vector3:
	var m := _resolve_manager()
	if m == null or not m.has_method("solve_domain"):
		return Vector3.UP
	var domain: Vector2 = m.solve_domain(wave_profile, _wave_domain(p_global_xz))
	return m.evaluate_normal(wave_profile, domain)


## World XZ relative to this body's domain origin -- the same subtraction the
## shader's `_water_domain_origin` performs, and the reason wave phase stays
## precise kilometres from the world origin.
func _wave_domain(p_global_xz: Vector2) -> Vector2:
	var origin := global_position
	return p_global_xz - Vector2(origin.x, origin.z)


## Body-registry contract (§5.5): is this world point in this body's water?
func contains_point(p_global_pos: Vector3) -> bool:
	return is_point_underwater(p_global_pos)


## Spec §8.2. The same question `contains_point` answers, under the name the underwater
## feature asks it by — one implementation, so the camera, a swimming character and a
## buoy can never disagree about where the water is.
##
## Deliberately compared against the WAVE surface and not the flat plane: at the
## shoreline in a 1 m swell the difference between those two IS the effect.
func is_point_underwater(p_global_pos: Vector3) -> bool:
	if not _has_surface():
		return false
	var lp: Vector3 = global_transform.affine_inverse() * p_global_pos
	var l2 := Vector2(lp.x, lp.z)
	# Broad phase: a rectangle test costs nothing next to the exact one, and the common
	# answer for a per-frame poll is "nowhere near".
	if not _poly_bounds.has_point(l2):
		return false
	if not _contains_local(l2):
		return false
	return p_global_pos.y <= get_water_height(Vector2(p_global_pos.x, p_global_pos.z))


## Re-seat this node on its curve: XZ onto the source spline's own origin, Y onto the
## curve's lowest point + fill_offset. Called once when the Add Water button creates water,
## and by the button afterwards.
##
## The XZ half is not tidiness. The geometry is read in world space and expressed relative
## to this node, so water left at the world origin while its curve sits 350 m away draws
## correctly but has a transform that says nothing, a selection handle nowhere near its
## water, and -- worst -- a `_water_domain_origin` of (0,0,0). That instance uniform
## exists precisely so wave phase stays precise far from the world origin, and it is set
## from this node's position, so leaving the node at the origin switches it off.
##
## Position only, never rotation: water inherits no basis from its brush because the
## surface is horizontal by construction, and copying a brush tilted about X or Z
## would tilt it.
##
## Never automatic: the brushes re-snap their spline points to the terrain surface, so an
## automatic fit would move the water level whenever the ground under the rim did.
func fit_to_curve() -> void:
	if curve != null:
		# A bare Curve3D is authored in THIS node's space, so its rim travels with the node
		# and "put the water plane at the rim" has no fixed point to solve for -- the earlier
		# version of this drifted by fill_offset on every press. In that mode the node's Y IS
		# the plane and the curve is drawn in it; there is nothing to fit.
		push_warning(("%s '%s': Fit to Curve needs a source_spline. A bare `curve` is "
			+ "authored in this node's own space, so it moves with the node and there is no "
			+ "level to solve for.") % [get_class_label(), name])
		return
	if source_spline == null or not is_instance_valid(source_spline):
		return
	var src: Curve3D = source_spline.curve
	if src == null or src.point_count == 0:
		return
	var level := _spline_level()
	if not is_finite(level):
		return
	var origin := source_spline.global_position
	global_position = Vector3(origin.x, level, origin.z)
	_schedule_rebuild()


## The level the spline implies: its lowest baked point in WORLD y, plus fill_offset.
##
## INF when there is nothing to solve from, which the callers treat as "leave the level alone"
## rather than as zero -- a body that silently dropped to y = 0 because its spline was missing for
## one frame would be a lake at the bottom of the world.
func _spline_level() -> float:
	if curve != null or source_spline == null or not is_instance_valid(source_spline):
		return INF
	var src: Curve3D = source_spline.curve
	if src == null or src.point_count == 0:
		return INF
	var xf := source_spline.global_transform
	var lowest := INF
	for p in src.get_baked_points():
		lowest = minf(lowest, (xf * p).y)
	if not is_finite(lowest):
		return INF
	return lowest + fill_offset


## Move this node's Y onto the spline-implied level, if that is what was asked for.
##
## Y only. Fit to Curve also seats the XZ, because a press is a deliberate act; doing it every
## rebuild would drag the body under the user's cursor. Guarded on an actual change so it does not
## write the transform -- and notify everything that listens -- on every rebuild of a still body.
func _apply_spline_level() -> void:
	if not level_from_spline:
		return
	var level := _spline_level()
	if is_finite(level) and not is_equal_approx(level, global_position.y):
		global_position.y = level


## Duplicate the resolved material into the scene so a plugin update cannot overwrite
## tuning. This is the water guide's hand-written advice ("duplicate a preset before
## editing it") turned into a button.
func make_unique() -> void:
	if material == null:
		return
	var dup := material.duplicate()
	dup.resource_local_to_scene = true
	material = dup
	water_preset = _custom_preset()
	_apply_material()


## Write the scene-local material to disk and re-point at the saved file, so tuned
## water becomes a project asset rather than being trapped in one scene.
func save_unique_material(p_path: String = "") -> void:
	if material == null:
		return
	var path := p_path
	if path.is_empty():
		path = "res://M_%s_water.tres" % String(name).to_snake_case()
	var to_save := material.duplicate()
	to_save.resource_local_to_scene = false
	var err := ResourceSaver.save(to_save, path)
	if err != OK:
		push_error("%s: could not save material to %s (error %d)" % [get_class_label(), path, err])
		return
	material = load(path)
	water_preset = _custom_preset()
	_apply_material()
	print("%s: saved water material to %s" % [get_class_label(), path])


func get_build_stats() -> Dictionary:
	return _last_stats


## Parsed `uniform float` defaults, per shader instance id. See shader_param.
static var _shader_defaults := {}


## A scalar shader parameter's effective value: what this body's material sets, else the default
## the SHADER ITSELF declares.
##
## The second half is the point, and it is not defensive coding. A .tres stores only the
## parameters its author changed, so get_shader_parameter() returns null for every untouched
## one -- and a GDScript transcription that filled those gaps from its own copy of the defaults
## would be a SECOND source of truth for numbers that have to agree with the GPU exactly. It
## would hold until somebody edited one default, and then a buoy would float at a height nothing
## on screen was drawn at, with both files looking correct in isolation.
##
## NOT RenderingServer.shader_get_parameter_default, which is the documented route and was the
## first implementation. It returns null under the headless dummy renderer, because nothing ever
## compiled the shader to reflect on -- so every gate, every tool script and every --script run
## would quietly fall through to the fallback and compute against different numbers than the game.
## A parity mechanism that stops working in exactly the environment parity is measured in is
## worse than no mechanism. The shader's SOURCE is available everywhere, so it is read instead.
##
## `uniform float NAME ... = <number>;` only. That covers what a CPU transcription of a wave
## needs, and stopping there keeps this a five-line regex rather than a GLSL parser. Anything
## else falls through to p_fallback.
func shader_param(p_name: StringName, p_fallback: Variant) -> Variant:
	var sm := material as ShaderMaterial
	if sm == null:
		return p_fallback
	var set_value = sm.get_shader_parameter(p_name)
	if set_value != null:
		return set_value
	if sm.shader == null:
		return p_fallback
	var declared: Dictionary = _shader_float_defaults(sm.shader)
	return declared.get(String(p_name), p_fallback)


## Cached, because _wave_offset() runs per buoy per physics tick and re-parsing a shader there
## would cost more than every wave in the scene put together. Keyed by instance id and holding no
## reference, so a freed shader cannot be kept alive by this table.
static func _shader_float_defaults(p_shader: Shader) -> Dictionary:
	var key := p_shader.get_instance_id()
	if _shader_defaults.has(key):
		return _shader_defaults[key]
	var out := {}
	var re := RegEx.new()
	re.compile("uniform\\s+float\\s+(\\w+)[^;=]*=\\s*([-+0-9.eE]+)\\s*;")
	for m in re.search_all(_expand_includes(p_shader.code, {})):
		out[m.get_string(1)] = m.get_string(2).to_float()
	_shader_defaults[key] = out
	return out


## Shader source with its #include-d files pasted in.
##
## Shader.code is the wrapper's own text, and every water uniform is declared in a .gdshaderinc --
## so without this the table comes back empty and every default silently becomes the fallback,
## which is the failure this whole path exists to prevent. The visited set guards a cycle; the
## water includes all carry #ifndef guards, but nothing here should depend on that.
static func _expand_includes(p_code: String, p_seen: Dictionary) -> String:
	var re := RegEx.new()
	re.compile("#include\\s+\"([^\"]+)\"")
	var out := p_code
	for m in re.search_all(p_code):
		var path := m.get_string(1)
		if p_seen.has(path):
			out = out.replace(m.get_string(0), "")
			continue
		p_seen[path] = true
		var f := FileAccess.open(path, FileAccess.READ)
		var text := f.get_as_text() if f != null else ""
		out = out.replace(m.get_string(0), _expand_includes(text, p_seen))
	return out


## Seconds on the scene's water clock, or 0. The same value the shader reads as `water_time`,
## which is what any CPU transcription of a wave has to be evaluated at.
func water_clock() -> float:
	var m := _resolve_manager()
	if m != null and m.has_method("get_water_time"):
		return m.get_water_time()
	return 0.0


## The name to use in messages. `get_class()` reports the NATIVE class (Node3D) for a GDScript
## type, so a warning built from it would say "Node3D" for every water body in the project.
func get_class_label() -> String:
	var s := get_script() as Script
	if s != null and not s.get_global_name().is_empty():
		return String(s.get_global_name())
	return get_class()


# ---- inspector ---------------------------------------------------------------

## The index of the Custom entry: the last one, by the convention _preset_names documents. Derived
## rather than a constant, because the two subclasses have lists of different lengths and a hard 2
## would silently mean "Custom" on one and out of range on the other.
func _custom_preset() -> int:
	return maxi(_preset_names().size() - 1, 0)


func _validate_property(property: Dictionary) -> void:
	if property.name == "material" and water_preset != _custom_preset():
		# The preset owns `material` unless the user has chosen Custom.
		property.usage |= PROPERTY_USAGE_READ_ONLY
	elif property.name == "water_preset":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(_preset_names())
	elif property.name == "wave_profile":
		# Re-hint the EXISTING export into a dropdown of the manager's live profile names.
		#
		# Not _get_property_list: declaring a second property with the same name as an
		# @export does not replace it, it adds one, and Godot then writes `wave_profile`
		# TWICE into every saved scene. _validate_property is the mechanism for changing
		# the hint of a property that already exists.
		var names := PackedStringArray()
		var m := _resolve_manager()
		if m and m.has_method("get_profile_names"):
			names = m.get_profile_names()
		if not names.is_empty():
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = ",".join(names)


func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	w.append_array(_shape_warnings())
	var m := _resolve_manager()
	if m == null:
		w.append("No Pasture3DPoolManager in the scene. The water will draw with whatever "
			+ "table its material compiles in, and nothing will drive water_time, so it "
			+ "will not move.")
	elif m.has_method("has_profile") and not m.has_profile(wave_profile):
		w.append("No wave profile named '%s' on the Pasture3DPoolManager." % wave_profile)
	if material == null:
		w.append("No material.")
	if level_from_spline and not is_finite(_spline_level()):
		w.append("level_from_spline is on but there is no spline to take a level from. It needs a "
			+ "source_spline with points; a bare `curve` is authored in this node's own space, so "
			+ "its rim travels with the node and there is no level to solve for.")
	if not _last_stats.is_empty() and not _last_stats.get("ok", false) \
			and _last_stats.get("reason", "") != "":
		w.append("The surface could not be built: %s." % _last_stats["reason"])
	# §8.3's named failure. A FogVolume renders NOTHING unless the scene's Environment has
	# volumetric fog switched on — no error, no warning, just no fog — and "the underwater fog
	# doesn't work" is the single most likely report this feature will generate. Say which setting.
	if underwater_enabled and underwater_fog and not _volumetric_fog_available():
		w.append("Underwater fog is on, but the scene's Environment does not have "
			+ "volumetric_fog_enabled — a FogVolume draws nothing without it. Enable it on the "
			+ "WorldEnvironment, or turn off underwater_fog.")
	# The raising-brush warning §7.8 describes. Checked here as well as at creation
	# time, because changing a brush's blend mode afterwards is the case a
	# creation-time-only dialog would miss — and it is the more likely one.
	var brush := _source_brush()
	if brush != null and _brush_raises(brush):
		var mode: String = brush._blend_mode_name() if brush.has_method("_blend_mode_name") else "?"
		w.append(("'%s' raises terrain (blend_mode = %s), so water here will sit inside the "
			+ "landform and be hidden. Set its blend_mode to MIN (or invert it) to carve.")
			% [brush.name, mode])
	return w


## Whether the scene's Environment would actually render a FogVolume.
##
## Reported as "available" when there is no Environment to inspect at all, rather than warned about:
## a headless or fixture scene has none and does not want to be told, and the warning exists to
## catch the specific case of an Environment that is present with the setting off.
func _volumetric_fog_available() -> bool:
	var env := _scene_environment()
	return env == null or env.volumetric_fog_enabled


## The Environment in force: the viewport's own, else the first WorldEnvironment in the scene. Both
## are checked because a Camera3D can carry its own and a WorldEnvironment is the usual authoring
## route; neither alone is the answer.
func _scene_environment() -> Environment:
	if not is_inside_tree():
		return null
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null and cam.environment != null:
			return cam.environment
		if vp is Window and vp.world_3d != null and vp.world_3d.environment != null:
			return vp.world_3d.environment
	var root := get_tree().current_scene
	if root != null:
		for n in _descendants(root):
			if n is WorldEnvironment and n.environment != null:
				return n.environment
	return null


func _descendants(p_node: Node) -> Array:
	var out: Array = [p_node]
	for c in p_node.get_children():
		out.append_array(_descendants(c))
	return out


## The Curve3D actually driving the mesh: the explicit override if set, else the spline's.
func _source_curve() -> Curve3D:
	if curve != null:
		return curve
	if source_spline != null and is_instance_valid(source_spline):
		return source_spline.curve
	return null


## Spline space -> this node's space. Identity for a bare `curve`, whose points are already
## authored here; the round trip through world for a source_spline, which is what makes the water
## follow its brush.
func _source_to_local() -> Transform3D:
	if curve == null and source_spline != null and is_instance_valid(source_spline):
		return global_transform.affine_inverse() * source_spline.global_transform
	return Transform3D()


func _source_brush() -> Node:
	if source_spline == null or not is_instance_valid(source_spline):
		return null
	var p := source_spline.get_parent()
	return p if p != null and p.is_class("Node3D") and p.has_method("is_configured") else null


## Effective sign of a brush, not its class: every raise brush can be configured to
## carve and vice versa. The BRUSH owns this answer (spec §7.8) — where the inversion
## lives differs per brush, and Pasture3DPlow keeps it on its material rather than on
## itself, so a table reimplemented here would drift from the one the Add Water button
## consults. Duck-typed, so a brush type added later gets this for free.
func _brush_raises(p_brush: Node) -> bool:
	return p_brush.has_method("brush_raises") and p_brush.brush_raises()
