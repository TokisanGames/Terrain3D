# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
class_name Terrain3DListEntry 
extends MarginContainer

signal changed(resource: Resource)
signal hovered
signal clicked

signal clear_clicked(entry: Terrain3DListEntry)
signal edit_clicked(entry: Terrain3DListEntry)
signal enable_clicked(entry: Terrain3DListEntry)
signal highlight_clicked(entry: Terrain3DListEntry)

var resource: Resource
var type := Terrain3DAssets.TYPE_TEXTURE
var _thumbnail: Texture2D
var drop_data: bool = false
var is_hovered: bool = false
var is_selected: bool = false
var enabled: bool = false : set = set_enabled
var highlighted: bool = false : set = set_highlighted

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
		set_highlighted(resource.is_highlighted())
		if resource is Terrain3DMeshAsset:
			set_enabled(resource.is_enabled())
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
	button_row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	button_row.alignment = FlowContainer.ALIGNMENT_CENTER
	button_row.mouse_filter = Control.MOUSE_FILTER_STOP
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
		button_enabled.pressed.connect(_on_enable_clicked)
		button_row.add_child(button_enabled, true)
		
	button_highlight.set_texture_normal(highlight_icon)
	button_highlight.set_custom_minimum_size(icon_size)
	button_highlight.set_h_size_flags(Control.SIZE_SHRINK_END)
	button_highlight.set_visible(resource != null)
	button_highlight.tooltip_text = "Highlight " + ( "Instances" if type == Terrain3DAssets.TYPE_MESH else "Texture" )
	button_highlight.toggle_mode = true
	button_highlight.mouse_filter = Control.MOUSE_FILTER_PASS
	button_highlight.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_highlight.set_pressed_no_signal(highlighted)
	button_highlight.pressed.connect(_on_highlight_clicked)
	button_row.add_child(button_highlight, true)
	
	button_edit.set_texture_normal(edit_icon)
	button_edit.set_custom_minimum_size(icon_size)
	button_edit.set_h_size_flags(Control.SIZE_SHRINK_END)
	button_edit.set_visible(resource != null)
	button_edit.tooltip_text = "Edit Asset"
	button_edit.mouse_filter = Control.MOUSE_FILTER_PASS
	button_edit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_edit.pressed.connect(_on_edit_clicked)
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
	button_clear.pressed.connect(_on_clear_clicked)
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
				button_row.visible = false
				draw_style_box(background, rect)
				draw_texture(add_icon, (get_size() / 2) - (add_icon.get_size() / 2))
			else:
				button_row.visible = true
				_thumbnail = resource.get_thumbnail()
				if _thumbnail:
					draw_texture_rect(_thumbnail, rect, false)
					texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
				else:
					draw_rect(rect, Color(.15, .15, .15, 1.))
				if resource is Terrain3DTextureAsset:
					self_modulate = resource.get_highlight_color() if highlighted else resource.get_albedo_color()
				else:
					button_enabled.set_pressed_no_signal(!resource.is_enabled())
					self_modulate = resource.get_highlight_color()
				button_highlight.self_modulate = Color("FC7F7F") if highlighted else Color.WHITE
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
			hovered.emit()
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
						_on_edit_clicked()
					else:
						clicked.emit()
				MOUSE_BUTTON_RIGHT:
					if resource:
						_on_edit_clicked()
				MOUSE_BUTTON_MIDDLE:
					if resource:
						clear()


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
		else:
			push_warning("Dropped invalid resource type, this dock is for %s" % 
				["textures" if type == Terrain3DAssets.TYPE_TEXTURE else "meshes"])
			return
		clicked.emit()
		edit_clicked.emit(self)


func set_edited_resource(p_res: Resource, p_no_signal: bool = true) -> void:
	resource = p_res
	if resource:
		if not resource.setting_changed.is_connected(_on_resource_changed):
			resource.setting_changed.connect(_on_resource_changed)
		if resource is Terrain3DTextureAsset:
			type = Terrain3DAssets.TYPE_TEXTURE
			if not resource.file_changed.is_connected(_on_resource_changed):
				resource.file_changed.connect(_on_resource_changed)
		elif resource is Terrain3DMeshAsset:
			type = Terrain3DAssets.TYPE_MESH
			if not resource.instancer_setting_changed.is_connected(_on_resource_changed):
				resource.instancer_setting_changed.connect(_on_resource_changed)

	if button_clear:
		button_clear.set_visible(resource != null)
		
	queue_redraw()
	if not p_no_signal:
		changed.emit(resource)


func _on_resource_changed(_value: int = 0) -> void:
	queue_redraw()
	changed.emit(resource)


func set_selected(value: bool) -> void:
	is_selected = value
	if is_selected:
		# Handle scrolling to show the selected item
		if is_inside_tree():
			await get_tree().process_frame
			get_parent().get_parent().get_v_scroll_bar().ratio = position.y / get_parent().size.y
	queue_redraw()


func _on_clear_clicked() -> void:
	if resource:
		clear_clicked.emit(self)
		
		
func clear() -> void:
	if resource:
		name_label.hide()
		set_edited_resource(null, false)
		update_count_label()


func _on_edit_clicked() -> void:
	if resource:
		edit_clicked.emit(self)


func _on_enable_clicked() -> void:
	if resource:
		enable_clicked.emit(self)
	
	
func toggle_enabled() -> void:
	enabled = !enabled
	
	
func set_enabled(value: bool) -> void:
	enabled = value
	if resource is Terrain3DMeshAsset:
		resource.set_enabled(enabled)


func _on_highlight_clicked() -> void:
	if resource:
		highlight_clicked.emit(self)


func toggle_highlighted() -> void:
	highlighted = !highlighted


func set_highlighted(value: bool) -> void:
	highlighted = value
	if resource:
		resource.set_highlighted(highlighted)
	queue_redraw()
	

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
