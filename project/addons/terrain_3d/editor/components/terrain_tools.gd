extends HBoxContainer


const Baker: Script = preload("res://addons/terrain_3d/editor/components/baker.gd")

var plugin: EditorPlugin
var menu_button: MenuButton = MenuButton.new()
var baker: Baker = Baker.new()

enum {
	MENU_BAKE_ARRAY_MESH,
	MENU_BAKE_OCCLUDER
}


func _enter_tree() -> void:
	baker.plugin = plugin
	
	menu_button.text = "Terrain3D Tools"
	menu_button.get_popup().add_item("Bake ArrayMesh", MENU_BAKE_ARRAY_MESH)
	menu_button.get_popup().add_item("Bake Occluder3D", MENU_BAKE_OCCLUDER)
	menu_button.get_popup().id_pressed.connect(_on_menu_pressed)
	add_child(menu_button)


func _on_menu_pressed(id: int) -> void:
	match id:
		MENU_BAKE_ARRAY_MESH:
			baker.bake_mesh_popup()
		MENU_BAKE_OCCLUDER:
			baker.bake_occluder_popup()
