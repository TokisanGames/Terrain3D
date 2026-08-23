# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DBrushHandles — which loop handle a click lands on, and which one is currently selected.
#
# Split out of brush_gizmo.gd, and not for tidiness: `EditorNode3DGizmoPlugin` REFUSES TO INSTANTIATE
# outside the editor ("can only be instantiated by editor"), so every line below was unreachable from a
# headless gate while it lived there — including the pick order, which is the part users actually
# complain about and the part that is pure geometry and therefore exactly what a gate is good at.
#
# It is also a coherent unit on its own: "where are the handles and which one did you click" needs a
# curve and a camera and knows nothing about materials, meshes or redraws. What stayed behind is
# everything that needs an EditorNode3DGizmo to talk to.
#
# Editor-only in practice; owned by brush_gizmo.gd, driven directly by bench/GizmoMarkerGate.gd.
@tool
extends RefCounted

## Screen-space pick radius (px) for clicking a loop point or tangent handle.
const PICK_RADIUS: float = 13.0
## Outward length (m) at which a zero-length tangent's grab handle is drawn/picked, so it can be pulled
## out from a straight point. Clamped to a fraction of the adjacent segment for short loops.
const TANGENT_STUB: float = 3.0

## The brush + loop point whose tangents are currently shown (instance id, and running point index gpi).
## Updated when a point/tangent is clicked; tangents for other points stay hidden to keep loops readable.
## Overridden by the "Toggle Tangents" button (Pasture3DTerrainBrush._show_all_tangents).
var sel_node_id: int = 0
var sel_gpi: int = -1
## WHICH of the selected point's three handles was last clicked — 0 position, 1 in-tangent, 2 out. Only
## the sprite uses it: that one handle draws filled and the rest hollow, so "what am I about to drag" is
## answerable by looking. The tangents SHOWN are still decided by `sel_gpi` alone.
##
## A box-select takes several subgizmos at once and this records none of them — Godot does not tell a
## plugin which subgizmos are selected, only which one its own ray hit, so a group drag draws unfilled.
var sel_kind: int = 0


## The pick itself, split from the gizmo callback so it can be driven with a real brush and a real
## camera. `EditorNode3DGizmo` has no way to be told which node it is for, so a gate cannot build one —
## and the collapse rule below is the whole of usability tweak 3 and needs to be measurable.
func pick_handle(p_node: Node3D, p_camera: Camera3D, p_point: Vector2) -> int:
	var node := p_node
	var best := -1
	var best_d := PICK_RADIUS
	var gpi := 0
	for path in loop_paths(node):
		for i in path.curve.point_count:
			for kind in 3:
				var world: Vector3 = node.to_global(handle_display_local(node, path, i, kind))
				if not p_camera.is_position_behind(world):
					var d := p_camera.unproject_position(world).distance_to(p_point)
					if d < best_d:
						best_d = d
						best = gpi * 3 + kind
			gpi += 1
	# ---- A HIDDEN HANDLE IS NOT A TARGET ----
	#
	# The tangents of an unselected point are not drawn, but they were still PICKED, and they sit a
	# three-metre stub from the point by default — so aiming at a point and landing a few pixels off it
	# grabbed an invisible handle instead. It looked like the point had been selected (the tangents
	# appear either way) right up until the drag bent the curve.
	#
	# So a hit on a handle that is not on screen resolves to its POINT. That both selects it and reveals
	# the handles, and a SECOND click can then take one deliberately — which is the order the user is
	# actually working in: pick the point, then shape it.
	if best >= 0:
		var bgpi := best / 3
		if best % 3 != 0 and not show_tangents(node, bgpi):
			best = bgpi * 3
	_update_selected_point(node, best / 3 if best >= 0 else -1, best % 3 if best >= 0 else 0)
	return best


## Track which point's tangents to show. A hit selects that point; a miss (click in empty space) clears
## it, hiding the tangents again. Redraw only when it actually changes.
func _update_selected_point(p_node: Node3D, p_gpi: int, p_kind: int = 0) -> void:
	var id := p_node.get_instance_id()
	if p_gpi >= 0:
		if sel_node_id != id or sel_gpi != p_gpi or sel_kind != p_kind:
			sel_node_id = id
			sel_gpi = p_gpi
			sel_kind = p_kind
			p_node.update_gizmos.call_deferred()
	elif sel_node_id == id and sel_gpi != -1:
		sel_gpi = -1
		sel_kind = 0
		p_node.update_gizmos.call_deferred()


## Whether to draw point `p_gpi`'s tangent handles: only the selected point, or all when the toggle is on.
func show_tangents(p_node: Node3D, p_gpi: int) -> bool:
	if Pasture3DTerrainBrush._show_all_tangents:
		return true
	return p_node.get_instance_id() == sel_node_id and p_gpi == sel_gpi


## [Path3D, point index] of the currently-selected loop point on `p_brush`, or [null, -1]. Lets the
## plugin remove it on the Delete key (see editor_plugin.gd).
func selected_point(p_brush: Node3D) -> Array:
	if p_brush == null or sel_node_id != p_brush.get_instance_id() or sel_gpi < 0:
		return [null, -1]
	var res := resolve_handle(p_brush, sel_gpi * 3)
	return [res[0], res[1]]


## Forget the selected point (e.g. after it was deleted) so its now-stale index isn't reused.
func clear_point_selection() -> void:
	sel_gpi = -1
	sel_kind = 0


## Map a flat subgizmo id back to [child Path3D, point index, kind], in the same order _redraw drew them.
func resolve_handle(p_node: Node3D, p_id: int) -> Array:
	var gpi: int = p_id / 3
	var kind: int = p_id % 3
	var base := 0
	for path in loop_paths(p_node):
		var n: int = path.curve.point_count
		if gpi < base + n:
			return [path, gpi - base, kind]
		base += n
	return [null, -1, -1]


## Node-local position where a handle is shown/picked. Position = the point; a tangent = the point plus
## its in/out offset, or a short outward stub when that offset is ~zero (so it can be grabbed).
func handle_display_local(p_node: Node3D, p_path: Path3D, p_idx: int, p_kind: int) -> Vector3:
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


## This brush's child loops that have a curve (the editable splines), in child order.
func loop_paths(p_node: Node3D) -> Array:
	var out: Array = []
	for c in p_node.get_children():
		if c is Path3D and c.curve != null:
			out.append(c)
	return out
