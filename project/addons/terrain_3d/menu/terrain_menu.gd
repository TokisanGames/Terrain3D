# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Menu for Terrain3D
extends HBoxContainer


const DirectoryWizard: Script = preload("res://addons/terrain_3d/menu/directory_setup.gd")
const Packer: Script = preload("res://addons/terrain_3d/menu/channel_packer.gd")
const Baker: Script = preload("res://addons/terrain_3d/menu/baker.gd")

var plugin: EditorPlugin
var menu_button: MenuButton = MenuButton.new()
var directory_setup: DirectoryWizard = DirectoryWizard.new()
var packer: Packer = Packer.new()
var baker: Baker = Baker.new()

# These are IDs and order must be consistent with add_item and set_disabled IDs
enum {
	MENU_DIRECTORY_SETUP,
	MENU_PACK_TEXTURES,
	MENU_SEPARATOR,
	MENU_BAKE_ARRAY_MESH,
	MENU_BAKE_OCCLUDER,
	MENU_SEPARATOR2,
	MENU_SET_UP_NAVIGATION,
	MENU_BAKE_NAV_MESH,
}


func _enter_tree() -> void:
	directory_setup.plugin = plugin
	packer.plugin = plugin
	baker.plugin = plugin
	add_child(directory_setup)
	add_child(baker)
	
	menu_button.text = "Terrain3D"
	menu_button.get_popup().add_item("Directory Setup...", 	MENU_DIRECTORY_SETUP)
	menu_button.get_popup().add_item("Pack Textures...", MENU_PACK_TEXTURES)	
	menu_button.get_popup().add_separator("", MENU_SEPARATOR)
	menu_button.get_popup().add_item("Bake ArrayMesh...", MENU_BAKE_ARRAY_MESH)
	menu_button.get_popup().add_item("Bake Occluder3D...", MENU_BAKE_OCCLUDER)
	menu_button.get_popup().add_separator("", MENU_SEPARATOR2)
	menu_button.get_popup().add_item("Set up Navigation...", MENU_SET_UP_NAVIGATION)
	menu_button.get_popup().add_item("Bake NavMesh...", MENU_BAKE_NAV_MESH)
	
	menu_button.get_popup().id_pressed.connect(_on_menu_pressed)
	menu_button.about_to_popup.connect(_on_menu_about_to_popup)
	add_child(menu_button)


func _on_menu_pressed(p_id: int) -> void:
	match p_id:
		MENU_DIRECTORY_SETUP:
			directory_setup.directory_setup_popup()
		MENU_PACK_TEXTURES:
			packer.pack_textures_popup()			
		MENU_BAKE_ARRAY_MESH:
			baker.bake_mesh_popup()
		MENU_BAKE_OCCLUDER:
			baker.bake_occluder_popup()
		MENU_SET_UP_NAVIGATION:
			baker.set_up_navigation_popup()
		MENU_BAKE_NAV_MESH:
			baker.bake_nav_mesh()


func _on_menu_about_to_popup() -> void:
	menu_button.get_popup().set_item_disabled(MENU_DIRECTORY_SETUP, not plugin.terrain)
	menu_button.get_popup().set_item_disabled(MENU_PACK_TEXTURES, not plugin.terrain)
	menu_button.get_popup().set_item_disabled(MENU_BAKE_ARRAY_MESH, not plugin.terrain)
	menu_button.get_popup().set_item_disabled(MENU_BAKE_OCCLUDER, not plugin.terrain)

	if plugin.terrain:
		var nav_regions: Array[NavigationRegion3D] = baker.find_terrain_nav_regions(plugin.terrain)
		menu_button.get_popup().set_item_disabled(MENU_BAKE_NAV_MESH, nav_regions.size() == 0)
		menu_button.get_popup().set_item_disabled(MENU_SET_UP_NAVIGATION, nav_regions.size() != 0)
	elif plugin.nav_region:
		var terrains: Array[Terrain3D] = baker.find_nav_region_terrains(plugin.nav_region)
		menu_button.get_popup().set_item_disabled(MENU_BAKE_NAV_MESH, terrains.size() == 0)
		menu_button.get_popup().set_item_disabled(MENU_SET_UP_NAVIGATION, true)
	else:
		menu_button.get_popup().set_item_disabled(MENU_BAKE_NAV_MESH, true)
		menu_button.get_popup().set_item_disabled(MENU_SET_UP_NAVIGATION, true)
