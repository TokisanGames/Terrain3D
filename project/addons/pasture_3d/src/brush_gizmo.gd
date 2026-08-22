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
## Cyan-white point markers, distinct from the purple origin marker.
const POINT_COLOR := Color(0.55, 0.95, 1.0)
## World half-size of the small tangent-handle marker.
const TANGENT_R: float = 0.8
## Orange tangent handles, distinct from cyan points and purple origin.
const TANGENT_COLOR := Color(1.0, 0.66, 0.2)

# ---- Constant-size sprite markers -----------------------------------------------------------------
#
# The wireframe octahedra were a single pixel thick and vanished into a checkered terrain the moment
# more than a couple of brushes were on screen — and they said nothing about WHICH brush you were
# looking at. The origin marker is now the node's own scene-tree icon and the loop handles are the
# filled/hollow dots a vector drawing program uses, all drawn at a CONSTANT SCREEN SIZE so they read the
# same whether the camera is on the mountain or a kilometre off it.
#
# `fixed_size` on a billboarded StandardMaterial3D is what makes them screen-constant. It is used rather
# than `add_unscaled_billboard`, which is the API for exactly this, because that one draws at the gizmo
# NODE'S ORIGIN and takes no transform — fine for the one origin marker, useless for the fifty loop
# points that are the bigger half of the problem. One mechanism for both beats two.
#
# THESE THREE ARE THE SIZE KNOBS. They are in `fixed_size` units, whose mapping to pixels depends on the
# viewport height and the camera's vertical FOV, so they are tuned by looking rather than derived.

## The brush's scene-tree icon at its origin.
const ICON_SIZE: float = 0.055
## A loop control point.
const POINT_SIZE: float = 0.030
## A bezier tangent handle — smaller than a point, so the point stays the thing you aim at.
const TANGENT_SIZE: float = 0.023
## Resolution of the generated dot textures. 64 is comfortably above the pixel size they are drawn at,
## so the mipmapped edge stays clean when the camera is close enough to make them large.
const DOT_PX: int = 64

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

## Sprite materials by key, one per (shape, colour) pair actually asked for. Same lazy interning as
## `_marker_materials` and for the same reason.
var _sprite_materials: Dictionary = {}

## The two dot textures and the unit quad, generated once for the whole editor session. `static` because
## nothing about them varies per plugin instance, and a gizmo plugin is re-instantiated on every @tool
## script reload — which is often.
static var _dot_hollow: ImageTexture
static var _dot_filled: ImageTexture
static var _quad: QuadMesh
## Script resource path -> the icon path its class (or the nearest ancestor that declares one) uses.
static var _icon_paths: Dictionary = {}
## Icon path -> the loaded texture.
static var _icon_cache: Dictionary = {}


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


## The shared unit quad every sprite is an instance of. Sized 1x1 and scaled by the transform, so the
## three size constants are the only place a size is written down.
static func _quad_mesh() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	return _quad


## A dot texture: WHITE body with a BLACK rim, on transparent. Filled is a disc, unfilled a ring.
##
## The body is white so the material's albedo can tint it — cyan for a point, orange for a handle — and
## the rim is black so it survives being tinted, which is what keeps the marker readable against pale
## terrain AND against a dark sky. A single-colour dot loses one of those two.
static func _dot_texture(p_filled: bool) -> ImageTexture:
	var img := Image.create_empty(DOT_PX, DOT_PX, true, Image.FORMAT_RGBA8)
	var c := (DOT_PX - 1) * 0.5
	var r_out := DOT_PX * 0.5 - 1.0
	var rim := DOT_PX * 0.10          # black outline thickness
	var r_in := r_out - DOT_PX * 0.30 # inner edge of the ring's white band
	var aa := 1.2                     # antialias width, pixels
	for y in DOT_PX:
		for x in DOT_PX:
			var d := Vector2(x - c, y - c).length()
			var alpha: float
			var white: float
			if p_filled:
				alpha = clampf((r_out - d) / aa, 0.0, 1.0)
				white = clampf((r_out - rim - d) / aa, 0.0, 1.0)
			else:
				alpha = minf(clampf((r_out - d) / aa, 0.0, 1.0),
						clampf((d - (r_in - rim)) / aa, 0.0, 1.0))
				white = minf(clampf((r_out - rim - d) / aa, 0.0, 1.0),
						clampf((d - r_in) / aa, 0.0, 1.0))
			img.set_pixel(x, y, Color(white, white, white, alpha))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _dot(p_filled: bool) -> ImageTexture:
	if p_filled:
		if _dot_filled == null:
			_dot_filled = _dot_texture(true)
		return _dot_filled
	if _dot_hollow == null:
		_dot_hollow = _dot_texture(false)
	return _dot_hollow


## A billboarded, screen-constant, always-on-top material for one texture and tint.
##
## `no_depth_test` mirrors what the wireframes did (`create_material(..., on_top = true)`): a brush sunk
## below the surface stays findable, which on a terrain plugin is the common case rather than the odd one.
func _sprite_material(p_key: String, p_tex: Texture2D, p_color: Color) -> StandardMaterial3D:
	if _sprite_materials.has(p_key):
		return _sprite_materials[p_key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = p_tex
	m.albedo_color = p_color
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Without this the billboard code throws the model scale away and every sprite comes out the same
	# size, which would make the three size constants above do nothing at all.
	m.billboard_keep_scale = true
	m.fixed_size = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.disable_receive_shadows = true
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.render_priority = 10
	_sprite_materials[p_key] = m
	return m


## Draw one dot at `p_at` (node-local).
func _dot_sprite(p_gizmo: EditorNode3DGizmo, p_at: Vector3, p_size: float, p_color: Color,
		p_filled: bool) -> void:
	var key := "%s:%s" % ["filled" if p_filled else "hollow", p_color.to_html(false)]
	p_gizmo.add_mesh(_quad_mesh(), _sprite_material(key, _dot(p_filled), p_color),
			Transform3D(Basis().scaled(Vector3.ONE * p_size), p_at))


## The node's SCENE-TREE icon, or null for a class that declares none.
##
## Read out of the project's global class list rather than from the node, because `@icon` is not exposed
## on Script and the editor theme only knows built-in classes. Walking `base` upward is what makes every
## brush family work without a list here: `Pasture3DTerrainBrush` declares `brush_terrain.svg`, so a new
## subclass that never declares one still gets a sensible icon instead of nothing.
static func icon_for(p_node: Node3D) -> Texture2D:
	var scr: Script = p_node.get_script()
	if scr == null or scr.resource_path.is_empty():
		return null
	if _icon_paths.is_empty():
		_build_icon_paths()
	var path: String = _icon_paths.get(scr.resource_path, "")
	if path.is_empty():
		return null
	if not _icon_cache.has(path):
		_icon_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _icon_cache[path]


static func _build_icon_paths() -> void:
	var list: Array = ProjectSettings.get_global_class_list()
	var by_name := {}
	for e in list:
		by_name[String(e.get("class", ""))] = e
	for e in list:
		var path := String(e.get("path", ""))
		if path.is_empty():
			continue
		var cur: Variant = e
		var icon := ""
		# Bounded, because a malformed class list could describe a cycle and this runs in an editor.
		for _step in 32:
			if cur == null:
				break
			icon = String((cur as Dictionary).get("icon", ""))
			if not icon.is_empty():
				break
			cur = by_name.get(String((cur as Dictionary).get("base", "")))
		if not icon.is_empty():
			_icon_paths[path] = icon


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
	var icon := icon_for(node)
	if icon != null:
		# The scene-tree icon, at a constant screen size: what kind of brush this is, answerable at a
		# glance and from any distance. The wireframe octahedron it replaced was a pixel thick and told
		# you only that SOMETHING was there.
		p_gizmo.add_mesh(_quad_mesh(), _sprite_material("icon:" + icon.resource_path, icon, Color.WHITE),
				Transform3D(Basis().scaled(Vector3.ONE * ICON_SIZE), centre))
	else:
		# A class that declares no icon anywhere up its chain keeps the old marker rather than nothing.
		var mat: Material = _marker_material(p_gizmo,
				node._gizmo_color() if node.has_method("_gizmo_color") else MARKER_COLOR)
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
		var gmat := get_material("tangents", p_gizmo)
		var is_sel_node := node.get_instance_id() == _h.sel_node_id
		var gpi := 0
		for path in _h.loop_paths(node):
			for i in path.curve.point_count:
				var c := node.to_local(path.to_global(path.curve.get_point_position(i)))
				_dot_sprite(p_gizmo, c, POINT_SIZE, POINT_COLOR,
						is_sel_node and gpi == _h.sel_gpi and _h.sel_kind == 0)
				# Tangents only for the selected point (or all, when the toggle is on) — declutter.
				if _h.show_tangents(node, gpi):
					for kind in [1, 2]:
						var hc := _h.handle_display_local(node, path, i, kind)
						# The stem stays a line: it is what says which point a handle belongs to, and
						# two dots with nothing between them do not say it.
						p_gizmo.add_lines(PackedVector3Array([c, hc]), gmat)
						_dot_sprite(p_gizmo, hc, TANGENT_SIZE, TANGENT_COLOR,
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
