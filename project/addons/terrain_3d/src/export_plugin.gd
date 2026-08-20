# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Export Plugin for Terrain3D
@tool
extends EditorExportPlugin

# The intention of this plugin is to strip out the uncompressed color map from the build. However it
# doesn't actually work, most likely because Godot takes the saved file rather than the resource we provide.
# Infrastructure is here in the hopes that we can work around the issue one day, or Godot provides a better
# facility. In the meantime, this essentially does nothing so is disabled. The extra map is freed from memory at runtime.

var plugin: EditorPlugin
var _hash: String


func _get_name() -> String:
	return "Terrain3DExportPlugin"

	
func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	# Godot caches exports based on this hash, so ensure we update on every version minimum
	_hash = plugin.terrain.get_version()
	for feat: String in features:
		_hash += feat
	_hash += platform.to_string()
	return true
	
	
func _customize_resource(resource: Resource, path: String) -> Resource:
	#if resource is Terrain3DRegion:
		#var region: Terrain3DRegion = resource.duplicate(true)
		#if region.compressed_color_map != null:
			## Read only compressed color map
			#region.clear_color_map()
		#else:
			## Editable, uncompressed color map
			#region.clear_compressed_color_map()
		#return region
	return null
	
	
func _get_customization_configuration_hash() -> int:
	return hash(_hash)
	# DEVELOPMENT ONLY: Forces Godot to skip the cache and run every time
	#return hash(Time.get_ticks_msec())
