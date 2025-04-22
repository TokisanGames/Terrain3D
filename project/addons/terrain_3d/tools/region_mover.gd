# This script can be used to move your regions by an offset. 
# Eventually this tool will find its way into a built in UI
# 
# Attach it to your Terrain3D node
# Save and reload your scene
# Select your Terrain3D node
# Enter a valid `offset` where all regions will be within -16, +15
# Run it
# It should unload the regions, rename files, and reload them
# Clear the script and resave your scene


@tool
extends Terrain3D


@export var offset: Vector2i
@export var run: bool = false : set = start_rename


func start_rename(val: bool = false) -> void:
	if val == false or offset == Vector2i.ZERO:
		return
		
	var dir_name: String = data_directory
	data_directory = ""
	var dir := DirAccess.open(dir_name)
	if not dir:
		print("An error occurred when trying to access the path: ", data_directory)
		return

	var affected_files: PackedStringArray
	var files: PackedStringArray = dir.get_files()
	for file_name in files:
		if file_name.match("terrain3d*.res") and not dir.current_is_dir():
			var region_loc: Vector2i = Terrain3DUtil.filename_to_location(file_name)
			var new_loc: Vector2i = region_loc + offset
			if new_loc.x < -16 or new_loc.x > 15 or new_loc.y < -16 or new_loc.y > 15:
				push_error("New location %.0v out of bounds for region %.0v. Aborting" % [ new_loc, region_loc ])
				return
			var new_name: String = "tmp_" + Terrain3DUtil.location_to_filename(new_loc)
			dir.rename(file_name, new_name)
			affected_files.push_back(new_name)
			print("File: %s renamed to: %s" % [ file_name, new_name ])
				
	for file_name in affected_files:
		var new_name: String = file_name.trim_prefix("tmp_")
		dir.rename(file_name, new_name)
		print("File: %s renamed to: %s" % [ file_name, new_name ])
		
	data_directory = dir_name
	EditorInterface.get_resource_filesystem().scan()	
