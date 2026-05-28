# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
class_name Terrain3DListContainer
extends Container

signal selected_list_size_changed(count: int)

var plugin: EditorPlugin
var type := Terrain3DAssets.TYPE_TEXTURE

## Array of the visual containers
var _entries: Array[Terrain3DListEntry]
## All of the asset resources of this type 
var asset_list: Array
## Filtered list of asset resources
var display_list: Array
## Array of ASSET_IDS
var selected_list : Array[int] = [0]

var height: float = 0.
var width: float = 90.
var focus_style: StyleBox
var _clearing_resource: bool = false

var search_text: String = ""
enum SORT_MODES { ASSET_ID, ALPHABETICAL }
var sort_mode: SORT_MODES = SORT_MODES.ASSET_ID

var _entry_idx_to_asset_id_map: Dictionary = {}
var _last_entry_clicked: int = -1

func _ready() -> void:
	set_v_size_flags(SIZE_EXPAND_FILL)
	set_h_size_flags(SIZE_EXPAND_FILL)
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_shadow_color", Color.BLACK)
	add_theme_constant_override("shadow_offset_x", 1)
	add_theme_constant_override("shadow_offset_y", 1)


func clear_list_entries() -> void:
	for e: Terrain3DListEntry in _entries:
		e.get_parent().remove_child(e)
		e.queue_free()
	_entries.clear()
	_entry_idx_to_asset_id_map.clear()
	
## This updates the master list
func update_asset_list() -> void:
	if plugin.debug:
		print("Terrain3DListContainer ", name, ": update_asset_list")
	
	# Grab terrain
	var t: Terrain3D = plugin.get_terrain()
	if not (t and t.assets):
		return
	
	if type == Terrain3DAssets.TYPE_TEXTURE:
		asset_list = t.assets.get_texture_list()
	else:
		if plugin.terrain:
			plugin.terrain.assets.create_mesh_thumbnails()
		asset_list = t.assets.get_mesh_list()
	update_list_entries()


########################
## Custom search and sort functions 
########################

func matches_search(value: Terrain3DAssetResource) -> bool:
	return search_text in value.resource_name
	
## Returns the relevant custom search callable depending on the selected mode
func get_custom_sort() -> Callable:
	match sort_mode:
		SORT_MODES.ALPHABETICAL:
			return sort_alphabetical
	return sort_by_id


func sort_by_id(a: Terrain3DAssetResource, b: Terrain3DAssetResource) -> bool:
	# This is not REALLY required, since the list is in id order in any case 
	# Provided as a default value to return from get_custom_sort 
	return true


func sort_alphabetical(a: Terrain3DAssetResource, b: Terrain3DAssetResource) -> bool:
# Handle invalid entries
	var a_valid: bool = a != null and a.name != null
	var b_valid: bool = b != null and b.name != null

	if not a_valid and not b_valid:
		return false  # equal; no swap
	if not a_valid:
		return false  # a goes after b
	if not b_valid:
		return true   # a goes before b

	# Both valid: alphabetical compare
	return a.name < b.name	
	

## This updates the visuals only for sorting and/or filtering - see also update_asset_list() 
func update_list_entries() -> void:
	clear_list_entries()
	display_list = asset_list.duplicate()
	display_list.filter(matches_search)
	if not sort_mode == SORT_MODES.ASSET_ID:
		# Deliverately pass in the return value here, not the callable
		display_list.sort_custom(get_custom_sort())
	var max_entries: int = Terrain3DAssets.MAX_TEXTURES if type == Terrain3DAssets.TYPE_TEXTURE else Terrain3DAssets.MAX_MESHES
	for candidate: Terrain3DAssetResource in display_list:
		add_list_entry(candidate)
	if asset_list.size() < max_entries and _entries.size() == asset_list.size():
		add_list_entry()
	update_selection()


func add_list_entry(p_resource: Resource = null) -> void:
	var entry: Terrain3DListEntry = Terrain3DListEntry.new()
	entry.focus_style = focus_style
	entry.set_edited_resource(p_resource)
	if not entry.get_resource_name().containsn(search_text) and not search_text == "":
		return

	var res_id: int = p_resource.id if p_resource else _entries.size()
	# Add to the mapping to look up later 
	_entry_idx_to_asset_id_map[_entries.size()] = res_id
	
	entry.type = type
	entry.hovered.connect(_on_resource_hovered.bind(res_id))
	entry.clicked.connect(_on_entry_clicked.bind(_entries.size()))
	entry.edit_clicked.connect(_on_edit_clicked)
	entry.changed.connect(_on_resource_changed.bind(res_id))
	entry.clear_clicked.connect(_on_clear_clicked)
	entry.highlight_clicked.connect(_on_highlight_clicked)
	entry.enable_clicked.connect(_on_enable_clicked)

	add_child(entry, true)
	_entries.push_back(entry)
	

func _on_resource_hovered(p_id: int):
	if type == Terrain3DAssets.TYPE_MESH:
		if plugin.terrain:
			plugin.terrain.assets.create_mesh_thumbnails(p_id, Vector2i(512, 512), true)


func set_selected_after_swap(p_type: Terrain3DAssets.AssetType, p_old_id: int, p_new_id: int) -> void:
	EditorInterface.mark_scene_as_unsaved()
	selected_list = [ p_new_id ]
	update_selection()


func _on_entry_clicked(p_entry_idx: int) -> void:
	if plugin.debug:
		print("Terrain3DListContainer: Clicked %s" % p_entry_idx)
	if type == Terrain3DAssets.TYPE_TEXTURE:
		if not plugin.editor.get_tool() in [ Terrain3DEditor.TEXTURE, Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS ]:
			plugin.ui.toolbar.change_tool("PaintTexture")
		add_entry_to_selection( [p_entry_idx], true)
	elif type == Terrain3DAssets.TYPE_MESH:
		if plugin.editor.get_tool() != Terrain3DEditor.INSTANCER:
			plugin.ui.toolbar.change_tool("InstanceMeshes")
		var entry_arr: Array = [ p_entry_idx ]
		if Input.is_key_pressed(KEY_SHIFT) and not _last_entry_clicked == -1:
			var lower_bound: int = mini(_last_entry_clicked, p_entry_idx)
			var upper_bound: int = maxi(_last_entry_clicked, p_entry_idx) + 1
			entry_arr = range(lower_bound, upper_bound)
		# Editor responds to modifier_ctrl so we must register touchscreen Invert
		var modifier_ctrl: bool = false 
		if plugin._use_meta:
			modifier_ctrl = Input.is_key_pressed(KEY_META) || plugin.ui.inverted_input
		else:
			modifier_ctrl = Input.is_key_pressed(KEY_CTRL) || plugin.ui.inverted_input
		add_entry_to_selection( entry_arr, !modifier_ctrl)


func add_entry_to_selection(p_entry_idx_array: Array, p_clear: bool) -> void:
	if p_clear:
		selected_list.clear()
	for entry_idx: int in p_entry_idx_array:
		if not _entry_idx_to_asset_id_map.has(entry_idx):
			push_error("%s tried to select entry_idx %s, was not present in the map")
			continue
		var asset_id: int = _entry_idx_to_asset_id_map[entry_idx]
		if not selected_list.has(asset_id):
			selected_list.push_back(asset_id)
			_last_entry_clicked = entry_idx
			if plugin.debug:
				print("Added %s to the selection, asset_id = %s" % [entry_idx, asset_id])
	update_list_entries()


func update_selection() -> void:
	if selected_list.is_empty():
			selected_list = [0]
	for entry: Terrain3DListEntry in _entries:
		if entry.resource:
			entry.set_selected(entry.resource.get_id() in selected_list)
	selected_list_size_changed.emit(selected_list.size())
	plugin.ui._on_setting_changed()
	

func _on_edit_clicked(p_entry: Terrain3DListEntry) -> void:
	EditorInterface.edit_resource(p_entry.resource)


func _on_highlight_clicked(p_entry: Terrain3DListEntry) -> void:
	if not p_entry.resource:
		return
	var highlight_state: bool = p_entry.highlighted
	if p_entry.resource.id in selected_list:
		# Highlight all selected assets
		for i: int in selected_list:
			var entry: Terrain3DListEntry = _entries[i]
			entry.set_highlighted(!highlight_state)
	else:
		# Highlight only this asset
		p_entry.toggle_highlighted()
		
	
func _on_clear_clicked(p_entry: Terrain3DListEntry) -> void:
	if not p_entry.resource:
		return
	selected_list.sort()
	selected_list.reverse()
	if p_entry.resource.id in selected_list:
		for i: int in selected_list:
			var entry: Terrain3DListEntry = _entries[i]
			entry.clear()
	else:
		p_entry.clear()
		
		
func _on_enable_clicked(p_entry: Terrain3DListEntry) -> void:
	if not p_entry.resource:
		return
	var enable_state: bool = p_entry.enabled
	if p_entry.resource.id in selected_list:
		# Toggle enabled for all selected assets
		for i: int in selected_list:
			var entry: Terrain3DListEntry = _entries[i]
			entry.set_enabled(!enable_state)
	else:
		# Toggle enabled for only this asset
		p_entry.toggle_enabled()
		

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


func remove_all_highlights():
	if not plugin.terrain:
		return
	for i: int in _entries.size():
		var resource: Terrain3DAssetResource = _entries[i].resource
		if resource and resource.is_highlighted():
			resource.set_highlighted(false)
			
			
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
