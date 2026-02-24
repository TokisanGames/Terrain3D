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

var texture_list: ListContainer
var mesh_list: ListContainer
var current_list: ListContainer
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
	
	texture_list = ListContainer.new()
	texture_list.name = "TextureList"
	texture_list.plugin = plugin
	texture_list.type = Terrain3DAssets.TYPE_TEXTURE
	asset_container.add_child(texture_list, true)
	mesh_list = ListContainer.new()
	mesh_list.name = "MeshList"
	mesh_list.plugin = plugin
	mesh_list.type = Terrain3DAssets.TYPE_MESH
	mesh_list.visible = false
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


func set_selected_by_asset_id(p_id: int) -> void:
	search_box.text = ""
	_on_search_text_changed()
	current_list.set_selected_id(p_id)
	
	
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
	current_list.update_asset_list()
	current_list.set_selected_id(0)


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
	if _updating_list or current_list == texture_list:
		return
	_updating_list = true
	current_list = texture_list
	texture_list.visible = true
	mesh_list.visible = false
	textures_btn.set_pressed_no_signal(true)
	meshes_btn.set_pressed_no_signal(false)
	texture_list.update_asset_list()
	if plugin.is_terrain_valid():
		EditorInterface.edit_node(plugin.terrain)
	save_editor_settings()
	_updating_list = false


func _on_meshes_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_meshes_pressed")
	if _updating_list or current_list == mesh_list:
		return
	_updating_list = true
	current_list = mesh_list
	mesh_list.visible = true
	texture_list.visible = false
	meshes_btn.set_pressed_no_signal(true)
	textures_btn.set_pressed_no_signal(false)
	mesh_list.update_asset_list()
	if plugin.is_terrain_valid():
		EditorInterface.edit_node(plugin.terrain)
	save_editor_settings()
	_updating_list = false


func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_tool_changed: ", p_tool, ", ", p_operation)
	remove_all_highlights()
	if p_tool == Terrain3DEditor.INSTANCER:
		_on_meshes_pressed()
	elif p_tool in [ Terrain3DEditor.TEXTURE, Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS ]:
		_on_textures_pressed()


## Update Dock Contents


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

	current_list.update_asset_list()


func remove_all_highlights():
	if not plugin.terrain:
		return
	for i: int in texture_list.entries.size():
		var resource: Terrain3DTextureAsset = texture_list.entries[i].resource
		if resource and resource.is_highlighted():
			resource.set_highlighted(false)
	for i: int in mesh_list.entries.size():
		var resource: Terrain3DMeshAsset = mesh_list.entries[i].resource
		if resource and resource.is_highlighted():
			resource.set_highlighted(false)


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


##############################################################
## class ListContainer
##############################################################

	
class ListContainer extends Container:
	var plugin: EditorPlugin
	var type := Terrain3DAssets.TYPE_TEXTURE
	var entries: Array[ListEntry]
	var selected_id: int = 0
	var height: float = 0.
	var width: float = 90.
	var focus_style: StyleBox
	var _clearing_resource: bool = false
	var search_text: String = ""

	
	func _ready() -> void:
		set_v_size_flags(SIZE_EXPAND_FILL)
		set_h_size_flags(SIZE_EXPAND_FILL)
		add_theme_color_override("font_color", Color.WHITE)
		add_theme_color_override("font_shadow_color", Color.BLACK)
		add_theme_constant_override("shadow_offset_x", 1)
		add_theme_constant_override("shadow_offset_y", 1)


	func clear() -> void:
		for e in entries:
			e.get_parent().remove_child(e)
			e.queue_free()
		entries.clear()


	func update_asset_list() -> void:
		if plugin.debug:
			print("Terrain3DListContainer ", name, ": update_asset_list")
		clear()
		
		# Grab terrain
		var t: Terrain3D = plugin.get_terrain()
		if not (t and t.assets):
			return
		
		if type == Terrain3DAssets.TYPE_TEXTURE:
			var texture_count: int = t.assets.get_texture_count()
			for i in texture_count:
				var texture: Terrain3DTextureAsset = t.assets.get_texture_asset(i)
				add_item(texture)
			if texture_count < Terrain3DAssets.MAX_TEXTURES:
				add_item()
		else:
			if plugin.terrain:
				plugin.terrain.assets.create_mesh_thumbnails()
			var mesh_count: int = t.assets.get_mesh_count()
			for i in mesh_count:
				var mesh: Terrain3DMeshAsset = t.assets.get_mesh_asset(i)
				add_item(mesh)
			if mesh_count < Terrain3DAssets.MAX_MESHES:
				add_item()
		set_selected_id(selected_id)


	func add_item(p_resource: Resource = null) -> void:
		var entry: ListEntry = ListEntry.new()
		entry.focus_style = focus_style
		entry.set_edited_resource(p_resource)
		if not entry.get_resource_name().containsn(search_text) and not search_text == "":
			return

		var res_id: int = p_resource.id if p_resource else entries.size()
		entry.hovered.connect(_on_resource_hovered.bind(res_id))
		entry.clicked.connect(clicked_id.bind(entries.size()))
		entry.inspected.connect(_on_resource_inspected)
		entry.changed.connect(_on_resource_changed.bind(res_id))
		entry.type = type
		add_child(entry, true)
		entries.push_back(entry)
		
		if p_resource:
			if not p_resource.id_changed.is_connected(set_selected_after_swap):
				p_resource.id_changed.connect(set_selected_after_swap)


	func _on_resource_hovered(p_id: int):
		if type == Terrain3DAssets.TYPE_MESH:
			if plugin.terrain:
				plugin.terrain.assets.create_mesh_thumbnails(p_id, Vector2i(512, 512), true)

	
	func set_selected_after_swap(p_type: Terrain3DAssets.AssetType, p_old_id: int, p_new_id: int) -> void:
		EditorInterface.mark_scene_as_unsaved()
		set_selected_id(clamp(p_new_id, 0, entries.size() - 2))


	func clicked_id(p_id: int) -> void:
		# Select Tool if clicking an asset
		plugin.select_terrain()
		if type == Terrain3DAssets.TYPE_TEXTURE and \
				not plugin.editor.get_tool() in [ Terrain3DEditor.TEXTURE, Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS ]:
			plugin.ui.toolbar.change_tool("PaintTexture")
		elif type == Terrain3DAssets.TYPE_MESH and plugin.editor.get_tool() != Terrain3DEditor.INSTANCER:
			plugin.ui.toolbar.change_tool("InstanceMeshes")
		set_selected_id(p_id)


	func set_selected_id(p_id: int) -> void:
		# "Add new" is the final entry only when search box is blank
		var max_id: int = max(0, entries.size() - (1 if search_text else 2))
		if plugin.debug:
			print("Terrain3DListContainer ", name, ": set_selected_id: ", selected_id, " to ", clamp(p_id, 0, max_id))
		selected_id = clamp(p_id, 0, max_id)
		for i in entries.size():
			var entry: ListEntry = entries[i]
			entry.set_selected(i == selected_id)
		plugin.ui._on_setting_changed()


	func get_selected_asset_id() -> int:
		# "Add new" is the final entry only when search box is blank
		var max_id: int = max(0, entries.size() - (1 if search_text else 2))
		var id: int = clamp(selected_id, 0, max_id)
		if plugin.debug:
			print("Terrain3DListContainer ", name, ": get_selected_asset_id: selected_id: ", selected_id, ", clamped: ", id, ", entries: ", entries.size())
		if id >= entries.size():
			return 0
		var res: Resource = entries[id].resource
		if not res:
			return 0
		if type == Terrain3DAssets.AssetType.TYPE_MESH:
			return (res as Terrain3DMeshAsset).id
		else:
			return (res as Terrain3DTextureAsset).id


	func _on_resource_inspected(p_resource: Resource) -> void:
		await get_tree().process_frame
		EditorInterface.edit_resource(p_resource)
	
	
	func _on_resource_changed(p_resource: Resource, p_id: int) -> void:
		if not p_resource and _clearing_resource:
			return
		if not p_resource:
			if plugin.debug:
				print("Terrain3DListContainer ", name, ": _on_resource_changed: removing asset ID: ", p_id)
			_clearing_resource = true
			var asset_dock: Control = get_parent().get_parent().get_parent()
			if type == Terrain3DAssets.TYPE_TEXTURE:
				asset_dock.confirm_dialog.dialog_text = "Are you sure you want to clear this texture?"
			else:
				asset_dock.confirm_dialog.dialog_text = "Are you sure you want to clear this mesh and delete all instances?"
			asset_dock.confirm_dialog.popup_centered()
			await asset_dock.confirmation_closed
			if not asset_dock._confirmed:
				update_asset_list()
				_clearing_resource = false
				return
			
		if not plugin.is_terrain_valid():
			plugin.select_terrain()
			await get_tree().process_frame

		if plugin.is_terrain_valid():
			if type == Terrain3DAssets.TYPE_TEXTURE:
				plugin.terrain.assets.set_texture_asset(p_id, p_resource)
			else:
				plugin.terrain.assets.set_mesh_asset(p_id, p_resource)

			# If removing an entry, clear inspector
			if not p_resource:
				EditorInterface.inspect_object(null)			
		_clearing_resource = false


	func set_entry_width(value: float) -> void:
		width = clamp(value, 90., 512.)
		redraw()


	func get_entry_width() -> float:
		return width
	

	func redraw() -> void:
		height = 0
		var id: int = 0
		var separation: float = 2.
		var columns: int = 3
		columns = clamp(size.x / width, 1, 100)
		var tile_size: Vector2 = Vector2(width, width) - Vector2(separation, separation)
		var count_font_size = clamp(tile_size.x/11, 11, 16)
		var name_font_size = clamp(tile_size.x/12, 12, 18)
		for c in get_children():
			if is_instance_valid(c):
				c.size = tile_size
				c.position = Vector2(id % columns, id / columns) * width + \
					Vector2(separation / columns, separation / columns)
				height = max(height, c.position.y + width)
				id += 1
				if type == Terrain3DAssets.TYPE_MESH:
					c.count_label.add_theme_font_size_override("font_size", count_font_size)
				c.name_label.add_theme_font_size_override("font_size", name_font_size)


	# Needed to enable ScrollContainer scroll bar
	func _get_minimum_size() -> Vector2:
		return Vector2(0, height)

		
	func _notification(p_what) -> void:
		if p_what == NOTIFICATION_SORT_CHILDREN:
			redraw()


##############################################################
## class ListEntry
##############################################################


class ListEntry extends MarginContainer:
	signal hovered()
	signal clicked()
	signal changed(resource: Resource)
	signal inspected(resource: Resource)
	
	var resource: Resource
	var type := Terrain3DAssets.TYPE_TEXTURE
	var _thumbnail: Texture2D
	var drop_data: bool = false
	var is_hovered: bool = false
	var is_selected: bool = false
	var is_highlighted: bool = false
	
	var name_label: Label
	var count_label: Label
	var button_row: FlowContainer
	var button_enabled: TextureButton
	var button_highlight: TextureButton
	var button_edit: TextureButton
	var spacer: Control 
	var button_clear: TextureButton

	@onready var focus_style: StyleBox = get_theme_stylebox("focus", "Button").duplicate()
	@onready var background: StyleBox = get_theme_stylebox("pressed", "Button")
	@onready var clear_icon: Texture2D = get_theme_icon("Close", "EditorIcons")
	@onready var edit_icon: Texture2D = get_theme_icon("Edit", "EditorIcons")
	@onready var enabled_icon: Texture2D = get_theme_icon("GuiVisibilityVisible", "EditorIcons")
	@onready var disabled_icon: Texture2D = get_theme_icon("GuiVisibilityHidden", "EditorIcons")
	@onready var highlight_icon: Texture2D = get_theme_icon("PreviewSun", "EditorIcons")
	@onready var add_icon: Texture2D = get_theme_icon("Add", "EditorIcons")


	func _ready() -> void:
		name = "ListEntry"
		custom_minimum_size = Vector2i(86., 86.)
		mouse_filter = Control.MOUSE_FILTER_PASS
		add_theme_constant_override("margin_top", 5)
		add_theme_constant_override("margin_left", 5)
		add_theme_constant_override("margin_right", 5)

		if resource:
			is_highlighted = resource.is_highlighted()

		setup_buttons()
		setup_label()
		setup_count_label()
		focus_style.set_border_width_all(2)
		focus_style.set_border_color(Color(1, 1, 1, .67))


	func setup_buttons() -> void:
		destroy_buttons()
		
		button_row = FlowContainer.new()
		button_enabled = TextureButton.new() 
		button_highlight = TextureButton.new() 
		button_edit = TextureButton.new() 
		spacer = Control.new()
		button_clear = TextureButton.new()
		
		var icon_size: Vector2 = Vector2(12, 12)
		
		button_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button_row.alignment = FlowContainer.ALIGNMENT_CENTER
		button_row.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(button_row, true)

		if type == Terrain3DAssets.TYPE_MESH:
			button_enabled.set_texture_normal(enabled_icon)
			button_enabled.set_texture_pressed(disabled_icon)
			button_enabled.set_custom_minimum_size(icon_size)
			button_enabled.set_h_size_flags(Control.SIZE_SHRINK_END)
			button_enabled.set_visible(resource != null)
			button_enabled.tooltip_text = "Enable Instances"
			button_enabled.toggle_mode = true
			button_enabled.mouse_filter = Control.MOUSE_FILTER_PASS
			button_enabled.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			button_enabled.pressed.connect(_on_enable)
			button_row.add_child(button_enabled, true)
			
		button_highlight.set_texture_normal(highlight_icon)
		button_highlight.set_custom_minimum_size(icon_size)
		button_highlight.set_h_size_flags(Control.SIZE_SHRINK_END)
		button_highlight.set_visible(resource != null)
		button_highlight.tooltip_text = "Highlight " + ( "Instances" if type == Terrain3DAssets.TYPE_MESH else "Texture" )
		button_highlight.toggle_mode = true
		button_highlight.mouse_filter = Control.MOUSE_FILTER_PASS
		button_highlight.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button_highlight.set_pressed_no_signal(is_highlighted)
		button_highlight.pressed.connect(_on_highlight)
		button_row.add_child(button_highlight, true)
		
		button_edit.set_texture_normal(edit_icon)
		button_edit.set_custom_minimum_size(icon_size)
		button_edit.set_h_size_flags(Control.SIZE_SHRINK_END)
		button_edit.set_visible(resource != null)
		button_edit.tooltip_text = "Edit Asset"
		button_edit.mouse_filter = Control.MOUSE_FILTER_PASS
		button_edit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button_edit.pressed.connect(_on_edit)
		button_row.add_child(button_edit, true)

		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_PASS
		button_row.add_child(spacer, true)
		
		button_clear.set_texture_normal(clear_icon)
		button_clear.set_custom_minimum_size(icon_size)
		button_clear.set_h_size_flags(Control.SIZE_SHRINK_END)
		button_clear.set_visible(resource != null)
		button_clear.tooltip_text = "Clear Asset"
		button_clear.mouse_filter = Control.MOUSE_FILTER_PASS
		button_clear.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button_clear.pressed.connect(_on_clear)
		button_row.add_child(button_clear, true)
		

	func destroy_buttons() -> void:
		if button_row:
			button_row.free()
			button_row = null
		if button_enabled:
			button_enabled.free()
			button_enabled = null
		if button_highlight:
			button_highlight.free()
			button_highlight = null
		if button_edit:
			button_edit.free()
			button_edit = null
		if spacer:
			spacer.free()
			spacer = null
		if button_clear:
			button_clear.free()
			button_clear = null


	func get_resource_name() -> StringName:
		if resource:
			if resource is Terrain3DMeshAsset:
				return (resource as Terrain3DMeshAsset).get_name()
			elif resource is Terrain3DTextureAsset:
				return (resource as Terrain3DTextureAsset).get_name()
		return ""


	func setup_label() -> void:
		name_label = Label.new()
		name_label.name = "MeshLabel"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 14)
		name_label.add_theme_color_override("font_color", Color.WHITE)
		name_label.add_theme_color_override("font_shadow_color", Color.BLACK)
		name_label.add_theme_constant_override("shadow_offset_x", 1)
		name_label.add_theme_constant_override("shadow_offset_y", 1)
		name_label.visible = false
		name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS	
		add_child(name_label, true)


	func setup_count_label() -> void:
		count_label = Label.new()
		count_label.name = "CountLabel"
		count_label.text = ""
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		count_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		count_label.add_theme_font_size_override("font_size", 14)
		count_label.add_theme_color_override("font_color", Color.WHITE)
		count_label.add_theme_color_override("font_shadow_color", Color.BLACK)
		count_label.add_theme_constant_override("shadow_offset_x", 1)
		count_label.add_theme_constant_override("shadow_offset_y", 1)
		add_child(count_label, true)
		var mesh_resource: Terrain3DMeshAsset = resource as Terrain3DMeshAsset
		if not mesh_resource: 
			return
		mesh_resource.instance_count_changed.connect(update_count_label)
		update_count_label()


	func update_count_label() -> void:
		if not type == Terrain3DAssets.AssetType.TYPE_MESH or \
				( resource and not resource.is_enabled() ):
			count_label.text = ""
			return
		var mesh_resource: Terrain3DMeshAsset = resource as Terrain3DMeshAsset
		if not mesh_resource:
			count_label.text = str(0)
		else:
			count_label.text = _format_number(mesh_resource.get_instance_count())


	func _notification(p_what) -> void:
		match p_what:
			NOTIFICATION_PREDELETE:
				destroy_buttons()
			NOTIFICATION_DRAW:
				# Hide spacer if icons are crowding small textures
				spacer.visible = size.x > 94. or type == Terrain3DAssets.TYPE_TEXTURE
				var rect: Rect2 = Rect2(Vector2.ZERO, get_size())
				if !resource:
					draw_style_box(background, rect)
					draw_texture(add_icon, (get_size() / 2) - (add_icon.get_size() / 2))
				else:
					_thumbnail = resource.get_thumbnail()
					if _thumbnail:
						draw_texture_rect(_thumbnail, rect, false)
						texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
					else:
						draw_rect(rect, Color(.15, .15, .15, 1.))
					if type == Terrain3DAssets.TYPE_TEXTURE:
						self_modulate = resource.get_highlight_color() if is_highlighted else resource.get_albedo_color()
					else:
						button_enabled.set_pressed_no_signal(!resource.is_enabled())
						self_modulate = resource.get_highlight_color()
					button_highlight.self_modulate = Color("FC7F7F") if is_highlighted else Color.WHITE
				if drop_data:
					draw_style_box(focus_style, rect)
				if is_hovered:
					draw_rect(rect, Color(1, 1, 1, 0.2))
				if is_selected:
					draw_style_box(focus_style, rect)
			NOTIFICATION_MOUSE_ENTER:
				if not resource:
					name_label.visible = false
				else:
					name_label.visible = true
				is_hovered = true
				name_label.text = get_resource_name()
				tooltip_text = get_resource_name()
				emit_signal("hovered")
				queue_redraw()
			NOTIFICATION_MOUSE_EXIT:
				name_label.visible = false
				is_hovered = false
				drop_data = false
				queue_redraw()


	func _gui_input(p_event: InputEvent) -> void:
		if p_event is InputEventMouseButton:
			if p_event.is_pressed():
				match p_event.get_button_index():
					MOUSE_BUTTON_LEFT:
						# If `Add new` is clicked
						if !resource:
							if type == Terrain3DAssets.TYPE_TEXTURE:
								set_edited_resource(Terrain3DTextureAsset.new(), false)
							else:
								set_edited_resource(Terrain3DMeshAsset.new(), false)
							_on_edit()
						else:
							emit_signal("clicked")
					MOUSE_BUTTON_RIGHT:
						if resource:
							_on_edit()
					MOUSE_BUTTON_MIDDLE:
						if resource:
							_on_clear()


	func _can_drop_data(p_at_position: Vector2, p_data: Variant) -> bool:
		drop_data = false
		if typeof(p_data) == TYPE_DICTIONARY:
			if p_data.files.size() == 1:
				queue_redraw()
				drop_data = true
		return drop_data

		
	func _drop_data(p_at_position: Vector2, p_data: Variant) -> void:
		if typeof(p_data) == TYPE_DICTIONARY:
			var res: Resource = load(p_data.files[0])
			if res is Texture2D and type == Terrain3DAssets.TYPE_TEXTURE:
				var ta := Terrain3DTextureAsset.new()
				if resource is Terrain3DTextureAsset:
					ta.id = resource.id
				ta.set_albedo_texture(res)
				set_edited_resource(ta, false)
				resource = ta
			elif res is Terrain3DTextureAsset and type == Terrain3DAssets.TYPE_TEXTURE:
				if resource is Terrain3DTextureAsset:
					res.id = resource.id
				set_edited_resource(res, false)
			elif res is PackedScene and type == Terrain3DAssets.TYPE_MESH:
				if not resource:
					resource = Terrain3DMeshAsset.new()		
				set_edited_resource(resource, false)
				resource.set_scene_file(res)
			elif res is Terrain3DMeshAsset and type == Terrain3DAssets.TYPE_MESH:
				if resource is Terrain3DMeshAsset:
					res.id = resource.id
				set_edited_resource(res, false)
			emit_signal("clicked")
			emit_signal("inspected", resource)


	func set_edited_resource(p_res: Resource, p_no_signal: bool = true) -> void:
		resource = p_res
		if resource:
			if not resource.setting_changed.is_connected(_on_resource_changed):
				resource.setting_changed.connect(_on_resource_changed)
			if resource is Terrain3DTextureAsset:
				if not resource.file_changed.is_connected(_on_resource_changed):
					resource.file_changed.connect(_on_resource_changed)
			elif resource is Terrain3DMeshAsset:
				if not resource.instancer_setting_changed.is_connected(_on_resource_changed):
					resource.instancer_setting_changed.connect(_on_resource_changed)
		
		if button_clear:
			button_clear.set_visible(resource != null)
			
		queue_redraw()
		if not p_no_signal:
			emit_signal("changed", resource)


	func _on_resource_changed(_value: int = 0) -> void:
		queue_redraw()
		emit_signal("changed", resource)


	func set_selected(value: bool) -> void:
		is_selected = value
		if is_selected:
			# Handle scrolling to show the selected item
			await get_tree().process_frame
			if is_inside_tree():
				get_parent().get_parent().get_v_scroll_bar().ratio = position.y / get_parent().size.y
		queue_redraw()


	func _on_clear() -> void:
		if resource:
			name_label.hide()
			set_edited_resource(null, false)
			update_count_label()

	
	func _on_edit() -> void:
		emit_signal("clicked")
		emit_signal("inspected", resource)


	func _on_enable() -> void:
		if resource is Terrain3DMeshAsset:
			resource.set_enabled(!resource.is_enabled())


	func _on_highlight() -> void:
		is_highlighted = !is_highlighted
		resource.set_highlighted(is_highlighted)


	func _format_number(num: int) -> String:
		var is_negative: bool = num < 0
		var str_num: String = str(abs(num))
		var result: String = ""
		var length: int = str_num.length()
		for i in length:
			result = str_num[length - 1 - i] + result
			if i < length - 1 and (i + 1) % 3 == 0:
				result = "," + result
		return "-" + result if is_negative else result
