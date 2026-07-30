# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DBrushGizmo — a clickable origin marker for every Pasture3DTerrainBrush, plus in-place
# editing of its child loops while the BRUSH stays selected. Clicking a brush's spline would select the
# child Path3D, not the brush; with many overlapping brushes the parent is awkward to grab. This gizmo
# draws a small octahedron at each brush origin (with collision, so clicking it selects the brush) and,
# while the brush is selected, exposes each loop's control points — and their in/out bezier tangents —
# as SUBGIZMOS, so clicking one shows Godot's standard move gizmo without changing the selection.
# The readable name is a separate Label3D on the brush (see terrain_brush.gd). Editor-only; registered
# by editor_plugin.gd.
@tool
extends EditorNode3DGizmoPlugin

## World half-size of the origin marker (and its click box).
const MARKER_R: float = 4.0
## Metres the marker floats above the terrain surface so it sits clear of the ground, not buried in it.
const SURFACE_LIFT: float = 3.0
## Light neon purple — stands out against terrain greens / browns / yellows / ochres.
const MARKER_COLOR := Color(0.74, 0.42, 1.0)
## World half-size of the per-point marker drawn at each loop control point.
const POINT_R: float = 1.1
## Cyan-white point markers, distinct from the purple origin marker.
const POINT_COLOR := Color(0.55, 0.95, 1.0)
## World half-size of the small tangent-handle marker.
const TANGENT_R: float = 0.8
## Orange tangent handles, distinct from cyan points and purple origin.
const TANGENT_COLOR := Color(1.0, 0.66, 0.2)
## Outward length (m) at which a zero-length tangent's grab handle is drawn/picked, so it can be pulled
## out from a straight point. Clamped to a fraction of the adjacent segment for short loops.
const TANGENT_STUB: float = 3.0
## Screen-space pick radius (px) for clicking a loop point or tangent handle.
const PICK_RADIUS: float = 13.0

## Per-drag capture of the true pre-drag value of each touched subgizmo (id -> Vector3): position for a
## point handle, in/out offset for a tangent. Lets undo restore exactly (esp. a stubbed zero tangent
## back to zero) and lets a tangent drag be applied as a delta so it grows smoothly from the stub.
var _orig: Dictionary = {}
## Per-drag capture of where a tangent handle was first shown (id -> node-local Vector3), the reference
## the live drag delta is measured from.
var _start: Dictionary = {}

## The brush + loop point whose tangents are currently shown (instance id, and running point index gpi).
## Updated when a point/tangent is clicked; tangents for other points stay hidden to keep loops readable.
## Overridden by the "Toggle Tangents" button (Pasture3DTerrainBrush._show_all_tangents).
var _sel_node_id: int = 0
var _sel_gpi: int = -1

## Per-drag note of whether the point being dragged started "smooth" (gpi -> bool), captured before the
## first mutation. When true, dragging one tangent mirrors the other (Shift breaks the symmetry).
var _smooth_drag: Dictionary = {}


func _init() -> void:
	# on_top so the markers show through the terrain (a brush sunk below the surface stays findable).
	create_material("marker", MARKER_COLOR, false, true)
	create_material("points", POINT_COLOR, false, true)
	create_material("tangents", TANGENT_COLOR, false, true)


func _get_gizmo_name() -> String:
	return "Pasture3D Brush"


func _has_gizmo(p_node: Node3D) -> bool:
	return p_node is Pasture3DTerrainBrush


func _redraw(p_gizmo: EditorNode3DGizmo) -> void:
	p_gizmo.clear()
	var node := p_gizmo.get_node_3d()
	# A node mid-removal (e.g. placement undo detaches the brush) is briefly still gizmo-tracked but out of
	# the tree, so global_transform reads would spam "!is_inside_tree()" and draw a stray marker. Skip it.
	if node == null or not node.is_inside_tree():
		return
	# Float the marker above the terrain surface under the brush origin (not the node's own Y, which may
	# be buried after a height change). Computed in node-local space so transforms/scale are respected.
	var centre := _marker_centre(node)
	var mat := get_material("marker", p_gizmo)
	p_gizmo.add_lines(octa(centre, MARKER_R), mat)
	# A solid box of collision triangles round the marker makes it pickable from any angle → clicking
	# selects the brush node. Built offset to the same floating centre as the visible marker
	# (add_collision_triangles has no transform arg, so move the vertices).
	var box := BoxMesh.new()
	box.size = Vector3.ONE * (MARKER_R * 2.0)
	var arrays := box.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += centre
	arrays[Mesh.ARRAY_VERTEX] = verts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tmesh := am.generate_triangle_mesh()
	if tmesh:
		p_gizmo.add_collision_triangles(tmesh)

	# Loop-point markers, their in/out tangent handles, and transform-gizmo editing — shown only while
	# the BRUSH itself is selected (not a child loop), so they don't clutter every brush or duplicate
	# Godot's native Path3D handles. Points and tangents are SUBGIZMOS (below): clicking one shows the
	# standard move gizmo while the brush keeps its own selection.
	if _brush_selected(node):
		var pmat := get_material("points", p_gizmo)
		var gmat := get_material("tangents", p_gizmo)
		var gpi := 0
		for path in _loop_paths(node):
			for i in path.curve.point_count:
				var c := node.to_local(path.to_global(path.curve.get_point_position(i)))
				p_gizmo.add_lines(octa(c, POINT_R), pmat)
				# Tangents only for the selected point (or all, when the toggle is on) — declutter.
				if _show_tangents(node, gpi):
					for kind in [1, 2]:
						var hc := _handle_display_local(node, path, i, kind)
						p_gizmo.add_lines(PackedVector3Array([c, hc]), gmat)
						p_gizmo.add_lines(octa(hc, TANGENT_R), gmat)
				gpi += 1


# ---- Loop points + tangents as subgizmos ----
# Each loop point owns three handles, encoded into the subgizmo id as `gpi * 3 + kind`, where `gpi` is
# the running point index across all child loops (in _loop_paths order) and kind is 0=position,
# 1=in-tangent, 2=out-tangent.


## Click test: the handle nearest the cursor in screen space (or -1). Position is tested first so it
## wins at exact overlap (e.g. a tangent that is still on its point).
func _subgizmos_intersect_ray(p_gizmo: EditorNode3DGizmo, p_camera: Camera3D, p_point: Vector2) -> int:
	var node := p_gizmo.get_node_3d()
	if not _brush_selected(node):
		return -1
	var best := -1
	var best_d := PICK_RADIUS
	var gpi := 0
	for path in _loop_paths(node):
		for i in path.curve.point_count:
			for kind in 3:
				var world: Vector3 = node.to_global(_handle_display_local(node, path, i, kind))
				if not p_camera.is_position_behind(world):
					var d := p_camera.unproject_position(world).distance_to(p_point)
					if d < best_d:
						best_d = d
						best = gpi * 3 + kind
			gpi += 1
	_update_selected_point(node, best / 3 if best >= 0 else -1)
	return best


## Track which point's tangents to show. A hit selects that point; a miss (click in empty space) clears
## it, hiding the tangents again. Redraw only when it actually changes.
func _update_selected_point(p_node: Node3D, p_gpi: int) -> void:
	var id := p_node.get_instance_id()
	if p_gpi >= 0:
		if _sel_node_id != id or _sel_gpi != p_gpi:
			_sel_node_id = id
			_sel_gpi = p_gpi
			p_node.update_gizmos.call_deferred()
	elif _sel_node_id == id and _sel_gpi != -1:
		_sel_gpi = -1
		p_node.update_gizmos.call_deferred()


## Whether to draw point `p_gpi`'s tangent handles: only the selected point, or all when the toggle is on.
func _show_tangents(p_node: Node3D, p_gpi: int) -> bool:
	if Pasture3DTerrainBrush._show_all_tangents:
		return true
	return p_node.get_instance_id() == _sel_node_id and p_gpi == _sel_gpi


## A point is "smooth" when both tangents are non-trivial and roughly mirror images (collinear, equal
## length). Such points keep their handles mirrored while dragging.
func _is_smooth(p_in: Vector3, p_out: Vector3) -> bool:
	if p_in.length() < 0.02 or p_out.length() < 0.02:
		return false
	return (p_in + p_out).length() < 0.1 * maxf(p_in.length(), p_out.length())


## [Path3D, point index] of the currently-selected loop point on `p_brush`, or [null, -1]. Lets the
## plugin remove it on the Delete key (see editor_plugin.gd).
func selected_point(p_brush: Node3D) -> Array:
	if p_brush == null or _sel_node_id != p_brush.get_instance_id() or _sel_gpi < 0:
		return [null, -1]
	var res := _resolve_handle(p_brush, _sel_gpi * 3)
	return [res[0], res[1]]


## Forget the selected point (e.g. after it was deleted) so its now-stale index isn't reused.
func clear_point_selection() -> void:
	_sel_gpi = -1


## Box-select: every loop POSITION inside the selection frustum (group move). Tangents are excluded so
## a box drag never drags curvature handles by surprise.
func _subgizmos_intersect_frustum(p_gizmo: EditorNode3DGizmo, _camera: Camera3D, p_frustum: Array[Plane]) -> PackedInt32Array:
	var node := p_gizmo.get_node_3d()
	var out := PackedInt32Array()
	if not _brush_selected(node):
		return out
	var gpi := 0
	for path in _loop_paths(node):
		for i in path.curve.point_count:
			var world: Vector3 = path.to_global(path.curve.get_point_position(i))
			if _inside_frustum(p_frustum, world):
				out.append(gpi * 3)
			gpi += 1
	return out


## The handle's transform (translation only) in the gizmo node's local space — where the gizmo appears.
func _get_subgizmo_transform(p_gizmo: EditorNode3DGizmo, p_id: int) -> Transform3D:
	var node := p_gizmo.get_node_3d()
	var res := _resolve_handle(node, p_id)
	var path: Path3D = res[0]
	if path == null:
		return Transform3D()
	return Transform3D(Basis(), _handle_display_local(node, path, res[1], res[2]))


## Live drag from the transform gizmo.
## - Position handle: take the new origin; Snap to Surface overrides Y onto the base beneath the brush.
## - Tangent handle: apply the drag as a delta from where the handle was first shown, growing the
##   tangent from its true pre-drag offset (so a stubbed zero tangent starts at zero, no jump). Kept
##   level (offset Y = 0) while Snap to Surface is on, so the loop stays planar with the surface.
func _set_subgizmo_transform(p_gizmo: EditorNode3DGizmo, p_id: int, p_transform: Transform3D) -> void:
	var node := p_gizmo.get_node_3d()
	var res := _resolve_handle(node, p_id)
	var path: Path3D = res[0]
	if path == null:
		return
	var idx: int = res[1]
	var kind: int = res[2]
	var brush := node as Pasture3DTerrainBrush
	if kind == 0:
		if not _orig.has(p_id):
			_orig[p_id] = path.curve.get_point_position(idx)
		var world := node.to_global(p_transform.origin)
		if brush != null and brush.snap_to_surface:
			var h: float = brush._base_height_below(Vector3(world.x, 0.0, world.z))
			if is_finite(h):
				world.y = h + brush.surface_offset
		path.curve.set_point_position(idx, path.to_local(world))
		return
	# Tangent (in/out).
	var gpi: int = p_id / 3
	if not _orig.has(p_id):
		_orig[p_id] = path.curve.get_point_in(idx) if kind == 1 else path.curve.get_point_out(idx)
		_start[p_id] = _handle_display_local(node, path, idx, kind)
		if not _smooth_drag.has(gpi):
			_smooth_drag[gpi] = _is_smooth(path.curve.get_point_in(idx), path.curve.get_point_out(idx))
	var delta_node: Vector3 = p_transform.origin - (_start[p_id] as Vector3)
	var delta_path: Vector3 = path.global_transform.basis.inverse() * (node.global_transform.basis * delta_node)
	var new_off: Vector3 = (_orig[p_id] as Vector3) + delta_path
	if brush != null and brush.snap_to_surface:
		new_off.y = 0.0
	if kind == 1:
		path.curve.set_point_in(idx, new_off)
	else:
		path.curve.set_point_out(idx, new_off)
	# On a smooth point, keep the opposite handle mirrored (equal length, opposite direction). Hold Shift
	# to break symmetry into an independent corner. The partner is folded into the same undo at commit.
	if _smooth_drag.get(gpi, false) and not Input.is_key_pressed(KEY_SHIFT):
		var partner_kind := 2 if kind == 1 else 1
		var partner_id := gpi * 3 + partner_kind
		if not _orig.has(partner_id):
			_orig[partner_id] = path.curve.get_point_in(idx) if partner_kind == 1 else path.curve.get_point_out(idx)
		if partner_kind == 1:
			path.curve.set_point_in(idx, -new_off)
		else:
			path.curve.set_point_out(idx, -new_off)


## Commit the drag(s) as one undoable action. The curve change fires curve.changed → the brush repaints
## (and again on undo). Restores come from the captured pre-drag values so a stubbed zero tangent undoes
## cleanly back to zero.
func _commit_subgizmos(p_gizmo: EditorNode3DGizmo, p_ids: PackedInt32Array, p_restores: Array[Transform3D], p_cancel: bool) -> void:
	var node := p_gizmo.get_node_3d()
	if p_cancel:
		# Restore every handle we touched — including mirrored partners not in p_ids (their pre-drag value
		# lives in _orig, so the passed restore transform is unused for them).
		for key in _orig.keys():
			_restore_handle(node, key, Transform3D())
		_orig.clear()
		_start.clear()
		_smooth_drag.clear()
		return
	var has_tangent := false
	for id in p_ids:
		if id % 3 != 0:
			has_tangent = true
			break
	var name := "Edit Loop Handle" if has_tangent else "Move Loop Point"
	if p_ids.size() != 1:
		name += "s"
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(name)
	for i in p_ids.size():
		var res := _resolve_handle(node, p_ids[i])
		var path: Path3D = res[0]
		if path == null:
			continue
		var idx: int = res[1]
		var kind: int = res[2]
		if kind == 0:
			var cur := path.curve.get_point_position(idx)
			var restore: Vector3 = _orig.get(p_ids[i], path.to_local(node.to_global(p_restores[i].origin)))
			ur.add_do_method(path.curve, "set_point_position", idx, cur)
			ur.add_undo_method(path.curve, "set_point_position", idx, restore)
		elif kind == 1:
			var cur := path.curve.get_point_in(idx)
			ur.add_do_method(path.curve, "set_point_in", idx, cur)
			ur.add_undo_method(path.curve, "set_point_in", idx, _orig.get(p_ids[i], cur))
		else:
			var cur := path.curve.get_point_out(idx)
			ur.add_do_method(path.curve, "set_point_out", idx, cur)
			ur.add_undo_method(path.curve, "set_point_out", idx, _orig.get(p_ids[i], cur))
	# Mirrored partner tangents were moved but aren't in p_ids — fold them into the same action so undo
	# reverts both handles together.
	for key in _orig.keys():
		if key % 3 == 0 or key in p_ids:
			continue
		var pres := _resolve_handle(node, key)
		var ppath: Path3D = pres[0]
		if ppath == null:
			continue
		var pidx: int = pres[1]
		if pres[2] == 1:
			var pcur := ppath.curve.get_point_in(pidx)
			ur.add_do_method(ppath.curve, "set_point_in", pidx, pcur)
			ur.add_undo_method(ppath.curve, "set_point_in", pidx, _orig[key])
		else:
			var pcur := ppath.curve.get_point_out(pidx)
			ur.add_do_method(ppath.curve, "set_point_out", pidx, pcur)
			ur.add_undo_method(ppath.curve, "set_point_out", pidx, _orig[key])
	ur.commit_action()
	_orig.clear()
	_start.clear()
	_smooth_drag.clear()


## Put one handle back to a transform (used on drag-cancel), preferring the captured pre-drag value.
func _restore_handle(p_node: Node3D, p_id: int, p_restore: Transform3D) -> void:
	var res := _resolve_handle(p_node, p_id)
	var path: Path3D = res[0]
	if path == null:
		return
	var idx: int = res[1]
	var kind: int = res[2]
	match kind:
		0:
			var pos: Vector3 = _orig.get(p_id, path.to_local(p_node.to_global(p_restore.origin)))
			path.curve.set_point_position(idx, pos)
		1:
			path.curve.set_point_in(idx, _orig.get(p_id, path.curve.get_point_in(idx)))
		_:
			path.curve.set_point_out(idx, _orig.get(p_id, path.curve.get_point_out(idx)))


## Map a flat subgizmo id back to [child Path3D, point index, kind], in the same order _redraw drew them.
func _resolve_handle(p_node: Node3D, p_id: int) -> Array:
	var gpi: int = p_id / 3
	var kind: int = p_id % 3
	var base := 0
	for path in _loop_paths(p_node):
		var n: int = path.curve.point_count
		if gpi < base + n:
			return [path, gpi - base, kind]
		base += n
	return [null, -1, -1]


## Node-local position where a handle is shown/picked. Position = the point; a tangent = the point plus
## its in/out offset, or a short outward stub when that offset is ~zero (so it can be grabbed).
func _handle_display_local(p_node: Node3D, p_path: Path3D, p_idx: int, p_kind: int) -> Vector3:
	var c := p_path.curve
	var p: Vector3 = c.get_point_position(p_idx)
	if p_kind != 0:
		p += _display_offset(p_node, p_path, p_idx, p_kind)
	return p_node.to_local(p_path.to_global(p))


## A tangent's display offset (path-local): the real in/out offset, or a stub when it is ~zero.
func _display_offset(p_node: Node3D, p_path: Path3D, p_idx: int, p_kind: int) -> Vector3:
	var c := p_path.curve
	var real: Vector3 = c.get_point_in(p_idx) if p_kind == 1 else c.get_point_out(p_idx)
	if real.length() > 0.02:
		return real
	return _stub_offset(p_node, p_path, p_idx, p_kind)


## Short outward offset for a zero-length tangent, pointing toward the adjacent point (prev for in, next
## for out), clamped to a fraction of that segment so it never overshoots on short loops.
func _stub_offset(p_node: Node3D, p_path: Path3D, p_idx: int, p_kind: int) -> Vector3:
	var c := p_path.curve
	var n: int = c.point_count
	var p: Vector3 = c.get_point_position(p_idx)
	var closed := _is_closed(p_node, p_path)
	var j: int
	if p_kind == 1:
		j = p_idx - 1
		if j < 0:
			j = (n - 1) if closed else p_idx + 1
	else:
		j = p_idx + 1
		if j >= n:
			j = 0 if closed else p_idx - 1
	if j < 0 or j >= n or j == p_idx:
		return Vector3.ZERO
	var dir: Vector3 = c.get_point_position(j) - p
	var l := dir.length()
	if l < 0.001:
		return Vector3.ZERO
	return dir / l * minf(TANGENT_STUB, l * 0.4)


## Whether this loop is a closed polygon (Mound/Plow: min ≥ 3 points) vs an open spline (Ridge/Trough).
func _is_closed(p_node: Node3D, p_path: Path3D) -> bool:
	var brush := p_node as Pasture3DTerrainBrush
	if brush != null:
		return brush._is_closed()
	return p_path.curve.point_count >= 3


## A point is inside the selection frustum when it is on the inner side of every plane.
func _inside_frustum(p_planes: Array[Plane], p_point: Vector3) -> bool:
	for pl in p_planes:
		if pl.is_point_over(p_point):
			return false
	return true


## This brush's child loops that have a curve (the editable splines), in child order.
func _loop_paths(p_node: Node3D) -> Array:
	var out: Array = []
	for c in p_node.get_children():
		if c is Path3D and c.curve != null:
			out.append(c)
	return out


## The brush node itself (not a child loop) is the current editor selection.
func _brush_selected(p_node: Node3D) -> bool:
	return p_node in EditorInterface.get_selection().get_selected_nodes()


## Marker centre in node-local space: the terrain surface height under the brush origin (+ lift), or the
## origin itself when there's no terrain/height to read.
func _marker_centre(node: Node3D) -> Vector3:
	var origin: Vector3 = node.global_transform.origin
	var surf_y := origin.y
	var brush := node as Pasture3DTerrainBrush
	if brush != null and brush.terrain != null and brush.terrain.data != null:
		var h: float = brush.terrain.data.get_height(Vector3(origin.x, 0.0, origin.z))
		if is_finite(h):
			surf_y = h
	var world_centre := Vector3(origin.x, surf_y + SURFACE_LIFT, origin.z)
	return node.to_local(world_centre)


## Octahedron wireframe (12 edges) of half-size `r` centred on `c` — reads as a gizmo "point" from any
## view. Used for the origin marker, loop points, and tangent handles at different sizes.
## Static, and shared with pool_gizmo.gd, so every Pasture3D marker is literally the same shape.
static func octa(c: Vector3, r: float) -> PackedVector3Array:
	var a := c + Vector3(r, 0, 0)
	var b := c + Vector3(-r, 0, 0)
	var t := c + Vector3(0, r, 0)
	var d := c + Vector3(0, -r, 0)
	var e := c + Vector3(0, 0, r)
	var f := c + Vector3(0, 0, -r)
	return PackedVector3Array([
		a, e, e, b, b, f, f, a,    # equator ring
		t, a, t, e, t, b, t, f,    # apex spokes
		d, a, d, e, d, b, d, f,    # nadir spokes
	])
