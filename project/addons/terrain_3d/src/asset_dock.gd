# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock for Terrain3D
@tool
extends PanelContainer

signal confirmation_closed
signal confirmation_confirmed
signal confirmation_canceled

const ES_DOCK_TILE_SIZE: String = "terrain3d/dock/tile_size"
const ES_DOCK_PINNED: String = "terrain3d/dock/always_on_top"
const ES_DOCK_TAB: String = "terrain3d/dock/tab"

var texture_list: Terrain3DListContainer
var mesh_list: Terrain3DListContainer
var current_list: Terrain3DListContainer
var _updating_list: bool

var pinned_btn: Button
var size_slider: HSlider
var box: BoxContainer
var buttons: BoxContainer
var textures_btn: Button
var meshes_btn: Button
var asset_container: ScrollContainer
var confirm_dialog: ConfirmationDialog
var _confirmed: bool = false
var search_box: TextEdit
var search_button: Button

#DEPRECATED 4.5
#class EdDock extends EditorDock:
	#func _update_layout(layout: int) -> void:
		#layout 1 vertical, 2 horizontal, 4 window
		#print("Terrain3DAssetDock: _update_layout called with: ", layout)

var _dock: MarginContainer #DEPRECATED 4.5 - Use EdDock
var _initialized: bool = false
var plugin: EditorPlugin
var window: Window


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		await get_tree().process_frame
		update_layout()
		
		
func initialize(p_plugin: EditorPlugin) -> void:
	if p_plugin:
		plugin = p_plugin

	_dock = ClassDB.instantiate("EditorDock") #DEPRECATED 4.5 - EdDock.new()
	_dock.title = "Terrain3D"
	_dock.dock_icon = preload("../icons/terrain3d.svg")
	_dock.default_slot = 8 #DEPRECATED 4.5 - EditorDock.DockSlot.DOCK_SLOT_BOTTOM
	_dock.closable = false
	_dock.available_layouts = 0x7 #DEPRECATED 4.5 - EditorDock.DOCK_LAYOUT_ALL
	_dock.add_child(self)
	plugin.add_dock(_dock)
	_dock.open()
	_dock.make_visible()

	pinned_btn = $Box/Buttons/Pinned
	size_slider = $Box/Buttons/SizeSlider
	size_slider.owner = null
	box = $Box
	buttons = $Box/Buttons
	textures_btn = $Box/Buttons/TexturesBtn
	meshes_btn = $Box/Buttons/MeshesBtn
	asset_container = $Box/ScrollContainer
	search_box = $Box/Buttons/SearchBox
	search_box.owner = null
	# Scale left column width to editor scale
	var editor_scale: float = EditorInterface.get_editor_scale()
	search_box.custom_minimum_size = Vector2(100. * editor_scale, 30. * editor_scale)
	search_button = $Box/Buttons/SearchBox/SearchButton
	
	texture_list = Terrain3DListContainer.new()
	texture_list.name = "TextureList"
	texture_list.plugin = plugin
	texture_list.type = Terrain3DAssets.TYPE_TEXTURE
	asset_container.add_child(texture_list, true)
	mesh_list = Terrain3DListContainer.new()
	mesh_list.name = "MeshList"
	mesh_list.plugin = plugin
	mesh_list.type = Terrain3DAssets.TYPE_MESH
	mesh_list.visible = false
	mesh_list.selected_list_size_changed.connect(_on_mesh_selection_changed)
	asset_container.add_child(mesh_list, true)
	current_list = texture_list

	load_editor_settings()

	# Connect signals
	resized.connect(update_layout)
	textures_btn.pressed.connect(_on_textures_pressed)
	meshes_btn.pressed.connect(_on_meshes_pressed)
	pinned_btn.toggled.connect(_on_pin_changed)
	pinned_btn.owner = null
	size_slider.value_changed.connect(_on_slider_changed)
	plugin.ui.toolbar.tool_changed.connect(_on_tool_changed)

	meshes_btn.add_theme_font_size_override("font_size", int(16. * EditorInterface.get_editor_scale()))
	textures_btn.add_theme_font_size_override("font_size", int(16. * EditorInterface.get_editor_scale()))

	search_box.text_changed.connect(_on_search_text_changed)
	search_button.pressed.connect(_on_search_button_pressed)
	
	confirm_dialog = ConfirmationDialog.new()
	add_child(confirm_dialog, true)
	confirm_dialog.hide()
	confirm_dialog.confirmed.connect(func(): _confirmed = true; \
		confirmation_closed.emit(); \
		confirmation_confirmed.emit() )
	confirm_dialog.canceled.connect(func(): _confirmed = false; \
		confirmation_closed.emit(); \
		confirmation_canceled.emit() )

	# Setup styles
	set("theme_override_styles/panel", get_theme_stylebox("panel", "Panel"))
	# Avoid saving icon resources in tscn when editing w/ a tool script
	if EditorInterface.get_edited_scene_root() != self:
		pinned_btn.icon = get_theme_icon("Pin", "EditorIcons")
		pinned_btn.text = ""
		search_button.icon = get_theme_icon("Search", "EditorIcons")

	_initialized = true
	update_dock()
	update_layout()


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		if search_box.has_focus():
			if plugin.debug:
				print("Terrain3DAssetDock: _on_box_gui_input: search_box releasing focus")
			search_box.release_focus()


## Dock placement


func remove_dock(p_force: bool = false) -> void:
	plugin.remove_dock(_dock)
	# plugin.remove_dock() only unregisters _dock; it was created here via
	# ClassDB.instantiate() and is owned by this script, not the scene tree.
	# Without an explicit free it leaks at editor shutdown along with its
	# dock_icon (terrain3d.svg) and the backing Texture + CanvasItem RIDs.
	# `self` is a child of _dock, so detach before freeing (editor_plugin.gd
	# still queue_free()s `self` afterward).
	if is_instance_valid(_dock):
		if get_parent() == _dock:
			_dock.remove_child(self)
		_dock.free()
		_dock = null


func update_dock() -> void:
	if not _initialized:
		return
	update_assets()
	_dock.make_visible()


func update_layout() -> void:
	if not _initialized:
		return
	if plugin.debug > 1:
		print("Terrain3DAssetDock: update_layout")	

	## Detect if we have a new window from `Make floating` and grab it
	if not window:
		if get_parent().get_parent().get_parent() is Window:
			window = get_parent().get_parent().get_parent()
			_on_pin_changed(pinned_btn.button_pressed)
			plugin.godot_editor_window.mouse_entered.connect(_on_godot_window_entered)
			return # Displaying will call this function again
		# Check if window was just freed. Freed objects have a different hash than null
		elif hash(window) != hash(null):
			window = null
			plugin.godot_editor_window.mouse_entered.disconnect(_on_godot_window_entered)
			return # Will call this function again upon display

	## Vertical layout: buttons on top
	if size.x < 700:
		box.vertical = true
		buttons.vertical = false
		search_box.reparent(box)
		box.move_child(search_box, 1)
		size_slider.reparent(box)
		box.move_child(size_slider, 2)
		pinned_btn.reparent(buttons)
	else:
	# Wide layout: buttons on left
		box.vertical = false
		buttons.vertical = true
		search_box.reparent(buttons)
		buttons.move_child(search_box, 0)
		size_slider.reparent(buttons)
		buttons.move_child(size_slider, 3)
		pinned_btn.reparent(box)

	pinned_btn.visible = is_instance_valid(window)
	save_editor_settings()


# When a floating asset dock has focus and the mouse returns, grab focus so cursor decal works
func _on_godot_window_entered() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_window_entered")
	if is_instance_valid(window) and window.has_focus():
		plugin.godot_editor_window.grab_focus()
	
	
func _on_search_text_changed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_search_text_changed: ", search_box.text)
	search_box.text = search_box.text.strip_escapes()
	var len: int = search_box.text.length()
	if len > 0:
		search_box.set_caret_column(len)
		search_button.icon = get_theme_icon("Close", "EditorIcons")
	else:
		search_button.icon = get_theme_icon("Search", "EditorIcons")
		
	mesh_list.search_text = search_box.text
	texture_list.search_text = search_box.text
	current_list.update_list_entries()


func _on_search_button_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_search_button_pressed")
	if search_box.text.length() > 0:
		search_box.text = ""
		_on_search_text_changed()
	else:
		if plugin.debug:
			print("Terrain3DAssetDock: _on_search_button_pressed: Search box grabbing focus")
		search_box.grab_focus()


## Dock Button handlers


func _on_pin_changed(toggled: bool) -> void:
	if window:
		window.always_on_top = pinned_btn.button_pressed
	save_editor_settings()


func _on_slider_changed(value: float) -> void:
	# Set both lists so they match
	if texture_list:
		texture_list.set_entry_width(value)
	if mesh_list:
		mesh_list.set_entry_width(value)
	save_editor_settings()
	# Hack to trigger ScrollContainer::_reposition_children() to update size of scroll bar handle
	asset_container.layout_direction = Control.LAYOUT_DIRECTION_LTR
	asset_container.layout_direction = Control.LAYOUT_DIRECTION_INHERITED


func _on_textures_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_textures_pressed")
	plugin.ui.toolbar.change_tool("PaintTexture")


func _on_meshes_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_meshes_pressed")
	plugin.ui.toolbar.change_tool("InstanceMeshes")

	
func set_dock_mode(tool: Terrain3DEditor.Tool) -> void:
	var mesh_mode: bool = tool == Terrain3DEditor.Tool.INSTANCER
	if not mesh_mode and tool != Terrain3DEditor.Tool.TEXTURE:
		return
	var list_to_set: Terrain3DListContainer = mesh_list if mesh_mode else texture_list
	if _updating_list or current_list == list_to_set:
		return
	_updating_list = true
	current_list = list_to_set
	mesh_list.visible = mesh_mode
	texture_list.visible = !mesh_mode
	meshes_btn.set_pressed_no_signal(mesh_mode)
	textures_btn.set_pressed_no_signal(!mesh_mode)
	current_list.update_asset_list()
	if plugin.is_terrain_valid():
		EditorInterface.edit_node(plugin.terrain)
	save_editor_settings()
	_updating_list = false
	

func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_tool_changed: ", p_tool, ", ", p_operation)
	mesh_list.remove_all_highlights()
	texture_list.remove_all_highlights()
	set_dock_mode(p_tool)


## Update Dock Contents


func _on_mesh_selection_changed(count: int) -> void:
	if not meshes_btn:
		return
	meshes_btn.text = "Meshes"
	meshes_btn.text += " (%s)" % count if count >=2 else ""


func update_assets() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: update_assets: ", plugin.terrain.assets if plugin.terrain else "")
	if not _initialized:
		return
	
	# Verify signals to individual lists
	if plugin.is_terrain_valid() and plugin.terrain.assets:
		if not plugin.terrain.assets.textures_changed.is_connected(texture_list.update_asset_list):
			plugin.terrain.assets.textures_changed.connect(texture_list.update_asset_list)
		if not plugin.terrain.assets.meshes_changed.is_connected(mesh_list.update_asset_list):
			plugin.terrain.assets.meshes_changed.connect(mesh_list.update_asset_list)
		if not plugin.terrain.assets.ids_swapped.is_connected(mesh_list.set_selected_after_swap):
			plugin.terrain.assets.ids_swapped.connect(mesh_list.set_selected_after_swap)
		if not plugin.terrain.assets.ids_swapped.is_connected(texture_list.set_selected_after_swap):
			plugin.terrain.assets.ids_swapped.connect(texture_list.set_selected_after_swap)
	current_list.update_asset_list()


## Manage Editor Settings


func load_editor_settings() -> void:
	# Remove old editor settings
	const ES_DOCK: String = "terrain3d/dock/"
	for setting in [ "slot", "floating", "window_position", "window_size" ]:
		plugin.erase_setting(ES_DOCK + setting)
	pinned_btn.button_pressed = plugin.get_setting(ES_DOCK_PINNED, true)
	size_slider.value = plugin.get_setting(ES_DOCK_TILE_SIZE, 90)
	_on_slider_changed(size_slider.value)
	# TODO Don't save tab until thumbnail generation more reliable
	#if plugin.get_setting(ES_DOCK_TAB, 0) == 1:
	#	_on_meshes_pressed()


func save_editor_settings() -> void:
	if not _initialized:
		return
	plugin.set_setting(ES_DOCK_TILE_SIZE, size_slider.value)
	plugin.set_setting(ES_DOCK_PINNED, pinned_btn.button_pressed)
	# TODO Don't save tab until thumbnail generation more reliable
	# plugin.set_setting(ES_DOCK_TAB, 0 if current_list == texture_list else 1)
