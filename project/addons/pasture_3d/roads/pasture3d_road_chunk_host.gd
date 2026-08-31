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

## Metres the ribbon rides above the graded ground. Exposed for tuning on unusual terrain scales, not
## for turning off — see Pasture3DRoadMesher.DEPTH_LIFT for why coplanar is not an option.
@export var depth_lift: float = Pasture3DRoadMesher.DEPTH_LIFT

## Chunks, each `{node: MeshInstance3D, centre: Vector3, meshes: Array[ArrayMesh], lod: int}`.
var _chunks: Array = []
var _dirty_lod: bool = true


func _ready() -> void:
	set_process(true)


## Rebuild every chunk for `p_brush`. Called at the end of a bake, from the network, so the whole
## network re-chunks in one pass and in a defined order.
##
## Returns the number of chunks built. Zero is the normal answer for a road with no alignment yet or no
## surface material, not an error.
func rebuild(p_brush: Pasture3DRoadBrush) -> int:
	_clear()
	if p_brush == null:
		return 0
	var run := p_brush.build_run()
	if run.is_empty():
		_why(p_brush, "the road has no solved alignment yet (build_run is empty)")
		return 0
	var t: Pasture3DRoadType = p_brush.resolved_road_type()
	if t == null:
		_why(p_brush, "the road has no road type")
		return 0
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
		var mid := (float(span[0]) + float(span[1])) * 0.5
		var at := Pasture3DRoadGrader.plan_point_at(plan, cum, mid)
		_chunks.append({
			"node": mi,
			"centre": Vector3(at.x, alignment.height_at(mid), at.y),
			"meshes": meshes,
			"lod": 0,
		})
	_dirty_lod = true
	if _chunks.is_empty():
		_why(p_brush, "%d span(s) were found but every one failed to mesh" % rejected)
	return _chunks.size()


## World metres across one terrain region — the unit chunk cuts snap to, so a chunk's lifetime matches
## the region it sits in.
func _region_metres(p_brush: Pasture3DRoadBrush) -> float:
	var terrain: Variant = p_brush.terrain
	if terrain == null:
		return 0.0
	return maxf(float(terrain.region_size) * terrain.vertex_spacing, 1.0)


func _clear() -> void:
	for c in _chunks:
		var n: Node = c["node"]
		if is_instance_valid(n):
			n.queue_free()
	_chunks.clear()


## Pick each chunk's tier from its distance to the camera.
##
## Distance to the chunk's CENTRE rather than to its nearest point: a long chunk would otherwise flip
## tier as the camera slides along beside it without getting any closer, and the whole point of cutting
## on region boundaries is that a chunk is small enough for its centre to be a fair answer.
func _process(_delta: float) -> void:
	if _chunks.is_empty():
		return
	var cam := _camera()
	if cam == null:
		return
	var eye := cam.global_position
	for c in _chunks:
		var mi: MeshInstance3D = c["node"]
		if not is_instance_valid(mi):
			continue
		var d := eye.distance_to(c["centre"])
		if far_distance > 0.0 and d > far_distance:
			# Nothing to fade into: the carriageway is already painted into the terrain, so stopping is
			# the whole transition (§10).
			mi.visible = false
			continue
		mi.visible = true
		var want := lod_for(d)
		if want != int(c["lod"]) or _dirty_lod:
			c["lod"] = want
			mi.mesh = c["meshes"][want]
	_dirty_lod = false


## The tier for a distance: the first band it falls inside, clamped to the coarsest mesh that exists.
##
## Public because it is the one part of the host that is arithmetic rather than scene-tree work, and an
## off-by-one band is invisible — the road still draws, at the wrong tier, and looks like the meshes
## being wrong rather than like the thresholds being read wrong.
func lod_for(p_distance: float) -> int:
	var meshes_max := Pasture3DRoadMesher.LOD_LEVELS - 1
	for i in lod_distances.size():
		if p_distance < lod_distances[i]:
			return mini(i, meshes_max)
	return meshes_max


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
