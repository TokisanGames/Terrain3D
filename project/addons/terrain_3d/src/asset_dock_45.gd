# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock for Terrain3D
@tool
extends PanelContainer

signal confirmation_closed
signal confirmation_confirmed
signal confirmation_canceled

const ES_DOCK_SLOT: String = "terrain3d/dock/slot"
const ES_DOCK_TILE_SIZE: String = "terrain3d/dock/tile_size"
const ES_DOCK_FLOATING: String = "terrain3d/dock/floating"
const ES_DOCK_PINNED: String = "terrain3d/dock/always_on_top"
const ES_DOCK_WINDOW_POSITION: String = "terrain3d/dock/window_position"
const ES_DOCK_WINDOW_SIZE: String = "terrain3d/dock/window_size"
const ES_DOCK_TAB: String = "terrain3d/dock/tab"

var texture_list: Terrain3DListContainer
var mesh_list: Terrain3DListContainer
var current_list: Terrain3DListContainer
var _updating_list: bool

var placement_opt: OptionButton
var floating_btn: Button
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

# Used only for editor, so change to single visible/hiddden
enum {
	HIDDEN = -1,
	SIDEBAR = 0,
	BOTTOM = 1,
	WINDOWED = 2,
}
var state: int = HIDDEN

enum {
	POS_LEFT_UL = 0,
	POS_LEFT_BL = 1,
	POS_LEFT_UR = 2,
	POS_LEFT_BR = 3,
	POS_RIGHT_UL = 4,
	POS_RIGHT_BL = 5,
	POS_RIGHT_UR = 6,
	POS_RIGHT_BR = 7,
	POS_BOTTOM = 8,
	POS_MAX = 9,
}
var slot: int = POS_RIGHT_BR
var _initialized: bool = false
var plugin: EditorPlugin
var window: Window
var _godot_last_state: Window.Mode = Window.MODE_FULLSCREEN


func initialize(p_plugin: EditorPlugin) -> void:
	if p_plugin:
		plugin = p_plugin
	
	_godot_last_state = plugin.godot_editor_window.mode
	placement_opt = $Box/Buttons/PlacementOpt
	pinned_btn = $Box/Buttons/Pinned
	floating_btn = $Box/Buttons/Floating
	floating_btn.owner = null # Godot complains about buttons that are reparented
	size_slider = $Box/Buttons/SizeSlider
	size_slider.owner = null
	box = $Box
	buttons = $Box/Buttons
	textures_btn = $Box/Buttons/TexturesBtn
	meshes_btn = $Box/Buttons/MeshesBtn
	asset_container = $Box/ScrollContainer
	search_box = $Box/Buttons/SearchBox
	search_box.owner = null
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
	placement_opt.item_selected.connect(set_slot)
	floating_btn.pressed.connect(make_dock_float)
	pinned_btn.toggled.connect(_on_pin_changed)
	pinned_btn.visible = ( window != null )
	pinned_btn.owner = null
	size_slider.value_changed.connect(_on_slider_changed)
	plugin.ui.toolbar.tool_changed.connect(_on_tool_changed)

	meshes_btn.add_theme_font_size_override("font_size", 16 * EditorInterface.get_editor_scale())
	textures_btn.add_theme_font_size_override("font_size", 16 * EditorInterface.get_editor_scale())

	_initialized = true
	update_dock()
	update_layout()


func _ready() -> void:
	if not _initialized:
		return
		
	# Setup styles
	set("theme_override_styles/panel", get_theme_stylebox("panel", "Panel"))
	# Avoid saving icon resources in tscn when editing w/ a tool script
	if EditorInterface.get_edited_scene_root() != self:
		pinned_btn.icon = get_theme_icon("Pin", "EditorIcons")
		pinned_btn.text = ""
		floating_btn.icon = get_theme_icon("MakeFloating", "EditorIcons")
		floating_btn.text = ""
		search_button.icon = get_theme_icon("Search", "EditorIcons")
	
	search_box.text_changed.connect(_on_search_text_changed)
	search_button.pressed.connect(_on_search_button_pressed)
	
	confirm_dialog = ConfirmationDialog.new()
	add_child(confirm_dialog, true)
	confirm_dialog.hide()
	confirm_dialog.confirmed.connect(func(): _confirmed = true; \
		emit_signal("confirmation_closed"); \
		emit_signal("confirmation_confirmed") )
	confirm_dialog.canceled.connect(func(): _confirmed = false; \
		emit_signal("confirmation_closed"); \
		emit_signal("confirmation_canceled") )


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		if search_box.has_focus():
			if plugin.debug:
				print("Terrain3DAssetDock: _on_box_gui_input: search_box releasing focus")
			search_box.release_focus()


## Dock placement


func set_slot(p_slot: int) -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: set_slot: ", p_slot)
	p_slot = clamp(p_slot, 0, POS_MAX-1)
	
	if slot != p_slot:
		slot = p_slot
		placement_opt.selected = slot
		save_editor_settings()
		plugin.select_terrain()
		update_dock()


func remove_dock(p_force: bool = false) -> void:
	if state == SIDEBAR:
		plugin.remove_control_from_docks(self)
		state = HIDDEN

	elif state == BOTTOM:
		plugin.remove_control_from_bottom_panel(self)
		state = HIDDEN

	# If windowed and destination is not window or final exit, otherwise leave
	elif state == WINDOWED and p_force and window:
		var parent: Node = get_parent()
		if parent:
			parent.remove_child(self)
		plugin.godot_editor_window.mouse_entered.disconnect(_on_godot_window_entered)
		plugin.godot_editor_window.focus_entered.disconnect(_on_godot_focus_entered)
		plugin.godot_editor_window.focus_exited.disconnect(_on_godot_focus_exited)
		window.hide()
		window.queue_free()
		window = null
		floating_btn.button_pressed = false
		floating_btn.visible = true
		pinned_btn.visible = false
		placement_opt.visible = true
		state = HIDDEN
		update_dock() # return window to side/bottom


func update_dock() -> void:
	if not _initialized or window:
		return

	update_assets()

	# Move dock to new destination
	remove_dock()
	# Sidebar
	if slot < POS_BOTTOM:
		state = SIDEBAR
		plugin.add_control_to_dock(slot, self)
	# Bottom
	elif slot == POS_BOTTOM:
		state = BOTTOM
		plugin.add_control_to_bottom_panel(self, "Terrain3D")
		plugin.make_bottom_panel_item_visible(self)


func update_layout() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: update_layout")	
	if not _initialized:
		return

	# Detect if we have a new window from Make floating, grab it so we can free it properly
	if not window and get_parent() and get_parent().get_parent() is Window:
		window = get_parent().get_parent()
		make_dock_float()
		return # Will call this function again upon display

	# Vertical layout: buttons on top
	if size.x < 500 or ( not window and slot < POS_BOTTOM ):
		box.vertical = true
		buttons.vertical = false
		search_box.reparent(box)
		box.move_child(search_box, 1)
		size_slider.reparent(box)
		box.move_child(size_slider, 2)
		floating_btn.reparent(buttons)
		pinned_btn.reparent(buttons)
	else:
	# Wide layout: buttons on left
		box.vertical = false
		buttons.vertical = true
		search_box.reparent(buttons)
		buttons.move_child(search_box, 0)
		size_slider.reparent(buttons)
		buttons.move_child(size_slider, 4)
		floating_btn.reparent(box)
		pinned_btn.reparent(box)

	save_editor_settings()


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


## Window Management


func make_dock_float() -> void:
	# If not already created (eg from editor panel 'Make Floating' button)	
	if not window:
		remove_dock()
		create_window()

	state = WINDOWED
	visible = true # Asset dock contents are hidden when popping out of the bottom!
	pinned_btn.visible = true
	floating_btn.visible = false
	placement_opt.visible = false
	window.title = "Terrain3D Asset Dock"
	window.always_on_top = pinned_btn.button_pressed
	window.close_requested.connect(remove_dock.bind(true))
	window.window_input.connect(_on_window_input)
	window.focus_exited.connect(save_editor_settings)
	window.mouse_exited.connect(save_editor_settings)
	window.size_changed.connect(save_editor_settings)
	plugin.godot_editor_window.mouse_entered.connect(_on_godot_window_entered)
	plugin.godot_editor_window.focus_entered.connect(_on_godot_focus_entered)
	plugin.godot_editor_window.focus_exited.connect(_on_godot_focus_exited)
	plugin.godot_editor_window.grab_focus()
	update_assets()
	save_editor_settings()


func create_window() -> void:
	window = Window.new()
	window.wrap_controls = true
	var mc := MarginContainer.new()
	mc.set_anchors_preset(PRESET_FULL_RECT, false)
	mc.add_child(self, true)
	window.add_child(mc, true)
	window.set_transient(false)
	window.set_size(plugin.get_setting(ES_DOCK_WINDOW_SIZE, Vector2i(512, 512)))
	window.set_position(plugin.get_setting(ES_DOCK_WINDOW_POSITION, Vector2i(704, 284)))
	plugin.add_child(window, true)
	window.show()


func clamp_window_position() -> void:
	if window and window.visible:
		var bounds: Vector2i
		if EditorInterface.get_editor_settings().get_setting("interface/editor/single_window_mode"):
			bounds = EditorInterface.get_base_control().size
		else:
			bounds = DisplayServer.screen_get_position(window.current_screen)
			bounds += DisplayServer.screen_get_size(window.current_screen)
		var margin: int = 40
		window.position.x = clamp(window.position.x, -window.size.x + 2*margin, bounds.x - margin)
		window.position.y = clamp(window.position.y, 25, bounds.y - margin)


func _on_window_input(event: InputEvent) -> void:
	# Capture CTRL+S when doc focused to save scene
	if event is InputEventKey and event.keycode == KEY_S and event.pressed and event.is_command_or_control_pressed():
		save_editor_settings()
		EditorInterface.save_scene()


func _on_godot_window_entered() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_window_entered")
	if is_instance_valid(window) and window.has_focus():
		plugin.godot_editor_window.grab_focus()


func _on_godot_focus_entered() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_focus_entered")
	# If asset dock is windowed, and Godot was minimized, and now is not, restore asset dock window
	if is_instance_valid(window):
		if _godot_last_state == Window.MODE_MINIMIZED and plugin.godot_editor_window.mode != Window.MODE_MINIMIZED:
			window.show()
			_godot_last_state = plugin.godot_editor_window.mode
			plugin.godot_editor_window.grab_focus()


func _on_godot_focus_exited() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_focus_exited")
	if is_instance_valid(window) and plugin.godot_editor_window.mode == Window.MODE_MINIMIZED:
		window.hide()
		_godot_last_state = plugin.godot_editor_window.mode


## Manage Editor Settings


func load_editor_settings() -> void:
	floating_btn.button_pressed = plugin.get_setting(ES_DOCK_FLOATING, false)
	pinned_btn.button_pressed = plugin.get_setting(ES_DOCK_PINNED, true)
	size_slider.value = plugin.get_setting(ES_DOCK_TILE_SIZE, 90)
	_on_slider_changed(size_slider.value)
	set_slot(plugin.get_setting(ES_DOCK_SLOT, POS_BOTTOM))
	if floating_btn.button_pressed:
		make_dock_float()
	# TODO Don't save tab until thumbnail generation more reliable
	#if plugin.get_setting(ES_DOCK_TAB, 0) == 1:
	#	_on_meshes_pressed()


func save_editor_settings() -> void:
	if not _initialized:
		return
	clamp_window_position()
	plugin.set_setting(ES_DOCK_SLOT, slot)
	plugin.set_setting(ES_DOCK_TILE_SIZE, size_slider.value)
	plugin.set_setting(ES_DOCK_FLOATING, floating_btn.button_pressed)
	plugin.set_setting(ES_DOCK_PINNED, pinned_btn.button_pressed)
	# TODO Don't save tab until thumbnail generation more reliable
	# plugin.set_setting(ES_DOCK_TAB, 0 if current_list == texture_list else 1)
	if window:
		plugin.set_setting(ES_DOCK_WINDOW_SIZE, window.size)
		plugin.set_setting(ES_DOCK_WINDOW_POSITION, window.position)
