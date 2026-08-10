# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Toolbar for Pasture3D
extends VFlowContainer

signal tool_changed(p_tool: Pasture3DEditor.Tool, p_operation: Pasture3DEditor.Operation)
## Landscape-brush pseudo-tools (not C++ Pasture3DEditor.Tools). See PASTURE3D_BRUSH_PLACEMENT_TOOL_SPEC.md.
signal placement_toggled(p_enabled: bool) # Place Brush: click terrain to drop a brush
signal selection_toggled(p_enabled: bool) # Select Brush: click a brush to select it

const ICON_REGION_ADD: String = "res://addons/pasture_3d/icons/region_add.svg"
const ICON_REGION_REMOVE: String = "res://addons/pasture_3d/icons/region_remove.svg"
const ICON_HEIGHT_ADD: String = "res://addons/pasture_3d/icons/height_add.svg"
const ICON_HEIGHT_SUB: String = "res://addons/pasture_3d/icons/height_sub.svg"
const ICON_HEIGHT_FLAT: String = "res://addons/pasture_3d/icons/height_flat.svg"
const ICON_HEIGHT_SLOPE: String = "res://addons/pasture_3d/icons/height_slope.svg"
const ICON_HEIGHT_SMOOTH: String = "res://addons/pasture_3d/icons/height_smooth.svg"
const ICON_LAYER_ERASE: String = "res://addons/pasture_3d/icons/layer_erase.svg"
const ICON_PAINT_TEXTURE: String = "res://addons/pasture_3d/icons/texture_paint.svg"
const ICON_SPRAY_TEXTURE: String = "res://addons/pasture_3d/icons/texture_spray.svg"
const ICON_COLOR: String = "res://addons/pasture_3d/icons/color_paint.svg"
const ICON_WETNESS: String = "res://addons/pasture_3d/icons/wetness.svg"
const ICON_AUTOSHADER: String = "res://addons/pasture_3d/icons/autoshader.svg"
const ICON_HOLES: String = "res://addons/pasture_3d/icons/holes.svg"
const ICON_NAVIGATION: String = "res://addons/pasture_3d/icons/navigation.svg"
const ICON_INSTANCER: String = "res://addons/pasture_3d/icons/multimesh.svg"

## Landscape brushes the Place-Brush tool can drop. Add an entry here to make a new brush placeable;
## the bottom-bar brush-type selector (built in tool_settings.gd) reads this list too. "offset" is the
## default vertical (Y) placement offset applied on top of the surface hit for that brush type.
const PLACEABLE_BRUSHES: Array[Dictionary] = [
	{ "label":"Mound",  "script":"res://addons/pasture_3d/connectors/mound.gd",  "icon":"res://addons/pasture_3d/icons/brush_mound.svg",  "offset":0.0 },
	# Offset 0: a Pond's stamp is inverted, so it carves DOWN from where it is dropped. Lifting it
	# the way Ridge does would leave the basin floating above the ground it is meant to cut into.
	{ "label":"Pond",   "script":"res://addons/pasture_3d/connectors/pond.gd",   "icon":"res://addons/pasture_3d/icons/brush_mound.svg",  "offset":0.0 },
	{ "label":"Ridge",  "script":"res://addons/pasture_3d/connectors/ridge.gd",  "icon":"res://addons/pasture_3d/icons/brush_ridge.svg",  "offset":20.0 },
	{ "label":"Trough", "script":"res://addons/pasture_3d/connectors/trough.gd", "icon":"res://addons/pasture_3d/icons/brush_trough.svg", "offset":-10.0 },
	{ "label":"Plow",   "script":"res://addons/pasture_3d/connectors/plow.gd",   "icon":"res://addons/pasture_3d/icons/brush_plow.svg",   "offset":0.0 },
	{ "label":"Splat",  "script":"res://addons/pasture_3d/connectors/splat.gd",  "icon":"res://addons/pasture_3d/icons/brush_splat.svg",  "offset":0.0 },
	# Sim only ever erodes the ground it is dropped on, so like Pond it wants no placement lift.
	{ "label":"Sim",    "script":"res://addons/pasture_3d/connectors/sim.gd",    "icon":"res://addons/pasture_3d/icons/brush_sim.svg",    "offset":0.0 },
]

var add_tool_group: ButtonGroup = ButtonGroup.new()
var sub_tool_group: ButtonGroup = ButtonGroup.new()
## Place Brush / Select Brush share their own group (allow_unpress so neither needs to stay pressed) —
## they're mutually exclusive with each other but independent of the sculpt/paint radio.
var landscape_tool_group: ButtonGroup = ButtonGroup.new()
var buttons: Dictionary
var placement_button: Button
var select_button: Button
var plugin: EditorPlugin


func _init() -> void:
	set_custom_minimum_size(Vector2(20, 0))


func _ready() -> void:
	add_tool_group.pressed.connect(_on_tool_selected)
	sub_tool_group.pressed.connect(_on_tool_selected)

	add_tool_button({ "tool":Pasture3DEditor.REGION, 
		"add_text":"Add Region (E)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_REGION_ADD,
		"sub_text":"Remove Region", "sub_op":Pasture3DEditor.SUBTRACT, "sub_icon":ICON_REGION_REMOVE })
	
	add_child(HSeparator.new())
	
	add_tool_button({ "tool":Pasture3DEditor.SCULPT, 
		"add_text":"Raise (R)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_HEIGHT_ADD,
		"sub_text":"Lower (R)", "sub_op":Pasture3DEditor.SUBTRACT, "sub_icon":ICON_HEIGHT_SUB })

	add_tool_button({ "tool":Pasture3DEditor.SCULPT, 
		"add_text":"Smooth (Shift)", "add_op":Pasture3DEditor.AVERAGE, "add_icon":ICON_HEIGHT_SMOOTH })

	add_tool_button({ "tool":Pasture3DEditor.HEIGHT, 
		"add_text":"Height (H)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_HEIGHT_FLAT,
		"sub_text":"Height (H)", "sub_op":Pasture3DEditor.SUBTRACT, "sub_icon":ICON_HEIGHT_FLAT })

	add_tool_button({ "tool":Pasture3DEditor.SCULPT,
		"add_text":"Slope (S)", "add_op":Pasture3DEditor.GRADIENT, "add_icon":ICON_HEIGHT_SLOPE })

	# Erase the active height layer's coverage to reveal the layers beneath (non-destructive).
	add_tool_button({ "tool":Pasture3DEditor.SCULPT,
		"add_text":"Erase Layer (G)", "add_op":Pasture3DEditor.ERASE, "add_icon":ICON_LAYER_ERASE })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Pasture3DEditor.TEXTURE, 
		"add_text":"Paint Texture (B)", "add_op":Pasture3DEditor.REPLACE, "add_icon":ICON_PAINT_TEXTURE })

	add_tool_button({ "tool":Pasture3DEditor.TEXTURE, 
		"add_text":"Spray Texture (V)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_SPRAY_TEXTURE })

	add_tool_button({ "tool":Pasture3DEditor.AUTOSHADER,
		"add_text":"Paint Autoshader (A)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_AUTOSHADER,
		"sub_text":"Disable Autoshader (A)", "sub_op":Pasture3DEditor.SUBTRACT })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Pasture3DEditor.COLOR,
		"add_text":"Paint Color (C)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_COLOR,
		"sub_text":"Remove Color (C)", "sub_op":Pasture3DEditor.SUBTRACT })
	
	add_tool_button({ "tool":Pasture3DEditor.ROUGHNESS,
		"add_text":"Paint Wetness (W)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_WETNESS,
		"sub_text":"Remove Wetness (W)", "sub_op":Pasture3DEditor.SUBTRACT })

	add_child(HSeparator.new())

	add_tool_button({ "tool":Pasture3DEditor.HOLES,
		"add_text":"Add Holes (X)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_HOLES,
		"sub_text":"Remove Holes (X)", "sub_op":Pasture3DEditor.SUBTRACT })

	add_tool_button({ "tool":Pasture3DEditor.NAVIGATION,
		"add_text":"Paint Navigable Area (N)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_NAVIGATION,
		"sub_text":"Remove Navigable Area (N)", "sub_op":Pasture3DEditor.SUBTRACT })

	add_tool_button({ "tool":Pasture3DEditor.INSTANCER,
		"add_text":"Instance Meshes (I)", "add_op":Pasture3DEditor.ADD, "add_icon":ICON_INSTANCER,
		"sub_text":"Remove Meshes (I)", "sub_op":Pasture3DEditor.SUBTRACT })

	add_child(HSeparator.new())
	_add_landscape_tools()

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
	buttons[button2.get_name()] = button


## Build the Place Brush + Select Brush toggles. They live in landscape_tool_group (allow_unpress) so
## they're mutually exclusive with each other but don't disturb the sculpt/paint radio. The brush-TYPE
## picker lives in the bottom tool-settings bar (tool_settings.gd), not here.
func _add_landscape_tools() -> void:
	landscape_tool_group.allow_unpress = true

	placement_button = Button.new()
	placement_button.set_name("PlaceBrush")
	placement_button.set_tooltip_text("Place Brush — click the terrain to drop the selected landscape brush")
	placement_button.set_button_icon(load(str(PLACEABLE_BRUSHES[0]["icon"])))
	placement_button.set_flat(true)
	placement_button.set_toggle_mode(true)
	placement_button.set_h_size_flags(SIZE_SHRINK_END)
	placement_button.set_button_group(landscape_tool_group)
	placement_button.toggled.connect(_on_placement_button_toggled)
	add_child(placement_button, true)
	buttons[placement_button.get_name()] = placement_button

	select_button = Button.new()
	select_button.set_name("SelectBrush")
	select_button.set_tooltip_text("Select Brush — click a landscape brush in the viewport to select it")
	select_button.set_button_icon(_select_tool_icon())
	select_button.set_flat(true)
	select_button.set_toggle_mode(true)
	select_button.set_h_size_flags(SIZE_SHRINK_END)
	select_button.set_button_group(landscape_tool_group)
	select_button.toggled.connect(_on_select_button_toggled)
	add_child(select_button, true)
	buttons[select_button.get_name()] = select_button


## Editor "select / arrow" icon for the Select Brush tool, with a fallback to a shipped brush icon.
func _select_tool_icon() -> Texture2D:
	var ic: Texture2D = EditorInterface.get_base_control().get_theme_icon("ToolSelect", "EditorIcons")
	return ic if ic else load("res://addons/pasture_3d/icons/brush_terrain.svg")


func _on_placement_button_toggled(p_pressed: bool) -> void:
	emit_signal("placement_toggled", p_pressed)


func _on_select_button_toggled(p_pressed: bool) -> void:
	emit_signal("selection_toggled", p_pressed)


## Untoggle both landscape tools without re-emitting (the caller has already updated the plugin flags).
func clear_landscape_toggles() -> void:
	if placement_button:
		placement_button.set_pressed_no_signal(false)
	if select_button:
		select_button.set_pressed_no_signal(false)


func get_button(p_name: String) -> Button:
	return buttons.get(p_name, null)


func show_add_buttons(p_enable: bool) -> void:
	for button in add_tool_group.get_buttons():
		button.visible = p_enable
	for button in sub_tool_group.get_buttons():
		button.visible = !p_enable


func _on_tool_selected(p_button: BaseButton) -> void:
	if plugin.debug:
		print("Pasture3DToolbar: _on_tool_selected: ", p_button)

	# A sculpt/paint tool was chosen → leave any landscape tool (its own group won't auto-unpress on a
	# different-group press, so do it explicitly + tell the UI).
	if placement_button and placement_button.button_pressed:
		placement_button.set_pressed_no_signal(false)
		emit_signal("placement_toggled", false)
	if select_button and select_button.button_pressed:
		select_button.set_pressed_no_signal(false)
		emit_signal("selection_toggled", false)

	# Select same tool on negative bar
	var group: ButtonGroup = p_button.get_button_group()
	var change_group: ButtonGroup = add_tool_group if group == sub_tool_group else sub_tool_group
	var id: int = p_button.get_meta("ID", -2)
	for button in change_group.get_buttons():
		button.set_pressed_no_signal(button.get_meta("ID", -1) == id)
	if plugin.debug:
		print("Pasture3DToolbar: _on_tool_selected: emitting tool_changed, ", 
			p_button.get_meta("Tool", Pasture3DEditor.TOOL_MAX), ", ", 
			p_button.get_meta("Operation", Pasture3DEditor.OP_MAX))
	emit_signal("tool_changed", p_button.get_meta("Tool", Pasture3DEditor.TOOL_MAX), p_button.get_meta("Operation", Pasture3DEditor.OP_MAX))


func change_tool(p_name: String) -> void:
	var btn: Button = get_node_or_null(p_name)
	if plugin.debug:
		print("Pasture3DToolbar: change_tool: ", p_name, ", pressed: ", btn and btn.button_pressed)
	if btn and not btn.button_pressed:
		await get_tree().process_frame
		btn.set_pressed(true)
