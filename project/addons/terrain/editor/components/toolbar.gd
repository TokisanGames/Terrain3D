extends VBoxContainer
	
signal tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation)

const ICON_REGION_ADD: Texture2D = preload("res://addons/terrain/icons/icon_map_add.svg")
const ICON_REGION_REMOVE: Texture2D = preload("res://addons/terrain/icons/icon_map_remove.svg")
const ICON_HEIGHT_ADD: Texture2D = preload("res://addons/terrain/icons/icon_height_add.svg")
const ICON_HEIGHT_SUB: Texture2D = preload("res://addons/terrain/icons/icon_height_sub.svg")
const ICON_HEIGHT_MUL: Texture2D = preload("res://addons/terrain/icons/icon_height_mul.svg")
const ICON_HEIGHT_FLAT: Texture2D = preload("res://addons/terrain/icons/icon_height_flat.svg")

var tool_group: ButtonGroup = ButtonGroup.new()

func _init() -> void:
	set_custom_minimum_size(Vector2(32, 0))

func _ready() -> void:
	tool_group.connect("pressed", _on_tool_selected)
	
	add_tool_button(Terrain3DEditor.REGION, Terrain3DEditor.ADD, "Add Region", ICON_REGION_ADD, tool_group)
	add_tool_button(Terrain3DEditor.REGION, Terrain3DEditor.SUBTRACT, "Delete Region", ICON_REGION_REMOVE, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.ADD, "Increase", ICON_HEIGHT_ADD, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.SUBTRACT, "Decrease", ICON_HEIGHT_SUB, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.MULTIPLY, "Multiply", ICON_HEIGHT_MUL, tool_group)
	add_tool_button(Terrain3DEditor.HEIGHT, Terrain3DEditor.REPLACE, "Flatten", ICON_HEIGHT_FLAT, tool_group)

	var buttons: Array[BaseButton] = tool_group.get_buttons()

	for i in buttons.size():
		if i < buttons.size() - 1:
			var button: BaseButton = buttons[i]
			var next_button: BaseButton = buttons[i+1]
			
			if button.get_meta("Tool") != next_button.get_meta("Tool"):
				var s: HSeparator = HSeparator.new()
				add_child(s)
				move_child(s, i+1)
		
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
	
