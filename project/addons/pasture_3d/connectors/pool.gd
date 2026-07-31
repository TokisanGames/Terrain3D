# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPool — a finite water body meshed from a landscape brush's spline.
# See PASTURE3D_WATER_BODIES_SPEC.md §7.
#
# The node that makes "add water to this basin" one button press. It takes the curve a
# Pasture3DMound (or Plow, or Splat) already drew, fills it with a subdivided surface,
# and puts a water material on it. The waves, the clock and the material all come from
# the scene's Pasture3DPoolManager, so a pond is not a special case of anything -- it
# is the same water the ocean is, over a smaller polygon.
#
# GDScript, deliberately (spec §4.3): this is an authoring node, and it lives next to
# the brushes whose idioms it borrows -- debounced refresh, internal children that
# never serialise, configuration warnings that name the fix.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DPool
extends Node3D

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const PRESET_PATHS := {
	0: WATER_DIR + "M_water_lake.tres",
	1: WATER_DIR + "M_water_pond.tres",
}
## Group every pool joins, so tools can find them without a tree walk.
const POOL_GROUP: StringName = &"pasture3d_pool"
## Debounce for rebuilds while a spline is being dragged (seconds). Matches the brushes.
const REFRESH_DELAY: float = 0.1

## Hard ceiling on generated vertices. A pool whose spacing would exceed this is a
## mistake -- almost always a metre-scale spacing over a kilometre-scale loop -- and
## silently building it locks the editor for minutes.
const MAX_VERTICES: int = 400000

# --- Source -------------------------------------------------------------------

## The spline this pool is filled from. Normally a brush's child Path3D: it carries the
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
## land offset. Use source_spline unless you are authoring a pool with no brush.
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
## Metres added to the surface height when Fit to Curve runs. Negative sits the water
## below the rim, which is where a basin's water actually is.
@export var fill_offset: float = -0.5
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
## toggle it and compare shape and timing on the same pool. Same idea, and the same name shape,
## as Pasture3DTerrainBrush.force_gdscript_raster. Leave off in normal use.
@export var force_gdscript_mesh: bool = false:
	set(v):
		force_gdscript_mesh = v
		_schedule_rebuild()

# --- Water --------------------------------------------------------------------

@export_group("Water")
## Which wave profile on the Pasture3DPoolManager drives this pool. Shown as a dropdown
## of the live profile names; see _get_property_list.
@export var wave_profile: StringName = &"lake_calm":
	set(v):
		wave_profile = v
		_apply_material()
		update_configuration_warnings()
## Lake / Pond pick a shipped preset. Custom uses `material` as given.
@export_enum("Lake", "Pond", "Custom") var water_preset: int = 0:
	set(v):
		water_preset = v
		if water_preset != 2:
			material = load(PRESET_PATHS[water_preset])
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
## far down "in this water" reaches, and a body below it has sunk out of the pool's care.
@export var volume_depth: float = 20.0:
	set(v):
		volume_depth = maxf(v, 0.1)
		_rebuild_volume()
## Spawn a FogVolume matching the box, tinted from the water material. Needs
## Environment.volumetric_fog_enabled; the pool warns when that is off rather than doing nothing.
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
## Last resolved manager. See _resolve_manager.
var _manager_cache: Node = null
## The offset loop in LOCAL XZ, and its bounds, as of the last rebuild. Every containment query
## reads these rather than re-deriving them; see rebuild().
var _poly_cache := PackedVector2Array()
var _poly_bounds := Rect2()
## The mesher's own inside mask, kept so containment is a lookup rather than a polygon walk. See
## is_point_underwater. Empty means "no mask, fall back to the exact test everywhere".
var _mask := PackedByteArray()
var _mask_gw := 0
var _mask_gh := 0
var _mask_spacing := 0.0

var _volume: Area3D = null
var _volume_shape: CollisionShape3D = null
var _fog: FogVolume = null
## Bodies currently inside the Area3D box -> whether they were last reported as submerged. The box
## is the broad phase; the polygon test that refines it has to be re-run as they move, which is why
## this is a set and not just a pair of signal handlers.
var _bodies_in_box := {}
var _camera_under := false
var _overlay_layer: CanvasLayer = null
var _overlay_rect: ColorRect = null
var _overlay_amount := 0.0


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
		_manager_cache = null # a pool moved between scenes must re-resolve, not keep the old scene's
		# The overlay is a CanvasLayer: leaving it up after the pool has gone would tint a scene
		# with no water in it.
		_drop_overlay()
		_camera_under = false
		_overlay_amount = 0.0
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		# The surface height IS this node's Y, so moving it in Y moves the water level and
		# the mesh (built flat, in local space) needs nothing.
		#
		# XZ is not symmetric with that. With a source_spline the polygon is read in WORLD
		# space and then expressed relative to this node, so an XZ move has to be compensated
		# by a rebuild — otherwise the mesh slides off its spline and stays there until the
		# next curve edit silently snaps it back. With a bare `curve` the points are in this
		# node's space and genuinely travel with it, so there is nothing to recompute.
		if curve == null and source_spline != null and is_instance_valid(source_spline):
			_schedule_rebuild()
		# The domain origin is this node's position — it is what keeps wave phase precise far
		# from the world origin — so it follows the node, not just a material assignment.
		_update_domain_origin()
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
## The pool reads its polygon through `source_spline.global_transform`, so dragging the
## brush -- or the Path3D under it, or any ancestor of either -- changes where the water
## is, and its shape if there is any rotation or scale. None of that emits a signal the
## pool could connect to: Node3D transform notifications reach the node that moved and
## its children, and a pool is a SIBLING of its brush by design (§7.7), so it is in
## neither set. A once-per-frame Transform3D comparison is the honest way to see it.
##
## The cost is one is_equal_approx per pool per frame and a debounced rebuild only when
## the answer changes, which is why this is not gated to the editor: a runtime scene that
## moves a brush should move its water too, and paying microseconds to make that true
## everywhere is better than an editor-only behaviour that surprises someone at runtime.
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

## The manager driving this pool, cached.
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
	var found := get_tree().get_nodes_in_group(&"pasture3d_water_manager")
	_manager_cache = found[0] if not found.is_empty() else null
	return _manager_cache


func _register() -> void:
	var m := _resolve_manager()
	if m and m.has_method("register_body"):
		m.register_body(self)
		if m.has_signal("profiles_changed") and not m.profiles_changed.is_connected(_on_profiles_changed):
			m.profiles_changed.connect(_on_profiles_changed)


func _unregister() -> void:
	var m := _resolve_manager()
	if m and m.has_method("unregister_body"):
		m.unregister_body(self)


func _on_profiles_changed() -> void:
	# The dropdown is built from the manager's live names (see _validate_property), so a
	# profile added or renamed has to re-hint the property or the list goes stale.
	notify_property_list_changed()
	# A profile knob moved. The table is re-uploaded by the manager into the shared
	# material, but the wavelength may have changed, and vertex spacing is derived
	# from it — so the MESH may now be too coarse for the waves it carries.
	if vertex_spacing <= 0.0:
		_schedule_rebuild()


# ---- geometry ----------------------------------------------------------------

## The loop, in this node's LOCAL XZ, decimated to roughly the grid resolution.
## Returns an empty array when there is no usable closed curve.
func _local_polygon(p_spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var src: Curve3D = null
	var to_local_xf := Transform3D()
	if curve != null:
		src = curve
		# A bare Curve3D has no transform of its own; its points are this node's space.
		to_local_xf = Transform3D()
	elif source_spline != null and is_instance_valid(source_spline) and source_spline.curve != null:
		src = source_spline.curve
		# Spline space -> world -> our space, so the pool tracks the brush.
		to_local_xf = global_transform.affine_inverse() * source_spline.global_transform
	if src == null or src.point_count < 3:
		return out
	# An OPEN curve is a river, not a lake. Filling one means closing it between its two
	# endpoints, which is a wedge the user never drew — so refuse and let the
	# configuration warning say why. Ribbon meshing (spec §10) is what open curves get.
	if not src.closed:
		return out

	var pts := src.get_baked_points()
	if pts.size() < 3:
		return out
	# The raw bake is ~0.2 m and far finer than the grid; decimating first makes the
	# scanline below O(rows x few) instead of O(rows x thousands).
	var step := maxf(p_spacing, 0.25)
	var last := Vector2.INF
	for p in pts:
		var lp: Vector3 = to_local_xf * p
		var v := Vector2(lp.x, lp.z)
		if last == Vector2.INF or last.distance_to(v) >= step:
			out.append(v)
			last = v
	if out.size() >= 2 and out[0].distance_to(out[out.size() - 1]) < step * 0.5:
		out.remove_at(out.size() - 1)
	return out


## Grown outward by edge_offset. Geometry2D returns a list because an offset can split
## or merge a polygon; the largest ring is the pool and the rest are slivers.
func _offset_polygon(p_poly: PackedVector2Array) -> PackedVector2Array:
	if is_zero_approx(edge_offset):
		return p_poly
	var rings := Geometry2D.offset_polygon(p_poly, edge_offset, Geometry2D.JOIN_MITER)
	var best := PackedVector2Array()
	var best_area := -1.0
	for r in rings:
		var a: float = absf(_polygon_area(r))
		if a > best_area:
			best_area = a
			best = r
	return best if not best.is_empty() else p_poly


func _polygon_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


## Inside-mask over grid POINTS by scanline.
##
## Not Geometry2D.is_point_in_polygon per point: that is O(points x edges), which for a
## 500 m lake at 1.4 m spacing is 127k x ~200 = 25M operations in GDScript — seconds,
## not milliseconds. A scanline is O(rows x edges + points) and does the same job. The
## brushes reached the same conclusion for the same reason.
func _inside_mask(p_poly: PackedVector2Array, p_min: Vector2, p_spacing: float,
		p_gw: int, p_gh: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(p_gw * p_gh)
	var n := p_poly.size()
	for iz in p_gh:
		var z := p_min.y + iz * p_spacing
		var xs := PackedFloat32Array()
		for i in n:
			var a := p_poly[i]
			var b := p_poly[(i + 1) % n]
			# Half-open crossing test: a vertex exactly on the scanline counts once,
			# so spans never pair up wrongly at a horizontal tangent.
			if (a.y <= z) != (b.y <= z):
				xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
		if xs.is_empty():
			continue
		xs.sort()
		var row := iz * p_gw
		var k := 0
		while k + 1 < xs.size():
			var x0: float = xs[k]
			var x1: float = xs[k + 1]
			var i0 := int(ceil((x0 - p_min.x) / p_spacing))
			var i1 := int(floor((x1 - p_min.x) / p_spacing))
			for ix in range(maxi(i0, 0), mini(i1, p_gw - 1) + 1):
				mask[row + ix] = 1
			k += 2
	return mask


## Builds the surface mesh. Returns a stats dictionary (also kept in _last_stats) so a
## gate can assert on it without re-deriving anything.
func rebuild() -> Dictionary:
	_last_stats = {"ok": false, "reason": "", "vertices": 0, "triangles": 0,
		"spacing": 0.0, "ms": 0.0}
	if not is_inside_tree():
		_last_stats["reason"] = "not in tree"
		return _last_stats
	# Baseline the spline-move watcher (_process) against the pose this build reflects, so a
	# rebuild triggered by anything else does not leave it looking like a move.
	if source_spline != null and is_instance_valid(source_spline):
		_source_xform = source_spline.global_transform
	var t0 := Time.get_ticks_usec()

	var spacing := _effective_spacing()
	_last_stats["spacing"] = spacing
	var poly := _offset_polygon(_local_polygon(spacing))
	# Cache it. Every containment question — the camera poll, the Area3D re-filter, a buoy asking
	# which body it is in — needs this same polygon, and rebuilding it per query means re-baking the
	# curve, decimating it and running Geometry2D.offset_polygon several times a frame. It only
	# changes when the mesh does, so it is stored where the mesh is.
	_poly_cache = poly
	if poly.size() < 3:
		_clear_surface()
		_poly_bounds = Rect2()
		_mask = PackedByteArray()
		_last_stats["reason"] = "no usable closed curve"
		update_configuration_warnings()
		return _last_stats

	# Bounds, snapped outward to the grid so the lattice is stable as the loop moves.
	var mn := poly[0]
	var mx := poly[0]
	for v in poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	mn = Vector2(floorf(mn.x / spacing) * spacing, floorf(mn.y / spacing) * spacing)
	mx = Vector2(ceilf(mx.x / spacing) * spacing, ceilf(mx.y / spacing) * spacing)
	# Local-space XZ bounds of the polygon: the broad phase for every containment query, and the
	# footprint the underwater volume spans.
	_poly_bounds = Rect2(mn, mx - mn)
	var gw := int(round((mx.x - mn.x) / spacing)) + 1
	var gh := int(round((mx.y - mn.y) / spacing)) + 1
	if gw < 2 or gh < 2:
		_clear_surface()
		_last_stats["reason"] = "loop smaller than one grid cell"
		update_configuration_warnings()
		return _last_stats
	if gw * gh > MAX_VERTICES:
		_clear_surface()
		_last_stats["reason"] = "would exceed %d vertices at %.2f m spacing" % [
			MAX_VERTICES, spacing]
		update_configuration_warnings()
		return _last_stats

	# The mesher's inside mask, kept for containment queries (see is_point_underwater). Built here
	# rather than inside the mesher so both mesher paths produce it and both agree with it.
	if ClassDB.class_exists("Pasture3DUtil") 			and ClassDB.class_has_method("Pasture3DUtil", "build_inside_mask", true):
		_mask = Pasture3DUtil.build_inside_mask(poly, mn, spacing, gw, gh)
	else:
		_mask = _inside_mask(poly, mn, spacing, gw, gh)
	_mask_gw = gw
	_mask_gh = gh
	_mask_spacing = spacing

	# The O(area) half. Native by default (spec §12 q1): the GDScript below is a faithful
	# transcription kept as the A/B oracle, exactly as the brushes keep force_gdscript_raster, and
	# `force_gdscript_mesh` switches between them on identical inputs.
	var mesh: ArrayMesh = null
	var native := false
	if not force_gdscript_mesh and ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_pool_mesh", true):
		mesh = Pasture3DUtil.build_pool_mesh(poly, mn, spacing, gw, gh)
		native = mesh != null
	if not native:
		mesh = _build_mesh_gdscript(poly, mn, spacing, gw, gh, _mask)
	_last_stats["native"] = native
	if mesh == null:
		_clear_surface()
		_last_stats["reason"] = "no cells inside the loop"
		update_configuration_warnings()
		return _last_stats

	_ensure_surface()
	_surface.mesh = mesh
	_apply_material()
	_apply_cull_box(mn, mx)
	# The volume spans the polygon, so it is derived from the same build rather than tracked.
	_rebuild_volume()

	var counted := _count_mesh(mesh)
	_last_stats["ok"] = true
	_last_stats["vertices"] = counted.x
	_last_stats["triangles"] = counted.y
	_last_stats["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	update_configuration_warnings()
	update_gizmos() # the selection marker floats over the surface, so it moves with it
	return _last_stats


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


## The GDScript mesher: the A/B oracle for Pasture3DUtil.build_pool_mesh.
##
## Kept deliberately, and kept identical in structure to the C++ port, so a suspected meshing bug can
## be bisected by flipping one export rather than by rebuilding the extension. Returns null when the
## loop encloses no cells.
func _build_mesh_gdscript(poly: PackedVector2Array, mn: Vector2, spacing: float,
		gw: int, gh: int, mask: PackedByteArray) -> ArrayMesh:

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Interior grid points are shared between the (up to) four cells that touch them.
	# Boundary triangles get their own vertices: they do not land on the lattice.
	var vert_of := {}

	for iz in gh - 1:
		for ix in gw - 1:
			var c00: int = mask[iz * gw + ix]
			var c10: int = mask[iz * gw + ix + 1]
			var c01: int = mask[(iz + 1) * gw + ix]
			var c11: int = mask[(iz + 1) * gw + ix + 1]
			var n_in := c00 + c10 + c01 + c11
			if n_in == 0:
				continue
			if n_in == 4:
				var a := _grid_vert(vert_of, verts, uvs, ix, iz, mn, spacing, gw)
				var b := _grid_vert(vert_of, verts, uvs, ix + 1, iz, mn, spacing, gw)
				var c := _grid_vert(vert_of, verts, uvs, ix, iz + 1, mn, spacing, gw)
				var d := _grid_vert(vert_of, verts, uvs, ix + 1, iz + 1, mn, spacing, gw)
				# CCW seen from above (+Y up, -Z forward).
				indices.append_array([a, c, b, b, c, d])
				continue
			# Partial cell: clip the square against the loop and fan the remainder.
			# Only ~perimeter/spacing cells reach here, so the expensive path is
			# bounded by the shore length rather than by the area.
			var x0 := mn.x + ix * spacing
			var z0 := mn.y + iz * spacing
			var cell := PackedVector2Array([
				Vector2(x0, z0), Vector2(x0 + spacing, z0),
				Vector2(x0 + spacing, z0 + spacing), Vector2(x0, z0 + spacing)])
			for piece in Geometry2D.intersect_polygons(cell, poly):
				if piece.size() < 3:
					continue
				var tri := Geometry2D.triangulate_polygon(piece)
				for i in range(0, tri.size(), 3):
					for j in range(3):
						var p: Vector2 = piece[tri[i + j]]
						indices.append(verts.size())
						verts.append(Vector3(p.x, 0.0, p.y))
						uvs.append(p)

	if verts.is_empty() or indices.is_empty():
		return null

	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _grid_vert(p_map: Dictionary, p_verts: PackedVector3Array, p_uvs: PackedVector2Array,
		p_ix: int, p_iz: int, p_min: Vector2, p_spacing: float, p_gw: int) -> int:
	var key := p_iz * p_gw + p_ix
	if p_map.has(key):
		return p_map[key]
	var x := p_min.x + p_ix * p_spacing
	var z := p_min.y + p_iz * p_spacing
	var idx := p_verts.size()
	p_verts.append(Vector3(x, 0.0, z))
	p_uvs.append(Vector2(x, z))
	p_map[key] = idx
	return idx


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
## AABB would cull the pool the moment a crest was the only thing on screen. Grown by
## the profile's amplitude sum, which is what the surface ACTUALLY reaches — the same
## mistake water spec §4.5 documents for the ocean.
func _apply_cull_box(p_min: Vector2, p_max: Vector2) -> void:
	if _surface == null:
		return
	var amp := 1.0
	var m := _resolve_manager()
	if m and m.has_method("get_profile"):
		var profile = m.get_profile(wave_profile)
		if profile != null:
			amp = maxf(profile.get_amplitude_sum(), 0.1)
	var size := Vector3(p_max.x - p_min.x, amp * 2.0, p_max.y - p_min.y)
	_surface.custom_aabb = AABB(Vector3(p_min.x, -amp, p_min.y), size)


# ---- surface child -----------------------------------------------------------

## Created at runtime with no owner, so it never serialises: the scene stores the pool
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
## shared. Keeps wave phase precise for a pool far from the world origin, which is why it
## has to track the node's position rather than being written once at material time.
func _update_domain_origin() -> void:
	if _surface != null and is_instance_valid(_surface):
		_surface.set_instance_shader_parameter("_water_domain_origin", global_position)


# ---- the underwater volume (spec §8) -----------------------------------------

## Build (or drop) the Area3D + FogVolume that span this pool's footprint.
##
## Both are internal children with no owner, like Surface: they are derived from the polygon and are
## rebuilt whenever it is, so serialising them would only let a stale copy load from a scene.
##
## The box is the BROAD phase and nothing more. A lake outline is frequently concave, and a box says
## "in the water" for a peninsula between two arms — which is why every signal it raises is
## re-filtered through is_point_underwater() before it reaches anyone (§8.2).
func _rebuild_volume() -> void:
	if not is_inside_tree():
		return
	if not underwater_enabled or _poly_cache.size() < 3:
		_drop_volume()
		return

	if _volume == null or not is_instance_valid(_volume):
		_volume = Area3D.new()
		_volume.name = "Volume"
		# The pool answers "is this point in the water", it does not push anything.
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
	# Spans the polygon in XZ and volume_depth downward from the surface. The top is the still
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
## tick, so the cost is bounded by how many things are actually near this pool.
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
	if underwater_enabled and not _bodies_in_box.is_empty():
		_refilter_bodies()


## Poll the active camera against the surface (spec §8.2).
##
## A Camera3D is not a physics body, has no collision shape, and generates no area signals whatever
## — so there is no event to listen for and polling is the whole of the technique, not a shortcut.
## One rectangle test per pool per frame in the common case; the polygon walk and the wave solve only
## run for a camera actually over this water.
func _poll_camera() -> void:
	var cam := _active_camera()
	if cam == null:
		return
	var under := underwater_enabled and is_point_underwater(cam.global_position)
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
## Runtime only, and built lazily the first time the camera actually goes under: a pool that is
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

## Surface height at a world XZ, including waves. The pool's own Y plus the profile's
## displacement, so it agrees with what the shader draws.
func get_water_height(p_global_xz: Vector2) -> float:
	var m := _resolve_manager()
	if m == null or not m.has_method("solve_domain"):
		return global_position.y
	var origin := global_position
	var target := p_global_xz - Vector2(origin.x, origin.z)
	var domain: Vector2 = m.solve_domain(wave_profile, target)
	return origin.y + m.evaluate_height(wave_profile, domain)


func get_water_normal(p_global_xz: Vector2) -> Vector3:
	var m := _resolve_manager()
	if m == null or not m.has_method("solve_domain"):
		return Vector3.UP
	var origin := global_position
	var target := p_global_xz - Vector2(origin.x, origin.z)
	var domain: Vector2 = m.solve_domain(wave_profile, target)
	return m.evaluate_normal(wave_profile, domain)


## Body-registry contract (§5.5): is this world point in this pool's water?
##
## Tested against the polygon, not the mesh AABB — lake outlines are frequently concave
## and a box says "in the water" for a peninsula. Vertically it is compared against the
## WAVE surface, so a point just under a trough is out and just under a crest is in.
func contains_point(p_global_pos: Vector3) -> bool:
	return is_point_underwater(p_global_pos)


## Spec §8.2. The same question `contains_point` answers, under the name the underwater
## feature asks it by — one implementation, so the camera, a swimming character and a
## buoy can never disagree about where the water is.
##
## Deliberately compared against the WAVE surface and not the flat plane: at the
## shoreline in a 1 m swell the difference between those two IS the effect.
func is_point_underwater(p_global_pos: Vector3) -> bool:
	if _poly_cache.size() < 3:
		return false
	var lp: Vector3 = global_transform.affine_inverse() * p_global_pos
	var l2 := Vector2(lp.x, lp.z)
	# Broad phase: a rectangle test costs nothing next to a polygon walk, and the common
	# answer for a per-frame poll is "nowhere near".
	if not _poly_bounds.has_point(l2):
		return false
	# Cell classification off the mesher's mask, which turns the common answer into an array
	# lookup. The exact polygon walk is O(perimeter) — a few hundred edges for a lake — and Phase 6
	# asks this question per buoy per physics tick, where it cost more than the wave solve did.
	#
	# Reading the MESHER's mask rather than a structure of its own is the point: a cell whose four
	# corners are all inside is exactly a cell the mesher filled with a quad, so "contained" and
	# "drawn" cannot disagree. Only cells the boundary crosses fall through to the exact test, and
	# there are O(shore length) of those.
	match _cell_state(l2):
		0:
			return false
		1:
			pass # every corner inside: the mesher drew a full quad here
		_:
			if not Geometry2D.is_point_in_polygon(l2, _poly_cache):
				return false
	return p_global_pos.y <= get_water_height(Vector2(p_global_pos.x, p_global_pos.z))


## 0 = no corner of this cell is inside the loop, 1 = all four are, 2 = mixed (or no mask).
func _cell_state(p_local_xz: Vector2) -> int:
	if _mask.is_empty() or _mask_spacing <= 0.0:
		return 2
	var ix := int(floor((p_local_xz.x - _poly_bounds.position.x) / _mask_spacing))
	var iz := int(floor((p_local_xz.y - _poly_bounds.position.y) / _mask_spacing))
	if ix < 0 or iz < 0 or ix >= _mask_gw - 1 or iz >= _mask_gh - 1:
		return 2 # on the grid's outer edge; let the exact test decide
	var n := int(_mask[iz * _mask_gw + ix]) + int(_mask[iz * _mask_gw + ix + 1]) 		+ int(_mask[(iz + 1) * _mask_gw + ix]) + int(_mask[(iz + 1) * _mask_gw + ix + 1])
	if n == 0:
		return 0
	return 1 if n == 4 else 2


## The pool's outline in local XZ, as the mesh was last built from it. Exposed so a gate — or a
## tool — can check containment against the same polygon the node uses rather than a re-derived one.
func get_polygon() -> PackedVector2Array:
	return _poly_cache


## Re-seat this node on its curve: XZ onto the source spline's own origin, Y onto the
## curve's lowest point + fill_offset. Called once when the Add Water button creates a
## pool, and by the button afterwards.
##
## The XZ half is not tidiness. The polygon is read in world space and expressed relative
## to this node, so a pool left at the world origin while its loop sits 350 m away draws
## correctly but has a transform that says nothing, a selection handle nowhere near its
## water, and -- worst -- a `_water_domain_origin` of (0,0,0). That instance uniform
## exists precisely so wave phase stays precise far from the world origin, and it is set
## from this node's position, so leaving the node at the origin switches it off.
##
## Position only, never rotation: a pool inherits no basis from its brush because the
## water plane is horizontal by construction, and copying a brush tilted about X or Z
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
		push_warning(("Pasture3DPool '%s': Fit to Curve needs a source_spline. A bare `curve` is "
			+ "authored in this node's own space, so it moves with the node and there is no "
			+ "level to solve for.") % name)
		return
	if source_spline == null or not is_instance_valid(source_spline):
		return
	var src: Curve3D = source_spline.curve
	if src == null or src.point_count == 0:
		return
	var xf := source_spline.global_transform
	var lowest := INF
	for p in src.get_baked_points():
		lowest = minf(lowest, (xf * p).y)
	if not is_finite(lowest):
		return
	var origin := source_spline.global_position
	global_position = Vector3(origin.x, lowest + fill_offset, origin.z)
	_schedule_rebuild()


## Duplicate the resolved material into the scene so a plugin update cannot overwrite
## tuning. This is the water guide's hand-written advice ("duplicate a preset before
## editing it") turned into a button.
func make_unique() -> void:
	if material == null:
		return
	var dup := material.duplicate()
	dup.resource_local_to_scene = true
	material = dup
	water_preset = 2
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
		push_error("Pasture3DPool: could not save material to %s (error %d)" % [path, err])
		return
	material = load(path)
	water_preset = 2
	_apply_material()
	print("Pasture3DPool: saved water material to %s" % path)


func get_build_stats() -> Dictionary:
	return _last_stats


# ---- inspector ---------------------------------------------------------------

func _validate_property(property: Dictionary) -> void:
	# The preset owns `material` unless the user has chosen Custom.
	if property.name == "material" and water_preset != 2:
		property.usage |= PROPERTY_USAGE_READ_ONLY
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
	var src := _source_curve()
	if src == null:
		w.append("No source. Set source_spline to a brush's Path3D, or assign a Curve3D.")
	elif src.point_count < 3:
		w.append("The source curve has fewer than 3 points, so there is no area to fill.")
	elif not src.closed:
		# Worth its own message rather than the generic one: the curve looks perfectly
		# valid in the viewport, and "closed" is a checkbox on the Curve3D the user has
		# probably never opened.
		w.append("The source curve is open. A pool fills a closed loop; an open spline is a "
			+ "river, and ribbon water is not built yet. Tick the curve's Closed property "
			+ "(or the brush's, on a Ridge or Trough) to fill it as a loop.")
	elif _local_polygon(_effective_spacing()).size() < 3:
		w.append("The source curve collapses to fewer than 3 usable points at this vertex "
			+ "spacing, so there is no area to fill.")
	var m := _resolve_manager()
	if m == null:
		w.append("No Pasture3DPoolManager in the scene. The water will draw with whatever "
			+ "table its material compiles in, and nothing will drive water_time, so it "
			+ "will not move.")
	elif m.has_method("has_profile") and not m.has_profile(wave_profile):
		w.append("No wave profile named '%s' on the Pasture3DPoolManager." % wave_profile)
	if material == null:
		w.append("No material.")
	if not _last_stats.is_empty() and not _last_stats.get("ok", false) \
			and _last_stats.get("reason", "") != "":
		w.append("The surface could not be built: %s." % _last_stats["reason"])
	# The raising-brush warning §7.8 describes. Checked here as well as at creation
	# time, because changing a brush's blend mode afterwards is the case a
	# creation-time-only dialog would miss — and it is the more likely one.
	# §8.3's named failure. A FogVolume renders NOTHING unless the scene's Environment has
	# volumetric fog switched on — no error, no warning, just no fog — and "the underwater fog
	# doesn't work" is the single most likely report this feature will generate. Say which setting.
	if underwater_enabled and underwater_fog and not _volumetric_fog_available():
		w.append("Underwater fog is on, but the scene's Environment does not have "
			+ "volumetric_fog_enabled — a FogVolume draws nothing without it. Enable it on the "
			+ "WorldEnvironment, or turn off underwater_fog.")
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
