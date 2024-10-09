// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_region.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Creates MMIs based on stored Multimesh data
void Terrain3DInstancer::_update_mmis(const Vector2i &p_region_loc, const int p_mesh_id) {
	IS_DATA_INIT(VOID);
	LOG(INFO, "Updating MMIs for ", (p_region_loc.x == INT32_MAX) ? "all regions" : "region " + String(p_region_loc),
			(p_mesh_id == -1) ? ", all meshes" : ", mesh " + String::num_int64(p_mesh_id));
	if (_mmis.has(Variant())) {
		_mmis.erase(Variant());
		LOG(WARN, "Removed errant null in MMI dictionary");
	}

	// For specified region_location, or max for all
	Array region_locations;
	if (p_region_loc.x == INT32_MAX) {
		region_locations = _terrain->get_data()->get_region_locations();
	} else {
		region_locations.push_back(p_region_loc);
	}
	for (int r = 0; r < region_locations.size(); r++) {
		Vector2i region_loc = region_locations[r];
		Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(region_loc);
		if (region.is_null()) {
			LOG(WARN, "Errant null region found at: ", region_loc);
			continue;
		}
		Dictionary mesh_dict = region->get_multimeshes();
		LOG(DEBUG, "Updating MMIs from: ", region_loc);

		// For specified mesh id in that region, or -1 for all
		Array mesh_types;
		if (p_mesh_id < 0) {
			mesh_types = mesh_dict.keys();
		} else {
			mesh_types.push_back(p_mesh_id);
		}
		for (int m = 0; m < mesh_types.size(); m++) {
			int mesh_id = mesh_types[m];
			bool fail = false;

			/// Verify the Multimesh data

			// Verify Multimesh exists. It should since its keyed
			Ref<MultiMesh> mm = mesh_dict.get(mesh_id, Ref<MultiMesh>());
			if (mm.is_null()) {
				LOG(DEBUG, "Dictionary for mesh id ", mesh_id, " is null, skipping");
				fail = true;
			}
			// Verify mesh id is valid and has a mesh
			Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(mesh_id);
			Ref<Mesh> mesh;
			if (ma.is_valid()) {
				mesh = ma->get_mesh();
				if (mesh.is_null()) {
					LOG(WARN, "MeshAsset ", mesh_id, " valid but mesh is null, skipping");
					fail = true;
				}
			} else {
				LOG(WARN, "MeshAsset ", mesh_id, " is null, skipping");
				fail = true;
			}
			// Clear this mesh id for this region and skip if fails the above checks
			if (fail) {
				clear_by_location(region_loc, mesh_id);
				continue;
			}

			/// Data seems good, apply it

			// Update mesh in the Multimesh in case IDs or meshes changed.
			mm->set_mesh(mesh);

			// Assign MMs to MMIs, creating any missing MMIs
			Vector3i mmi_key = Vector3i(region_loc.x, region_loc.y, mesh_id);
			MultiMeshInstance3D *mmi;
			if (!_mmis.has(mmi_key)) {
				LOG(DEBUG, "No MMI found, creating new MultiMeshInstance3D, attaching to tree");
				mmi = memnew(MultiMeshInstance3D);
				mmi->set_as_top_level(true);
				_terrain->get_mmi_parent()->add_child(mmi, true);
				_mmis[mmi_key] = mmi;
				LOG(DEBUG, _mmis);
			}
			mmi = cast_to<MultiMeshInstance3D>(_mmis[mmi_key]);
			mmi->set_multimesh(mm);
			mmi->set_cast_shadows_setting(ma->get_cast_shadows());
			if (mmi->is_inside_tree() && mmi->get_global_transform() != Transform3D()) {
				LOG(WARN, "Terrain3D parent nodes have non-zero transform. Resetting instancer global_transform");
				mmi->set_global_transform(Transform3D());
			}
		}
		LOG(DEBUG, "mm: ", mesh_dict);
	}
	LOG(DEBUG, "_mmis: ", _mmis);
}

void Terrain3DInstancer::_destroy_mmi_by_location(const Vector2i &p_region_loc, const int p_mesh_id) {
	Vector3i mmi_key = Vector3i(p_region_loc.x, p_region_loc.y, p_mesh_id);
	LOG(DEBUG, "Deleting MMI at: ", p_region_loc, " mesh_id: ", p_mesh_id);
	MultiMeshInstance3D *mmi = cast_to<MultiMeshInstance3D>(_mmis[mmi_key]);
	bool result = _mmis.erase(mmi_key);
	LOG(DEBUG, "Removing mmi from dictionary: ", mmi, ", success: ", result);
	result = remove_from_tree(mmi);
	LOG(DEBUG, "Removing from tree, success: ", result);
	result = memdelete_safely(mmi);
	LOG(DEBUG, "Deleting MMI, success: ", result);
}

void Terrain3DInstancer::_backup_regionl(const Vector2i &p_region_loc) {
	if (_terrain->get_data() != nullptr) {
		Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(p_region_loc);
		_backup_region(region);
	}
}

void Terrain3DInstancer::_backup_region(const Ref<Terrain3DRegion> &p_region) {
	if (_terrain->get_editor() != nullptr) {
		_terrain->get_editor()->backup_region(p_region);
	} else {
		p_region->set_modified(true);
	}
}

Ref<MultiMesh> Terrain3DInstancer::_create_multimesh(const int p_mesh_id, const TypedArray<Transform3D> &p_xforms, const TypedArray<Color> &p_colors) const {
	Ref<MultiMesh> mm;
	IS_INIT(mm);
	Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	if (mesh_asset.is_null()) {
		LOG(ERROR, "No mesh id ", p_mesh_id, " found");
		return mm;
	}
	Ref<Mesh> mesh = mesh_asset->get_mesh();
	mm.instantiate();
	mm->set_transform_format(MultiMesh::TRANSFORM_3D);
	mm->set_use_colors(true);
	mm->set_mesh(mesh);

	if (p_xforms.size() > 0) {
		mm->set_instance_count(p_xforms.size());
		for (int i = 0; i < p_xforms.size(); i++) {
			mm->set_instance_transform(i, p_xforms[i]);
			if (i < p_colors.size()) {
				mm->set_instance_color(i, p_colors[i]);
			}
		}
	}
	return mm;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DInstancer::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	}
	IS_DATA_INIT_MESG("Terrain or storage not ready yet", VOID);
	LOG(INFO, "Initializing Instancer");
	_update_mmis();
}

void Terrain3DInstancer::destroy() {
	IS_DATA_INIT(VOID);
	LOG(INFO, "Destroying all MMIs");
	while (_mmis.size() > 0) {
		Vector3i key = _mmis.keys()[0];
		_destroy_mmi_by_location(Vector2i(key.x, key.y), key.z);
	}
	_mmis.clear();
}

void Terrain3DInstancer::clear_by_mesh(const int p_mesh_id) {
	LOG(INFO, "Deleting Multimeshes in all regions with mesh_id: ", p_mesh_id);
	Array region_locations = _terrain->get_data()->get_region_locations();
	for (int i = 0; i < region_locations.size(); i++) {
		clear_by_location(region_locations[i], p_mesh_id);
	}
}

void Terrain3DInstancer::clear_by_location(const Vector2i &p_region_loc, const int p_mesh_id) {
	LOG(INFO, "Deleting Multimeshes w/ mesh_id: ", p_mesh_id, " in region: ", p_region_loc);
	Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(p_region_loc);
	clear_by_region(region, p_mesh_id);
}

void Terrain3DInstancer::clear_by_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id) {
	if (p_region.is_null()) {
		LOG(ERROR, "Region is null");
		return;
	}
	Vector2i region_loc = p_region->get_location();
	LOG(INFO, "Deleting Multimeshes w/ mesh_id: ", p_mesh_id, " in region: ", region_loc);
	Dictionary mesh_dict = p_region->get_multimeshes();
	if (mesh_dict.has(p_mesh_id)) {
		_backup_region(p_region);
		mesh_dict.erase(p_mesh_id);
	}
	_destroy_mmi_by_location(region_loc, p_mesh_id);
}

void Terrain3DInstancer::add_instances(const Vector3 &p_global_position, const Dictionary &p_params) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);

	int mesh_id = p_params.get("asset_id", 0);
	if (mesh_id < 0 || mesh_id >= _terrain->get_assets()->get_mesh_count()) {
		LOG(ERROR, "Mesh ID out of range: ", mesh_id, ", valid: 0 to ", _terrain->get_assets()->get_mesh_count() - 1);
		return;
	}
	Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(mesh_id);

	real_t brush_size = CLAMP(real_t(p_params.get("size", 10.f)), 0.1f, 4096.f); // Meters
	real_t radius = brush_size * .4f; // Ring1's inner radius
	real_t strength = CLAMP(real_t(p_params.get("strength", .1f)), .01f, 100.f); // (premul) 1-10k%
	real_t fixed_scale = CLAMP(real_t(p_params.get("fixed_scale", 100.f)) * .01f, .01f, 100.f); // 1-10k%
	real_t random_scale = CLAMP(real_t(p_params.get("random_scale", 0.f)) * .01f, 0.f, 10.f); // +/- 1000%
	real_t density = CLAMP(.1f * brush_size * strength * mesh_asset->get_density() /
					MAX(0.01f, fixed_scale + .5f * random_scale),
			.001f, 1000.f);

	// Density based on strength, mesh AABB and input scale determines how many to place, even fractional
	uint32_t count = _get_instace_count(density);
	if (count <= 0) {
		return;
	}
	LOG(EXTREME, "Adding ", count, " instances at ", p_global_position);

	real_t fixed_spin = CLAMP(real_t(p_params.get("fixed_spin", 0.f)), .0f, 360.f); // degrees
	real_t random_spin = CLAMP(real_t(p_params.get("random_spin", 360.f)), 0.f, 360.f); // degrees
	real_t fixed_angle = CLAMP(real_t(p_params.get("fixed_angle", 0.f)), -180.f, 180.f); // degrees
	real_t random_angle = CLAMP(real_t(p_params.get("random_angle", 10.f)), 0.f, 180.f); // degrees
	bool align_to_normal = bool(p_params.get("align_to_normal", false));

	real_t height_offset = CLAMP(real_t(p_params.get("height_offset", 0.f)), -100.0f, 100.f); // meters
	real_t random_height = CLAMP(real_t(p_params.get("random_height", 0.f)), 0.f, 100.f); // meters

	Color vertex_color = Color(p_params.get("vertex_color", COLOR_WHITE));
	real_t random_hue = CLAMP(real_t(p_params.get("random_hue", 0.f)) / 360.f, 0.f, 1.f); // degrees -> 0-1
	real_t random_darken = CLAMP(real_t(p_params.get("random_darken", 0.f)) * .01f, 0.f, 1.f); // 0-100%

	Vector2 slope_range = p_params["slope"]; // 0-90 degrees already clamped in Editor
	bool invert = p_params["modifier_alt"];
	Terrain3DData *data = _terrain->get_data();

	TypedArray<Transform3D> xforms;
	TypedArray<Color> colors;
	for (int i = 0; i < count; i++) {
		Transform3D t;

		// Get random XZ position and height in a circle
		real_t r_radius = radius * sqrt(UtilityFunctions::randf());
		real_t r_theta = UtilityFunctions::randf() * Math_TAU;
		Vector3 rand_vec = Vector3(r_radius * cos(r_theta), 0.f, r_radius * sin(r_theta));
		Vector3 position = p_global_position + rand_vec;
		// Get height, but skip holes
		real_t height = data->get_height(position);
		if (std::isnan(height)) {
			continue;
		} else {
			position.y = height;
		}
		if (!data->is_in_slope(position, slope_range, invert)) {
			continue;
		}

		// Orientation
		Vector3 normal = Vector3(0.f, 1.f, 0.f);
		if (align_to_normal) {
			normal = data->get_normal(position);
			if (std::isnan(normal.x)) {
				normal = Vector3(0.f, 1.f, 0.f);
			} else {
				normal = normal.normalized();
				Vector3 z_axis = Vector3(0.f, 0.f, 1.f);
				Vector3 x_axis = -z_axis.cross(normal);
				t.basis = Basis(x_axis, normal, z_axis).orthonormalized();
			}
		}
		real_t spin = (fixed_spin + random_spin * UtilityFunctions::randf()) * Math_PI / 180.f;
		if (abs(spin) > 0.001f) {
			t.basis = t.basis.rotated(normal, spin);
		}
		real_t angle = (fixed_angle + random_angle * (2.f * UtilityFunctions::randf() - 1.f)) * Math_PI / 180.f;
		if (abs(angle) > 0.001f) {
			t.basis = t.basis.rotated(t.basis.get_column(0), angle); // Rotate pitch, X-axis
		}

		// Scale
		real_t t_scale = CLAMP(fixed_scale + random_scale * (2.f * UtilityFunctions::randf() - 1.f), 0.01f, 10.f);
		t = t.scaled(Vector3(t_scale, t_scale, t_scale));

		// Position. mesh_asset height offset added in add_transforms
		real_t offset = height_offset + random_height * (2.f * UtilityFunctions::randf() - 1.f);
		position += t.basis.get_column(1) * offset; // Offset along UP axis
		t = t.translated(position);

		// Color
		Color col = vertex_color;
		col.set_v(CLAMP(col.get_v() - random_darken * UtilityFunctions::randf(), 0.f, 1.f));
		col.set_h(fmod(col.get_h() + random_hue * (2.f * UtilityFunctions::randf() - 1.f), 1.f));

		xforms.push_back(t);
		colors.push_back(col);
	}

	// Append multimesh
	if (xforms.size() > 0) {
		add_transforms(mesh_id, xforms, colors);
	}
}

void Terrain3DInstancer::remove_instances(const Vector3 &p_global_position, const Dictionary &p_params) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);

	int mesh_id = p_params.get("asset_id", 0);
	int mesh_count = _terrain->get_assets()->get_mesh_count();
	if (mesh_id < 0 || mesh_id >= mesh_count) {
		LOG(ERROR, "Mesh ID out of range: ", mesh_id, ", valid: 0 to ", _terrain->get_assets()->get_mesh_count() - 1);
		return;
	}

	bool modifier_shift = p_params.get("modifier_shift", false);
	real_t brush_size = CLAMP(real_t(p_params.get("size", 10.f)), .5f, 4096.f); // Meters
	real_t radius = brush_size * .4f; // Ring1's inner radius
	real_t strength = CLAMP(real_t(p_params.get("strength", .1f)), .01f, 100.f); // (premul) 1-10k%
	real_t fixed_scale = CLAMP(real_t(p_params.get("fixed_scale", 100.f)) * .01f, .01f, 100.f); // 1-10k%
	real_t random_scale = CLAMP(real_t(p_params.get("random_scale", 0.f)) * .01f, 0.f, 10.f); // +/- 1000%

	Vector2 slope_range = p_params["slope"]; // 0-90 degrees already clamped in Editor
	bool invert = p_params["modifier_alt"];
	Terrain3DData *data = _terrain->get_data();

	Vector2i region_loc = data->get_region_location(p_global_position);

	// If CTRL+SHIFT pressed, repeat for every mesh, otherwise only do mesh_id
	for (int m = (modifier_shift ? 0 : mesh_id); m <= (modifier_shift ? mesh_count - 1 : mesh_id); m++) {
		Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(m);
		real_t density = CLAMP(.1f * brush_size * strength * mesh_asset->get_density() /
						MAX(0.01f, fixed_scale + .5f * random_scale),
				.001f, 1000.f);

		// Density based on strength, mesh AABB and input scale determines how many to place, even fractional
		uint32_t count = _get_instace_count(density);
		if (count == 0) {
			continue;
		}

		Ref<MultiMesh> multimesh = get_multimesh(region_loc, m);
		if (multimesh.is_null()) {
			LOG(EXTREME, "Multimesh is already null. doing nothing");
			continue;
		}

		LOG(EXTREME, "Removing ", count, " instances from ", p_global_position);
		TypedArray<Transform3D> xforms;
		TypedArray<Color> colors;
		for (int i = 0; i < multimesh->get_instance_count(); i++) {
			Transform3D t = multimesh->get_instance_transform(i);
			// If quota not yet met, instance is within a cylinder radius, and can work on slope, remove it
			Vector2 origin2d = Vector2(t.origin.x, t.origin.z);
			Vector2 mouse2d = Vector2(p_global_position.x, p_global_position.z);
			if (count > 0 && (origin2d - mouse2d).length() < radius &&
					data->is_in_slope(t.origin, slope_range, invert)) {
				count--;
				continue;
			} else {
				xforms.push_back(t);
				colors.push_back(multimesh->get_instance_color(i));
			}
		}

		if (xforms.size() == 0) {
			LOG(DEBUG, "Removed all instances, erasing multimesh in region");
			clear_by_location(region_loc, m);
		} else {
			append_location(region_loc, m, xforms, colors, true);
		}
	}
}

void Terrain3DInstancer::add_multimesh(const int p_mesh_id, const Ref<MultiMesh> &p_multimesh, const Transform3D &p_xform) {
	LOG(INFO, "Extracting ", p_multimesh->get_instance_count(), " transforms from multimesh");
	TypedArray<Transform3D> xforms;
	TypedArray<Color> colors;
	for (int i = 0; i < p_multimesh->get_instance_count(); i++) {
		xforms.push_back(p_xform * p_multimesh->get_instance_transform(i));
		Color c = COLOR_WHITE;
		if (p_multimesh->is_using_colors()) {
			c = p_multimesh->get_instance_color(i);
		}
		colors.push_back(c);
	}
	add_transforms(p_mesh_id, xforms, colors);
}

void Terrain3DInstancer::add_transforms(const int p_mesh_id, const TypedArray<Transform3D> &p_xforms, const TypedArray<Color> &p_colors) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);
	if (p_xforms.size() == 0) {
		return;
	}
	if (p_mesh_id < 0 || p_mesh_id >= _terrain->get_assets()->get_mesh_count()) {
		LOG(ERROR, "Mesh ID out of range: ", p_mesh_id, ", valid: 0 to ", _terrain->get_assets()->get_mesh_count() - 1);
		return;
	}

	Dictionary xforms_dict;
	Dictionary colors_dict;
	Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(p_mesh_id);

	// Separate incoming transforms/colors into Dictionary { region_loc => Array[Transform3D] }
	LOG(INFO, "Separating ", p_xforms.size(), " transforms and ", p_colors.size(), " colors into regions");
	for (int i = 0; i < p_xforms.size(); i++) {
		// Get adjusted xform/color
		Transform3D trns = p_xforms[i];
		trns.origin += trns.basis.get_column(1) * mesh_asset->get_height_offset(); // Offset along UP axis
		Color col = COLOR_WHITE;
		if (p_colors.size() > i) {
			col = p_colors[i];
		}

		// Store by region offset
		Vector2i region_loc = _terrain->get_data()->get_region_location(trns.origin);
		if (!xforms_dict.has(region_loc)) {
			xforms_dict[region_loc] = TypedArray<Transform3D>();
			colors_dict[region_loc] = TypedArray<Color>();
		}
		TypedArray<Transform3D> xforms = xforms_dict[region_loc];
		TypedArray<Color> colors = colors_dict[region_loc];
		xforms.push_back(trns);
		colors.push_back(col);
	}

	// Merge incoming transforms with existing transforms
	Array region_locations = xforms_dict.keys();
	for (int i = 0; i < region_locations.size(); i++) {
		Vector2i region_loc = region_locations[i];
		TypedArray<Transform3D> xforms = xforms_dict[region_loc];
		TypedArray<Color> colors = colors_dict[region_loc];
		LOG(DEBUG, "Adding ", xforms.size(), " transforms to region location: ", region_loc);
		append_location(region_loc, p_mesh_id, xforms, colors);
	}
}

// Appends new transforms to existing multimeshes
void Terrain3DInstancer::append_location(const Vector2i &p_region_loc, const int p_mesh_id,
		const TypedArray<Transform3D> &p_xforms, const TypedArray<Color> &p_colors, const bool p_clear, const bool p_update) {
	IS_DATA_INIT(VOID);
	Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(p_region_loc);
	if (region.is_null()) {
		LOG(WARN, "Null region found at: ", p_region_loc);
		return;
	}
	append_region(region, p_mesh_id, p_xforms, p_colors, p_clear, p_update);
}

void Terrain3DInstancer::append_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id,
		const TypedArray<Transform3D> &p_xforms, const TypedArray<Color> &p_colors, const bool p_clear, const bool p_update) {
	Dictionary mesh_dict = p_region->get_multimeshes();

	// Collect old data
	TypedArray<Transform3D> old_xforms;
	TypedArray<Color> old_colors;
	if (!p_clear) {
		Ref<MultiMesh> multimesh = mesh_dict.get(p_mesh_id, Ref<MultiMesh>());
		if (multimesh.is_valid()) {
			uint32_t old_count = multimesh->get_instance_count();
			LOG(EXTREME, "Merging w/ old instances: ", old_count, ": ", multimesh);
			for (int i = 0; i < old_count; i++) {
				old_xforms.push_back(multimesh->get_instance_transform(i));
				old_colors.push_back(multimesh->get_instance_color(i));
			}
		}
	}

	// Erase empties if no transforms in both the old and new data
	if (old_xforms.size() == 0 && p_xforms.size() == 0) {
		clear_by_region(p_region, p_mesh_id);
		return;
	}

	// Create a new Multimesh
	Ref<MultiMesh> mm = _create_multimesh(p_mesh_id);
	int old_count = old_xforms.size();
	mm->set_instance_count(old_count + p_xforms.size());
	for (int i = 0; i < old_count; i++) {
		mm->set_instance_transform(i, old_xforms[i]);
		mm->set_instance_color(i, old_colors[i]);
	}
	for (int i = 0; i < p_xforms.size(); i++) {
		mm->set_instance_transform(i + old_count, p_xforms[i]);
		mm->set_instance_color(i + old_count, p_colors[i]);
	}

	LOG(EXTREME, "Setting multimesh in region: ", p_region->get_location(), ", mesh_id: ", p_mesh_id, " instance count: ", mm->get_instance_count(), " mm: ", mm);
	_backup_region(p_region);
	mesh_dict[p_mesh_id] = mm;
	if (p_update) {
		_update_mmis(p_region->get_location(), p_mesh_id);
	}
}

// Review all transforms in one area and adjust their transforms w/ the current height
void Terrain3DInstancer::update_transforms(const AABB &p_aabb) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);
	LOG(EXTREME, "Updating transforms for all meshes within ", p_aabb);

	Array region_locations = _terrain->get_data()->get_region_locations();
	Rect2 brush_rect = aabb2rect(p_aabb);
	for (int r = 0; r < region_locations.size(); r++) {
		Vector2i region_loc = region_locations[r];
		Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(region_loc);
		if (region.is_null()) {
			LOG(WARN, "No region found at: ", region_loc);
			continue;
		}
		int region_size = _terrain->get_region_size();
		Rect2 region_rect;
		region_rect.set_position(region_loc * region_size);
		region_rect.set_size(Vector2(region_size, region_size));
		LOG(EXTREME, "RO: ", region_loc, " RAABB: ", region_rect, " intersects: ", brush_rect.intersects(region_rect));

		// If specified area includes this region, update all MMs within
		if (brush_rect.intersects(region_rect)) {
			Dictionary mesh_dict = region->get_multimeshes();
			LOG(EXTREME, "Region ", region_loc, " intersect AABB and contains ", mesh_dict.size(), " mesh types");
			// For all mesh ids
			for (int m = 0; m < mesh_dict.keys().size(); m++) {
				int mesh_id = mesh_dict.keys()[m];
				Ref<MultiMesh> mm = mesh_dict.get(mesh_id, Ref<MultiMesh>());
				if (mm.is_null()) {
					continue;
				}
				Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(mesh_id);
				TypedArray<Transform3D> xforms;
				TypedArray<Color> colors;
				LOG(EXTREME, "Multimesh ", mesh_id, " has ", mm->get_instance_count(), " to review");
				for (int i = 0; i < mm->get_instance_count(); i++) {
					Transform3D t = mm->get_instance_transform(i);
					if (brush_rect.has_point(Vector2(t.origin.x, t.origin.z))) {
						// Reset height to terrain height + mesh height offset along UP axis
						real_t height = _terrain->get_data()->get_height(t.origin);
						// If the new height is a nan due to creating a hole, remove the instance
						if (std::isnan(height)) {
							continue;
						}
						t.origin.y = height + mesh_asset->get_height_offset();
					}
					xforms.push_back(t);
					colors.push_back(mm->get_instance_color(i));
				}
				// Replace multimesh
				append_location(region_loc, mesh_id, xforms, colors, true);
			}
		}
	}
}

// Transfer foliage data from one region to another
// p_src_rect is the vertex/pixel offset into the region data, NOT a global position
// Need to force_update_mmis() after
void Terrain3DInstancer::copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2 &p_src_rect, const Terrain3DRegion *p_dst_region) {
	if (p_src_region == nullptr || p_dst_region == nullptr) {
		LOG(ERROR, "Source (", p_src_region, ") or destination (", p_dst_region, ") regions are null");
		return;
	}
	LOG(INFO, "Copying foliage data from src ", p_src_region->get_location(), " to dest ", p_dst_region->get_location());
	// Get absolute global area, including vertex spacing
	Vector2 global_pos = p_src_rect.position + p_src_region->get_location() * p_src_region->get_region_size();
	Rect2 abs_area(global_pos * _terrain->get_vertex_spacing(),
			p_src_rect.size * _terrain->get_vertex_spacing());
	Dictionary src_mms = p_src_region->get_multimeshes();
	Array keys = src_mms.keys();
	for (int i = 0; i < keys.size(); i++) {
		int mesh_id = keys[i];
		TypedArray<Transform3D> xforms;
		TypedArray<Color> colors;
		Ref<MultiMesh> src_mm = src_mms[mesh_id];
		if (src_mm.is_null()) {
			LOG(ERROR, "Region has null multimesh for mesh_id ", mesh_id);
			continue;
		}
		// Get all transforms within src_area
		for (int j = 0; j < src_mm->get_instance_count(); j++) {
			Transform3D xf = src_mm->get_instance_transform(j);
			if (abs_area.has_point(Point2(xf.origin.x, xf.origin.z))) {
				xforms.push_back(xf);
				if (src_mm->is_using_colors()) {
					colors.push_back(src_mm->get_instance_color(j));
				}
			}
		}
		append_region(Ref<Terrain3DRegion>(p_dst_region), mesh_id, xforms, colors, false, false);
	}
}

// Changes the ID of a mesh, without changing the mesh on the ground
// Called when the mesh asset id has changed. Updates Multimeshes and MMIs dictionary keys
void Terrain3DInstancer::swap_ids(const int p_src_id, const int p_dst_id) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);
	Ref<Terrain3DAssets> assets = _terrain->get_assets();
	int asset_count = assets->get_mesh_count();
	LOG(INFO, "Swapping IDs of multimeshes: ", p_src_id, " and ", p_dst_id);
	if (p_src_id >= 0 && p_src_id < asset_count && p_dst_id >= 0 && p_dst_id < asset_count) {
		// Change id keys in storage mm dictionary
		Array region_locations = _terrain->get_data()->get_region_locations();
		for (int i = 0; i < region_locations.size(); i++) {
			Vector2i region_loc = region_locations[i];
			Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(region_loc);
			if (region.is_null()) {
				LOG(WARN, "No region found at: ", region_loc);
				return;
			}
			Dictionary mesh_dict = region->get_multimeshes();
			// mesh_dict could have src, src&dst, dst or nothing. All 4 must be considered
			// Pop out any existing MMs
			Ref<MultiMesh> mm_src;
			Ref<MultiMesh> mm_dst;
			if (mesh_dict.has(p_src_id)) {
				_backup_region(region);
				mm_src = mesh_dict[p_src_id];
				mesh_dict.erase(p_src_id);
			}
			if (mesh_dict.has(p_dst_id)) {
				_backup_region(region);
				mm_dst = mesh_dict[p_dst_id];
				mesh_dict.erase(p_dst_id);
			}
			// If src is ok, insert into dst slot
			if (mm_src.is_valid()) {
				_backup_region(region);
				mesh_dict[p_dst_id] = mm_src;
			}
			// If dst is ok, insert into src slot
			if (mm_dst.is_valid()) {
				_backup_region(region);
				mesh_dict[p_src_id] = mm_dst;
			}
			LOG(DEBUG, "Swapped multimesh ids at: ", region_loc);
		}

		// Change key in _mmi dictionary
		Array mmi_keys = _mmis.keys();
		Dictionary to_src_mmis;
		Dictionary to_dst_mmis;

		for (int i = 0; i < mmi_keys.size(); i++) {
			Vector3i key = mmi_keys[i];
			if (key.z == p_src_id) {
				Vector3i dst_key = key; // setup destination key
				dst_key.z = p_dst_id;
				to_dst_mmis[dst_key] = _mmis[key]; // store MMI under dest key
				_mmis.erase(key);
			} else if (key.z == p_dst_id) {
				Vector3i src_key = key; // setup source key
				src_key.z = p_src_id;
				to_src_mmis[src_key] = _mmis[key]; // store MMI under src key
				_mmis.erase(key);
			}
		}
		_mmis.merge(to_src_mmis);
		_mmis.merge(to_dst_mmis);
		LOG(DEBUG, "Swapped multimesh instance ids");
	}
}

Ref<MultiMesh> Terrain3DInstancer::get_multimeshp(const Vector3 &p_global_position, const int p_mesh_id) const {
	Vector2i region_loc = _terrain->get_data()->get_region_location(p_global_position);
	return get_multimesh(region_loc, p_mesh_id);
}

Ref<MultiMesh> Terrain3DInstancer::get_multimesh(const Vector2i &p_region_loc, const int p_mesh_id) const {
	IS_DATA_INIT(Ref<MultiMesh>());
	Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(p_region_loc);
	if (region.is_null()) {
		LOG(WARN, "Null region found at: ", p_region_loc);
		return Ref<MultiMesh>();
	}
	Dictionary mesh_dict = region->get_multimeshes();
	Ref<MultiMesh> mm = mesh_dict.get(p_mesh_id, Ref<MultiMesh>());
	LOG(EXTREME, "Retrieving MultiMesh at region: ", p_region_loc, " mesh_id: ", p_mesh_id, " : ", mm);
	return mm;
}

MultiMeshInstance3D *Terrain3DInstancer::get_multimesh_instancep(const Vector3 &p_global_position, const int p_mesh_id) const {
	Vector2i region_loc = _terrain->get_data()->get_region_location(p_global_position);
	return get_multimesh_instance(region_loc, p_mesh_id);
}

MultiMeshInstance3D *Terrain3DInstancer::get_multimesh_instance(const Vector2i &p_region_loc, const int p_mesh_id) const {
	Vector3i key = Vector3i(p_region_loc.x, p_region_loc.y, p_mesh_id);
	MultiMeshInstance3D *mmi = cast_to<MultiMeshInstance3D>(_mmis[key]);
	LOG(EXTREME, "Retrieving MultiMeshInstance3D at region: ", p_region_loc, " mesh_id: ", p_mesh_id, " : ", mmi);
	return mmi;
}

void Terrain3DInstancer::set_cast_shadows(const int p_mesh_id, const GeometryInstance3D::ShadowCastingSetting p_cast_shadows) {
	LOG(INFO, "Setting shadow casting on MMIS with mesh: ", p_mesh_id, " to mode: ", p_cast_shadows);
	Array keys = _mmis.keys();
	for (int i = 0; i < keys.size(); i++) {
		Vector3i key = keys[i];
		if (key.z == p_mesh_id) {
			MultiMeshInstance3D *mmi = cast_to<MultiMeshInstance3D>(_mmis[key]);
			if (mmi) {
				mmi->set_cast_shadows_setting(p_cast_shadows);
			}
		}
	}
}

void Terrain3DInstancer::force_update_mmis() {
	destroy();
	_update_mmis();
}

void Terrain3DInstancer::print_multimesh_buffer(MultiMeshInstance3D *p_mmi) const {
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
	ClassDB::bind_method(D_METHOD("clear_by_mesh", "mesh_id"), &Terrain3DInstancer::clear_by_mesh);
	ClassDB::bind_method(D_METHOD("clear_by_location", "region_location", "mesh_id"), &Terrain3DInstancer::clear_by_location);
	ClassDB::bind_method(D_METHOD("add_instances", "global_position", "params"), &Terrain3DInstancer::add_instances);
	ClassDB::bind_method(D_METHOD("remove_instances", "global_position", "params"), &Terrain3DInstancer::remove_instances);
	ClassDB::bind_method(D_METHOD("add_multimesh", "mesh_id", "multimesh", "transform"), &Terrain3DInstancer::add_multimesh, DEFVAL(Transform3D()));
	ClassDB::bind_method(D_METHOD("add_transforms", "mesh_id", "transforms", "colors"), &Terrain3DInstancer::add_transforms, DEFVAL(TypedArray<Color>()));
	ClassDB::bind_method(D_METHOD("append_location", "region_location", "mesh_id", "transforms", "colors", "clear", "update"), &Terrain3DInstancer::append_location, DEFVAL(false), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("append_region", "region", "mesh_id", "transforms", "colors", "clear", "update"), &Terrain3DInstancer::append_region, DEFVAL(false), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("update_transforms", "aabb"), &Terrain3DInstancer::update_transforms);

	ClassDB::bind_method(D_METHOD("swap_ids", "src_id", "dest_id"), &Terrain3DInstancer::swap_ids);
	ClassDB::bind_method(D_METHOD("get_mmis"), &Terrain3DInstancer::get_mmis);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "mesh_id", "mode"), &Terrain3DInstancer::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("force_update_mmis"), &Terrain3DInstancer::force_update_mmis);
}
