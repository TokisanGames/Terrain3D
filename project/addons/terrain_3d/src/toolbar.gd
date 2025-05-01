# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Toolbar for Terrain3D
extends VFlowContainer

signal tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation)

const ICON_REGION_ADD: String = "res://addons/terrain_3d/icons/region_add.svg"
const ICON_REGION_REMOVE: String = "res://addons/terrain_3d/icons/region_remove.svg"
const ICON_HEIGHT_ADD: String = "res://addons/terrain_3d/icons/height_add.svg"
const ICON_HEIGHT_SUB: String = "res://addons/terrain_3d/icons/height_sub.svg"
const ICON_HEIGHT_FLAT: String = "res://addons/terrain_3d/icons/height_flat.svg"
const ICON_HEIGHT_SLOPE: String = "res://addons/terrain_3d/icons/height_slope.svg"
const ICON_HEIGHT_SMOOTH: String = "res://addons/terrain_3d/icons/height_smooth.svg"
const ICON_PAINT_TEXTURE: String = "res://addons/terrain_3d/icons/texture_paint.svg"
const ICON_SPRAY_TEXTURE: String = "res://addons/terrain_3d/icons/texture_spray.svg"
const ICON_COLOR: String = "res://addons/terrain_3d/icons/color_paint.svg"
const ICON_WETNESS: String = "res://addons/terrain_3d/icons/wetness.svg"
const ICON_AUTOSHADER: String = "res://addons/terrain_3d/icons/autoshader.svg"
const ICON_HOLES: String = "res://addons/terrain_3d/icons/holes.svg"
const ICON_NAVIGATION: String = "res://addons/terrain_3d/icons/navigation.svg"
const ICON_INSTANCER: String = "res://addons/terrain_3d/icons/multimesh.svg"

var add_tool_group: ButtonGroup = ButtonGroup.new()
var sub_tool_group: ButtonGroup = ButtonGroup.new()
var buttons: Dictionary


func _init() -> void:
	set_custom_minimum_size(Vector2(20, 0))


func _ready() -> void:
	add_tool_group.pressed.connect(_on_tool_selected)
	sub_tool_group.pressed.connect(_on_tool_selected)

	add_tool_button({ "tool":Terrain3DEditor.REGION, 
		"add_text":"Add Region (E)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_REGION_ADD,
		"sub_text":"Remove Region", "sub_op":Terrain3DEditor.SUBTRACT, "sub_icon":ICON_REGION_REMOVE })
	
	add_child(HSeparator.new())
	
	add_tool_button({ "tool":Terrain3DEditor.SCULPT, 
		"add_text":"Raise (R)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_HEIGHT_ADD,
		"sub_text":"Lower (R)", "sub_op":Terrain3DEditor.SUBTRACT, "sub_icon":ICON_HEIGHT_SUB })

	add_tool_button({ "tool":Terrain3DEditor.SCULPT, 
		"add_text":"Smooth (Shift)", "add_op":Terrain3DEditor.AVERAGE, "add_icon":ICON_HEIGHT_SMOOTH })

	add_tool_button({ "tool":Terrain3DEditor.HEIGHT, 
		"add_text":"Height (H)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_HEIGHT_FLAT,
		"sub_text":"Height (H)", "sub_op":Terrain3DEditor.SUBTRACT, "sub_icon":ICON_HEIGHT_FLAT })

	add_tool_button({ "tool":Terrain3DEditor.SCULPT, 
		"add_text":"Slope (S)", "add_op":Terrain3DEditor.GRADIENT, "add_icon":ICON_HEIGHT_SLOPE })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Terrain3DEditor.TEXTURE, 
		"add_text":"Paint Base Texture (B)", "add_op":Terrain3DEditor.REPLACE, "add_icon":ICON_PAINT_TEXTURE })

	add_tool_button({ "tool":Terrain3DEditor.TEXTURE, 
		"add_text":"Spray Overlay Texture (V)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_SPRAY_TEXTURE })

	add_tool_button({ "tool":Terrain3DEditor.AUTOSHADER,
		"add_text":"Paint Autoshader (A)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_AUTOSHADER,
		"sub_text":"Disable Autoshader (A)", "sub_op":Terrain3DEditor.SUBTRACT })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Terrain3DEditor.COLOR,
		"add_text":"Paint Color (C)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_COLOR,
		"sub_text":"Remove Color (C)", "sub_op":Terrain3DEditor.SUBTRACT })
	
	add_tool_button({ "tool":Terrain3DEditor.ROUGHNESS,
		"add_text":"Paint Wetness (W)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_WETNESS,
		"sub_text":"Remove Wetness (W)", "sub_op":Terrain3DEditor.SUBTRACT })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Terrain3DEditor.HOLES,
		"add_text":"Add Holes (X)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_HOLES,
		"sub_text":"Remove Holes (X)", "sub_op":Terrain3DEditor.SUBTRACT })

	add_tool_button({ "tool":Terrain3DEditor.NAVIGATION,
		"add_text":"Paint Navigable Area (N)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_NAVIGATION,
		"sub_text":"Remove Navigable Area (N)", "sub_op":Terrain3DEditor.SUBTRACT })

	add_tool_button({ "tool":Terrain3DEditor.INSTANCER,
		"add_text":"Instance Meshes (I)", "add_op":Terrain3DEditor.ADD, "add_icon":ICON_INSTANCER,
		"sub_text":"Remove Meshes (I)", "sub_op":Terrain3DEditor.SUBTRACT })

	# Select first button
	var buttons: Array[BaseButton] = add_tool_group.get_buttons()
	buttons[0].set_pressed(true)
	show_add_buttons(true)


func add_tool_button(p_params: Dictionary) -> void:
	# Additive button
	var button := Button.new()
	var name_str: String = p_params.get("add_text", "blank").get_slice('(', 0).to_pascal_case()
	button.set_name(name_str)
	button.set_meta("Tool", p_params.get("tool", 0))
	button.set_meta("Operation", p_params.get("add_op", 0))
	button.set_meta("ID", add_tool_group.get_buttons().size() + 1)
	button.set_tooltip_text(p_params.get("add_text", "blank"))
	button.set_button_icon(load(p_params.get("add_icon")))
	button.set_flat(true)
	button.set_toggle_mode(true)
	button.set_h_size_flags(SIZE_SHRINK_END)
	button.set_button_group(p_params.get("group", add_tool_group))
	add_child(button, true)
	buttons[button.get_name()] = button

	# Subtractive button
	var button2: Button
	if p_params.has("sub_text"):
		button2 = Button.new()
		name_str = p_params.get("sub_text", "blank").get_slice('(', 0).to_pascal_case()
		button.set_name(name_str)
		button2.set_meta("Tool", p_params.get("tool", 0))
		button2.set_meta("Operation", p_params.get("sub_op", 0))
		button2.set_meta("ID", button.get_meta("ID"))
		button2.set_tooltip_text(p_params.get("sub_text", "blank"))
		button2.set_button_icon(load(p_params.get("sub_icon", p_params.get("add_icon"))))
		button2.set_flat(true)
		button2.set_toggle_mode(true)
		button2.set_h_size_flags(SIZE_SHRINK_END)
	else:
		button2 = button.duplicate()
	button2.set_button_group(p_params.get("group", sub_tool_group))
	add_child(button2, true)
	buttons[button2.get_name()] = button


func get_button(p_name: String) -> Button:
	return buttons.get(p_name, null)


func show_add_buttons(p_enable: bool) -> void:
	for button in add_tool_group.get_buttons():
		button.visible = p_enable
	for button in sub_tool_group.get_buttons():
		button.visible = !p_enable


func _on_tool_selected(p_button: BaseButton) -> void:
	# Select same tool on negative bar
	var group: ButtonGroup = p_button.get_button_group()
	var change_group: ButtonGroup = add_tool_group if group == sub_tool_group else sub_tool_group
	var id: int = p_button.get_meta("ID", -2)
	for button in change_group.get_buttons():
		button.set_pressed_no_signal(button.get_meta("ID", -1) == id)
	
	emit_signal("tool_changed", p_button.get_meta("Tool", Terrain3DEditor.TOOL_MAX), p_button.get_meta("Operation", Terrain3DEditor.OP_MAX))
