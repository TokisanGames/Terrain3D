# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPoolGizmo — a clickable marker floating above every Pasture3DPool, so a designer can select
# a body of water the same way they select a brush.
#
# A pool is the hardest node in the scene to click. Its only visible geometry is the water surface,
# which is a MeshInstance3D held as an INTERNAL child (never saved, hidden from the Scene dock), so
# clicking the water hits nothing selectable; the node's own origin is a point in space with no
# gizmo; and it sits at the bottom of a basin among the brushes that carved it. This draws the same
# octahedron marker the brushes use — in ORANGE rather than purple, because a pool is not a brush and
# the two frequently sit at the same XZ — with a collision box so clicking it selects the pool.
#
# Editor-only; registered by editor_plugin.gd. Marker-only by design: the loop belongs to the brush,
# and giving a pool its own point handles would mean two gizmos editing one curve.
@tool
extends EditorNode3DGizmoPlugin

## The brush gizmo owns the fallback marker shape, so the two are literally the same octahedron and
## cannot drift apart visually.
const BrushGizmo: Script = preload("res://addons/pasture_3d/src/brush_gizmo.gd")
## The shared sprite machinery. A water body is not a brush and never will be — its loop belongs to the
## brush that carved it — but "this node's icon, legible from any distance" is the same problem, and it
## is answered in one place rather than two.
const Sprites: Script = preload("res://addons/pasture_3d/src/gizmo_sprites.gd")

## World half-size of the marker (and its click box). Matches the brush marker.
const MARKER_R: float = 4.0
## Metres the marker floats above the water surface, so it is clear of the plane rather than
## z-fighting with it. Larger than the brush's lift: a pool marker frequently shares its XZ with the
## marker of the brush that carved it, and the water is below the terrain in a basin, so this
## separates the two rather than stacking them.
const SURFACE_LIFT: float = 6.0
## Orange — distinct from the brushes' purple at a glance, and it reads against both water and
## terrain. Shares a hue family with the brush gizmo's tangent handles, which are never on screen at
## the same time as a pool marker (tangents show only while a BRUSH is selected).
const MARKER_COLOR := Color(1.0, 0.55, 0.1)

## Built by hand rather than through create_material(), and that is what makes the handle visible
## when the pool is NOT selected.
##
## EditorNode3DGizmoPlugin.create_material() stores four variants and get_material() hands back a
## different one depending on the gizmo's selected/editable state — and every UNSELECTED variant has
## its alpha multiplied by 0.3. That is the right default for a gizmo decorating a node you have
## already found. It is the wrong one for a handle whose entire purpose is to be findable, and at 30%
## alpha over a bright water surface it is not there at all. One material, full alpha, always.
var _marker_material: StandardMaterial3D
## Same orange, dimmed and depth-tested: the volume outline is context for the handle, not a second
## thing competing with it, and it SHOULD be occluded by terrain so the box reads as being in the
## ground rather than floating over it.
var _volume_material: StandardMaterial3D


func _init() -> void:
	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.albedo_color = MARKER_COLOR
	_marker_material.disable_fog = true
	# no_depth_test, like the brush marker: a pool sunk in a basin stays findable from above the rim,
	# and the water surface it floats over is itself transparent geometry.
	_marker_material.no_depth_test = true
	# Transparent surfaces are depth-sorted against each other, and the water is transparent too.
	# Priority is the tie-break that keeps the handle in front of its own pool rather than inside it.
	_marker_material.render_priority = 100

	_volume_material = StandardMaterial3D.new()
	_volume_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_volume_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_volume_material.albedo_color = Color(MARKER_COLOR.r, MARKER_COLOR.g, MARKER_COLOR.b, 0.35)
	_volume_material.disable_fog = true


func _get_gizmo_name() -> String:
	return "Pasture3D Pool"


func _has_gizmo(p_node: Node3D) -> bool:
	# Duck-typed rather than `is Pasture3DPool`: a class_name reference here is a parse-time
	# dependency, and this file is loaded by the editor plugin at startup.
	return p_node != null and p_node.is_in_group(&"pasture3d_pool")


func _redraw(p_gizmo: EditorNode3DGizmo) -> void:
	p_gizmo.clear()
	var node := p_gizmo.get_node_3d()
	# A node mid-removal (undoing an Add Water press detaches the pool) is briefly still
	# gizmo-tracked but out of the tree; global_transform reads would spam "!is_inside_tree()".
	if node == null or not node.is_inside_tree():
		return

	var centre := _marker_centre(node)
	# The node's own sprite — a pool reads as a level sheet of water, a stream as a meander — tinted
	# with the orange that has always told a water body apart from a brush. Grayscale art, so the tint
	# is the whole of the colour; see icons/gizmo/_style.txt.
	var sprite: Texture2D = Sprites.sprite_for(node)
	if sprite != null:
		p_gizmo.add_mesh(Sprites._quad_mesh(),
				Sprites._sprite_material("sprite:%s:%s" % [sprite.resource_name,
						MARKER_COLOR.to_html(false)], sprite, MARKER_COLOR),
				Transform3D(Basis().scaled(Vector3.ONE * Sprites.ICON_SIZE), centre))
	else:
		p_gizmo.add_lines(BrushGizmo.octa(centre, MARKER_R), _marker_material)
	# A solid box of collision triangles makes the marker pickable from any angle, which is what
	# turns it from decoration into a selection handle. add_collision_triangles takes no transform,
	# so the vertices are moved to the marker rather than the mesh being placed.
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

	# The underwater volume's extent, while the pool is selected (spec §8.4). In a running game the
	# effect is what you see; in the editor the box is invisible, and "how deep does this water
	# claim to be" is otherwise unanswerable without reading the inspector and doing the arithmetic.
	# Selected only — every pool in a scene outlining its box would be a cage.
	if node in EditorInterface.get_selection().get_selected_nodes():
		var vol := _volume_of(node)
		if vol != null and vol.shape is BoxShape3D:
			var box_size: Vector3 = (vol.shape as BoxShape3D).size
			p_gizmo.add_lines(_box_lines(vol.position, box_size * 0.5), _volume_material)


## Marker centre in node-local space: above the middle of the WATER, not above the node's origin.
##
## Those are usually close — Add Water seats a pool on its spline's origin — but a loop drawn well
## off its brush's centre would otherwise put the handle in the grass beside the lake. The surface
## mesh's AABB centre is where the water actually is, so the handle is always findable by looking at
## the water. Falls back to the node origin when there is no mesh yet (an unbuilt or misconfigured
## pool still needs to be selectable, which is when you most want to click it).
func _marker_centre(p_node: Node3D) -> Vector3:
	var local := Vector3.ZERO
	var surface := _surface_of(p_node)
	if surface != null and surface.mesh != null:
		var aabb: AABB = surface.mesh.get_aabb()
		local = aabb.get_center()
	# The water plane is the node's Y, and the mesh is flat, so only XZ is taken from the AABB.
	return Vector3(local.x, SURFACE_LIFT, local.z)


## The pool's internal surface MeshInstance3D. It is added with add_child (not INTERNAL_MODE) but is
## never given an owner, so it is a normal child at runtime and simply absent from saved scenes.
func _surface_of(p_node: Node3D) -> MeshInstance3D:
	for c in p_node.get_children():
		if c is MeshInstance3D:
			return c
	return null


## The pool's underwater volume shape, or null when underwater_enabled is off.
func _volume_of(p_node: Node3D) -> CollisionShape3D:
	for c in p_node.get_children():
		if c is Area3D:
			for cc in c.get_children():
				if cc is CollisionShape3D:
					return cc
	return null


## The 12 edges of a box, as line pairs. `p_half` is the half-extent; `p_centre` is node-local.
func _box_lines(p_centre: Vector3, p_half: Vector3) -> PackedVector3Array:
	var c := PackedVector3Array()
	for i in 8:
		c.append(p_centre + Vector3(
			p_half.x if (i & 1) else -p_half.x,
			p_half.y if (i & 2) else -p_half.y,
			p_half.z if (i & 4) else -p_half.z))
	var out := PackedVector3Array()
	# Every pair of corners differing in exactly one bit is an edge — 12 of them, no table needed.
	for i in 8:
		for bit in [1, 2, 4]:
			var j: int = i | bit
			if j != i:
				out.append(c[i])
				out.append(c[j])
	return out
