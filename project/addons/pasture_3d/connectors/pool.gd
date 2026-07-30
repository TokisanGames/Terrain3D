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

# --- Internals ----------------------------------------------------------------

var _surface: MeshInstance3D = null
var _timer: SceneTreeTimer = null
var _dirty := false
var _last_stats := {}
## World transform of source_spline as of the last rebuild. See _process.
var _source_xform := Transform3D()


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
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		# The surface height IS this node's Y, so moving it moves the water. The mesh
		# is built in local space and does not need regenerating — only its cull box
		# tracks the transform, and that is set from the mesh, so nothing to do here
		# beyond keeping the registry's idea of where we are current.
		pass
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
func _process(_delta: float) -> void:
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

func _resolve_manager() -> Node:
	if manager != null and is_instance_valid(manager):
		return manager
	if not is_inside_tree():
		return null
	var found := get_tree().get_nodes_in_group(&"pasture3d_water_manager")
	return found[0] if not found.is_empty() else null


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
	if poly.size() < 3:
		_clear_surface()
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

	var mask := _inside_mask(poly, mn, spacing, gw, gh)

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
		_clear_surface()
		_last_stats["reason"] = "no cells inside the loop"
		update_configuration_warnings()
		return _last_stats

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

	_ensure_surface()
	_surface.mesh = mesh
	_apply_material()
	_apply_cull_box(mn, mx)

	_last_stats["ok"] = true
	_last_stats["vertices"] = verts.size()
	_last_stats["triangles"] = indices.size() / 3
	_last_stats["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	update_configuration_warnings()
	return _last_stats


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
	# Per-body, and an INSTANCE uniform since Phase 1 precisely so the shared material
	# above is possible. Keeps wave phase precise for a pool far from the world origin.
	_surface.set_instance_shader_parameter("_water_domain_origin", global_position)


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
	var poly := _offset_polygon(_local_polygon(_effective_spacing()))
	if poly.size() < 3:
		return false
	var lp: Vector3 = global_transform.affine_inverse() * p_global_pos
	if not Geometry2D.is_point_in_polygon(Vector2(lp.x, lp.z), poly):
		return false
	return p_global_pos.y <= get_water_height(Vector2(p_global_pos.x, p_global_pos.z))


## Drop this node's Y onto the curve's lowest point + fill_offset.
func fit_to_curve() -> void:
	var src: Curve3D = curve
	var xf := Transform3D()
	if src == null and source_spline != null and is_instance_valid(source_spline):
		src = source_spline.curve
		xf = source_spline.global_transform
	if src == null or src.point_count == 0:
		return
	var lowest := INF
	for p in src.get_baked_points():
		lowest = minf(lowest, (xf * p).y if curve == null else (global_transform * p).y)
	if is_finite(lowest):
		global_position = Vector3(global_position.x, lowest + fill_offset, global_position.z)
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

func _get_property_list() -> Array[Dictionary]:
	# wave_profile as a dropdown of the manager's live profile names. Same mechanism
	# Pasture3DTerrainBrush uses for its tool_layer dropdown.
	var names := PackedStringArray()
	var m := _resolve_manager()
	if m and m.has_method("get_profile_names"):
		names = m.get_profile_names()
	return [{
		"name": "wave_profile",
		"type": TYPE_STRING_NAME,
		"usage": PROPERTY_USAGE_DEFAULT,
		"hint": PROPERTY_HINT_ENUM_SUGGESTION if names.is_empty() else PROPERTY_HINT_ENUM,
		"hint_string": ",".join(names),
	}]


func _validate_property(property: Dictionary) -> void:
	# The preset owns `material` unless the user has chosen Custom.
	if property.name == "material" and water_preset != 2:
		property.usage |= PROPERTY_USAGE_READ_ONLY


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
	var brush := _source_brush()
	if brush != null and _brush_raises(brush):
		var mode: String = brush._blend_mode_name() if brush.has_method("_blend_mode_name") else "?"
		w.append(("'%s' raises terrain (blend_mode = %s), so water here will sit inside the "
			+ "landform and be hidden. Set its blend_mode to MIN (or invert it) to carve.")
			% [brush.name, mode])
	return w


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
