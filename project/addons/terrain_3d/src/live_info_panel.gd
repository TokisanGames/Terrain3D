@tool
class_name Terrain3DLiveInfoPanel
extends MarginContainer

@onready var info_label: Label = %InfoLabel
@onready var panel_container: PanelContainer = $PanelContainer

var plugin: EditorPlugin
var enabled: bool = false: set = set_enabled

func _ready() -> void:
	if not plugin.has_setting("terrain3d/config/live_info_panel_enabled"):
		plugin.set_setting("terrain3d/config/live_info_panel_enabled", enabled)
	set_enabled(plugin.get_setting("terrain3d/config/live_info_panel_enabled"))
	panel_container.add_theme_stylebox_override(&"panel", get_theme_stylebox(&"Information3dViewport", &"EditorStyles"))
	info_label.text = "Cursor Pos:\nRegion:\nHeight:\nSlope:\nTexture:"


func update(cursor_position: Vector3) -> void:
	if not enabled:
		return
		
	var region_loc: Vector2i = plugin.terrain.data.get_region_location(cursor_position)
	var lbl_text: String
	var in_region: bool = plugin.editor.get_tool() == Terrain3DEditor.REGION
	lbl_text += "Cursor Pos: %0.1f, %0.1f%s\n" % [ cursor_position.x, cursor_position.z, "*" if in_region else "" ]
	lbl_text += "Region: %s, %s\n" % [region_loc.x, region_loc.y]

	var slope: float = rad_to_deg(plugin.terrain.data.get_normal(cursor_position).angle_to(Vector3.UP))
	if  in_region or is_nan(slope):
		lbl_text += "Height: -\n"
		lbl_text += "Slope: -\n"
		lbl_text += "Texture: -"
	else:
		lbl_text += "Height: %0.2f\n" % plugin.terrain.data.get_height(cursor_position)
		lbl_text += "Slope: %0.1f°\n" % slope
		var texture_id: Vector3 = plugin.terrain.data.get_texture_id(cursor_position)
		var auto: String = "Auto" if plugin.terrain.data.get_control_auto(cursor_position) else "-"
		lbl_text += "Texture: %02d | %02d | %.1f | %s" % [texture_id.x, texture_id.y, texture_id.z, auto ]
	info_label.text = lbl_text

	
func _enter_tree() -> void:
	if not visibility_changed.is_connected(_on_visibilty_changed):
		visibility_changed.connect(_on_visibilty_changed)
		

func _exit_tree() -> void:
	if visibility_changed.is_connected(_on_visibilty_changed):
		visibility_changed.disconnect(_on_visibilty_changed)


func set_enabled(value: bool) -> void:
	enabled = value
	visible = enabled
	plugin.set_setting("terrain3d/config/live_info_panel_enabled", enabled)
	
# When de/selecting the Terrain3D node the live info panel is hidden/shown
# We don't want it to be revealed if it is not enabled 
func _on_visibilty_changed() -> void:
	if not enabled and visible:
		visible = false
