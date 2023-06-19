@tool
extends Node


@export var clear_terrain: bool = false : set = reset_terrain

func reset_terrain(value) -> void:
	if value:
		%Terrain3D.storage = Terrain3DStorage.new()
		%TextureRect.texture = null


@export_group("Import Noise")
@export var noise_position: Vector3 = Vector3(0,0,0)
@export var noise_image_size: Vector2i = Vector2i(2048, 2048)
@export var noise_frequency: float = 0.001
@export var noise_height_scale: float = 0.25
@export var run_noise_import: bool = false : set = import_noise

func import_noise(value) -> void:
	if value:
		print("Generating noise for import from GDScript")
		if not %Terrain3D.storage:
			%Terrain3D.storage = Terrain3DStorage.new()

		var fnl := FastNoiseLite.new()
		fnl.frequency = noise_frequency
		var img: Image = fnl.get_seamless_image(noise_image_size.x, noise_image_size.y)
		var imported_images: Array[Image]
		imported_images.resize(Terrain3DStorage.TYPE_MAX)
		imported_images[Terrain3DStorage.TYPE_HEIGHT] = img
		%Terrain3D.storage.import_images(imported_images, noise_position, 0.0, noise_height_scale)
		update_preview(img)


@export_group("Import File")
@export_file var height_file_name: String = ""
@export_file var control_file_name: String = ""
@export_file var color_file_name: String = ""
@export var import_position: Vector3 = Vector3.ZERO
@export var import_offset: float = 0.0
@export var import_scale: float = 1.0
@export var r16_range: Vector2 = Vector2(0, 1)
@export var r16_size: Vector2i = Vector2i(1024, 1024)
@export var run_import: bool = false : set = start_import

func start_import(value: bool) -> void:
	if value:
		print("Importing files:\n\t%s\n\t%s\n\t%s" % [ height_file_name, control_file_name, color_file_name])
		if not %Terrain3D.storage:
			%Terrain3D.storage = Terrain3DStorage.new()

		var imported_images: Array[Image]
		imported_images.resize(Terrain3DStorage.TYPE_MAX)
		var min_max := Vector2(0, 1)
		var img: Image
		if height_file_name:
			img = Terrain3DStorage.load_image(height_file_name, ResourceLoader.CACHE_MODE_IGNORE, r16_range, r16_size)
			min_max = Terrain3DStorage.get_min_max(img)
			imported_images[Terrain3DStorage.TYPE_HEIGHT] = img
			update_preview(img)
		if control_file_name:
			img = Terrain3DStorage.load_image(control_file_name, ResourceLoader.CACHE_MODE_IGNORE)
			imported_images[Terrain3DStorage.TYPE_CONTROL] = img
		if color_file_name:
			img = Terrain3DStorage.load_image(color_file_name, ResourceLoader.CACHE_MODE_IGNORE)
			imported_images[Terrain3DStorage.TYPE_COLOR] = img
		%Terrain3D.storage.import_images(imported_images, import_position, import_offset-min_max.x, import_scale/(min_max.y))


@export_group("Export File")
enum MapType { TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR }
@export var map_type: MapType = MapType.TYPE_HEIGHT
@export var file_name_out: String = ""
@export var run_export: bool = false : set = start_export

func start_export(value: bool) -> void:
	if(not file_name_out.begins_with("res://")):
		file_name_out = "res://" + file_name_out
	print("Exporting map type %d to file: %s" % [ map_type, file_name_out ])
	var err: int = %Terrain3D.storage.export_image(file_name_out, map_type)
	print("Export error status: ", err, " ", error_string(err))
	

func update_preview(img: Image) -> void:
	if not img or img.is_empty():
		%TextureRect1.texture = null
		return

	print("update_preview: Format: ", img.get_format())
	print("update_preview: Highest & lowest values: ", %Terrain3D.storage.get_min_max(img))
	print("update_preview: Drawing heightmap")
	var aspect_ratio: float = img.get_size().x / img.get_size().y
	var drawn: Image = %Terrain3D.storage.get_thumbnail(img, Vector2i(256, 256/aspect_ratio))
	if drawn:
		print("update_preview: Drawn image type: ", drawn.get_format())
		%TextureRect.texture = ImageTexture.create_from_image(drawn)
