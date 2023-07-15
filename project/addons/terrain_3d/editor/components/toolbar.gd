extends VBoxContainer
	
	
signal tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation)

const ICON_REGION_ADD: Texture2D = preload("res://addons/terrain_3d/icons/icon_map_add.svg")
const ICON_REGION_REMOVE: Texture2D = preload("res://addons/terrain_3d/icons/icon_map_remove.svg")
const ICON_HEIGHT_ADD: Texture2D = preload("res://addons/terrain_3d/icons/icon_height_add.svg")
const ICON_HEIGHT_SUB: Texture2D = preload("res://addons/terrain_3d/icons/icon_height_sub.svg")
const ICON_HEIGHT_MUL: Texture2D = preload("res://addons/terrain_3d/icons/icon_height_mul.svg")
const ICON_HEIGHT_DIV: Texture2D = preload("res://addons/terrain_3d/icons/icon_height_div.svg")
const ICON_HEIGHT_FLAT: Texture2D = preload("res://addons/terrain_3d/icons/icon_height_flat.svg")
const ICON_HEIGHT_SMOOTH: Texture2D = preload("res://addons/terrain_3d/icons/icon_height_smooth.svg")
const ICON_PAINT_TEXTURE: Texture2D = preload("res://addons/terrain_3d/icons/icon_brush.svg")
const ICON_SPRAY_TEXTURE: Texture2D = preload("res://addons/terrain_3d/icons/icon_spray.svg")
const ICON_PAINT_COLOR: Texture2D = preload("res://addons/terrain_3d/icons/icon_color.svg")
const ICON_PAINT_ROUGHNESS: Texture2D = preload("res://addons/terrain_3d/icons/icon_roughness.svg")

var tool_group: ButtonGroup = ButtonGroup.new()


func _init() -> void:
	set_custom_minimum_size(Vector2(32, 0))


func _ready() -> void:
	tool_group.connect("pressed", _on_tool_selected)
	
	add_tool_button(Terrain3DEditor.REGION, Terrain3DEditor.ADD, "Add Region", ICON_REGION_ADD, tool_group)
	add_tool_button(Terrain3DEditor.REGION, Terrain3DEditor.SUBTRACT, "Delete Region", ICON_REGION_REMOVE, tool_group)
	add_child(HSeparator.new())
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.ADD, "Raise", ICON_HEIGHT_ADD, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.SUBTRACT, "Lower", ICON_HEIGHT_SUB, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.MULTIPLY, "Expand (Away from 0)", ICON_HEIGHT_MUL, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.DIVIDE, "Reduce (Towards 0)", ICON_HEIGHT_DIV, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.REPLACE, "Flatten", ICON_HEIGHT_FLAT, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.AVERAGE, "Smooth", ICON_HEIGHT_SMOOTH, tool_group)
	add_child(HSeparator.new())
	add_tool_button(Terrain3DEditor.TEXTURE, Terrain3DEditor.REPLACE, "Paint Texture", ICON_PAINT_TEXTURE, tool_group)
	add_tool_button(Terrain3DEditor.TEXTURE, Terrain3DEditor.ADD, "Spray Texture", ICON_SPRAY_TEXTURE, tool_group)
	add_child(HSeparator.new())
	add_tool_button(Terrain3DEditor.COLOR, Terrain3DEditor.REPLACE, "Paint Color", ICON_PAINT_COLOR, tool_group)
	add_tool_button(Terrain3DEditor.ROUGHNESS, Terrain3DEditor.REPLACE, "Paint Roughness", ICON_PAINT_ROUGHNESS, tool_group)

	var buttons: Array[BaseButton] = tool_group.get_buttons()
	buttons[0].set_pressed(true)


func add_tool_button(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation, 
		p_tip: String, p_icon: Texture2D, p_group: ButtonGroup) -> void:
		
	var button: Button = Button.new()
	button.set_meta("Tool", p_tool)
	button.set_meta("Operation", p_operation)
	button.set_tooltip_text(p_tip)
	button.set_button_icon(p_icon)
	button.set_button_group(p_group)
	button.set_flat(true)
	button.set_toggle_mode(true)
	button.set_h_size_flags(SIZE_SHRINK_END)
	add_child(button)
		

func _on_tool_selected(p_button: BaseButton) -> void:
	emit_signal("tool_changed", p_button.get_meta("Tool", -1), p_button.get_meta("Operation", -1))
	
