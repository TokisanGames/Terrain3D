@tool
class_name ChunkBaker
extends Node3D


@export var navmesh_template:NavigationMesh
@export_dir() var bake_path:String
@export var terrain:Terrain3D
@export_range(-1, 15) var bake_region:int
@export var pretty_print:bool = true
var region_done:bool
var bundle:NavmeshBundle
var region_offsets:Array[Vector2i]:
	get:
		return terrain.storage.data_region_offsets
var region_size:int:
	get:
		return terrain.storage.region_size
var stop_it:bool
var width:int
var height:int
var area:int:
	get:
		return width * height
var task_id:int
var parsed_geometry:NavigationMeshSourceGeometryData3D
var xz:Rect2
var to_bake:int
var region_uv:Vector2i
var bake_thread:Thread
var progress:PackedStringArray
var current_region:int

signal setup_finished


## Bakes a navigation mesh group for a [class Terrain3D], and any child nodes as usual. It wraps it in a [class NavmeshBundle] and saves it to disk.
func bake_terrain() -> void:
	if not bake_thread == null:
		bake_thread.wait_to_finish()
	
	_setup_nav()
	bake_thread = Thread.new()
	bake_thread.start(_thread.bind())


func _thread() -> void:
	if bake_region == -1:
		for r in range(region_offsets.size()):
			_set_size(r)
			_bake_region()
	else:
		_set_size(bake_region)
		_bake_region()
	_teardown()


func _bake_region() -> void:
	# dumb mistake proofing (for me)
	if navmesh_template == null:
		push_error("Chunk Baker: Chunk baker must have a template navmesh.")
		return
	if navmesh_template.filter_baking_aabb.size == Vector3.ZERO:
		push_error("Chunk Baker: Please define bake chunk sizes by setting the Navmesh Template's Filter>Filter Baking AABB size.")
		return
	if terrain == null:
		push_error("Chunk Baker: Please assign a terrain.")
	if bake_region >= region_offsets.size():
		push_error("Chunk Baker: Attempt to bake region index %s, but the terrain doesn't have that many regions.")
		return
	
	if pretty_print:
		progress.clear()
		progress.resize(area)
		progress.fill("[color=orange]#[/color]")
	
	task_id = WorkerThreadPool.add_group_task(_work, area)
	WorkerThreadPool.wait_for_group_task_completion(task_id)


func _set_size(r:int) -> void:
	current_region = r
	region_uv = region_offsets[r]
	var region_center:Vector2 = region_uv*region_size
	xz = Rect2(region_center.x - region_size*.5, region_center.y - region_size*.5, region_size, region_size)
	print("Setting bounds for region %s: %s - %s" % [r, xz.position, xz.end])
	var aabb:AABB = navmesh_template.filter_baking_aabb
	
	width = range(xz.position.x, xz.end.x, aabb.size.x).size() # may need to -1
	height = range(xz.position.y, xz.end.y, aabb.size.z).size()


func _setup_nav() -> void:
	_set_size(0)
	# Fill bundle
	bundle = NavmeshBundle.new()
	for _i in range(area * region_offsets.size() if bake_region == -1 else area):
		bundle.meshes.append(navmesh_template.duplicate())
	# parse geometry
	var nm:NavigationMesh = navmesh_template.duplicate()
	nm.filter_baking_aabb = AABB()
	nm.filter_baking_aabb_offset = Vector3.ZERO
	print("Parsing geometry on the main thread...")
	parsed_geometry = NavigationMeshSourceGeometryData3D.new()
	NavigationMeshGenerator.parse_source_geometry_data(nm, parsed_geometry, self, func(): 
		print("Parsed geometry.")
		)


func _teardown() -> void:
	print("Tearing down.")
	ResourceSaver.save(bundle, "%s/%s_%s_bundle.res" % [bake_path, name, Time.get_unix_time_from_system()])
	bundle = null


func _work(index:int) -> void:
	var size = (navmesh_template.filter_baking_aabb as AABB).size
	var pos_offset = Vector3(_get_x(index % width), 0, _get_y(floori(index / height)))
	
	var agent_diameter = navmesh_template.agent_radius * 2
	var offset_index = index + ((area * current_region) if bake_region == -1 else 0) # offset index if going through indices so we don't write to the same chunk of meshes over and over
	bundle.meshes[offset_index].filter_baking_aabb.size = size + Vector3(agent_diameter, 0, agent_diameter) # expand to compensate for agent diameter
	bundle.meshes[offset_index].filter_baking_aabb_offset = pos_offset
	
	NavigationMeshGenerator.bake_from_source_geometry_data(bundle.meshes[offset_index], parsed_geometry, func():
		if pretty_print:
			progress[index] = "[color=green]#[/color]"
			print_progress()
		)


func _get_x(x:int) -> float:
	return lerp(xz.position.x, xz.end.x, x as float / width as float)


func _get_y(y:int) -> float:
	return lerp(xz.position.y, xz.end.y, y as float / height as float)


func print_progress() -> void:
	print("\n\n\n\n")
	print("Baking region %s" % current_region)
	print_rich("".join(progress))
