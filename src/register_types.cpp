// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>

#include "register_types.h"
#include "terrain_3d.h"
#include "terrain_3d_editor.h"

using namespace godot;

void initialize_terrain_3d(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<Terrain3D>();
	ClassDB::register_class<Terrain3DAssets>();
	ClassDB::register_class<Terrain3DData>();
	ClassDB::register_class<Terrain3DEditor>();
	ClassDB::register_class<Terrain3DCollision>();
	ClassDB::register_class<Terrain3DInstancer>();
	ClassDB::register_class<Terrain3DMaterial>();
	ClassDB::register_class<Terrain3DMeshAsset>();
	ClassDB::register_class<Terrain3DRegion>();
	ClassDB::register_class<Terrain3DTextureAsset>();
	ClassDB::register_class<Terrain3DUtil>();
}

void uninitialize_terrain_3d(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
// Initialization.
GDExtensionBool GDE_EXPORT terrain_3d_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_terrain_3d);
	init_obj.register_terminator(uninitialize_terrain_3d);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SERVERS);

	return init_obj.init();
}
}
