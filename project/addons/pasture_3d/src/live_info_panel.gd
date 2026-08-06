@tool
class_name Pasture3DLiveInfoPanel
extends MarginContainer

@onready var info_label: Label = %InfoLabel
@onready var panel_container: PanelContainer = $PanelContainer

var plugin: EditorPlugin
var enabled: bool = false: set = set_enabled


func _ready() -> void:
	if not plugin.has_setting("pasture3d/config/live_info_panel_enabled"):
		plugin.set_setting("pasture3d/config/live_info_panel_enabled", enabled)
	set_enabled(plugin.get_setting("pasture3d/config/live_info_panel_enabled", false))
	panel_container.add_theme_stylebox_override(&"panel", get_theme_stylebox(&"Information3dViewport", &"EditorStyles"))
	info_label.text = "Cursor Pos:\nRegion:\nHeight:\nSlope:\nTexture:"


func update(cursor_position: Vector3) -> void:
	if not enabled:
		return
	# Driven from mouse motion in the 3D viewport, which can outlive the terrain: the node can be
	# deleted, or the plugin disabled, between a motion event and this call.
	if plugin == null or not is_instance_valid(plugin.terrain) or plugin.terrain.data == null:
		return

	var region_loc: Vector2i = plugin.terrain.data.get_region_location(cursor_position)
	var lbl_text: String
	# The region tool paints whole regions, so a per-texel height/slope/texture readout under the
	# cursor would be answering a question that tool is not asking. The asterisk marks that.
	var in_region: bool = plugin.editor.get_tool() == Pasture3DEditor.REGION
	lbl_text += "Cursor Pos: %0.1f, %0.1f%s\n" % [cursor_position.x, cursor_position.z, " *" if in_region else ""]
	lbl_text += "Region: %s, %s\n" % [region_loc.x, region_loc.y]

	var slope: float = rad_to_deg(plugin.terrain.data.get_normal(cursor_position).angle_to(Vector3.UP))
	if in_region or is_nan(slope):
		lbl_text += "Height: -\n"
		lbl_text += "Slope: -\n"
		lbl_text += "Texture: -"
	else:
		lbl_text += "Height: %0.2f\n" % plugin.terrain.data.get_height(cursor_position)
		lbl_text += "Slope: %0.1f°\n" % slope
		var texture_id: Vector3 = plugin.terrain.data.get_texture_id(cursor_position)
		var auto: String = "Auto" if plugin.terrain.data.get_control_auto(cursor_position) else "-"
		lbl_text += "Texture: %02d | %02d | %.1f | %s" % [texture_id.x, texture_id.y, texture_id.z, auto]
	info_label.text = lbl_text


func _enter_tree() -> void:
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)


func _exit_tree() -> void:
	if visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.disconnect(_on_visibility_changed)


func set_enabled(value: bool) -> void:
	enabled = value
	visible = enabled
	if plugin:
		plugin.set_setting("pasture3d/config/live_info_panel_enabled", enabled)


# De/selecting the Pasture3D node hides/shows the panel along with the rest of the tool UI.
# Reject the show half when the panel is not enabled.
func _on_visibility_changed() -> void:
	if not enabled and visible:
		visible = false
