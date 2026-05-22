@tool
extends Node

const TERRAIN_GENERATION: String = "res://addons/terrain_3d/menu/terrain_generation.tscn"

var height_slider: HSlider
var frequency_slider: HSlider
var octaves_spin_box: SpinBox

var region_count_spin_box: SpinBox
var region_size_option_button: OptionButton

var mesh_instance_3d: MeshInstance3D
var mat: ShaderMaterial
var preview_camera_3d: Camera3D
var _preview: SubViewportContainer
var generate_button: Button

var noise_generator: FastNoiseLite
var noise_texture: NoiseTexture2D
var normal_texture: NoiseTexture2D

var region_size_arr: Array[int] = [256, 512, 1024]
var region_size_idx: int = 0

var plugin: EditorPlugin
var terrain: Terrain3D
var dialog: ConfirmationDialog

func set_up_pop_up() -> void:
	if not plugin.terrain:
		push_error("Not connected terrain. Click the Terrain3D node first")
		return
	terrain = plugin.terrain
	print("Setting up TerrainGeneration pop up")
	dialog = load(TERRAIN_GENERATION).instantiate()
	dialog.hide()
	
	dialog.confirmed.connect(_on_close_requested)
	dialog.canceled.connect(_on_close_requested)
	dialog.get_ok_button().pressed.connect(_on_ok_pressed)
	
	mesh_instance_3d = dialog.find_child("MeshInstance3D")
	mat = mesh_instance_3d.get_active_material(0)
	preview_camera_3d = dialog.find_child("PreviewCamera3D")
	_preview = dialog.find_child("SubViewportContainer")

	noise_generator = FastNoiseLite.new()
	noise_texture = NoiseTexture2D.new()
	normal_texture = NoiseTexture2D.new()
		
	height_slider = dialog.find_child("HeightSlider")	
	height_slider.value_changed.connect(set_height_scale)
	height_slider.value = 2.0
	
	frequency_slider = dialog.find_child("FrequencySlider")
	frequency_slider.value_changed.connect(set_frequency)
	frequency_slider.value = noise_generator.frequency
		
	octaves_spin_box = dialog.find_child("OctavesSpinBox")
	octaves_spin_box.value_changed.connect(set_octaves)
	octaves_spin_box.value = noise_generator.fractal_octaves
	
	region_size_option_button = dialog.find_child("RegionSizeOptionButton")
	region_size_option_button.item_selected.connect(set_region_size)
	region_size_option_button.select(region_size_arr.find(int(terrain.region_size)))
	set_region_size(region_size_option_button.selected)
	generate_button = dialog.find_child("GenerateButton")
	generate_button.pressed.connect(_generate_terrain)
	
	height_slider.value = height_slider.value
	frequency_slider.value = height_slider.value
	octaves_spin_box.value = octaves_spin_box.value
		
	noise_texture.noise = noise_generator
	noise_texture.seamless = true
	set_shader_param("noise", noise_texture)
	
	normal_texture.noise = noise_generator
	normal_texture.as_normal_map = true
	normal_texture.invert = true
	normal_texture.seamless = true
	set_shader_param("normal_map", normal_texture)
		
	# Popup
	EditorInterface.popup_dialog_centered(dialog)
	
func _on_close_requested() -> void:
	dialog.queue_free()
	dialog = null


func _on_ok_pressed() -> void:
	if not terrain:
		push_error("Not connected terrain. Click the Terrain3D node first")
		return
	_generate_terrain()


func _generate_terrain() -> void:
	print_debug("Generating Terrain")
	if not terrain:
		push_error("Not connected terrain. Click the Terrain3D node first")
		return
	reset_terrain()
	var region_size: int = region_size_arr[region_size_idx]
	terrain.data.change_region_size(region_size)
	var img: Image = noise_texture.get_image()
	print_debug("Using image of size ", img.get_size())
	terrain.data.import_images([img, null, null], Vector3(0., 0., 0.), 0.0, height_slider.value * 1.)
	terrain.data.save_directory(terrain.data_directory)
	print("Generated Terrain")
	# Enable the next line and `Debug/Visible Collision Shapes` to see collision
	#terrain.collision.mode = Terrain3DCollision.DYNAMIC_EDITOR


func reset_terrain() -> void:
	if not terrain:
		push_error("Not connected terrain. Click the Terrain3D node first")
		return
	for region:Terrain3DRegion in terrain.data.get_regions_active():
		terrain.data.remove_region(region, false)
	terrain.data.save_directory(terrain.data_directory)

	
func set_region_size(item_id: int) -> void:
	region_size_idx = item_id
	var region_size: int  = region_size_arr[region_size_idx]
	print("Regionsize = ", region_size)
	noise_texture.height = region_size_arr[region_size_idx]
	noise_texture.width = region_size_arr[region_size_idx]
	normal_texture.height = region_size_arr[region_size_idx]
	normal_texture.width = region_size_arr[region_size_idx]
	(mesh_instance_3d.mesh as PlaneMesh).size = Vector2(region_size_arr[region_size_idx], region_size_arr[region_size_idx])
	
	
func set_height_scale(value: float) -> void:
	set_shader_param("noise_scale", value)
	height_slider.tooltip_text = str(value)
	
	
func set_frequency(value: float) -> void:
	value *= 0.1
	noise_generator.frequency = value
	frequency_slider.tooltip_text = str(value)
	
	
func set_octaves(value: int) -> void:
	noise_generator.fractal_octaves = value
	octaves_spin_box.tooltip_text = str(value)
	
	
func set_shader_param(p_name: String, value: Variant) -> void:
	mat.set_shader_parameter(p_name, value)
