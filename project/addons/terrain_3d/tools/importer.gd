@tool
extends Terrain3D


@export var clear_all: bool = false : set = reset_settings
@export var clear_terrain: bool = false : set = reset_terrain
@export var update_height_range: bool = false : set = update_heights


func reset_settings(value) -> void:
	if value:
		height_file_name = ""
		control_file_name = ""
		color_file_name = ""
		import_position = Vector3.ZERO
		import_offset = 0.0
		import_scale = 1.0
		r16_range = Vector2(0, 1)
		r16_size = Vector2i(1024, 1024)
		storage = null
		material = null
		texture_list = null


func reset_terrain(value) -> void:
	if value:
		storage = null


func update_heights(value) -> void:
	if value and storage:
		storage.update_height_range()


@export_group("Import File")
@export_global_file var height_file_name: String = ""
@export_global_file var control_file_name: String = ""
@export_global_file var color_file_name: String = ""
@export var import_position: Vector3 = Vector3.ZERO
@export var import_scale: float = 1.0
@export var import_offset: float = 0.0
@export var r16_range: Vector2 = Vector2(0, 1)
@export var r16_size: Vector2i = Vector2i(1024, 1024)
@export var run_import: bool = false : set = start_import

func start_import(value: bool) -> void:
	if value:
		print("Importing files:\n\t%s\n\t%s\n\t%s" % [ height_file_name, control_file_name, color_file_name])
		if not storage:
			storage = Terrain3DStorage.new()

		var imported_images: Array[Image]
		imported_images.resize(Terrain3DStorage.TYPE_MAX)
		var min_max := Vector2(0, 1)
		var img: Image
		if height_file_name:
			img = Terrain3DStorage.load_image(height_file_name, ResourceLoader.CACHE_MODE_IGNORE, r16_range, r16_size)
			min_max = Terrain3D.get_min_max(img)
			imported_images[Terrain3DStorage.TYPE_HEIGHT] = img
		if control_file_name:
			img = Terrain3DStorage.load_image(control_file_name, ResourceLoader.CACHE_MODE_IGNORE)
			imported_images[Terrain3DStorage.TYPE_CONTROL] = img
		if color_file_name:
			img = Terrain3DStorage.load_image(color_file_name, ResourceLoader.CACHE_MODE_IGNORE)
			imported_images[Terrain3DStorage.TYPE_COLOR] = img
			if texture_list.get_texture_count() == 0:
				material.show_checkered = false
				material.show_colormap = true
		storage.import_images(imported_images, import_position, import_offset, import_scale)
		print("Import finished")


@export_group("Export File")
enum { TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR }
@export_enum("Height:0", "Control:1", "Color:2") var map_type: int = TYPE_HEIGHT
@export var file_name_out: String = ""
@export var run_export: bool = false : set = start_export

func start_export(value: bool) -> void:
	var err: int = storage.export_image(file_name_out, map_type)
	print("Export error status: ", err, " ", error_string(err))
	
