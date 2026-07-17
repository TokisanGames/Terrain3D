# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
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
var buttons: Dictionary[String, Button]
var plugin: EditorPlugin
var editor_settings: EditorSettings
# < 4.6 compatiblility
var version: int
var default_keybinds: Dictionary[String, String] = {
	"Invert Tool": "Ctrl",
	"Sculpt Smooth": "Shift",
	"Alternate Mode": "Alt",
	"Decrease Tool Size": "[",
	"Increase Tool Size": "]",
	"Decrease Tool Strength": "-",
	"Increase Tool Strength": "=",
	"Toggle Region Grid": "1",
	"Toggle Region Labels": "2",
	"Toggle Contour Lines": "3",
	"Toggle Instancer Grid": "4",
	"Toggle Vertex Grid": "5",
	"Add or Remove Region": "E",
	"Sculpt Raise or Lower": "R",
	"Sculpt Height": "H",
	"Sculpt Slope": "S",
	"Paint Color": "C",
	"Remove Color": "C",
	"Paint Navigable Area": "N",
	"Remove Navigable Area": "N",
	"Instance Meshes": "I",
	"Remove Meshes": "I",
	"Add Holes": "X",
	"Paint Wetness": "W",
	"Remove Wetness": "W",
	"Paint Texture": "B",
	"Spray Texture": "V",
	"Paint Autoshader": "A",
	"Inverse Slope Range": "T",
}


func _init() -> void:
	set_custom_minimum_size(Vector2(20, 0))
	version = Engine.get_version_info().hex


func _ready() -> void:
	add_tool_group.pressed.connect(_on_tool_selected)
	sub_tool_group.pressed.connect(_on_tool_selected)
	
	editor_settings = EditorInterface.get_editor_settings()
	
	add_tool_button({ "tool":Terrain3DEditor.REGION,
		"add_text":"Add Region (%s)" % get_shortcut_key("Add or Remove Region"), 
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_REGION_ADD,
		"sub_text":"Remove Region (%s)" % get_shortcut_key("Add or Remove Region"),
		"sub_op":Terrain3DEditor.SUBTRACT, "sub_icon":ICON_REGION_REMOVE })
	
	add_child(HSeparator.new())
	
	add_tool_button({ "tool":Terrain3DEditor.SCULPT,
		"add_text":"Raise (%s)" % get_shortcut_key("Sculpt Raise or Lower"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_HEIGHT_ADD,
		"sub_text":"Lower (%s)" % get_shortcut_key("Sculpt Raise or Lower"),
		"sub_op":Terrain3DEditor.SUBTRACT, "sub_icon":ICON_HEIGHT_SUB })

	add_tool_button({ "tool":Terrain3DEditor.SCULPT,
		"add_text":"Smooth (%s)" % get_shortcut_key("Sculpt Smooth"),
		"add_op":Terrain3DEditor.AVERAGE, "add_icon":ICON_HEIGHT_SMOOTH })

	add_tool_button({ "tool":Terrain3DEditor.HEIGHT,
		"add_text":"Height (%s)" % get_shortcut_key("Sculpt Height"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_HEIGHT_FLAT,
		"sub_text":"Height (%s)" % get_shortcut_key("Sculpt Height"),
		"sub_op":Terrain3DEditor.SUBTRACT, "sub_icon":ICON_HEIGHT_FLAT })

	add_tool_button({ "tool":Terrain3DEditor.SCULPT,
		"add_text":"Slope (%s)" % get_shortcut_key("Sculpt Slope"),
		"add_op":Terrain3DEditor.GRADIENT, "add_icon":ICON_HEIGHT_SLOPE })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Terrain3DEditor.TEXTURE,
		"add_text":"Paint Texture (%s)" % get_shortcut_key("Paint Texture"),
		"add_op":Terrain3DEditor.REPLACE, "add_icon":ICON_PAINT_TEXTURE })

	add_tool_button({ "tool":Terrain3DEditor.TEXTURE,
		"add_text":"Spray Texture (%s)" % get_shortcut_key("Spray Texture"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_SPRAY_TEXTURE })

	add_tool_button({ "tool":Terrain3DEditor.AUTOSHADER,
		"add_text":"Paint Autoshader (%s)" % get_shortcut_key("Paint Autoshader"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_AUTOSHADER,
		"sub_text":"Disable Autoshader (%s)" % get_shortcut_key("Paint Autoshader"),
		"sub_op":Terrain3DEditor.SUBTRACT })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Terrain3DEditor.COLOR,
		"add_text":"Paint Color (%s)"  % get_shortcut_key("Paint Color"), 
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_COLOR,
		"sub_text":"Remove Color (%s)" % get_shortcut_key("Remove Color"),
		"sub_op":Terrain3DEditor.SUBTRACT })
	
	add_tool_button({ "tool":Terrain3DEditor.ROUGHNESS,
		"add_text":"Paint Wetness (%s)" % get_shortcut_key("Paint Wetness"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_WETNESS,
		"sub_text":"Remove Wetness (%s)" % get_shortcut_key("Remove Wetness"),
		"sub_op":Terrain3DEditor.SUBTRACT })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Terrain3DEditor.HOLES,
		"add_text":"Add Holes (%s)" % get_shortcut_key("Add Holes"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_HOLES,
		"sub_text":"Remove Holes (%s)" % get_shortcut_key("Add Holes"),
		"sub_op":Terrain3DEditor.SUBTRACT })

	add_tool_button({ "tool":Terrain3DEditor.NAVIGATION,
		"add_text":"Paint Navigable Area (%s)" % get_shortcut_key("Paint Navigable Area"),
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_NAVIGATION,
		"sub_text":"Remove Navigable Area (%s)" % get_shortcut_key("Remove Navigable Area"),
		"sub_op":Terrain3DEditor.SUBTRACT })

	add_tool_button({ "tool":Terrain3DEditor.INSTANCER,
		"add_text":"Instance Meshes (%s)" % get_shortcut_key("Instance Meshes"), 
		"add_op":Terrain3DEditor.ADD, "add_icon":ICON_INSTANCER,
		"sub_text":"Remove Meshes (%s)" % get_shortcut_key("Remove Meshes"), 
		"sub_op":Terrain3DEditor.SUBTRACT })

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
		button2.set_name(name_str)
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
	buttons[button2.get_name()] = button2


func get_button(p_name: String) -> Button:
	return buttons.get(p_name, null)


func show_add_buttons(p_enable: bool) -> void:
	for button in add_tool_group.get_buttons():
		button.visible = p_enable
	for button in sub_tool_group.get_buttons():
		button.visible = !p_enable


func update_tooltips() -> void:
	buttons["AddRegion"].tooltip_text = "Add Region (%s)" % get_shortcut_key("Add or Remove Region")
	buttons["RemoveRegion"].tooltip_text = "Remove Region (%s)" % get_shortcut_key("Add or Remove Region")
	buttons["Raise"].tooltip_text = "Raise (%s)" % get_shortcut_key("Sculpt Raise or Lower")
	buttons["Lower"].tooltip_text = "Lower (%s)" % get_shortcut_key("Sculpt Raise or Lower")
	buttons["Height"].tooltip_text = "Height (%s)" % get_shortcut_key("Sculpt Height")
	buttons["Slope"].tooltip_text = "Slope (%s)" % get_shortcut_key("Sculpt Slope")
	buttons["PaintTexture"].tooltip_text = "Paint Texture (%s)" % get_shortcut_key("Paint Texture")
	buttons["SprayTexture"].tooltip_text = "Spray Texture (%s)" % get_shortcut_key("Spray Texture")
	buttons["PaintAutoshader"].tooltip_text = "Paint Autoshader (%s)" % get_shortcut_key("Paint Autoshader")
	buttons["DisableAutoshader"].tooltip_text = "Disable Autoshader (%s)" % get_shortcut_key("Paint Autoshader")
	buttons["PaintColor"].tooltip_text = "Paint Color (%s)"  % get_shortcut_key("Paint Color")
	buttons["RemoveColor"].tooltip_text = "Remove Color (%s)"  % get_shortcut_key("Paint Color")
	buttons["PaintWetness"].tooltip_text = "Paint Wetness (%s)" % get_shortcut_key("Paint Wetness")
	buttons["RemoveWetness"].tooltip_text = "Remove Wetness (%s)" % get_shortcut_key("Paint Wetness")
	buttons["AddHoles"].tooltip_text = "Add Holes (%s)" % get_shortcut_key("Add Holes")
	buttons["RemoveHoles"].tooltip_text = "Remove Holes (%s)" % get_shortcut_key("Add Holes")
	buttons["PaintNavigableArea"].tooltip_text = "Paint Navigable Area (%s)" % get_shortcut_key("Paint Navigable Area")
	buttons["RemoveNavigableArea"].tooltip_text = "Remove Navigable Area (%s)" % get_shortcut_key("Paint Navigable Area")
	buttons["InstanceMeshes"].tooltip_text = "Instance Meshes (%s)" % get_shortcut_key("Instance Meshes")
	buttons["RemoveMeshes"].tooltip_text = "Remove Meshes (%s)" % get_shortcut_key("Instance Meshes")


func get_shortcut_key(shortcut_name: String) -> String:
	if version >= 0x040600:
		var shortcut:Shortcut = editor_settings.get_shortcut("terrain_3d/" + shortcut_name)
		if shortcut:
			var event:InputEvent = shortcut.events[0]
			var key:String = event.as_text()
			key = key.rstrip(" - Physical")
			return key
		else:
			return ""
	else: # < 4.6 compatiblility
		return default_keybinds[shortcut_name]


func _on_tool_selected(p_button: BaseButton) -> void:
	if plugin.debug:
		print("Terrain3DToolbar: _on_tool_selected: ", p_button)
	# Select same tool on negative bar
	var group: ButtonGroup = p_button.get_button_group()
	var change_group: ButtonGroup = add_tool_group if group == sub_tool_group else sub_tool_group
	var id: int = p_button.get_meta("ID", -2)
	for button in change_group.get_buttons():
		button.set_pressed_no_signal(button.get_meta("ID", -1) == id)
	if plugin.debug:
		print("Terrain3DToolbar: _on_tool_selected: emitting tool_changed, ", 
			p_button.get_meta("Tool", Terrain3DEditor.TOOL_MAX), ", ", 
			p_button.get_meta("Operation", Terrain3DEditor.OP_MAX))
	emit_signal("tool_changed", p_button.get_meta("Tool", Terrain3DEditor.TOOL_MAX), p_button.get_meta("Operation", Terrain3DEditor.OP_MAX))


func change_tool(p_name: String) -> void:
	var btn: Button = get_node_or_null(p_name)
	if plugin.debug:
		print("Terrain3DToolbar: change_tool: ", p_name, ", pressed: ", btn and btn.button_pressed)
	if btn and not btn.button_pressed:
		await get_tree().process_frame
		btn.set_pressed(true)
