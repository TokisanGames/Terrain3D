@tool
extends EditorExportPlugin
var terrain: Terrain3D
var terrain_data: Terrain3DData
var region: Terrain3DRegion
var hashing: String
func _get_name() -> String:
	return "ExportPlugin"

func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	for feat in features:
		hashing += feat
	hashing += platform.to_string()
	
	return true
	
func _customize_resource(resource: Resource, path: String) -> Resource:
	if resource is Terrain3DRegion:
		region = resource
		if region.compressed_color_map != null:
			region.color_map = null
			return region
	return null
	
func _get_customization_configuration_hash() -> int:
	return hash(hashing)
	
