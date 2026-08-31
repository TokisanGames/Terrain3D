# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DJunctionGizmo — draws every resolved junction on a Pasture3DRoadNetwork: the footprint disc,
# each approach's trimmed end, and which road has right of way.
#
# ---- THIS IS THE MESH'S STAND-IN, AND THAT IS DELIBERATE (§11) ----
#
# P4a resolves junction geometry and P5 builds the ribbon mesh, so between the two there is nothing in
# the viewport that shows whether a junction is right. The inspector shows numbers — a centre, a radius,
# an array of trim-backs — and reading those against two splines by eye is exactly the kind of check that
# does not get done. So the numbers are drawn where the roads are.
#
# It draws what a MESHER would need and no more: the footprint it has to fill, the ends it has to meet,
# and the road whose profile it must not break. When P5 lands, a junction that meshes badly can be
# compared against this rather than against the inspector.
#
# Editor-only; registered by editor_plugin.gd.
@tool
extends EditorNode3DGizmoPlugin

## Metres the drawing floats above the junction's solved elevation, so it reads over the graded road
## surface instead of z-fighting with it.
const LIFT: float = 0.35
## Segments in the footprint circle. Enough that a 30 m junction does not look like a stop sign.
const CIRCLE_SEGMENTS: int = 48
## Half-length of the cross drawn at each approach's trimmed end, metres.
const TICK: float = 2.0

## Cyan for a live junction — no other Pasture3D gizmo uses it, so a junction is never mistaken for a
## brush marker (purple), a pool (orange) or a spline handle.
const LIVE := Color(0.2, 0.9, 1.0)
## The major road's spoke, drawn in white: the one road that keeps its own profile through here, and the
## first thing to check when a junction looks wrong.
const MAJOR := Color(1.0, 1.0, 1.0)
## A junction the author disabled. Still drawn — it is a decision, not an absence, and a disabled
## junction that the author has forgotten about is exactly what a grey ring is for.
const DISABLED := Color(0.55, 0.55, 0.55)
## A record kept for its overrides after the roads stopped crossing. Drawn where it last was.
const UNDETECTED := Color(0.9, 0.35, 0.3)

## Lane connectors. Green for a path that goes straight through or turns without conflict.
const CONNECTOR := Color(0.35, 0.95, 0.45)
## A turn that crosses the oncoming carriageway. Amber, because it is the one a consumer has to yield
## on, and because seeing at a glance which turns are conflicted is how you check `traffic_side` is set
## the way the world actually drives.
const CONFLICT := Color(1.0, 0.7, 0.15)
## Conflict points closer together than this share one cross, metres. About half a lane: two movements
## that meet within that distance are meeting at the same place as far as a reader is concerned.
const MARK_MERGE: float = 1.5
## A turn the author forbade. Drawn, unlike the connectors that were never generated: a banned turn is a
## decision, and one you cannot see is one you cannot find again.
const FORBIDDEN := Color(0.5, 0.3, 0.3)
## Stop lines.
const STOP := Color(1.0, 0.25, 0.25)

## Points sampled along each connector curve when drawing it.
const CONNECTOR_STEPS: int = 12

var _mat: Dictionary = {}


func _get_gizmo_name() -> String:
	return "Pasture3D Road Junction"


func _has_gizmo(p_node: Node3D) -> bool:
	# Duck-typed via the group rather than `is Pasture3DRoadNetwork`: this file is preloaded by the
	# editor plugin at startup, and a class_name reference here would be a parse-time dependency on the
	# whole road stack.
	return p_node != null and p_node.is_in_group(&"pasture3d_road_network")


func _redraw(p_gizmo: EditorNode3DGizmo) -> void:
	p_gizmo.clear()
	var net := p_gizmo.get_node_3d()
	if net == null or not net.is_inside_tree():
		return
	var junctions: Array = net.get("junctions")
	if junctions == null or junctions.is_empty():
		return

	# World → network-local once. The gizmo draws in the node's space, and every number a junction
	# carries is in world metres.
	var to_local := net.global_transform.affine_inverse()

	# Approaches are looked up by road key, which is what the junction stores. Built once per redraw
	# rather than per junction: a network with twenty roads and twenty junctions would otherwise walk
	# the scene four hundred times.
	var by_key := {}
	for b in net.call("road_brushes"):
		by_key[b.call("road_key")] = b

	for j in junctions:
		if j == null:
			continue
		var colour := LIVE
		if not j.detected:
			colour = UNDETECTED
		elif j.disabled:
			colour = DISABLED
		var centre: Vector3 = to_local * Vector3(j.center.x, j.elevation + LIFT, j.center.y)
		p_gizmo.add_lines(_circle(centre, j.effective_radius()), _material_for(colour))

		# One spoke per participant, out to where that road's grading actually stops. A spoke that does
		# not reach the ring, or overshoots it, is the trim-back being wrong — which is the failure this
		# gizmo exists to make visible.
		for i in j.road_keys.size():
			var key: String = j.road_keys[i]
			var brush = by_key.get(key, null)
			if brush == null:
				continue
			var s: float = j.arc_length_for(key)
			var trim: float = j.trim_back_for(key)
			if not is_finite(s):
				continue
			var spoke := colour
			if j.detected and not j.disabled and j.is_major(key):
				spoke = MAJOR
			var mat := _material_for(spoke)
			# Both ends: a road crosses the junction, so it is trimmed on the way in AND on the way out.
			for sign_i in [-1.0, 1.0]:
				var at: Vector2 = brush.call("point_at_arc", s + trim * sign_i)
				var end: Vector3 = to_local * Vector3(at.x, j.elevation + LIFT, at.y)
				var line := PackedVector3Array([centre, end])
				line.append_array(_cross(end))
				p_gizmo.add_lines(line, mat)

		if not j.detected or j.disabled:
			continue
		# The lane graph. Drawn after the arms so it reads on top of them, and only for a live junction:
		# the connectors of a disabled junction are kept but are not paths anything may take.
		for c in j.connectors:
			if c == null or c.curve == null or c.curve.point_count < 2:
				continue
			var c_colour := CONNECTOR
			if not c.allowed():
				c_colour = FORBIDDEN
			elif c.crosses_oncoming:
				c_colour = CONFLICT
			p_gizmo.add_lines(_curve_lines(c.curve, to_local), _material_for(c_colour))
		# Where two movements actually meet. Small crosses in the conflict colour: a junction whose
		# conflict points are not in its footprint, or which has none at all, is the right-of-way solver
		# failing in a way no amount of staring at the connectors would show.
		#
		# DEDUPLICATED BY POSITION, and that is a drawing decision rather than a data one. The records
		# are per ORDERED PAIR of movements, so an ordinary crossroads produces dozens, many of them
		# within centimetres of each other — every pair crossing the middle meets in roughly the same
		# place. Drawn one for one they overlap into a solid blob that shows neither where the conflicts
		# are nor how many there are. One cross per distinct place answers the question the gizmo is
		# actually asked: is the right-of-way solver finding meetings inside the footprint.
		var marks := PackedVector3Array()
		var placed := {}
		for r in j.conflicts:
			if r == null:
				continue
			# Snapped to a grid rather than compared pairwise: the count is quadratic in the connectors
			# and this runs on every gizmo redraw.
			var cell := Vector3i(roundi(r.point.x / MARK_MERGE), roundi(r.point.y / MARK_MERGE),
					roundi(r.point.z / MARK_MERGE))
			if placed.has(cell):
				continue
			placed[cell] = true
			marks.append_array(_cross(to_local * (r.point + Vector3(0.0, LIFT, 0.0))))
		if not marks.is_empty():
			p_gizmo.add_lines(marks, _material_for(CONFLICT))
		for sl in j.stop_lines:
			if sl == null:
				continue
			var ends: Array = sl.endpoints()
			p_gizmo.add_lines(PackedVector3Array([
					to_local * (ends[0] + Vector3(0.0, LIFT, 0.0)),
					to_local * (ends[1] + Vector3(0.0, LIFT, 0.0))]), _material_for(STOP))


## A horizontal circle of `p_r` metres about `p_centre`, as line pairs.
func _circle(p_centre: Vector3, p_r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var r := maxf(p_r, 0.25)
	var prev := p_centre + Vector3(r, 0.0, 0.0)
	for i in range(1, CIRCLE_SEGMENTS + 1):
		var a := TAU * float(i) / float(CIRCLE_SEGMENTS)
		var p := p_centre + Vector3(cos(a) * r, 0.0, sin(a) * r)
		out.append(prev)
		out.append(p)
		prev = p
	return out


## A curve as a polyline in the network's local space, lifted clear of the road surface.
func _curve_lines(p_curve: Curve3D, p_to_local: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var length := p_curve.get_baked_length()
	var lift := Vector3(0.0, LIFT, 0.0)
	var prev: Vector3 = p_to_local * (p_curve.sample_baked(0.0) + lift)
	for i in range(1, CONNECTOR_STEPS + 1):
		var p: Vector3 = p_to_local * (p_curve.sample_baked(length * float(i) / float(CONNECTOR_STEPS)) + lift)
		out.append(prev)
		out.append(p)
		prev = p
	return out


## A small horizontal cross at `p_at`, marking one trimmed end.
func _cross(p_at: Vector3) -> PackedVector3Array:
	return PackedVector3Array([
		p_at - Vector3(TICK, 0.0, 0.0), p_at + Vector3(TICK, 0.0, 0.0),
		p_at - Vector3(0.0, 0.0, TICK), p_at + Vector3(0.0, 0.0, TICK),
	])


## One unshaded, always-visible material per colour.
##
## Built by hand rather than through create_material(), for the reason the pool marker documents: every
## UNSELECTED variant create_material() hands back has its alpha multiplied by 0.3, and a junction is
## most worth looking at while the ROAD is selected — which is never when the network is.
func _material_for(p_colour: Color) -> StandardMaterial3D:
	var key := p_colour.to_html(false)
	if _mat.has(key):
		return _mat[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = p_colour
	m.disable_fog = true
	# Depth-tested, unlike the brush and pool markers: those are handles that must be findable through
	# terrain, this is a drawing of something lying ON the ground and should be hidden by a hill in
	# front of it. A junction floating through a mountainside would be the wrong answer.
	m.no_depth_test = false
	m.render_priority = 50
	_mat[key] = m
	return m
