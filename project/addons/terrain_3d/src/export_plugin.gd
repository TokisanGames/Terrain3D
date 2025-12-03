# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Export Plugin for Terrain3D
@tool
extends EditorExportPlugin


var _hash: String
var _free_uncompressed_color_maps: bool
var _color_compression_mode: Image.CompressMode


func _get_name() -> String:
	return "Terrain3DExportPlugin"


func _begin_customize_scenes(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	return true
	
	
func _customize_scene(scene: Node, path: String) -> Node:
	var _terrain: Terrain3D = scene.find_child("Terrain3D", true)
	if (_terrain != null):
		_free_uncompressed_color_maps = _terrain.get_free_uncompressed_color_maps()
		_color_compression_mode = _terrain.get_image_color_compression_mode()
	return null
	
	
func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	_hash = ""
	for feat: String in features:
		_hash += feat
	_hash += platform.to_string()
	return true
	
	
func _customize_resource(resource: Resource, path: String) -> Resource:
	var _region: Terrain3DRegion
	if resource is Terrain3DRegion:
		_region = resource
		if _color_compression_mode != Image.COMPRESS_MAX and _free_uncompressed_color_maps and _region.compressed_color_map != null:
			_region.free_uncompressed_color_map()
			return _region
	return null
	
	
func _get_customization_configuration_hash() -> int:
	return hash(_hash)
