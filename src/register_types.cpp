#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "register_types.h"
#include "terrain.h"
#include "terrain_storage.h"

using namespace godot;

void initialize_terrain_types(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<Terrain3D>();
	ClassDB::register_class<Terrain3DStorage>();
	ClassDB::register_class<TerrainMaterial3D>();
	ClassDB::register_class<TerrainLayerMaterial3D>();
}

void uninitialize_terrain_types(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

// Initialization.

GDExtensionBool GDE_EXPORT terrain_library_init(const GDExtensionInterface *p_interface, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_interface, p_library, r_initialization);

	init_obj.register_initializer(initialize_terrain_types);
	init_obj.register_terminator(uninitialize_terrain_types);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
