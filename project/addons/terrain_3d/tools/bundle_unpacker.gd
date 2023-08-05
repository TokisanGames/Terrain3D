@tool
class_name NavmeshBundleUnpacker
extends Node


@export var bundle:NavmeshBundle


func unpack() -> void:
	var i = 0
	
	for nm in bundle.meshes:
		var region = NavigationRegion3D.new()
		region.navigation_mesh = nm
		add_child(region)
		region.name = "%s" % i
		region.owner = get_tree().edited_scene_root
