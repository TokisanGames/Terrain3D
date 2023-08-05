@tool
class_name ChunkBaker
extends Node3D


@export var navmesh_template:NavigationMesh
@export_dir() var bake_path:String
@export var terrain:Terrain3D
@export_range(0, 100, 1, "or_greater") var bake_region:int
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

signal setup_finished


## Bakes a navigation mesh group for a [class Terrain3D], and any child nodes as usual. It wraps it in a [class NavmeshBundle] and saves it to disk.
func bake_terrain() -> void:
	_setup()
	
	print("Setting up worker pool")
	task_id = WorkerThreadPool.add_group_task(_work, area)
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	
	_teardown()


func stop() -> void:
	stop_it = true


func _wrap_up() -> void:
	ResourceSaver.save(bundle, "%s/%s_bundle.tres" % [bake_path, name])
	print("Finished baking.")


func _setup() -> void:
	print("Setting up worker.")
	var offsets = region_offsets
	var region_uv = offsets[bake_region]
	# Grab region info
	var region_center:Vector2 = region_uv*region_size
	#var region_index = terrain.storage.get_region_index(Vector3(region_center.x, 0, region_center.y))
	xz = Rect2(region_center.x - region_size*.5, region_center.y - region_size*.5, region_size, region_size)
	var aabb:AABB = navmesh_template.filter_baking_aabb
	
	bundle = NavmeshBundle.new()
	width = range(xz.position.x, xz.end.x, aabb.size.x).size() # may need to -1
	height = range(xz.position.y, xz.end.y, aabb.size.z).size()
	# Fill bundle
	for _i in range(area):
		bundle.meshes.append(navmesh_template.duplicate())
	# parse geometry
	var nm:NavigationMesh = navmesh_template.duplicate()
	nm.filter_baking_aabb = AABB()
	nm.filter_baking_aabb_offset = Vector3.ZERO
	print("Parsing geometry...")
	parsed_geometry = NavigationMeshSourceGeometryData3D.new()
	NavigationMeshGenerator.parse_source_geometry_data(nm, parsed_geometry, self, func(): print("Parsed geometry."))
	print("Finished setup.")


func _teardown() -> void:
	print("Tearing down.")
	ResourceSaver.save(bundle, "%s/%s_%s_bundle.tres" % [bake_path, name, Time.get_unix_time_from_system()])
	bundle = null

func _work(index:int) -> void:
	var size = (navmesh_template.filter_baking_aabb as AABB).size
	var pos_offset = Vector3(_get_x(index % width), 0, _get_y(floori(index / height)))
	print(pos_offset)
	
	var agent_diameter = navmesh_template.agent_radius * 2
	bundle.meshes[index].filter_baking_aabb.size = size + Vector3(agent_diameter, 0, agent_diameter) # expand to compensate for agent diameter
	bundle.meshes[index].filter_baking_aabb_offset = pos_offset
	
	print("Baking chunk %s..." % index)
	NavigationMeshGenerator.bake_from_source_geometry_data(bundle.meshes[index], parsed_geometry, func(): print("Chunk %s finished." % index))


func _get_x(x:int) -> float:
	return lerp(xz.position.x, xz.end.x, x as float / width as float)


func _get_y(y:int) -> float:
	return lerp(xz.position.y, xz.end.y, y as float / height as float)
