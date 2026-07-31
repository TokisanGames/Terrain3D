// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifdef GDEXTENSION
#include <gdextension_interface.h>
#endif

#include <godot_cpp/core/class_db.hpp>

#include "register_types.h"
#include "pasture_3d.h"
#include "pasture_3d_compat.h"
#include "pasture_3d_editor.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_buoy.h"
#include "pasture_3d_ocean.h"
#include "pasture_3d_wave_profile.h"
#include "pasture_3d_pool_manager.h"

void initialize_pasture_3d_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<Pasture3D>();
	ClassDB::register_class<Pasture3DAssets>();
	ClassDB::register_class<Pasture3DData>();
	ClassDB::register_class<Pasture3DEditor>();
	ClassDB::register_class<Pasture3DCollision>();
	ClassDB::register_class<Pasture3DInstancer>();
	ClassDB::register_class<Pasture3DLayer>();
	ClassDB::register_class<Pasture3DLayerStack>();
	ClassDB::register_class<Pasture3DMaterial>();
	ClassDB::register_class<Pasture3DMeshAsset>();
	ClassDB::register_class<Pasture3DRegion>();
	ClassDB::register_class<Pasture3DTextureAsset>();
	ClassDB::register_class<Pasture3DUtil>();
	// Water bodies (PASTURE3D_WATER_BODIES_SPEC.md). The profile must be registered
	// before the manager: the manager exports a TypedArray of it, and the property
	// hint names the class by string.
	ClassDB::register_class<Pasture3DWaveProfile>();
	ClassDB::register_class<Pasture3DPoolManager>();
	ClassDB::register_class<Pasture3DOcean>();
	ClassDB::register_class<Pasture3DBuoy>();

	// Backward-compat: keep legacy Terrain3D* resource names loadable (see pasture_3d_compat.h).
	ClassDB::register_class<Terrain3DRegion>();
	ClassDB::register_class<Terrain3DMaterial>();
	ClassDB::register_class<Terrain3DAssets>();
	ClassDB::register_class<Terrain3DMeshAsset>();
	ClassDB::register_class<Terrain3DTextureAsset>();
}

void uninitialize_pasture_3d_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

#ifdef GDEXTENSION
extern "C" {
// Initialization.
GDExtensionBool GDE_EXPORT pasture_3d_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_pasture_3d_module);
	init_obj.register_terminator(uninitialize_pasture_3d_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SERVERS);

	return init_obj.init();
}
}
#endif /* GDEXTENSION */
