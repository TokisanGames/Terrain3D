# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadChunkHost — the node side of TIER MID (§10). Owns one road's ribbon chunks, swaps their
# LOD by distance, and hides them entirely once tier FAR is enough.
#
# ---- WHY HIDING IS THE INTERESTING PART ----
#
# The road is painted into the terrain already (P5a), so beyond `far_distance` this host has nothing to
# add: it hides its chunks and the road is still there, still the right shape, still the right surface,
# because it IS the terrain. That is the one transition in the whole LOD chain with nothing to pop —
# and it only works in that direction. A system whose farthest tier were "a coarser mesh" would have to
# fade something out over something else; this one just stops drawing.
#
# ---- A HOST, NOT A MESHER ----
#
# Every number comes from Pasture3DRoadMesher, which is a pure kernel and is where the gate looks. This
# file allocates resources, parents nodes and reads a camera — the parts that need a scene tree and
# therefore cannot be gated headlessly. Keeping the split sharp is what lets the seam contract be
# checked at all.
#
# ---- LOD IS A MESH SWAP, NEVER A REBUILD ----
#
# §10's design-to note: a chunk carries all its LOD meshes as one resource, built once at bake. Choosing
# a tier is then an assignment, which is why `_process` can afford to run every frame and why a fast car
# crossing three LOD bands does not stall.
@tool
class_name Pasture3DRoadChunkHost
extends Node3D

## Distance in metres at which each LOD takes over. Beyond the last, the chunk is hidden and the painted
## terrain is the road. Ascending; the count need not match LOD_LEVELS.
@export var lod_distances: PackedFloat32Array = PackedFloat32Array([60.0, 140.0, 300.0]):
	set(v):
		lod_distances = v
		_dirty_lod = true

## Beyond this, no ribbon at all — tier FAR carries the road. 0 disables hiding, which is for looking at
## the mesh rather than for shipping.
@export var far_distance: float = 600.0:
	set(v):
		far_distance = v
		_dirty_lod = true

## Dead band on every threshold, metres. A tier or a hide only changes once the distance is this far
## PAST the line, so a camera parked on a threshold does not flip the mesh every frame.
##
## Needed because the thresholds are hard comparisons over a distance that jitters: an orbiting or
## hand-held camera crosses a line dozens of times a second, and each crossing is a mesh swap. The
## symptom is a ribbon that flickers, which reads as the chunks failing to build rather than as the
## comparison being exact.
@export var lod_hysteresis: float = 12.0

## Metres the ribbon rides above the graded ground. Exposed for tuning on unusual terrain scales, not
## for turning off — see Pasture3DRoadMesher.DEPTH_LIFT for why coplanar is not an option.
@export var depth_lift: float = Pasture3DRoadMesher.DEPTH_LIFT

## Give each chunk a collider on the carriageway.
##
## ---- WHAT THIS IS AND IS NOT FOR ----
##
## NOT the driving surface. The road went through the HEIGHTMAP (P2), so the terrain's own collision
## already is the road: a vehicle is supported by the graded ground whether this is on or off, and
## turning it on adds nothing to hold the car up. What it adds is IDENTITY — a raycast that answers "am
## I on tarmac or on grass", on its own physics layer, without sampling the control map and decoding a
## texture id. Off by default, because a road that does not need the question asked should not pay for
## the shapes.
@export var collision_enabled: bool = false

## Physics layer and mask for those colliders. Layer 2 by default so a road query cannot be confused
## with a terrain query, and mask 0 because these shapes answer questions — nothing needs to collide
## WITH them.
@export_flags_3d_physics var collision_layer: int = 2
@export_flags_3d_physics var collision_mask: int = 0

## Draw lane markings on the carriageway (§10, P5c).
@export var markings_enabled: bool = true

## Material for the painted stripes. Left null, markings are built and drawn untextured — visible, but
## not white, which reads as a bug rather than as a missing material.
@export var markings_material: Material = null

## Place the road type's verge props through the terrain's instancer (§10, P5c).
@export var props_enabled: bool = true

## Chunks, each `{node: MeshInstance3D, centre: Vector3, meshes: Array[ArrayMesh], lod: int}`.
var _chunks: Array = []
var _dirty_lod: bool = true
var _report: bool = false
var _hidden: int = 0
var _nearest: float = INF

## Shapes built by the last rebuild.
##
## Counted and REPORTED because a road collider is otherwise invisible: these hosts are not owned by the
## edited scene, so Godot draws no CollisionShape3D gizmo for them and the viewport looks exactly the
## same whether the shapes exist or not. Turning the setting on and seeing nothing change is the whole
## problem — so the host says the number out loud, and Debug > Visible Collision Shapes shows them when
## the game runs.
var _colliders: int = 0
var _last_digest: String = ""
var last_rebuilt: bool = false

## Cached pick geometry for the editor gizmo. See `pick_meshes`.
var _pick_meshes: Array[TriangleMesh] = []
var _pick_digest: String = ""


func _ready() -> void:
	set_process(true)


## Rebuild every chunk for `p_brush`. Called at the end of a bake, from the network, so the whole
## network re-chunks in one pass and in a defined order.
##
## Returns the number of chunks built. Zero is the normal answer for a road with no alignment yet or no
## surface material, not an error.
func rebuild(p_brush: Pasture3DRoadBrush) -> int:
	if p_brush == null:
		_clear()
		_last_digest = ""
		last_rebuilt = false
		return 0
	var run := p_brush.build_run()
	if run.is_empty():
		_clear()
		_last_digest = ""
		last_rebuilt = false
		_why(p_brush, "the road has no solved alignment yet (build_run is empty)")
		return 0
	var t: Pasture3DRoadType = p_brush.resolved_road_type()
	if t == null:
		_clear()
		_last_digest = ""
		last_rebuilt = false
		_why(p_brush, "the road has no road type")
		return 0

	# ---- WHAT THE SKIP DIGEST OWES, AND WHY IT IS A LIST OF VALUES ----
	#
	# This used to identify the road type by `str(t.get_instance_id())`. An instance id does not change
	# when the resource's PROPERTIES change, and nothing else here covered the cross-section either —
	# `alignment_digest()` hashes plan points, ds, drape, max_grade, design_speed and pins, which is every
	# input to the VERTICAL solve and none to the cross-section. So the digest was stable across exactly
	# the edits that change the mesh: lane_count, lane_width, shoulder_width, crown, surface_material. The
	# terrain re-graded to the new carriageway and the ribbon kept the old width until something unrelated
	# perturbed the alignment.
	#
	# It names the mesher's inputs one at a time, rather than hashing every exported property of the road
	# type, and that is the point rather than an economy. A generic hash would also churn on properties
	# the ribbon never reads — max_grade, the physics surface_id — forcing a full mesh rebuild on every
	# vertical-only edit, which is the cost this cache exists to avoid. Listing them means adding an input
	# to the mesher is a change that visibly has to be made here too.
	#
	# `_region_metres` rather than `terrain.region_size`: chunk_spans cuts on region boundaries, and the
	# boundary it actually cuts on is region_size * vertex_spacing, so the metres are the mesh input and
	# the region count alone would miss a vertex_spacing change.
	var digest := "%s|%s|%.4f|%s|%s|%s|%.4f|%.4f|%.4f|%.4f|%s" % [
		p_brush.alignment_digest(),
		p_brush.junction_digest(),
		depth_lift,
		str(collision_enabled),
		str(markings_enabled),
		str(props_enabled),
		t.half_width(p_brush.resolved_lane_count()),
		t.shoulder_width,
		t.crown,
		_region_metres(p_brush),
		str(t.surface_material.get_instance_id()) if t.surface_material != null else "",
	]
	if not _chunks.is_empty() and _last_digest == digest:
		last_rebuilt = false
		return _chunks.size()

	_clear()
	_last_digest = digest
	last_rebuilt = true
	var plan: PackedVector2Array = run["plan"]
	var cum: PackedFloat32Array = run["cum"]
	var alignment: Pasture3DRoadAlignment = run["alignment"]
	var half: float = run["half_width"]
	var shoulder: float = t.shoulder_width
	var crown: float = t.crown

	var region := _region_metres(p_brush)
	var skips := p_brush.junction_skips()
	var spans := Pasture3DRoadMesher.chunk_spans(plan, cum, region, skips)
	if spans.is_empty():
		_why(p_brush, "no spans left: %.1f m of road, %.0f m regions, %d junction footprint(s)"
				% [cum[cum.size() - 1] if cum.size() > 0 else 0.0, region, skips.size()])
		return 0
	var rejected := 0
	var prop_transforms: Array = []
	for span in spans:
		var meshes: Array = []
		var empty := false
		for lod in Pasture3DRoadMesher.LOD_LEVELS:
			var arrays := Pasture3DRoadMesher.build_chunk(plan, cum, alignment, float(span[0]),
					float(span[1]), half, shoulder, crown, lod, depth_lift)
			if arrays.is_empty():
				empty = true
				break
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			if t.surface_material != null:
				mesh.surface_set_material(0, t.surface_material)
			meshes.append(mesh)
		if empty:
			rejected += 1
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Chunk_%.0f" % float(span[0])
		mi.mesh = meshes[0]
		# The ribbon is authored in WORLD space by the mesher, so the host must not add a transform of
		# its own on top of it. A host that inherited the brush's transform would move the mesh and leave
		# the graded ground where it was.
		mi.top_level = true
		add_child(mi)
		if collision_enabled:
			_add_collider(mi, plan, cum, alignment, float(span[0]), float(span[1]), half, shoulder, crown)
		if markings_enabled:
			_add_markings(mi, p_brush, plan, cum, alignment, float(span[0]), float(span[1]), crown)
		if props_enabled:
			prop_transforms.append_array(_prop_transforms(t, plan, cum, alignment, float(span[0]),
					float(span[1]), crown))
		var mid := (float(span[0]) + float(span[1])) * 0.5
		var at := Pasture3DRoadGrader.plan_point_at(plan, cum, mid)
		_chunks.append({
			"node": mi,
			"centre": Vector3(at.x, alignment.height_at(mid), at.y),
			# The chunk's own extent, which is what distance is measured to. See `_distance_to`.
			"bounds": (meshes[0] as ArrayMesh).get_aabb(),
			"meshes": meshes,
			"lod": 0,
		})
	# Called even when props are OFF, with nothing to place: it clears the instancer by mesh id first, so
	# switching props off removes the ones already out there. Skipping the call entirely would leave a
	# verge full of props that no longer has a setting saying they should be there.
	_place_props(p_brush, t, prop_transforms if props_enabled else [])
	_dirty_lod = true
	_report = true
	if _chunks.is_empty():
		_why(p_brush, "%d span(s) were found but every one failed to mesh" % rejected)
	return _chunks.size()


## One chunk's collider, as a child of the chunk so it is culled, hidden and freed with it.
##
## Built at lift ZERO, and that is the whole subtlety: the ribbon is lifted DEPTH_LIFT above the ground
## so it cannot z-fight with the surface it was graded into, but a COLLIDER lifted by the same amount is
## a road that sits two centimetres above itself. A wheel rests on it early, a raycast looking for the
## ground hits the road before the terrain, and "on the road" and "on the ground" stop being the same
## height. The lift is a rendering fix; collision has no z-fighting to fix.
##
## LOD 0 only. A collider that changed shape with camera distance would move the ground under a car
## parked at the edge of a threshold.
func _add_collider(p_parent: Node3D, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_half: float,
		p_shoulder: float, p_crown: float) -> void:
	var arrays := Pasture3DRoadMesher.build_chunk(p_plan, p_cum, p_alignment, p_from, p_to, p_half,
			p_shoulder, p_crown, 0, 0.0)
	if arrays.is_empty():
		return
	_collider_from(p_parent, arrays)


## A trimesh body over one surface's triangles, on the road physics layer.
##
## Takes ARRAYS rather than building its own, so the apron and the ribbon get colliders from the same
## code and cannot disagree about the layer, the shape type or the winding.
func _collider_from(p_parent: Node3D, p_arrays: Array) -> void:
	var faces := PackedVector3Array()
	var verts: PackedVector3Array = p_arrays[Mesh.ARRAY_VERTEX]
	for i: int in p_arrays[Mesh.ARRAY_INDEX]:
		faces.append(verts[i])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = "Collision"
	_colliders += 1
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	p_parent.add_child(body)


## One chunk's lane markings, as a child of the chunk for the same reason the collider is.
##
## The stripe plan is resolved at the START of the span rather than once per road: `resolved_lanes` and
## `resolved_one_way` both take a distance, so a road that gains a lane part way along gains a lane line
## there too. Resolving once for the whole road would draw the first chunk's cross-section over all of it.
func _add_markings(p_parent: Node3D, p_brush: Pasture3DRoadBrush, p_plan: PackedVector2Array,
		p_cum: PackedFloat32Array, p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float,
		p_crown: float) -> void:
	var t: Pasture3DRoadType = p_brush.resolved_road_type()
	if t == null:
		return
	var stripes := Pasture3DRoadMarkings.plan(p_brush.resolved_lanes(p_from), t.divider_type,
			p_brush.resolved_one_way(p_from))
	var arrays := Pasture3DRoadMarkings.build(p_plan, p_cum, p_alignment, stripes, p_from, p_to,
			p_crown, 2.0, depth_lift)
	if arrays.is_empty():
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if markings_material != null:
		mesh.surface_set_material(0, markings_material)
	var mi := MeshInstance3D.new()
	mi.name = "Markings"
	mi.mesh = mesh
	p_parent.add_child(mi)


## The transforms for one span's verge props. Nothing is placed here — they are accumulated across the
## whole road and handed over in one call, because the instancer is cleared per mesh id and a per-span
## hand-off would leave only the last span's props standing.
func _prop_transforms(p_type: Pasture3DRoadType, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_crown: float) -> Array:
	if p_type == null or p_type.prop_mesh_id < 0:
		return []
	if p_type.prop_both_sides:
		return Pasture3DRoadProps.place_both(p_plan, p_cum, p_alignment, p_from, p_to,
				p_type.prop_offset, p_type.prop_spacing, p_crown)
	return Pasture3DRoadProps.place(p_plan, p_cum, p_alignment, p_from, p_to, p_type.prop_offset,
			p_type.prop_spacing, p_crown)


## Hand the road's props to the terrain's instancer, which keys multimeshes by region location — so road
## props stream with terrain regions and need no streaming code of their own (§10).
##
## Cleared by mesh id before placing, for the reason the paint pass clears before painting: nothing else
## removes them, so moving a road would leave its old guardrail standing in a field. The cost is that a
## road sharing a mesh id with another road clears that road's props too — which is why the clear is
## here, once per rebuild, rather than per span.
func _place_props(p_brush: Pasture3DRoadBrush, p_type: Pasture3DRoadType, p_transforms: Array) -> void:
	if p_type == null or p_type.prop_mesh_id < 0 or p_brush == null or p_brush.terrain == null:
		return
	var inst = p_brush.terrain.get_instancer()
	if inst == null:
		return
	inst.clear_by_mesh(p_type.prop_mesh_id)
	if p_transforms.is_empty():
		return
	inst.add_transforms(p_type.prop_mesh_id, p_transforms, PackedColorArray(), true)


## Build one apron per junction. `p_aprons` is prepared by the network, each entry
## `{center, radius, plan, cum, alignment, crown, material}` — the host does no lookups of its own.
##
## Hosted here rather than on a road's own host because a junction belongs to no single road: it is where
## several stop being separate. Put on the network's host, it is rebuilt once per resolve instead of once
## per participant, and there is no question of which road owns it.
##
## Each apron carries one mesh repeated across the LOD slots. A disc of two dozen triangles has nothing
## worth decimating, and sharing the resource costs nothing — what it buys is that aprons go through the
## same distance culling and the same far-hide as everything else, with no second code path.
func rebuild_aprons(p_aprons: Array, p_lift: float = Pasture3DRoadMesher.DEPTH_LIFT) -> int:
	_clear()
	depth_lift = p_lift
	for a: Dictionary in p_aprons:
		var arrays := Pasture3DRoadMesher.build_apron(a["center"], float(a["radius"]), a["plan"],
				a["cum"], a["alignment"], float(a["crown"]), 24, p_lift)
		if arrays.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: Material = a.get("material")
		if mat != null:
			mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = "Junction_%s" % str(a.get("id", "?"))
		mi.mesh = mesh
		mi.top_level = true
		add_child(mi)
		if collision_enabled:
			# Rebuilt at lift ZERO, like the ribbon's (see `_add_collider`), and NOT reused from the mesh
			# above — that one carries the render lift. Without this the road has a hole in its collision
			# at every junction: a raycast asking "am I on tarmac" answers yes along the road and no in the
			# middle of the crossroads, which is exactly where a vehicle most needs the answer.
			var solid := Pasture3DRoadMesher.build_apron(a["center"], float(a["radius"]), a["plan"],
					a["cum"], a["alignment"], float(a["crown"]), 24, 0.0)
			if not solid.is_empty():
				_collider_from(mi, solid)
		var meshes: Array = []
		for _lod in Pasture3DRoadMesher.LOD_LEVELS:
			meshes.append(mesh)
		var c: Vector2 = a["center"]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		_chunks.append({
			"node": mi,
			"centre": Vector3(c.x, verts[0].y, c.y),
			"bounds": mesh.get_aabb(),
			"meshes": meshes,
			"lod": 0,
		})
	_dirty_lod = true
	_report = true
	return _chunks.size()


## World metres across one terrain region — the unit chunk cuts snap to, so a chunk's lifetime matches
## the region it sits in.
func _region_metres(p_brush: Pasture3DRoadBrush) -> float:
	var terrain: Variant = p_brush.terrain
	if terrain == null:
		return 0.0
	return maxf(float(terrain.region_size) * terrain.vertex_spacing, 1.0)


## Drop the previous build.
##
## `remove_child` FIRST and `queue_free` after, rather than `queue_free` alone. A queued node is still a
## child, still drawn and still colliding until the frame ends, so a rebuild that only queues leaves the
## old ribbon and the old shapes overlapping the new ones for a frame — visible as z-fighting on a
## road that just rebuilt, and as a doubled collider to anything raycasting in between. It also means a
## caller cannot look at the tree and see what it just built, which is how a criterion asserting that
## turning collision OFF removes the shapes ended up reading the shapes that were on their way out.
func _clear() -> void:
	for c in _chunks:
		var n: Node = c["node"]
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	_chunks.clear()
	_colliders = 0


## Pick each chunk's tier from its distance to the camera, and hide it once tier FAR is enough.
##
## Distance is to the chunk's NEAREST POINT, not to its centre — see `_distance_to`, which is where the
## reasoning lives, because measuring to the centre broke tier NEAR and made whole chunks pop.
func _process(_delta: float) -> void:
	if _chunks.is_empty():
		return
	var cam := _camera()
	if cam == null:
		# No camera to measure from. Everything stays at whatever it was, which for a fresh rebuild is
		# LOD 0 and visible — the right default, because a chunk nobody can measure should be SEEN rather
		# than culled by a distance that was never computed.
		return
	var eye := cam.global_position
	for c in _chunks:
		var mi: MeshInstance3D = c["node"]
		if not is_instance_valid(mi):
			continue
		var d := _distance_to(c, eye)
		_nearest = minf(_nearest, d)
		if far_distance > 0.0:
			# Hysteresis both ways: hide only past far + band, show again only inside far - band. Without
			# the gap, a chunk sitting on the line toggles every frame.
			var shown: bool = mi.visible
			if shown and d > far_distance + lod_hysteresis:
				mi.visible = false
			elif not shown and d < far_distance - lod_hysteresis:
				mi.visible = true
			elif _dirty_lod:
				mi.visible = d <= far_distance
			if not mi.visible:
				# Nothing to fade into: the carriageway is already painted into the terrain, so stopping is
				# the whole transition (§10).
				_hidden += 1
				continue
		else:
			mi.visible = true
		var want := lod_for(d, int(c["lod"]))
		if want != int(c["lod"]) or _dirty_lod:
			c["lod"] = want
			mi.mesh = c["meshes"][want]
	# Report ONCE per rebuild, on the first frame that had a camera. A ribbon that is built, parented and
	# hidden looks exactly like a ribbon that was never built, and the two were confused for a whole
	# debugging session — so the host says which it is, with the distance that decided it.
	if _report and Engine.is_editor_hint():
		_report = false
		var tiers := PackedInt32Array()
		tiers.resize(Pasture3DRoadMesher.LOD_LEVELS)
		for c in _chunks:
			tiers[int(c["lod"])] += 1
		print("[Pasture3D] %s: %d chunk(s) at LOD %s, %d hidden beyond %.0f m; nearest is %.0f m; %s"
				% [get_parent().name if get_parent() != null else name, _chunks.size(), str(Array(tiers)),
					_hidden, far_distance, _nearest,
					("%d collider(s)" % _colliders) if collision_enabled else "no collision"])
	_hidden = 0
	_nearest = INF
	_dirty_lod = false


## Distance from `p_eye` to the NEAREST POINT of a chunk, not to its centre.
##
## ---- WHY THE CENTRE IS THE WRONG POINT ----
##
## A chunk is cut to a terrain region, so at the default 256 m region it is up to 256 m LONG. Measuring
## to its centre means a chunk you are STANDING ON reports up to 128 m, and two things follow, both of
## which look like other bugs:
##
##   The chunk under your wheels is given a distant tier. With the default thresholds it never reaches
##   LOD 0 at all on a full-length chunk, so tier NEAR effectively does not exist and the road looks
##   permanently coarse — which reads as the LOD meshes being wrong rather than as the distance being
##   measured to the wrong place.
##
##   Whole chunks pop. As the camera moves, a centre crosses `far_distance` and 256 m of road appears or
##   vanishes in one frame, while the near end of that chunk was only 470 m away. That is the snapping.
##
## The mesh's own AABB is exact and already computed, so this costs a clamp.
func _distance_to(p_chunk: Dictionary, p_eye: Vector3) -> float:
	var box: Variant = p_chunk.get("bounds")
	if box == null:
		return p_eye.distance_to(p_chunk["centre"])
	var aabb: AABB = box
	var near := Vector3(
			clampf(p_eye.x, aabb.position.x, aabb.end.x),
			clampf(p_eye.y, aabb.position.y, aabb.end.y),
			clampf(p_eye.z, aabb.position.z, aabb.end.z))
	return p_eye.distance_to(near)


## The tier for a distance: the first band it falls inside, clamped to the coarsest mesh that exists.
##
## `p_current` is the tier the chunk is already showing. Passing it applies HYSTERESIS: the chunk keeps
## what it has until the distance clears the threshold by `lod_hysteresis`, so a camera hovering on a
## line does not swap the mesh every frame. Pass -1 for the raw answer.
##
## Public because it is the one part of the host that is arithmetic rather than scene-tree work, and an
## off-by-one band is invisible — the road still draws, at the wrong tier, and looks like the meshes
## being wrong rather than like the thresholds being read wrong.
func lod_for(p_distance: float, p_current: int = -1) -> int:
	var meshes_max := Pasture3DRoadMesher.LOD_LEVELS - 1
	var want := meshes_max
	for i in lod_distances.size():
		if p_distance < lod_distances[i]:
			want = mini(i, meshes_max)
			break
	if p_current < 0 or want == p_current or lod_hysteresis <= 0.0:
		return want
	# Moving to a COARSER tier needs the distance to be past that tier's own lower edge by the band;
	# moving FINER needs it to be inside the current tier's lower edge by the band. Asymmetric on purpose:
	# the band is measured against the line being crossed, not against where the chunk happens to be.
	var edge := p_current - 1 if want < p_current else p_current
	if edge < 0 or edge >= lod_distances.size():
		return want
	var line := lod_distances[edge]
	if want > p_current and p_distance < line + lod_hysteresis:
		return p_current
	if want < p_current and p_distance > line - lod_hysteresis:
		return p_current
	return want


## The camera to measure from: the editor's viewport camera when there is one, the game's otherwise.
## Both, because a road that only LODs at runtime cannot be judged in the editor, which is where the
## thresholds are actually chosen.
func _camera() -> Camera3D:
	# Reached through the singleton rather than by naming the class: EditorInterface does not exist in an
	# exported build, and a direct reference makes this script fail to load in the shipped game — which
	# would take the road meshes out of the very build they are for.
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		var ed: Object = Engine.get_singleton("EditorInterface")
		var vp: Variant = ed.get_editor_viewport_3d(0)
		if vp != null:
			return vp.get_camera_3d()
	var world := get_viewport()
	return world.get_camera_3d() if world != null else null


## Say why a road built nothing. Every reason is otherwise silent and they all look identical: a road
## with no ribbon and a road whose ribbon was never asked for are the same picture.
func _why(p_brush: Pasture3DRoadBrush, p_reason: String) -> void:
	if Engine.is_editor_hint():
		print("[Pasture3D] %s: no ribbon — %s" % [p_brush.name, p_reason])


## The ribbon as TriangleMeshes in `p_node`'s local space, for the editor gizmo's collision triangles.
##
## The gizmo used to build these itself, inside `_redraw`: for every chunk it copied the vertex array,
## transformed it, built an ArrayMesh and called `generate_triangle_mesh()` — a BVH build per chunk. That
## ran on every redraw, which the editor issues on selection, on camera moves and on every transform
## change, so simply dragging a road paid a full pick-geometry rebuild per frame while the geometry
## itself had not changed.
##
## The cache key is the ribbon's own rebuild digest plus the node transform, because those are the only
## two things the result depends on: `_last_digest` changes exactly when the chunk meshes do, and the
## transform is what takes them from world space to local. Nothing else in a redraw can move a triangle.
func pick_meshes(p_node: Node3D) -> Array[TriangleMesh]:
	if p_node == null:
		return []
	var key := "%s|%s" % [_last_digest, str(p_node.global_transform)]
	if key == _pick_digest and not _pick_meshes.is_empty():
		return _pick_meshes

	var out: Array[TriangleMesh] = []
	for chunk in _chunks:
		var meshes: Array = chunk.get("meshes", [])
		if meshes.is_empty() or not (meshes[0] is ArrayMesh):
			continue
		var m: ArrayMesh = meshes[0]
		if m.get_surface_count() == 0:
			continue
		var arrays := m.surface_get_arrays(0)
		var wverts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var local_verts := PackedVector3Array()
		local_verts.resize(wverts.size())
		for vi in wverts.size():
			local_verts[vi] = p_node.to_local(wverts[vi])
		arrays[Mesh.ARRAY_VERTEX] = local_verts
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var tm := am.generate_triangle_mesh()
		if tm != null:
			out.append(tm)

	# Only a non-empty result is cached. An empty one means the ribbon is not built YET — a state that
	# ends without the digest changing — so caching it would leave the road unpickable until the next
	# rebuild.
	if not out.is_empty():
		_pick_meshes = out
		_pick_digest = key
	return out
