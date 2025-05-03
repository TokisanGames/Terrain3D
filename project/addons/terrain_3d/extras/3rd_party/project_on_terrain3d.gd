# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# This script is an addon for HungryProton's Scatter https://github.com/HungryProton/scatter
# It provides a `Project on Terrain3D` modifier, which allows Scatter 
# to detect the terrain height from Terrain3D without using collision.
#
# Copy this file into /addons/proton_scatter/src/modifiers
# Then uncomment everything below (select, press CTRL+K)
# In the editor, add this modifier to Scatter, then set your Terrain3D node

#@tool
#extends "base_modifier.gd"
#
#
#signal projection_completed
#
#
#@export var terrain_node : NodePath
#@export var align_with_collision_normal : bool = false
#@export_range(0.0, 90.0, 0.1) var max_slope : float = 90.0
#@export var enable_texture_filtering : bool = false
#@export_range(0, 31) var target_texture_id : int = 0
#@export var not_target_texture : bool = false
#@export_range(0.0, 1.0, 0.01) var texture_threshold : float = 0.8
#
#var _terrain: Terrain3D
#
#
#func _init() -> void:
	#display_name = "Project On Terrain3D"
	#category = "Edit"
	#can_restrict_height = false
	#global_reference_frame_available = true
	#local_reference_frame_available = true
	#individual_instances_reference_frame_available = true
	#use_global_space_by_default()
#
	#documentation.add_paragraph(
		#"This is a modified version of `Project on Colliders` that queries Terrain3D
		#for heights without using collision. It constrains placement by slope or texture.
#
		#This modifier must have terrain_node set to a Terrain3D node.")
#
	#var p := documentation.add_parameter("Terrain Node")
	#p.set_type("NodePath")
	#p.set_description("Set your Terrain3D node.")
		#
	#p = documentation.add_parameter("Align with collision normal")
	#p.set_type("bool")
	#p.set_description(
		#"Rotate the transform to align it with the collision normal in case
		#the ray cast hit a collider.")
		#
	#p = documentation.add_parameter("Enable Texture Filtering")
	#p.set_type("bool")
	#p.set_description(
		#"If enabled, objects will only be placed based on the ground texture specified.")
		#
	#p = documentation.add_parameter("Target Texture ID")
	#p.set_type("int")
	#p.set_description(
		#"The ID of the texture to place objects on (0-31). Objects will only be placed on this texture.")
		#
	#p = documentation.add_parameter("Not Target Texture")
	#p.set_type("bool") 
	#p.set_description(
		#"If true, objects will be placed on all textures EXCEPT the target texture.")
		#
	#p = documentation.add_parameter("Texture Threshold")
	#p.set_type("float") 
	#p.set_description("The blend value required for placement on the texture.")
#
#
#func _process_transforms(transforms, domain, _seed) -> void:
	#if transforms.is_empty():
		#return
#
	#if terrain_node:
		#_terrain = domain.get_root().get_node_or_null(terrain_node)
#
	#if not _terrain:
		#warning += """No Terrain3D node found"""
		#return
#
	#if not _terrain.data:
		#warning += """Terrain3DData is not initialized"""
		#return
#
	## Review transforms
	#var gt: Transform3D = domain.get_global_transform()
	#var gt_inverse := gt.affine_inverse()
	#var new_transforms_array: Array[Transform3D] = []
	#var remapped_max_slope: float = remap(max_slope, 0.0, 90.0, 0.0, 1.0)
	#for i in transforms.list.size():
		#var t: Transform3D = transforms.list[i]
		#
		#var location: Vector3 = (gt * t).origin
		#var height: float = _terrain.data.get_height(location)		
		#if is_nan(height):
			#continue
		#
		#var normal: Vector3 = _terrain.data.get_normal(location)
		#if not abs(Vector3.UP.dot(normal)) >= (1.0 - remapped_max_slope):
			#continue
		#
		#if enable_texture_filtering:
			#var texture_info: Vector3 = _terrain.data.get_texture_id(location)
			#var base_id: int = int(texture_info.x)
			#var overlay_id: int = int(texture_info.y)
			#var blend_value: float = texture_info.z
			## Skip if overlay or blend != target texture, unless inverted
			#if ((overlay_id != target_texture_id or blend_value < texture_threshold) and \
				#(base_id != target_texture_id or blend_value >= texture_threshold)) != not_target_texture:
					#continue
#
		#if align_with_collision_normal and not is_nan(normal.x):
			#t.basis.y = normal
			#t.basis.x = -t.basis.z.cross(normal)
			#t.basis = t.basis.orthonormalized()
#
		#t.origin.y = height - gt.origin.y
		#new_transforms_array.push_back(t)
#
	#transforms.list.clear()
	#transforms.list.append_array(new_transforms_array)
#
	#if transforms.is_empty():
		#warning += """All transforms have been removed. Possible reasons include: \n"""
		#if enable_texture_filtering:
			#warning += """+ No matching texture found at any position.
			#+ Texture threshold may be too high.
			#"""
		#warning += """+ No collider is close enough to the shapes.
		#+ Ray length is too short.
		#+ Ray direction is incorrect.
		#+ Collision mask is not set properly.
		#+ Max slope is too low.
		#"""
