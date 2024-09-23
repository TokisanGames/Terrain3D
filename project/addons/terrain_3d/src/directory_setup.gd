extends Node

const DIRECTORY_SETUP: String = "res://addons/terrain_3d/src/directory_setup.tscn"

var plugin: EditorPlugin
var dialog: ConfirmationDialog
var select_dir_btn: Button
var selected_dir_le: LineEdit
var select_upg_btn: Button
var upgrade_file_le: LineEdit
var editor_file_dialog: EditorFileDialog


func _init() -> void:
	editor_file_dialog = EditorFileDialog.new()
	editor_file_dialog.set_filters(PackedStringArray(["*.res"]))
	editor_file_dialog.set_file_mode(EditorFileDialog.FILE_MODE_SAVE_FILE)
	editor_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	editor_file_dialog.ok_button_text = "Open"
	editor_file_dialog.title = "Open a folder or file"
	editor_file_dialog.file_selected.connect(_on_file_selected)
	editor_file_dialog.dir_selected.connect(_on_dir_selected)
	editor_file_dialog.size = Vector2i(850, 550)
	editor_file_dialog.transient = false
	editor_file_dialog.exclusive = false
	editor_file_dialog.popup_window = true
	add_child(editor_file_dialog)


func directory_setup_popup() -> void:
	dialog = load(DIRECTORY_SETUP).instantiate()
	dialog.hide()
	
	# Nodes
	select_dir_btn = dialog.get_node("Margin/VBox/DirHBox/SelectDir")
	selected_dir_le = dialog.get_node("Margin/VBox/DirHBox/LineEdit")
	select_upg_btn = dialog.get_node("Margin/VBox/UpgradeHBox/SelectResFile")
	upgrade_file_le = dialog.get_node("Margin/VBox/UpgradeHBox/LineEdit")
	upgrade_file_le.text = ""

	if plugin.terrain.data_directory:
		selected_dir_le.text = plugin.terrain.data_directory
		
	if plugin.terrain.storage:
		upgrade_file_le.text = plugin.terrain.storage.get_path()

	# Icons
	plugin.ui.set_button_editor_icon(select_upg_btn, "Folder")
	plugin.ui.set_button_editor_icon(select_dir_btn, "Folder")
	
	#Signals
	select_upg_btn.pressed.connect(_on_select_file_pressed.bind(EditorFileDialog.FILE_MODE_OPEN_FILE))
	select_dir_btn.pressed.connect(_on_select_file_pressed.bind(EditorFileDialog.FILE_MODE_OPEN_DIR))
	dialog.confirmed.connect(_on_close_requested)
	dialog.canceled.connect(_on_close_requested)
	dialog.get_ok_button().pressed.connect(_on_ok_pressed)

	# Popup
	EditorInterface.popup_dialog_centered(dialog)


func _on_close_requested() -> void:
	dialog.queue_free()
	dialog = null


func _on_select_file_pressed(file_mode: EditorFileDialog.FileMode) -> void:
	editor_file_dialog.file_mode = file_mode
	editor_file_dialog.popup_centered()


func _on_dir_selected(path: String) -> void:
	selected_dir_le.text = path


func _on_file_selected(path: String) -> void:
	upgrade_file_le.text = path


func _on_ok_pressed() -> void:
	if not plugin.terrain:
		push_error("Not connected terrain. Click the Terrain3D node first")
		return
	if selected_dir_le.text.is_empty():
		push_error("No data directory specified")
		return
	if not DirAccess.dir_exists_absolute(selected_dir_le.text):
		push_error("Directory doesn't exist: ", selected_dir_le.text)
		return
	# Check if directory empty of terrain files		
	var data_found: bool = false
	var files: Array = DirAccess.get_files_at(selected_dir_le.text)
	for file in files:
		if file.begins_with("terrain3d") || file.ends_with(".res"):
			data_found = true
			break

	print("Setting terrain directory: ", selected_dir_le.text)
	plugin.terrain.data_directory = selected_dir_le.text

	if not upgrade_file_le.text.is_empty():	
		if data_found:
			push_warning("Target directory already has terrain data. Specify an empty directory to upgrade")
			return
		if not FileAccess.file_exists(upgrade_file_le.text):
			push_error("File doesn't exist: ", upgrade_file_le.text)
			return	

		if not plugin.terrain.storage or \
			( plugin.terrain.storage and plugin.terrain.storage.get_path() != upgrade_file_le.text):
				print("Loading storage file: ", upgrade_file_le.text)
				plugin.terrain.set_storage(load(upgrade_file_le.text))
		
		if plugin.terrain.storage:
			print("Begining upgrade of: ", upgrade_file_le.text)
			plugin.terrain.split_storage()
