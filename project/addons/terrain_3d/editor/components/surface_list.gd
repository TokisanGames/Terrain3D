extends PanelContainer

signal resource_changed(resource: Resource, index: int)
signal resource_inspected(resource: Resource)
signal resource_selected

var list: ListContainer
var entries: Array[ListEntry]

var selected_index: int = 0

func _init() -> void:
	list = ListContainer.new()
	
	var root: VBoxContainer = VBoxContainer.new()
	var scroll: ScrollContainer = ScrollContainer.new()
	var label: Label = Label.new()
	
	label.set_text("Surfaces")
	label.set_horizontal_alignment(HORIZONTAL_ALIGNMENT_CENTER)
	label.set_vertical_alignment(VERTICAL_ALIGNMENT_CENTER)
	scroll.set_v_size_flags(SIZE_EXPAND_FILL)
	scroll.set_h_size_flags(SIZE_EXPAND_FILL)
	list.set_v_size_flags(SIZE_EXPAND_FILL)
	list.set_h_size_flags(SIZE_EXPAND_FILL)
	
	scroll.add_child(list)
	root.add_child(label)
	root.add_child(scroll)
	add_child(root)
	
	set_custom_minimum_size(Vector2(256, 448))
	
func _ready() -> void:
	get_child(0).get_child(0).set("theme_override_styles/normal", get_theme_stylebox("bg", "EditorInspectorCategory"))
	get_child(0).get_child(0).set("theme_override_fonts/font", get_theme_font("bold", "EditorFonts"))
	get_child(0).get_child(0).set("theme_override_font_sizes/font_size",get_theme_font_size("bold_size", "EditorFonts"))
	set("theme_override_styles/panel", get_theme_stylebox("panel", "Panel"))
	
func notify_resource_changed(resource: Resource, index: int) -> void:
	if !resource:
		selected_index = clamp(selected_index, 0, entries.size() - 3)
	
	emit_signal("resource_changed", resource, index)
	
func notify_resource_inspected(resource: Resource):
	emit_signal("resource_inspected", resource)

func set_selected_index(index: int):
	selected_index = index
	emit_signal("resource_selected")
	
	for i in entries.size():
		var entry: ListEntry = entries[i]
		entry.set_selected(i == selected_index)
	
func get_selected_index():
	return selected_index

func add_item(resource: Resource = null) -> void:
	var entry: ListEntry = ListEntry.new()
	var index: int = entries.size()
	
	entry.set_edited_resource(resource)
	entry.connect("changed", notify_resource_changed.bind(index))
	entry.connect("inspected", notify_resource_inspected)
	entry.connect("selected", set_selected_index.bind(index))
	
	if resource:
		entry.set_selected(index == selected_index)
	
	list.add_child(entry)
	entries.push_back(entry)
	
func clear():
	for i in entries:
		i.free()
	entries.clear()
	
class ListContainer extends Container:
	var height: float = 0
	
	func _notification(what):
		if what == NOTIFICATION_SORT_CHILDREN:
			height = 0
			var index: int = 0
			var separation: float = 4
			for c in get_children():
				if is_instance_valid(c):
					var width: float = size.x / 3
					c.size = Vector2(width,width) - Vector2(separation, separation)
					c.position = Vector2(index % 3, index / 3) * width + Vector2(separation/3, separation/3)
					height = max(height, c.position.y + width)
					index += 1
					
	func _get_minimum_size():
		return Vector2(0, height)

class ListEntry extends VBoxContainer:
	signal selected()
	signal changed(resource: Terrain3DSurface)
	signal inspected(resource: Terrain3DSurface)
	
	var resource: Terrain3DSurface
	var drop_data: bool = false
	var is_hovered: bool = false
	var is_selected: bool = false
	
	var button_close: TextureButton
	var button_edit: TextureButton
	
	@onready var add_icon: Texture2D = get_theme_icon("Add", "EditorIcons")
	@onready var close_icon: Texture2D = get_theme_icon("Close", "EditorIcons")
	@onready var edit_icon: Texture2D = get_theme_icon("Edit", "EditorIcons")
	@onready var background: StyleBox = get_theme_stylebox("pressed", "Button")
	@onready var focus: StyleBox = get_theme_stylebox("focus", "Button")
	
	func _ready():
		var icon_size: Vector2 = Vector2(12, 12)
		
		button_close = TextureButton.new()
		button_close.set_texture_normal(close_icon)
		button_close.set_custom_minimum_size(icon_size)
		button_close.set_h_size_flags(Control.SIZE_SHRINK_END)
		button_close.set_visible(resource != null)
		button_close.connect("pressed", close)
		add_child(button_close)
		
		button_edit = TextureButton.new()
		button_edit.set_texture_normal(edit_icon)
		button_edit.set_custom_minimum_size(icon_size)
		button_edit.set_h_size_flags(Control.SIZE_SHRINK_END)
		button_edit.set_visible(resource != null)
		button_edit.connect("pressed", edit)
		add_child(button_edit)
		
	func _notification(what):
		match what:
			NOTIFICATION_DRAW:
				var rect: Rect2 = Rect2(Vector2.ZERO, get_size())
				if !resource:
					draw_style_box(background, rect)
					draw_texture(add_icon, (get_size() / 2) - (add_icon.get_size() / 2))
				else:
					var texture: Texture2D = resource.get_albedo_texture()
					if texture:
						draw_texture_rect(texture, rect, false)
					modulate = resource.get_albedo()
					
					if !texture:
						# Draw checker texture
						var s: Vector2 = rect.size
						var col_a: Color = Color(0.8, 0.8, 0.8)
						var col_b: Color = Color(0.5, 0.5, 0.5)
						draw_rect(Rect2(Vector2.ZERO, s/2), col_a)
						draw_rect(Rect2(s/2, s/2), col_a)
						draw_rect(Rect2(Vector2(s.x, 0) / 2, s/2), col_b)
						draw_rect(Rect2(Vector2(0, s.y) / 2, s/2), col_b)
				if drop_data:
					draw_style_box(focus, rect)
				if is_hovered:
					draw_rect(rect, Color(1,1,1,0.2))
				if is_selected:
					draw_style_box(focus, rect)
				
			NOTIFICATION_MOUSE_ENTER:
				is_hovered = true
				queue_redraw()
			NOTIFICATION_MOUSE_EXIT:
				is_hovered = false
				drop_data = false
				queue_redraw()
	
	func _gui_input(event: InputEvent):
		if event is InputEventMouseButton:
			if event.is_pressed():
				match event.get_button_index():
					MOUSE_BUTTON_LEFT:
						if !resource:
							set_edited_resource(Terrain3DSurface.new(), false)
						else:
							emit_signal("selected")
					MOUSE_BUTTON_RIGHT:
						edit()
					MOUSE_BUTTON_MIDDLE:
						close()
			
	func _can_drop_data(at_position: Vector2, data: Variant):
		drop_data = false
		if typeof(data) == TYPE_DICTIONARY:
			if data.files.size() == 1:
				queue_redraw()
				drop_data = true
		return drop_data
		
	func _drop_data(at_position: Vector2, data: Variant):
		if typeof(data) == TYPE_DICTIONARY:
			var res: Resource = load(data.files[0])
			if res is Terrain3DSurface:
				set_edited_resource(res, false)
			if res is Texture2D:
				var surf: Terrain3DSurface = Terrain3DSurface.new()
				surf.set_albedo_texture(res)
				set_edited_resource(surf, false)
	
	func set_edited_resource(res: Terrain3DSurface, no_signal: bool = true):
		resource = res
		if resource:
			var text: String = resource.get_path()
			if text.is_empty():
				text = "New Surface"
			set_tooltip_text(text)
		
		if button_close:
			button_close.set_visible(resource != null)
			
		queue_redraw()
		if !no_signal:
			emit_signal("changed", res)
			
	func set_selected(value: bool):
		is_selected = value
		queue_redraw()
			
	func close():
		if resource:
			set_edited_resource(null, false)
	
	func edit():
		emit_signal("inspected", resource)
