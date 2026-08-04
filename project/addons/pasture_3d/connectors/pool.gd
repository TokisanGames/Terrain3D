# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPool — a lake, a pond, a reservoir: still water filling a closed outline.
# See PASTURE3D_WATER_BODIES_SPEC.md §7.
#
# The node that makes "add water to this basin" one button press. It takes the loop a
# Pasture3DMound (or Pond, or Plow, or Splat) already drew, fills it with a subdivided flat
# surface, and puts a water material on it. The waves, the clock and the material all come from
# the scene's Pasture3DPoolManager, so a pond is not a special case of anything -- it is the same
# water the ocean is, over a smaller polygon.
#
# CLOSED CURVES ONLY, and that is the change the split made. This file used to switch on
# `curve.closed` at every rebuild and become a river when the answer was no; rivers are now
# Pasture3DStream, and an open curve here is a misconfiguration with a Convert to Stream button
# next to it rather than a second personality. Everything a lake and a river agree about lives in
# Pasture3DWaterBody; this class is only the part that is a filled outline.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DPool
extends Pasture3DWaterBody

const PRESET_PATHS := {
	0: WATER_DIR + "M_water_lake.tres",
	1: WATER_DIR + "M_water_pond.tres",
}

# A group of its own, and not for tidiness: an inspector group runs until the next one, and the
# base class ends inside "Underwater" -- so an ungrouped export here would file the migration
# button under the fog settings.
@export_group("Migration")
## Turn this pool into a Pasture3DStream, in place, keeping its settings and its name.
##
## The migration path for water authored before the split, when an open curve made a
## Pasture3DPool mesh itself as a ribbon. Such a pool now draws nothing and says so; this is the
## one press that fixes it. Hidden on a closed curve, where there is nothing to convert.
@export_tool_button("Convert to Stream") var _convert_btn = convert_to_stream

## The offset loop in LOCAL XZ, as of the last rebuild. Every containment query reads this rather
## than re-deriving it; see _build_surface.
var _poly_cache := PackedVector2Array()
## The mesher's own inside mask, kept so containment is a lookup rather than a polygon walk. See
## _contains_local. Empty means "no mask, fall back to the exact test everywhere".
var _mask := PackedByteArray()
var _mask_gw := 0
var _mask_gh := 0
var _mask_spacing := 0.0


# ---- the shape contract ------------------------------------------------------

func _preset_names() -> PackedStringArray:
	return PackedStringArray(["Lake", "Pond", "Custom"])


func _preset_paths() -> Dictionary:
	return PRESET_PATHS


func _has_surface() -> bool:
	return _poly_cache.size() >= 3


## Cell classification off the mesher's mask, which turns the common answer into an array
## lookup. The exact polygon walk is O(perimeter) — a few hundred edges for a lake — and Phase 6
## asks this question per buoy per physics tick, where it cost more than the wave solve did.
##
## Reading the MESHER's mask rather than a structure of its own is the point: a cell whose four
## corners are all inside is exactly a cell the mesher filled with a quad, so "contained" and
## "drawn" cannot disagree. Only cells the boundary crosses fall through to the exact test, and
## there are O(shore length) of those.
func _contains_local(p_local_xz: Vector2) -> bool:
	match _cell_state(p_local_xz):
		0:
			return false
		1:
			return true # every corner inside: the mesher drew a full quad here
	return Geometry2D.is_point_in_polygon(p_local_xz, _poly_cache)


func _shape_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	var src := _source_curve()
	if src == null:
		w.append("No source. Set source_spline to a brush's Path3D, or assign a Curve3D.")
	elif not src.closed:
		# The split's one behaviour change, so it names the class AND the button rather than
		# reporting a shape problem: water authored before it will land here, having silently
		# meshed itself as a ribbon for however long, and "3 points" would be the wrong diagnosis.
		w.append("This curve is OPEN, and a Pasture3DPool fills a CLOSED outline. An open curve "
			+ "is a river: press Convert to Stream to turn this into a Pasture3DStream, which "
			+ "follows the channel downhill and takes its surface from the banks.")
	elif src.point_count < 3:
		w.append("The source curve has fewer than 3 points, so there is no area to fill.")
	elif _local_polygon(_effective_spacing()).size() < 3:
		w.append("The source curve collapses to fewer than 3 usable points at this vertex "
			+ "spacing, so there is no area to fill.")
	return w


# ---- geometry ----------------------------------------------------------------

## The loop, in this node's LOCAL XZ, decimated to roughly the grid resolution.
## Returns an empty array when there is no usable closed curve.
func _local_polygon(p_spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var src := _source_curve()
	if src == null or src.point_count < 3:
		return out
	# An OPEN curve is a river, not a lake. Filling one means closing it between its two
	# endpoints, which is a wedge the user never drew — so refuse and let the configuration
	# warning point at Pasture3DStream.
	if not src.closed:
		return out
	var to_local_xf := _source_to_local()

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


## Fill the loop with a flat sheet at this node's Y.
func _build_surface(p_spacing: float) -> void:
	var poly := _offset_polygon(_local_polygon(p_spacing))
	# Cache it. Every containment question — the camera poll, the Area3D re-filter, a buoy asking
	# which body it is in — needs this same polygon, and rebuilding it per query means re-baking the
	# curve, decimating it and running Geometry2D.offset_polygon several times a frame. It only
	# changes when the mesh does, so it is stored where the mesh is.
	_poly_cache = poly
	if poly.size() < 3:
		_build_failed("no usable closed curve")
		return

	# Bounds, snapped outward to the grid so the lattice is stable as the loop moves.
	var mn := poly[0]
	var mx := poly[0]
	for v in poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	mn = Vector2(floorf(mn.x / p_spacing) * p_spacing, floorf(mn.y / p_spacing) * p_spacing)
	mx = Vector2(ceilf(mx.x / p_spacing) * p_spacing, ceilf(mx.y / p_spacing) * p_spacing)
	# Local-space XZ bounds of the polygon: the broad phase for every containment query, and the
	# footprint the underwater volume spans.
	_poly_bounds = Rect2(mn, mx - mn)
	var gw := int(round((mx.x - mn.x) / p_spacing)) + 1
	var gh := int(round((mx.y - mn.y) / p_spacing)) + 1
	if gw < 2 or gh < 2:
		_build_failed("loop smaller than one grid cell")
		return
	if _budget_exceeded(gw * gh, p_spacing):
		return

	# The mesher's inside mask, kept for containment queries (see _contains_local). Built here
	# rather than inside the mesher so both mesher paths produce it and both agree with it.
	if ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_inside_mask", true):
		_mask = Pasture3DUtil.build_inside_mask(poly, mn, p_spacing, gw, gh)
	else:
		_mask = _inside_mask(poly, mn, p_spacing, gw, gh)
	_mask_gw = gw
	_mask_gh = gh
	_mask_spacing = p_spacing

	# The O(area) half. Native by default (spec §12 q1): the GDScript below is a faithful
	# transcription kept as the A/B oracle, exactly as the brushes keep force_gdscript_raster, and
	# `force_gdscript_mesh` switches between them on identical inputs.
	var mesh: ArrayMesh = null
	var native := false
	if not force_gdscript_mesh and ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_pool_mesh", true):
		mesh = Pasture3DUtil.build_pool_mesh(poly, mn, p_spacing, gw, gh)
		native = mesh != null
	if not native:
		mesh = _build_mesh_gdscript(poly, mn, p_spacing, gw, gh, _mask)
	_last_stats["native"] = native
	if mesh == null:
		_build_failed("no cells inside the loop")
		return

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
	arrays[Mesh.ARRAY_COLOR] = _neutral_colours(verts.size())
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


## 0 = no corner of this cell is inside the loop, 1 = all four are, 2 = mixed (or no mask).
func _cell_state(p_local_xz: Vector2) -> int:
	if _mask.is_empty() or _mask_spacing <= 0.0:
		return 2
	var ix := int(floor((p_local_xz.x - _poly_bounds.position.x) / _mask_spacing))
	var iz := int(floor((p_local_xz.y - _poly_bounds.position.y) / _mask_spacing))
	if ix < 0 or iz < 0 or ix >= _mask_gw - 1 or iz >= _mask_gh - 1:
		return 2 # on the grid's outer edge; let the exact test decide
	var n := int(_mask[iz * _mask_gw + ix]) + int(_mask[iz * _mask_gw + ix + 1]) \
		+ int(_mask[(iz + 1) * _mask_gw + ix]) + int(_mask[(iz + 1) * _mask_gw + ix + 1])
	if n == 0:
		return 0
	return 1 if n == 4 else 2


## The pool's outline in local XZ, as the mesh was last built from it. Exposed so a gate — or a
## tool — can check containment against the same polygon the node uses rather than a re-derived one.
func get_polygon() -> PackedVector2Array:
	return _poly_cache


func _forget_surface() -> void:
	super()
	_poly_cache = PackedVector2Array()
	_mask = PackedByteArray()


# ---- migration ---------------------------------------------------------------

## Replace this pool with an equivalent Pasture3DStream, in the same place in the scene.
##
## Before the split, a Pasture3DPool with an open curve meshed itself as a ribbon; scenes authored
## then hold rivers that are Pasture3DPool nodes, and after the split those build nothing. One
## press converts one. Returns the new node, or null when there was nothing to do.
##
## Deliberately NOT automatic. Swapping a node's class rewrites the scene, and doing that behind
## the user's back on load -- before they have seen the warning, saved anything, or had a chance to
## undo -- is how a migration turns into a bug report about a scene that changed on its own. The
## warning explains, the button acts.
func convert_to_stream() -> Node:
	var src := _source_curve()
	if src != null and src.closed:
		push_warning(("Pasture3DPool '%s': this curve is closed, so it is already a lake. "
			+ "Convert to Stream is for water whose curve is open.") % name)
		return null
	var parent := get_parent()
	if parent == null:
		push_warning("Pasture3DPool '%s': nothing to convert into — it has no parent." % name)
		return null

	var script: GDScript = load("res://addons/pasture_3d/connectors/stream.gd")
	if script == null:
		push_error("Pasture3D: could not load stream.gd — cannot convert.")
		return null
	var stream: Node3D = script.new()
	stream.name = name
	stream.transform = transform
	# The preset FIRST and the material last: setting water_preset loads whatever preset it names,
	# so the other order would quietly overwrite a material the user had tuned.
	stream.water_preset = stream._custom_preset()
	for p in ["source_spline", "curve", "edge_offset", "fill_offset", "max_vertices",
			"vertex_spacing", "force_gdscript_mesh", "wave_profile", "manager",
			"underwater_enabled", "volume_depth", "underwater_fog", "underwater_density_scale",
			"underwater_overlay", "overlay_canvas_layer", "overlay_transition"]:
		stream.set(p, get(p))
	stream.material = material

	var idx := get_index()
	var scene_owner := owner
	var ur := _editor_undo()
	if ur != null:
		ur.create_action("Convert %s to Pasture3DStream" % name)
		ur.add_do_method(self, "_apply_convert", stream, parent, idx, scene_owner)
		ur.add_undo_method(self, "_revert_convert", stream, parent, idx, scene_owner)
		ur.add_do_reference(stream)
		ur.add_undo_reference(self)
		ur.commit_action()
	else:
		_apply_convert(stream, parent, idx, scene_owner)
	return stream


## Put the stream in and take the pool out. Both nodes stay alive -- the undo action holds
## whichever one is outside -- so undo and redo move the SAME two instances rather than rebuilding.
func _apply_convert(p_stream: Node, p_parent: Node, p_index: int, p_owner: Node) -> void:
	if not is_instance_valid(p_stream) or not is_instance_valid(p_parent):
		return
	if get_parent() == p_parent:
		p_parent.remove_child(self)
	if p_stream.get_parent() == null:
		p_parent.add_child(p_stream)
		p_parent.move_child(p_stream, mini(p_index, p_parent.get_child_count() - 1))
		p_stream.owner = p_owner
	if Engine.is_editor_hint():
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(p_stream)


func _revert_convert(p_stream: Node, p_parent: Node, p_index: int, p_owner: Node) -> void:
	if is_instance_valid(p_stream) and p_stream.get_parent() == p_parent:
		p_parent.remove_child(p_stream)
	if get_parent() == null and is_instance_valid(p_parent):
		p_parent.add_child(self)
		p_parent.move_child(self, mini(p_index, p_parent.get_child_count() - 1))
		owner = p_owner


## The editor's undo manager, or null outside the editor -- a headless run, or a script driving the
## conversion. Same accessor Pasture3DTerrainBrush uses, and the null case is why _apply_convert is
## one method with an explicit inverse rather than a pile of do-steps: it has to be callable, and
## therefore testable, without an editor.
func _editor_undo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


# ---- inspector ---------------------------------------------------------------

func _validate_property(property: Dictionary) -> void:
	super(property)
	if property.name == "_convert_btn":
		# Only on the water this is a migration FOR. A Convert to Stream button on every lake in
		# the project would be an invitation to break one.
		var src := _source_curve()
		if src == null or src.closed:
			property.usage = PROPERTY_USAGE_NONE
