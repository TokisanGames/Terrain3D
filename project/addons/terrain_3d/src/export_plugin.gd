# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Export Plugin for Terrain3D
@tool
extends EditorExportPlugin


var _hash: String
var _free_uncompressed_color_maps: bool
var _color_compress_mode: Image.CompressMode


func _get_name() -> String:
	return "Terrain3DExportPlugin"


func _begin_customize_scenes(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	return true
	
	
func _customize_scene(scene: Node, path: String) -> Node:
	var terrain: Terrain3D = scene.find_child("Terrain3D", true)
	if terrain:
		_free_uncompressed_color_maps = terrain.get_free_uncompressed_color_maps()
		_color_compress_mode = terrain.get_color_image_compress_mode()
	return null
	
	
func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	_hash = ""
	for feat: String in features:
		_hash += feat
	_hash += platform.to_string()
	return true
	
	
func _customize_resource(resource: Resource, path: String) -> Resource:
	if resource is Terrain3DRegion:
		var region: Terrain3DRegion = resource
		if _color_compress_mode != Image.COMPRESS_MAX and _free_uncompressed_color_maps and region.compressed_color_map != null:
			region.free_uncompressed_color_map()
			return region
	return null
	
	
func _get_customization_configuration_hash() -> int:
	return hash(_hash)
