// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

#include "logger.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DInstancer::Terrain3DInstancer() {
}

Terrain3DInstancer::~Terrain3DInstancer() {
}

void Terrain3DInstancer::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	}
	if (!_terrain || !_terrain->get_storage().is_valid()) {
		LOG(ERROR, "Terrain or storage not ready yet");
		return;
	}

	_multimesh.instantiate();
	_multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
	_multimesh->set_instance_count(0);
	Ref<QuadMesh> mesh;
	mesh.instantiate();
	mesh->set_size(Vector2(.5f, 2.f));
	mesh->set_subdivide_depth(3);
	Ref<StandardMaterial3D> mat;
	mat.instantiate();
	mat->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
	mat->set_albedo(Color(0.f, .624f, .016f));
	mat->set_feature(BaseMaterial3D::FEATURE_BACKLIGHT, true);
	mat->set_backlight(Color(.5f, .5f, .5f));
	/*mat->set_distance_fade(BaseMaterial3D::DISTANCE_FADE_PIXEL_DITHER);
	mat->set_distance_fade_max_distance(20.f);
	mat->set_distance_fade_min_distance(30.f);*/

	mesh->surface_set_material(0, mat);
	_multimesh->set_mesh(mesh);
	_multimesh_instance = memnew(MultiMeshInstance3D);
	_multimesh_instance->set_multimesh(_multimesh);
	_terrain->add_child(_multimesh_instance);
}

void Terrain3DInstancer::destroy() {
	LOG(DEBUG, "Freeing _multimesh_instance");
	memdelete_safely(_multimesh_instance);
}

void Terrain3DInstancer::add_instances(Vector3 p_global_position, real_t p_radius, uint32_t p_count) {
	if (p_count <= 0) {
		return;
	}

	TypedArray<Transform3D> xforms;

	// Place new instances
	for (int i = 0; i < p_count; i++) {
		float r_theta = UtilityFunctions::randf() * Math_TAU;
		float r_radius = sqrt(UtilityFunctions::randf());
		Vector3 rand_vec = Vector3(r_radius * cos(r_theta), 0.f, r_radius * sin(r_theta));
		Transform3D t;
		t.origin = p_global_position + rand_vec * p_radius;

		Vector3 normal = _terrain->get_storage()->get_normal(t.origin);
		if (UtilityFunctions::is_nan(normal.x)) {
			normal = Vector3(0.f, 1.f, 0.f);
		}
		normal = normal.normalized();
		Vector3 z_axis = Vector3(0.f, 0.f, 1.f);
		Vector3 crossp = -z_axis.cross(normal);
		t.basis = Basis(crossp, normal, z_axis).orthonormalized();
		t.basis = t.basis.rotated(normal, UtilityFunctions::randf() * Math_TAU);

		real_t height = _terrain->get_storage()->get_height(t.origin);
		if (UtilityFunctions::is_nan(height)) {
			continue;
		} else {
			t.origin.y = height;
			t.origin += normal * 1.f; // TODO Multiply object height offset, if has center origin
		}
		xforms.push_back(t);
	}

	// Merge with old instances
	if (xforms.size() > 0) {
		uint32_t old_count = _multimesh->get_instance_count();
		for (int i = 0; i < old_count; i++) {
			xforms.push_back(_multimesh->get_instance_transform(i));
		}
		Ref<Mesh> mesh = _multimesh->get_mesh();
		Ref<MultiMesh> mm;
		mm.instantiate();
		mm->set_transform_format(MultiMesh::TRANSFORM_3D);
		mm->set_instance_count(xforms.size());
		mm->set_mesh(mesh);
		for (int i = 0; i < xforms.size(); i++) {
			mm->set_instance_transform(i, xforms[i]);
		}

		_multimesh = mm;
		_multimesh_instance->set_multimesh(_multimesh);
	}
}

void Terrain3DInstancer::remove_instances(Vector3 p_global_position, real_t p_radius, uint32_t p_count) {
	TypedArray<Transform3D> xforms;
	for (int i = 0; i < _multimesh->get_instance_count(); i++) {
		Transform3D t = _multimesh->get_instance_transform(i);
		// If quota not yet met and instance within radius, exclude it
		if (p_count > 0 && (t.origin - p_global_position).length() < p_radius) {
			p_count--;
			continue;
		} else {
			xforms.push_back(t);
		}
	}

	Ref<Mesh> mesh = _multimesh->get_mesh();
	Ref<MultiMesh> mm;
	mm.instantiate();
	mm->set_transform_format(MultiMesh::TRANSFORM_3D);
	mm->set_instance_count(xforms.size());
	mm->set_mesh(mesh);
	for (int i = 0; i < xforms.size(); i++) {
		mm->set_instance_transform(i, xforms[i]);
	}

	_multimesh = mm;
	_multimesh_instance->set_multimesh(_multimesh);
}

void Terrain3DInstancer::save() {
	String path = get_path();
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save instances to external file: " + path);
		Error err;
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		ERR_FAIL_COND(err);
		LOG(DEBUG, "ResourceSaver return error (0 is OK): ", err);
		LOG(INFO, "Finished saving instances");
	}
}

void Terrain3DInstancer::print_multimesh_buffer(MultiMeshInstance3D *p_mmi) {
	if (p_mmi == nullptr) {
		return;
	}
	Ref<MultiMesh> mm = p_mmi->get_multimesh();
	PackedRealArray b = mm->get_buffer();
	UtilityFunctions::print("MM instance count: ", mm->get_instance_count());
	int mmsize = b.size();
	if (mmsize <= 12 || mmsize % 12 != 0) {
		UtilityFunctions::print("MM buffer size not a multiple of 12: ", mmsize);
		return;
	}
	for (int i = 0; i < mmsize; i += 12) {
		Transform3D tfm;
		tfm.set(b[i + 0], b[i + 1], b[i + 2], // basis x
				b[i + 4], b[i + 5], b[i + 6], // basis y
				b[i + 8], b[i + 9], b[i + 10], // basis z
				b[i + 3], b[i + 7], b[i + 11]); // origin
		UtilityFunctions::print(i / 12, ": ", tfm);
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DInstancer::_bind_methods() {

	// Public
	ClassDB::bind_method(D_METHOD("get_multimesh"), &Terrain3DInstancer::get_multimesh);
	ClassDB::bind_method(D_METHOD("add_instances", "global_position", "radius", "count"), &Terrain3DInstancer::add_instances);
	ClassDB::bind_method(D_METHOD("remove_instances", "global_position", "radius", "count"), &Terrain3DInstancer::remove_instances);

	ClassDB::bind_method(D_METHOD("save"), &Terrain3DInstancer::save);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	//ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "textures", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DInstancer"), ro_flags), "set_textures", "get_textures");

	//BIND_CONSTANT(MAX_TEXTURES);

	//ADD_SIGNAL(MethodInfo("textures_changed"));
}
