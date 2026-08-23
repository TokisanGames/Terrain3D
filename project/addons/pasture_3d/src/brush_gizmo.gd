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
## Fallback origin-marker colour, for a node that does not declare one. The colour is the BRUSH'S
## decision (`Pasture3DTerrainBrush._gizmo_color`), not this plugin's — otherwise adding a family that
## needs its own colour would mean teaching the gizmo a list of class names.
const MARKER_COLOR := Color(0.74, 0.42, 1.0)
## World half-size of the per-point marker drawn at each loop control point.
const POINT_R: float = 1.1
## The shared marker machinery: sprites at a constant screen size, and the handle dots.
const Sprites: Script = preload("res://addons/pasture_3d/src/gizmo_sprites.gd")

## Cyan-white point markers, distinct from the purple origin marker.
const POINT_COLOR := Color(0.55, 0.95, 1.0)
## World half-size of the small tangent-handle marker.
const TANGENT_R: float = 0.8
## Orange tangent handles, distinct from cyan points and purple origin.
const TANGENT_COLOR := Color(1.0, 0.66, 0.2)


## Per-drag capture of the true pre-drag value of each touched subgizmo (id -> Vector3): position for a
## point handle, in/out offset for a tangent. Lets undo restore exactly (esp. a stubbed zero tangent
## back to zero) and lets a tangent drag be applied as a delta so it grows smoothly from the stub.
var _orig: Dictionary = {}
## Per-drag capture of where a tangent handle was first shown (id -> node-local Vector3), the reference
## the live drag delta is measured from.
var _start: Dictionary = {}

## Where the handles are and which one is selected. A plain RefCounted so a headless gate can drive it —
## see the header of brush_handles.gd for why that could not be done in place.
const Handles: Script = preload("res://addons/pasture_3d/src/brush_handles.gd")
var _h: Handles = Handles.new()

## Per-drag note of whether the point being dragged started "smooth" (gpi -> bool), captured before the
## first mutation. When true, dragging one tangent mirrors the other (Shift breaks the symmetry).
var _smooth_drag: Dictionary = {}

## Marker materials created on demand, one per distinct colour a brush asked for (html colour -> the
## name it was registered under). `create_material` is per-plugin and by name, so the set has to be
## interned somewhere; doing it lazily means a new brush family declares a colour and nothing else.
var _marker_materials: Dictionary = {}


func _init() -> void:
	# on_top so the markers show through the terrain (a brush sunk below the surface stays findable).
	create_material("marker", MARKER_COLOR, false, true)
	create_material("points", POINT_COLOR, false, true)
	create_material("tangents", TANGENT_COLOR, false, true)


## The marker material for one colour, registering it the first time it is asked for.
func _marker_material(p_gizmo: EditorNode3DGizmo, p_color: Color) -> Material:
	var key := p_color.to_html(false)
	if not _marker_materials.has(key):
		var mname := "marker_%s" % key
		# on_top, as the default marker is: a brush sunk below the surface stays findable.
		create_material(mname, p_color, false, true)
		_marker_materials[key] = mname
	return get_material(_marker_materials[key], p_gizmo)


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
	# The colour stays the BRUSH'S decision (`Pasture3DTerrainBrush._gizmo_color`) — light neon purple
	# for a stamping brush, dark blue for the erosion family. The sprites are grayscale so the tint is
	# the whole of it: white becomes the colour, the black outline stays black whatever it is.
	var tint: Color = node._gizmo_color() if node.has_method("_gizmo_color") else MARKER_COLOR
	var sprite: Texture2D = Sprites.sprite_for(node)
	if sprite != null:
		# What kind of brush this is, answerable at a glance and from any distance. The wireframe
		# octahedron it replaced was a pixel thick and told you only that SOMETHING was there.
		p_gizmo.add_mesh(Sprites._quad_mesh(),
				Sprites._sprite_material("sprite:%s:%s" % [sprite.resource_name, tint.to_html(false)],
						sprite, tint),
				Transform3D(Basis().scaled(Vector3.ONE * Sprites.ICON_SIZE), centre))
	else:
		# A class with no sprite anywhere up its chain keeps the old marker rather than nothing.
		p_gizmo.add_lines(octa(centre, MARKER_R), _marker_material(p_gizmo, tint))
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
		var gmat := get_material("tangents", p_gizmo)
		var is_sel_node := node.get_instance_id() == _h.sel_node_id
		var gpi := 0
		for path in _h.loop_paths(node):
			for i in path.curve.point_count:
				var c := node.to_local(path.to_global(path.curve.get_point_position(i)))
				Sprites._dot_sprite(p_gizmo, c, Sprites.POINT_SIZE, POINT_COLOR,
						is_sel_node and gpi == _h.sel_gpi and _h.sel_kind == 0)
				# Tangents only for the selected point (or all, when the toggle is on) — declutter.
				if _h.show_tangents(node, gpi):
					for kind in [1, 2]:
						var hc := _h.handle_display_local(node, path, i, kind)
						# The stem stays a line: it is what says which point a handle belongs to, and
						# two dots with nothing between them do not say it.
						p_gizmo.add_lines(PackedVector3Array([c, hc]), gmat)
						Sprites._dot_sprite(p_gizmo, hc, Sprites.TANGENT_SIZE, TANGENT_COLOR,
								is_sel_node and gpi == _h.sel_gpi and _h.sel_kind == kind)
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
	return _h.pick_handle(node, p_camera, p_point)


## [Path3D, point index] of the currently-selected loop point on `p_brush`, or [null, -1]. Lets the
## plugin remove it on the Delete key (see editor_plugin.gd).
func selected_point(p_brush: Node3D) -> Array:
	return _h.selected_point(p_brush)


## Forget the selected point (e.g. after it was deleted) so its now-stale index isn't reused.
func clear_point_selection() -> void:
	_h.clear_point_selection()


## A point is "smooth" when both tangents are non-trivial and roughly mirror images (collinear, equal
## length). Such points keep their handles mirrored while dragging.
func _is_smooth(p_in: Vector3, p_out: Vector3) -> bool:
	if p_in.length() < 0.02 or p_out.length() < 0.02:
		return false
	return (p_in + p_out).length() < 0.1 * maxf(p_in.length(), p_out.length())


## Box-select: every loop POSITION inside the selection frustum (group move). Tangents are excluded so
## a box drag never drags curvature handles by surprise.
func _subgizmos_intersect_frustum(p_gizmo: EditorNode3DGizmo, _camera: Camera3D, p_frustum: Array[Plane]) -> PackedInt32Array:
	var node := p_gizmo.get_node_3d()
	var out := PackedInt32Array()
	if not _brush_selected(node):
		return out
	var gpi := 0
	for path in _h.loop_paths(node):
		for i in path.curve.point_count:
			var world: Vector3 = path.to_global(path.curve.get_point_position(i))
			if _inside_frustum(p_frustum, world):
				out.append(gpi * 3)
			gpi += 1
	return out


## The handle's transform (translation only) in the gizmo node's local space — where the gizmo appears.
func _get_subgizmo_transform(p_gizmo: EditorNode3DGizmo, p_id: int) -> Transform3D:
	var node := p_gizmo.get_node_3d()
	var res := _h.resolve_handle(node, p_id)
	var path: Path3D = res[0]
	if path == null:
		return Transform3D()
	return Transform3D(Basis(), _h.handle_display_local(node, path, res[1], res[2]))


## Live drag from the transform gizmo.
## - Position handle: take the new origin; Snap to Surface overrides Y onto the base beneath the brush.
## - Tangent handle: apply the drag as a delta from where the handle was first shown, growing the
##   tangent from its true pre-drag offset (so a stubbed zero tangent starts at zero, no jump). Kept
##   level (offset Y = 0) while Snap to Surface is on, so the loop stays planar with the surface.
func _set_subgizmo_transform(p_gizmo: EditorNode3DGizmo, p_id: int, p_transform: Transform3D) -> void:
	var node := p_gizmo.get_node_3d()
	var res := _h.resolve_handle(node, p_id)
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
		_start[p_id] = _h.handle_display_local(node, path, idx, kind)
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
		var res := _h.resolve_handle(node, p_ids[i])
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
		var pres := _h.resolve_handle(node, key)
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
	var res := _h.resolve_handle(p_node, p_id)
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


## A point is inside the selection frustum when it is on the inner side of every plane.
func _inside_frustum(p_planes: Array[Plane], p_point: Vector3) -> bool:
	for pl in p_planes:
		if pl.is_point_over(p_point):
			return false
	return true


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
