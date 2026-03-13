# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Importer for Terrain3D
@tool
extends Terrain3D


@export_tool_button("Clear All") var clear_all = reset_settings
@export_tool_button("Clear Terrain") var clear_terrain = reset_terrain
@export_tool_button("Update Height Range") var update_height_range = update_heights


func reset_settings() -> void:
	height_file_name = ""
	control_file_name = ""
	color_file_name = ""
	import_splat_maps = false
	splat_map_paths.clear()
	material_ids.clear()
	destination_directory = ""
	import_position = Vector2i.ZERO
	height_offset = 0.0
	import_scale = 1.0
	r16_range = Vector2(0, 1)
	r16_size = Vector2i(1024, 1024)
	material = null
	assets = null
	reset_terrain()


func reset_terrain() -> void:
	data_directory = ""
	for region:Terrain3DRegion in data.get_regions_active():
		data.remove_region(region, false)
	data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)


## Recalculates min and max heights for all regions.
func update_heights() -> void:
	if data:
		data.calc_height_range(true)


@export_group("Import File")
## EXR or R16 are recommended for heightmaps. 16-bit PNGs are down sampled to 8-bit and not recommended.
@export_global_file var height_file_name: String = ""
## Only use EXR files in our proprietary format.
@export_global_file var control_file_name: String = ""
## Any RGB or RGBA format is fine; PNG or Webp are recommended.
@export_global_file var color_file_name: String = ""

@export_subgroup("Advanced")
## Enable to import splat maps.
@export var import_splat_maps: bool = false
## Should use RGBA format; PNG recommended. Must match size of heightmap. Max 8 splat maps supported.
@export_global_file var splat_map_paths: Array[String]
## Mark used channels with the corresponding index. Mark -1 for unused.
@export var material_ids: PackedInt32Array
@export_subgroup("")

## The top left (-X, -Y) corner position of where to place the imported data. Positions are descaled and ignore the vertex_spacing setting.
@export var import_position: Vector2i = Vector2i(0, 0) : set = set_import_position
## This scales the height of imported values.
@export var import_scale: float = 1.0
## This vertically offsets the height of imported values.
@export var height_offset: float = 0.0
## The lowest and highest height values of the imported image. Only use for r16 files.
@export var r16_range: Vector2 = Vector2(0, 1)
## The dimensions of the imported image. Only use for r16 files.
@export var r16_size: Vector2i = Vector2i(1024, 1024) : set = set_r16_size
@export_tool_button("Run Import") var run_import = start_import

@export_dir var destination_directory: String = ""
@export_tool_button("Save to Disk") var save_to_disk = save_data


func set_import_position(p_value: Vector2i) -> void:
	import_position.x = clamp(p_value.x, -8192, 8192)
	import_position.y = clamp(p_value.y, -8192, 8192)


func set_r16_size(p_value: Vector2i) -> void:
	r16_size.x = clamp(p_value.x, 0, 16384)
	r16_size.y = clamp(p_value.y, 0, 16384)


func start_import() -> void:
	print("Terrain3DImporter: Importing files:\n\t%s\n\t%s\n\t%s" % [ height_file_name, control_file_name, color_file_name])

	var imported_images: Array[Image]
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	var min_max := Vector2(0, 1)
	var img: Image
	if height_file_name:
		img = Terrain3DUtil.load_image(height_file_name, ResourceLoader.CACHE_MODE_IGNORE, r16_range, r16_size)
		min_max = Terrain3DUtil.get_min_max(img)
		imported_images[Terrain3DRegion.TYPE_HEIGHT] = img
	if control_file_name:
		img = Terrain3DUtil.load_image(control_file_name, ResourceLoader.CACHE_MODE_IGNORE)
		imported_images[Terrain3DRegion.TYPE_CONTROL] = img
	if color_file_name:
		img = Terrain3DUtil.load_image(color_file_name, ResourceLoader.CACHE_MODE_IGNORE)
		imported_images[Terrain3DRegion.TYPE_COLOR] = img
		if assets.get_texture_count() == 0:
			material.show_checkered = false
			material.show_colormap = true
	var pos := Vector3(import_position.x * vertex_spacing, 0, import_position.y * vertex_spacing)
	data.import_images(imported_images, pos, height_offset, import_scale)

	if import_splat_maps:
		if splat_map_paths.is_empty():
			push_error("The list of splat maps is empty")
		elif splat_map_paths.size() > 8:
			push_error("There can be max 8 splat maps because max 32 textures can be represented")
		else:
			var splat_images : Array[Image]
			var splat_tex_array : Texture2DArray = Texture2DArray.new()
			for file : String in splat_map_paths:
				var splat : Texture2D = ResourceLoader.load(file, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE)
				var splat_img : Image = splat.get_image()
				if splat_img.is_compressed():
					splat_img.decompress()
				splat_images.append(splat_img)
			data.set_splat_channel_to_material_list(material_ids, splat_images.size())
			data.import_splat_map(splat_images, pos)
	print("Terrain3DImporter: Import finished")


func save_data() -> void:
	if destination_directory.is_empty():
		push_error("Set destination directory first")
		return
	data.save_directory(destination_directory)


@export_group("Export File")
enum { TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR }
@export_enum("Height:0", "Control:1", "Color:2") var map_type: int = TYPE_HEIGHT
@export var file_name_out: String = ""
@export_tool_button("Run Export") var run_export = start_export

func start_export() -> void:
	var err: int = data.export_image(file_name_out, map_type)
	print("Terrain3DImporter: Export error status: ", err, " ", error_string(err))
	
