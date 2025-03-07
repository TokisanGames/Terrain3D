# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Channel Packer for Terrain3D
extends RefCounted

const WINDOW_SCENE: String = "res://addons/terrain_3d/menu/channel_packer.tscn"
const TEMPLATE_PATH: String = "res://addons/terrain_3d/menu/channel_packer_import_template.txt"
const DRAG_DROP_SCRIPT: String = "res://addons/terrain_3d/menu/channel_packer_dragdrop.gd"
enum { 
	INFO,
	WARN,
	ERROR,
}

enum {
	IMAGE_ALBEDO,
	IMAGE_HEIGHT,
	IMAGE_NORMAL,
	IMAGE_ROUGHNESS
}

var plugin: EditorPlugin
var window: Window
var save_file_dialog: EditorFileDialog
var open_file_dialog: EditorFileDialog
var invert_green_checkbox: CheckBox
var invert_smooth_checkbox: CheckBox
var invert_height_checkbox: CheckBox
var lumin_height_button: Button
var generate_mipmaps_checkbox: CheckBox
var high_quality_checkbox: CheckBox
var align_normals_checkbox: CheckBox
var resize_toggle_checkbox: CheckBox
var resize_option_box: SpinBox
var height_channel: Array[Button]
var height_channel_selected: int = 0
var roughness_channel: Array[Button]
var roughness_channel_selected: int = 0
var last_opened_directory: String
var last_saved_directory: String
var packing_albedo: bool = false
var queue_pack_normal_roughness: bool = false
var images: Array[Image] = [null, null, null, null]
var status_label: Label
var no_op: Callable = func(): pass
var last_file_selected_fn: Callable = no_op
var normal_vector: Vector3


func pack_textures_popup() -> void:
	if window != null:
		window.show()
		window.grab_focus()
		window.move_to_center()
		return
	window = (load(WINDOW_SCENE) as PackedScene).instantiate()
	window.close_requested.connect(_on_close_requested)
	window.window_input.connect(func(event:InputEvent):
		if event is InputEventKey:
			if event.pressed and event.keycode == KEY_ESCAPE:
				_on_close_requested()
		)
	window.find_child("CloseButton").pressed.connect(_on_close_requested)
	
	status_label = window.find_child("StatusLabel") as Label
	invert_green_checkbox = window.find_child("InvertGreenChannelCheckBox") as CheckBox
	invert_smooth_checkbox = window.find_child("InvertSmoothCheckBox") as CheckBox
	invert_height_checkbox = window.find_child("ConvertDepthToHeight") as CheckBox
	lumin_height_button = window.find_child("LuminanceAsHeightButton") as Button
	generate_mipmaps_checkbox = window.find_child("GenerateMipmapsCheckBox") as CheckBox
	high_quality_checkbox = window.find_child("HighQualityCheckBox") as CheckBox
	align_normals_checkbox = window.find_child("AlignNormalsCheckBox") as CheckBox
	resize_toggle_checkbox = window.find_child("ResizeToggle") as CheckBox
	resize_option_box = window.find_child("ResizeOptionButton") as SpinBox
	height_channel = [
		window.find_child("HeightChannelR") as Button,
		window.find_child("HeightChannelG") as Button,
		window.find_child("HeightChannelB") as Button,
		window.find_child("HeightChannelA") as Button
	]
	roughness_channel = [
		window.find_child("RoughnessChannelR") as Button,
		window.find_child("RoughnessChannelG") as Button,
		window.find_child("RoughnessChannelB") as Button,
		window.find_child("RoughnessChannelA") as Button
	]
	
	height_channel[0].pressed.connect(func() -> void: height_channel_selected = 0)
	height_channel[1].pressed.connect(func() -> void: height_channel_selected = 1)
	height_channel[2].pressed.connect(func() -> void: height_channel_selected = 2)
	height_channel[3].pressed.connect(func() -> void: height_channel_selected = 3)
	
	roughness_channel[0].pressed.connect(func() -> void: roughness_channel_selected = 0)
	roughness_channel[1].pressed.connect(func() -> void: roughness_channel_selected = 1)
	roughness_channel[2].pressed.connect(func() -> void: roughness_channel_selected = 2)
	roughness_channel[3].pressed.connect(func() -> void: roughness_channel_selected = 3)
	
	plugin.add_child(window)
	_init_file_dialogs()
	
	# the dialog disables the parent window "on top" so, restore it after 1 frame to alow the dialog to clear.
	var set_on_top_fn: Callable = func(_file: String = "") -> void:
		await RenderingServer.frame_post_draw
		window.always_on_top = true
	save_file_dialog.file_selected.connect(set_on_top_fn)
	save_file_dialog.canceled.connect(set_on_top_fn)
	open_file_dialog.file_selected.connect(set_on_top_fn)
	open_file_dialog.canceled.connect(set_on_top_fn)
	
	_init_texture_picker(window.find_child("AlbedoVBox"), IMAGE_ALBEDO)
	_init_texture_picker(window.find_child("HeightVBox"), IMAGE_HEIGHT)
	_init_texture_picker(window.find_child("NormalVBox"), IMAGE_NORMAL)
	_init_texture_picker(window.find_child("RoughnessVBox"), IMAGE_ROUGHNESS)

	(window.find_child("PackButton") as Button).pressed.connect(_on_pack_button_pressed)


func _on_close_requested() -> void:
	last_file_selected_fn = no_op
	images = [null, null, null, null]
	window.queue_free()
	window = null


func _init_file_dialogs() -> void:
	save_file_dialog = EditorFileDialog.new()
	save_file_dialog.set_filters(PackedStringArray(["*.png"]))
	save_file_dialog.set_file_mode(EditorFileDialog.FILE_MODE_SAVE_FILE)
	save_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	save_file_dialog.file_selected.connect(_on_save_file_selected)
	save_file_dialog.ok_button_text = "Save"
	save_file_dialog.size = Vector2i(550, 550)
	#save_file_dialog.transient = false
	#save_file_dialog.exclusive = false
	#save_file_dialog.popup_window = true
	
	open_file_dialog = EditorFileDialog.new()
	open_file_dialog.set_filters(PackedStringArray(
		["*.png", "*.bmp", "*.exr", "*.hdr", "*.jpg", "*.jpeg", "*.tga", "*.svg", "*.webp", "*.ktx", "*.dds"]))
	open_file_dialog.set_file_mode(EditorFileDialog.FILE_MODE_OPEN_FILE)
	open_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	open_file_dialog.ok_button_text = "Open"
	open_file_dialog.size = Vector2i(550, 550)
	#open_file_dialog.transient = false
	#open_file_dialog.exclusive = false
	#open_file_dialog.popup_window = true
	
	window.add_child(save_file_dialog)
	window.add_child(open_file_dialog)


func _init_texture_picker(p_parent: Node, p_image_index: int) -> void:
	var line_edit: LineEdit = p_parent.find_child("LineEdit") as LineEdit
	var file_pick_button: Button = p_parent.find_child("PickButton") as Button
	var clear_button: Button = p_parent.find_child("ClearButton") as Button
	var texture_rect: TextureRect = p_parent.find_child("TextureRect") as TextureRect
	var texture_button: Button = p_parent.find_child("TextureButton") as Button
	texture_button.set_script(load(DRAG_DROP_SCRIPT) as GDScript)
	
	var set_channel_fn: Callable = func(used_channels: int) -> void:
		var channel_count: int = 4
		# enum Image.UsedChannels
		match used_channels:
			Image.USED_CHANNELS_L, Image.USED_CHANNELS_R: channel_count = 1
			Image.USED_CHANNELS_LA, Image.USED_CHANNELS_RG: channel_count = 2
			Image.USED_CHANNELS_RGB: channel_count = 3
			Image.USED_CHANNELS_RGBA: channel_count = 4
		if p_image_index == IMAGE_HEIGHT:
			for i in 4:
				height_channel[i].visible = i < channel_count
			height_channel[0].button_pressed = true
			height_channel[0].pressed.emit()
		elif p_image_index == IMAGE_ROUGHNESS:
			for i in 4:
				roughness_channel[i].visible = i < channel_count
			roughness_channel[0].button_pressed = true
			roughness_channel[0].pressed.emit()
	
	var load_image_fn: Callable = func(path: String):
		var image: Image = Image.new()
		var error: int = OK
		# Special case for dds files
		if path.get_extension() == "dds":
			image = ResourceLoader.load(path).get_image()
			if not image.is_empty():
				# if the dds file is loaded, we must clear any mipmaps and
				# decompress if needed in order to do per pixel operations.
				image.clear_mipmaps()
				image.decompress()
			else:
				error = FAILED
		else:
			error = image.load(path)
		if error != OK:
			_show_message(ERROR, "Failed to load texture '" + path + "'")
			texture_rect.texture = null
			images[p_image_index] = null
		else:
			_show_message(INFO, "Loaded texture '" + path + "'")
			texture_rect.texture = ImageTexture.create_from_image(image)
			images[p_image_index] = image
			_set_wh_labels(p_image_index, image.get_width(), image.get_height())
			if p_image_index == IMAGE_NORMAL:
				_set_normal_vector(image)
			if p_image_index == IMAGE_HEIGHT or p_image_index == IMAGE_ROUGHNESS:
				set_channel_fn.call(image.detect_used_channels())
	
	var os_drop_fn: Callable = func(files: PackedStringArray) -> void:
		# OS drag drop holds mouse focus until released,
		# Get mouse pos and check directly if inside texture_rect
		var rect = texture_button.get_global_rect()
		var mouse_position = texture_button.get_global_mouse_position()
		if rect.has_point(mouse_position):
			if files.size() != 1:
				_show_message(ERROR, "Cannot load multiple files")
			else:
				line_edit.text = files[0]
				load_image_fn.call(files[0])
	
	var godot_drop_fn: Callable = func(path: String) -> void:
		path = ProjectSettings.globalize_path(path)
		line_edit.text = path
		load_image_fn.call(path)
	
	var open_fn: Callable = func() -> void:
		open_file_dialog.current_path = last_opened_directory
		if last_file_selected_fn != no_op:
			open_file_dialog.file_selected.disconnect(last_file_selected_fn)
		last_file_selected_fn = func(path: String) -> void: 
			line_edit.text = path
			load_image_fn.call(path)
		open_file_dialog.file_selected.connect(last_file_selected_fn)
		open_file_dialog.popup_centered_ratio()
	
	var line_edit_submit_fn: Callable = func(path: String) -> void:
		line_edit.text = path
		load_image_fn.call(path)
	
	var clear_fn: Callable = func() -> void:
		line_edit.text = ""
		texture_rect.texture = null
		images[p_image_index] = null
		_set_wh_labels(p_image_index, -1, -1)
	
	line_edit.text_submitted.connect(line_edit_submit_fn)
	file_pick_button.pressed.connect(open_fn)
	texture_button.pressed.connect(open_fn)
	clear_button.pressed.connect(clear_fn)
	texture_button.dropped.connect(godot_drop_fn)
	window.files_dropped.connect(os_drop_fn)
	
	if p_image_index == IMAGE_HEIGHT:
		var lumin_fn: Callable = func() -> void:
			if !images[IMAGE_ALBEDO]:
				_show_message(ERROR, "Albedo Image Required for Operation")
			else:
				line_edit.text = "Generated Height"
				var height_texture: Image = Terrain3DUtil.luminance_to_height(images[IMAGE_ALBEDO])
				if height_texture.is_empty():
					_show_message(ERROR, "Height Texture Generation error")
				# blur the image by resizing down and back..
				var w: int = height_texture.get_width()
				var h: int = height_texture.get_height()
				height_texture.resize(w / 4, h / 4)
				height_texture.resize(w, h, Image.INTERPOLATE_CUBIC)
				# "Load" the height texture
				images[IMAGE_HEIGHT] = height_texture
				texture_rect.texture = ImageTexture.create_from_image(images[IMAGE_HEIGHT])
				_set_wh_labels(IMAGE_HEIGHT, height_texture.get_width(), height_texture.get_height())
				set_channel_fn.call(Image.USED_CHANNELS_R)
				_show_message(INFO, "Height Texture generated sucsessfully")
		lumin_height_button.pressed.connect(lumin_fn)
	plugin.ui.set_button_editor_icon(file_pick_button, "Folder")
	plugin.ui.set_button_editor_icon(clear_button, "Remove")


func _set_wh_labels(p_image_index: int, width: int, height: int) -> void:
	var w: String = ""
	var h: String = ""
	if width > 0 and height > 0:
		w = "w: " + str(width)
		h = "h: " + str(height)
	match p_image_index:
		0:
			window.find_child("AlbedoW").text = w
			window.find_child("AlbedoH").text = h
		1:
			window.find_child("HeightW").text = w
			window.find_child("HeightH").text = h
		2:
			window.find_child("NormalW").text = w
			window.find_child("NormalH").text = h
		3:
			window.find_child("RoughnessW").text = w
			window.find_child("RoughnessH").text = h


func _show_message(p_level: int, p_text: String) -> void:
	status_label.text = p_text
	match p_level:
		INFO:
			print("Terrain3DChannelPacker: " + p_text)
			status_label.add_theme_color_override("font_color", Color(0, 0.82, 0.14))
		WARN:
			push_warning("Terrain3DChannelPacker: " + p_text)
			status_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0))
		ERROR,_:
			push_error("Terrain3DChannelPacker: " + p_text)
			status_label.add_theme_color_override("font_color", Color(0.9, 0, 0))


func _create_import_file(png_path: String) -> void:
	var dst_import_path: String = png_path + ".import"
	var file: FileAccess = FileAccess.open(TEMPLATE_PATH, FileAccess.READ)
	var template_content: String = file.get_as_text()
	file.close()
	template_content = template_content.replace(
		"$SOURCE_FILE", png_path).replace(
		"$HIGH_QUALITY", str(high_quality_checkbox.button_pressed)).replace(
		"$GENERATE_MIPMAPS", str(generate_mipmaps_checkbox.button_pressed)
	)
	var import_content: String = template_content
	file = FileAccess.open(dst_import_path, FileAccess.WRITE)
	file.store_string(import_content)
	file.close()


func _on_pack_button_pressed() -> void:
	packing_albedo = images[IMAGE_ALBEDO] != null and images[IMAGE_HEIGHT] != null
	var packing_normal_roughness: bool = images[IMAGE_NORMAL] != null and images[IMAGE_ROUGHNESS] != null
	
	if not packing_albedo and not packing_normal_roughness:
		_show_message(WARN, "Please select an albedo and height texture or a normal and roughness texture")
		return
	if packing_albedo:
		save_file_dialog.current_path = last_saved_directory + "packed_albedo_height"
		save_file_dialog.title = "Save Packed Albedo/Height Texture"
		save_file_dialog.popup_centered_ratio()
		if packing_normal_roughness:
			queue_pack_normal_roughness = true
		return
	if packing_normal_roughness:
		save_file_dialog.current_path = last_saved_directory + "packed_normal_roughness"
		save_file_dialog.title = "Save Packed Normal/Roughness Texture"
		save_file_dialog.popup_centered_ratio()


func _on_save_file_selected(p_dst_path) -> void:
	last_saved_directory = p_dst_path.get_base_dir() + "/"
	var error: int
	if packing_albedo:
		error = _pack_textures(images[IMAGE_ALBEDO], images[IMAGE_HEIGHT], p_dst_path, false,
		invert_height_checkbox.button_pressed, false, height_channel_selected)
	else:
		error = _pack_textures(images[IMAGE_NORMAL], images[IMAGE_ROUGHNESS], p_dst_path,
			invert_green_checkbox.button_pressed, invert_smooth_checkbox.button_pressed,
			align_normals_checkbox.button_pressed, roughness_channel_selected)
	
	if error == OK:
		EditorInterface.get_resource_filesystem().scan()
		if window.visible:
			window.hide()
		await EditorInterface.get_resource_filesystem().resources_reimported
		# wait 1 extra frame, to ensure the UI is responsive.
		await RenderingServer.frame_post_draw
		window.show()
	
	if queue_pack_normal_roughness:
		queue_pack_normal_roughness = false
		packing_albedo = false
		save_file_dialog.current_path = last_saved_directory + "packed_normal_roughness"
		save_file_dialog.title = "Save Packed Normal/Roughness Texture"
		
		save_file_dialog.call_deferred("popup_centered_ratio")
		save_file_dialog.call_deferred("grab_focus")


func _alignment_basis(normal: Vector3) -> Basis:
	var up: Vector3 = Vector3(0, 0, 1)
	var v: Vector3 = normal.cross(up)
	var c: float = normal.dot(up)
	var k: float = 1.0 / (1.0 + c)
	
	var vxy: float = v.x * v.y * k
	var vxz: float = v.x * v.z * k
	var vyz: float = v.y * v.z * k
	
	return Basis(Vector3(v.x * v.x * k + c, vxy - v.z, vxz + v.y),
		Vector3(vxy + v.z, v.y * v.y * k + c, vyz - v.x),
		Vector3(vxz - v.y, vyz + v.x, v.z * v.z * k + c)
	)


func _set_normal_vector(source: Image, quiet: bool = false) -> void:
	# Calculate texture normal sum direction
	var normal: Image = source
	var sum: Color = Color(0.0, 0.0, 0.0, 0.0)
	for x in normal.get_width():
		for y in normal.get_height():
			sum += normal.get_pixel(x, y)
	var div: float = normal.get_height() * normal.get_width()
	sum /= Color(div, div, div)
	sum *= 2.0
	sum -= Color(1.0, 1.0, 1.0)
	normal_vector = Vector3(sum.r, sum.g, sum.b).normalized()
	if normal_vector.dot(Vector3(0.0, 0.0, 1.0)) < 0.999 && !quiet:
		_show_message(WARN, "Normal Texture Not Orthoganol to UV plane.\nFor Compatability with Detiling and Rotation, Select Orthoganolize Normals")


func _align_normals(source: Image, iteration: int = 0) -> void:
	# generate matrix to re-align the normalmap
	var mat3: Basis = _alignment_basis(normal_vector)
	# re-align the normal map pixels
	for x in source.get_width():
		for y in source.get_height():
			var old_pixel: Color = source.get_pixel(x, y)
			var vector_pixel: Vector3 = Vector3(old_pixel.r, old_pixel.g, old_pixel.b)
			vector_pixel *= 2.0
			vector_pixel -= Vector3.ONE
			vector_pixel = vector_pixel.normalized()
			vector_pixel = vector_pixel * mat3
			vector_pixel += Vector3.ONE
			vector_pixel *= 0.5
			var new_pixel: Color = Color(vector_pixel.x, vector_pixel.y, vector_pixel.z, old_pixel.a)
			source.set_pixel(x, y, new_pixel)
	_set_normal_vector(source, true)
	if normal_vector.dot(Vector3(0.0, 0.0, 1.0)) < 0.999 && iteration < 3:
		++iteration
		_align_normals(source, iteration)


func _pack_textures(p_rgb_image: Image, p_a_image: Image, p_dst_path: String, p_invert_green: bool,
	p_invert_smooth: bool, p_align_normals : bool, p_alpha_channel: int) -> Error:
	if p_rgb_image and p_a_image:
		if p_rgb_image.get_size() != p_a_image.get_size() and !resize_toggle_checkbox.button_pressed:
			_show_message(ERROR, "Textures must be the same size.\nEnable resize to override image dimensions")
			return FAILED
	
		if resize_toggle_checkbox.button_pressed:
			var size: int = max(128, resize_option_box.value)
			p_rgb_image.resize(size, size, Image.INTERPOLATE_CUBIC)
			p_a_image.resize(size, size, Image.INTERPOLATE_CUBIC)
	
		if p_align_normals and normal_vector.dot(Vector3(0.0, 0.0, 1.0)) < 0.999:
			_align_normals(p_rgb_image)
		elif p_align_normals:
			_show_message(INFO, "Alignment OK, skipping Normal Orthogonalization")
	
		var output_image: Image = Terrain3DUtil.pack_image(p_rgb_image, p_a_image,
			p_invert_green, p_invert_smooth, p_alpha_channel)
	
		if not output_image:
			_show_message(ERROR, "Failed to pack textures")
			return FAILED
		if output_image.detect_alpha() != Image.ALPHA_BLEND:
			_show_message(WARN, "Warning, Alpha channel empty")

		output_image.save_png(p_dst_path)
		_create_import_file(p_dst_path)
		_show_message(INFO, "Packed to " + p_dst_path + ".")
		return OK
	else:
		_show_message(ERROR, "Failed to load one or more textures")
		return FAILED
