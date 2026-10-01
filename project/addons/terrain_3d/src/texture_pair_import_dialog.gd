# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Bulk albedo/normal texture pair import dialog for Terrain3D
@tool
extends ConfirmationDialog
class_name Terrain3DTexturePairImportDialog

var plugin: EditorPlugin

var _pending_albedo_files: PackedStringArray = []
var _pending_normal_files: PackedStringArray = []
var _rows: Array[Dictionary] = []
var _rows_box: VBoxContainer
var _open_file_dialog: EditorFileDialog
var _edit_row_index: int = -1
var _edit_row_side: String = ""


func _init() -> void:
	title = "Import Texture Pairs"
	min_size = Vector2i(560, 420)
	# Non-modal: let the user drag files in from the FileSystem dock while this is open
	exclusive = false
	transient = false
	always_on_top = true
	confirmed.connect(_on_import)
	canceled.connect(queue_free)
	close_requested.connect(queue_free)
	_build_ui()


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vbox)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 12)
	vbox.add_child(columns)
	columns.add_child(_build_column("Albedo", _on_albedo_dropped))
	columns.add_child(_build_column("Normal", _on_normal_dropped))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 220)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)

	var row_actions := HBoxContainer.new()
	vbox.add_child(row_actions)
	var add_row_btn := Button.new()
	add_row_btn.text = "+ Add Row"
	add_row_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row_btn.pressed.connect(_on_add_row_pressed)
	row_actions.add_child(add_row_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear List"
	clear_btn.tooltip_text = "Remove all rows"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(_on_clear_pressed)
	row_actions.add_child(clear_btn)

	var image_filters: PackedStringArray = []
	for ext in Terrain3DTexturePairMatcher.IMAGE_EXTENSIONS:
		image_filters.append("*." + ext)

	_open_file_dialog = EditorFileDialog.new()
	_open_file_dialog.set_filters(image_filters)
	_open_file_dialog.set_file_mode(EditorFileDialog.FILE_MODE_OPEN_FILE)
	_open_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_open_file_dialog.file_selected.connect(_on_file_picked)
	add_child(_open_file_dialog)

	get_ok_button().text = "Import"
	get_ok_button().disabled = true


func _build_column(p_title: String, p_dropped_callback: Callable) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = p_title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(label)
	var drop_zone := DropZone.new()
	drop_zone.text = "Drop %s images here" % p_title
	drop_zone.custom_minimum_size = Vector2(0, 60)
	drop_zone.files_dropped.connect(p_dropped_callback)
	col.add_child(drop_zone)
	return col


func _on_albedo_dropped(p_files: PackedStringArray) -> void:
	for file in p_files:
		if not _pending_albedo_files.has(file):
			_pending_albedo_files.append(file)
	_rebuild_rows()


func _on_normal_dropped(p_files: PackedStringArray) -> void:
	for file in p_files:
		if not _pending_normal_files.has(file):
			_pending_normal_files.append(file)
	_rebuild_rows()


func _rebuild_rows() -> void:
	_rows = Terrain3DTexturePairMatcher.pair_lists(_pending_albedo_files, _pending_normal_files)
	_refresh_rows_ui()


func _refresh_rows_ui() -> void:
	for child in _rows_box.get_children():
		child.queue_free()
	for i in _rows.size():
		_rows_box.add_child(_build_row(i))
	get_ok_button().disabled = not _has_valid_row()


func _has_valid_row() -> bool:
	for row in _rows:
		if row.albedo != "":
			return true
	return false


func _build_row(p_index: int) -> HBoxContainer:
	var row: Dictionary = _rows[p_index]
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var albedo_label := Label.new()
	albedo_label.text = row.albedo.get_file() if row.albedo != "" else "(choose albedo)"
	albedo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	albedo_label.clip_text = true
	if row.albedo == "":
		albedo_label.modulate = Color(1., 1., 1., .5)
	hbox.add_child(albedo_label)

	var albedo_change := Button.new()
	albedo_change.text = "Change"
	albedo_change.pressed.connect(_on_change_pressed.bind(p_index, "albedo"))
	hbox.add_child(albedo_change)

	var arrow := Label.new()
	arrow.text = "  →  "
	hbox.add_child(arrow)

	var normal_label := Label.new()
	normal_label.text = row.normal.get_file() if row.normal != "" else "(none)"
	normal_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	normal_label.clip_text = true
	if row.normal == "":
		normal_label.modulate = Color(1., 1., 1., .5)
	hbox.add_child(normal_label)

	var normal_change := Button.new()
	normal_change.text = "Change"
	normal_change.pressed.connect(_on_change_pressed.bind(p_index, "normal"))
	hbox.add_child(normal_change)

	var remove_btn := Button.new()
	remove_btn.text = "x"
	remove_btn.tooltip_text = "Remove row"
	remove_btn.pressed.connect(_on_remove_row.bind(p_index))
	hbox.add_child(remove_btn)

	return hbox


func _on_add_row_pressed() -> void:
	_rows.push_back({ "albedo": "", "normal": "" })
	_refresh_rows_ui()


func _on_clear_pressed() -> void:
	_pending_albedo_files.clear()
	_pending_normal_files.clear()
	_rows.clear()
	_refresh_rows_ui()


func _on_change_pressed(p_index: int, p_side: String) -> void:
	_edit_row_index = p_index
	_edit_row_side = p_side
	_open_file_dialog.popup_centered()


func _on_file_picked(p_path: String) -> void:
	if _edit_row_index >= 0 and _edit_row_index < _rows.size():
		_rows[_edit_row_index][_edit_row_side] = p_path
		if _edit_row_side == "albedo" and not _pending_albedo_files.has(p_path):
			_pending_albedo_files.append(p_path)
		elif _edit_row_side == "normal" and not _pending_normal_files.has(p_path):
			_pending_normal_files.append(p_path)
	_edit_row_index = -1
	_edit_row_side = ""
	_refresh_rows_ui()


func _on_remove_row(p_index: int) -> void:
	if p_index >= 0 and p_index < _rows.size():
		_rows.remove_at(p_index)
		_refresh_rows_ui()


func _on_import() -> void:
	var new_assets: Array[Terrain3DTextureAsset] = []
	for row in _rows:
		if row.albedo == "":
			continue
		var albedo_res: Resource = load(row.albedo)
		if not (albedo_res is Texture2D):
			continue
		var ta := Terrain3DTextureAsset.new()
		ta.set_albedo_texture(albedo_res)
		if row.normal != "":
			var normal_res: Resource = load(row.normal)
			if normal_res is Texture2D:
				ta.set_normal_texture(normal_res)
		new_assets.push_back(ta)
	if not new_assets.is_empty() and plugin and plugin.asset_dock:
		plugin.asset_dock.texture_list.add_assets_bulk(new_assets)
	queue_free()


##############################################################
## class DropZone
##############################################################


class DropZone extends Button:
	signal files_dropped(files: PackedStringArray)


	func _can_drop_data(p_at_position: Vector2, p_data: Variant) -> bool:
		if typeof(p_data) == TYPE_DICTIONARY and p_data.has("files"):
			for file in p_data.files:
				if Terrain3DTexturePairMatcher.IMAGE_EXTENSIONS.has(file.get_extension().to_lower()):
					return true
		return false


	func _drop_data(p_at_position: Vector2, p_data: Variant) -> void:
		var files: PackedStringArray = []
		for file in p_data.files:
			if Terrain3DTexturePairMatcher.IMAGE_EXTENSIONS.has(file.get_extension().to_lower()):
				files.append(file)
		if not files.is_empty():
			files_dropped.emit(files)