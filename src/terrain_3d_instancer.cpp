// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/resource_saver.hpp>

#include "constants.h"
#include "logger.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_region.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Creates MMIs based on Multimesh data stored in Terrain3DRegions
void Terrain3DInstancer::_process_updates() {
	if (_queued_updates.empty()) {
		if (RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates))) {
			LOG(DEBUG, "Disconnect from RS::frame_pre_draw signal");
			RS->disconnect("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates));
		}
		return;
	}
	IS_DATA_INIT(VOID);
	const Terrain3DData *data = _terrain->get_data();
	TypedArray<Vector2i> region_locations = data->get_region_locations();
	int mesh_count = _terrain->get_assets()->get_mesh_count();

	// Process all regions/mesh_ids sentinel and exit
	bool update_all = false;
	if (_queued_updates.find({ V2I_MAX, -2 }) != _queued_updates.end()) {
		destroy();
		update_all = true;
	} else if (_queued_updates.find({ V2I_MAX, -1 }) != _queued_updates.end()) {
		update_all = true;
	}
	if (update_all) {
		LOG(DEBUG, "Updating all regions, all mesh_ids");
		for (int i = 0; i < region_locations.size(); i++) {
			Vector2i region_loc = region_locations[i];
			const Terrain3DRegion *region = data->get_region_ptr(region_loc);
			if (!region) {
				LOG(WARN, "Errant null region found at: ", region_loc);
				continue;
			}
			for (int mesh_id = 0; mesh_id < mesh_count; mesh_id++) {
				auto pair = std::make_pair(region_loc, mesh_id);
				if (region->get_instances().has(mesh_id)) {
					_update_mmi_by_region(region, mesh_id);
				}
			}
		}
		_queued_updates.clear();
		return;
	}

	// Identify pairs to process in a de-duplicating Set
	V2IIntPair to_process;

	// Process queued pairs with at least one specific element
	for (const auto &[queued_loc, queued_mesh] : _queued_updates) {
		if (queued_loc == V2I_MAX && queued_mesh < 0 || queued_mesh >= mesh_count) {
			continue; // Skip sentinels handled above
		}
		// If all regions for specific mesh_id
		if (queued_loc == V2I_MAX && queued_mesh >= 0) {
			for (int i = 0; i < region_locations.size(); i++) {
				Vector2i region_loc = region_locations[i];
				auto pair = std::make_pair(region_loc, queued_mesh);
				to_process.emplace(pair);
			}
		} else {
			// Else one specific region
			if (queued_mesh == -1) {
				// All mesh_ids for this region
				for (int mesh_id = 0; mesh_id < mesh_count; mesh_id++) {
					auto pair = std::make_pair(queued_loc, mesh_id);
					to_process.emplace(pair);
				}
			} else {
				// Specific region + mesh - most common case
				auto pair = std::make_pair(queued_loc, queued_mesh);
				to_process.emplace(pair);
			}
		}
	}
	LOG(DEBUG, "Processing ", (int)to_process.size(), " queued updates");
	for (const auto &[region_loc, mesh_id] : to_process) {
		const Terrain3DRegion *region = data->get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "Errant null region found at: ", region_loc);
			continue;
		}
		if (!region->get_instances().has(mesh_id)) {
			continue;
		}
		_update_mmi_by_region(region, mesh_id);
	}
	_queued_updates.clear();
}

void Terrain3DInstancer::_update_mmi_by_region(const Terrain3DRegion *p_region, const int p_mesh_id) {
	if (!p_region) {
		LOG(ERROR, "p_region is null");
		return;
	}
	if (p_mesh_id < 0 || p_mesh_id >= Terrain3DAssets::MAX_MESHES) {
		LOG(ERROR, "p_mesh_id is out of bounds");
		return;
	}
	Vector2i region_loc = p_region->get_location();
	Dictionary mesh_inst_dict = p_region->get_instances();

	// Create MMI container if needed (always, per region)
	String rname("Region" + Util::location_to_string(region_loc));
	if (_mmi_containers.count(region_loc) == 0) {
		LOG(DEBUG, "Creating new region MMI container Terrain3D/MMI/", rname);
		Node3D *node = memnew(Node3D);
		node->set_name(rname);
		_mmi_containers[region_loc] = node;
		_terrain->get_mmi_parent()->add_child(node, true);
	}

	// Verify mesh id is valid, enabled, and has MeshInstance3Ds
	Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	if (!ma.is_valid()) {
		LOG(WARN, "MeshAsset ", p_mesh_id, " is null, destroying MMIs");
		_destroy_mmi_by_location(region_loc, p_mesh_id); // Clean up if orphaned
		return;
	}
	if (!ma->is_enabled()) {
		LOG(DEBUG, "Disabling mesh ", p_mesh_id, " in region ", region_loc, ": destroying MMIs");
		_destroy_mmi_by_location(region_loc, p_mesh_id);
		return;
	}
	if (ma->get_lod_count() == 0) {
		LOG(WARN, "MeshAsset ", p_mesh_id, " valid but has no meshes, destroying MMIs");
		_destroy_mmi_by_location(region_loc, p_mesh_id);
		return;
	}

	// Process cells
	Dictionary cell_inst_dict = mesh_inst_dict[p_mesh_id];
	Array cell_locations = cell_inst_dict.keys();

	for (int c = 0; c < cell_locations.size(); c++) {
		Vector2i cell = cell_locations[c];
		Array triple = cell_inst_dict[cell];
		if (triple.size() < 3) {
			LOG(WARN, "Triple is empty for region, ", region_loc, ", cell ", cell);
			continue;
		}
		TypedArray<Transform3D> xforms = triple[0];
		PackedColorArray colors = triple[1];
		bool modified = triple[2];

		// Clean MMIs if xforms have been removed
		if (xforms.size() == 0) {
			LOG(EXTREME, "Empty cell in region ", region_loc, " mesh ", p_mesh_id, " cell ", cell, ": destroying MMIs");
			_destroy_mmi_by_cell(region_loc, p_mesh_id, cell);
			continue;
		}
		// Clean MMIs f/ LODs not used
		for (int lod = 0; lod < Terrain3DMeshAsset::MAX_LOD_COUNT; lod++) {
			if (lod > ma->get_last_lod() || (ma->get_cast_shadows() == SHADOWS_ONLY && (lod > ma->get_last_shadow_lod() || lod < ma->get_shadow_impostor()))) {
				_destroy_mmi_by_cell(region_loc, p_mesh_id, cell, lod);
				LOG(EXTREME, "Destroyed old MMIs mesh ", p_mesh_id, " cell ", cell, ", LOD ", lod);
			}
		}
		// Clean Shadow MMIs
		bool shadow_lod_disabled = (ma->get_shadow_impostor() == 0 ||
				ma->get_cast_shadows() == SHADOWS_OFF);
		if (shadow_lod_disabled) {
			_destroy_mmi_by_cell(region_loc, p_mesh_id, cell, Terrain3DMeshAsset::SHADOW_LOD_ID);
			LOG(EXTREME, "Destroyed stale shadow MMI mesh ", p_mesh_id, " for disabled impostor in cell ", cell);
		}

		// Setup MMIs for each LOD + shadows

		// Get or create mesh dict (defined here as cleanup above might invalidate it)
		MeshMMIDict &mesh_mmi_dict = _mmi_nodes[region_loc];
		Ref<MultiMesh> shadow_impostor_source_mm;

		for (int lod = ma->get_last_lod(); lod >= Terrain3DMeshAsset::SHADOW_LOD_ID; lod--) {
			// Don't create shadow MMI if not needed
			if (lod == Terrain3DMeshAsset::SHADOW_LOD_ID && shadow_lod_disabled) {
				continue;
			}
			// Don't create MMIs for certain lods in Shadows only
			if (ma->get_cast_shadows() == SHADOWS_ONLY &&
					lod >= 0 && (lod > ma->get_last_shadow_lod() || lod < ma->get_shadow_impostor())) {
				continue;
			}

			// Get or create MMI - [] creates key if missing
			Vector2i mesh_key(p_mesh_id, lod);
			CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
			MultiMeshInstance3D *mmi = cell_mmi_dict[cell]; // null if missing
			if (!mmi) {
				mmi = memnew(MultiMeshInstance3D);
				LOG(EXTREME, "No MMI found, Created new MultiMeshInstance3D for cell ", cell, ": ", ptr_to_str(mmi));
				// Node name is MMI3D_Cell##_##_Mesh#_LOD#
				String cstring = "_C" + Util::location_to_string(cell).trim_prefix("_");
				String mstring = "_M" + String::num_int64(p_mesh_id);
				String lstring = "_L" + ((lod == Terrain3DMeshAsset::SHADOW_LOD_ID) ? "S" : String::num_int64(lod));
				mmi->set_name("MMI3D" + cstring + mstring + lstring);
				cell_mmi_dict[cell] = mmi;

				//Attach to tree
				Node *node_container = _terrain->get_mmi_parent()->get_node_internal(rname);
				if (!node_container) {
					LOG(ERROR, rname, " isn't attached to the tree.");
					memdelete(mmi);
					cell_mmi_dict.erase(cell);
					continue;
				}
				node_container->add_child(mmi, true);
				modified = true; // New MMI needs full update
			}

			// Always update MMI propertiess
			if (ma->is_highlighted()) {
				mmi->set_material_override(ma->get_highlight_material());
				mmi->set_material_overlay(Ref<Material>());
			} else {
				mmi->set_material_override(ma->get_material_override());
				mmi->set_material_overlay(ma->get_material_overlay());
			}
			mmi->set_cast_shadows_setting(ma->get_lod_cast_shadows(lod));
			_set_mmi_lod_ranges(mmi, ma, lod);

			// Reposition MMI to region location
			Transform3D t = Transform3D();
			int region_size = p_region->get_region_size();
			real_t vertex_spacing = _terrain->get_vertex_spacing();
			t.origin.x += region_loc.x * region_size * vertex_spacing;
			t.origin.z += region_loc.y * region_size * vertex_spacing;
			mmi->set_as_top_level(true);
			mmi->set_global_transform(t);

			// Only recreate MultiMesh if modified/no existing (with override for shadow)
			// Always update shadow MMI (source may have changed)
			if (modified || mmi->get_multimesh().is_null() ||
					lod == Terrain3DMeshAsset::SHADOW_LOD_ID) {
				// Subtract previous instance count of this MMI
				if (lod == 0) {
					if (mmi->get_multimesh().is_valid()) {
						ma->update_instance_count(-mmi->get_multimesh()->get_instance_count());
					}
				}

				Ref<MultiMesh> mm;
				if (lod == Terrain3DMeshAsset::SHADOW_LOD_ID) {
					// Reuse impostor LOD MM as shadow impostor
					mm = shadow_impostor_source_mm;
					if (mm.is_null()) {
						LOG(ERROR, "Shadow MM is null for cell ", cell, " lod ", lod, " xforms: ", xforms.size());
						continue;
					}
				} else {
					mm = _create_multimesh(p_mesh_id, lod, xforms, colors);
				}
				if (mm.is_null()) {
					LOG(ERROR, "Null MM for cell ", cell, " lod ", lod, " xforms: ", xforms.size());
					continue;
				}
				mmi->set_multimesh(mm);

				// Add current instance count of this new MMI
				if (lod == 0) {
					ma->update_instance_count(mm->get_instance_count());
				}

				// Clear modified only for visible LODs
				if (lod != Terrain3DMeshAsset::SHADOW_LOD_ID) {
					triple[2] = false;
				}
			} else {
				// Needed to update generated mesh changes
				mmi->get_multimesh()->set_mesh(ma->get_mesh(lod));
			}
			// Capture source MM from shadow impostor LOD
			if (lod == ma->get_shadow_impostor()) {
				shadow_impostor_source_mm = mmi->get_multimesh();
			}
		} // End for LOD loop

		// Set all LOD mmi AABB to match LOD0 to ensure no gaps between transitions.
		AABB mmi_custom_aabb;
		for (int lod = 0; lod <= ma->get_last_lod(); lod++) {
			Vector2i mesh_key(p_mesh_id, lod);
			CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
			MultiMeshInstance3D *mmi = cell_mmi_dict[cell];
			if (mmi) {
				if (lod == 0) {
					mmi_custom_aabb = mmi->get_aabb();
				} else {
					mmi->set_custom_aabb(mmi_custom_aabb);
				}
			}
		}
		if (ma->get_shadow_impostor() > 0) {
			Vector2i mesh_key(p_mesh_id, Terrain3DMeshAsset::SHADOW_LOD_ID);
			CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
			MultiMeshInstance3D *mmi = cell_mmi_dict[cell];
			if (mmi) {
				mmi->set_custom_aabb(mmi_custom_aabb);
			}
		}
	}
}

void Terrain3DInstancer::_set_mmi_lod_ranges(MultiMeshInstance3D *p_mmi, const Ref<Terrain3DMeshAsset> &p_ma, const int p_lod) {
	if (!p_mmi || p_ma.is_null()) {
		return;
	}
	int source_lod = p_lod;
	real_t lod_begin = p_ma->get_lod_range_begin(source_lod);
	real_t lod_end = p_ma->get_lod_range_end(source_lod);
	if (source_lod == Terrain3DMeshAsset::SHADOW_LOD_ID) {
		source_lod = p_ma->get_shadow_impostor();
		lod_begin = 0.f;
		lod_end = p_ma->get_lod_range_begin(source_lod);
	}
	real_t margin = p_ma->get_fade_margin();
	if (margin > 0.f) {
		lod_begin = MAX(lod_begin < 0.001f ? 0.f : lod_begin - margin, 0.f);
		lod_end = MAX(lod_end < 0.001f ? 0.f : lod_end + margin, 0.f);
		p_mmi->set_visibility_range_begin_margin(lod_begin < 0.001f ? 0.f : margin);
		p_mmi->set_visibility_range_end_margin(lod_end < 0.001f ? 0.f : margin);
		p_mmi->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_SELF);
	} else {
		// Fade mode unset (Godot default)
		p_mmi->set_visibility_range_begin_margin(0.f);
		p_mmi->set_visibility_range_end_margin(0.f);
		p_mmi->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_DISABLED);
	}
	p_mmi->set_visibility_range_begin(lod_begin);
	p_mmi->set_visibility_range_end(lod_end);
}

void Terrain3DInstancer::_update_vertex_spacing(const real_t p_vertex_spacing) {
	IS_DATA_INIT(VOID);
	TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
	for (int r = 0; r < region_locations.size(); r++) {
		Vector2i region_loc = region_locations[r];
		Terrain3DRegion *region = _terrain->get_data()->get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "Errant null region found at: ", region_loc);
			continue;
		}
		real_t old_spacing = region->get_vertex_spacing();
		if (old_spacing == p_vertex_spacing) {
			LOG(DEBUG, "region vertex spacing == vertex spacing, skipping update transform spacing for region at: ", region_loc);
			continue;
		}

		// For all mesh_ids in region
		Dictionary mesh_inst_dict = region->get_instances();
		LOG(DEBUG, "Updating MMIs from: ", region_loc);
		Array mesh_types = mesh_inst_dict.keys();
		for (int m = 0; m < mesh_types.size(); m++) {
			int mesh_id = mesh_types[m];
			Dictionary cell_inst_dict = mesh_inst_dict[mesh_id];
			Array cell_locations = cell_inst_dict.keys();
			for (int c = 0; c < cell_locations.size(); c++) {
				// Get instances
				Vector2i cell = cell_locations[c];
				Array triple = cell_inst_dict[cell];
				TypedArray<Transform3D> xforms = triple[0];
				// Descale, then Scale to the new value
				for (int i = 0; i < xforms.size(); i++) {
					Transform3D t = xforms[i];
					t.origin.x /= old_spacing;
					t.origin.x *= p_vertex_spacing;
					t.origin.z /= old_spacing;
					t.origin.z *= p_vertex_spacing;
					xforms[i] = t;
				}
				triple[0] = xforms;
				triple[2] = true;
				cell_inst_dict[cell] = triple;
			}
		}
		// After all transforms are updated, set the new region vertex spacing value
		region->set_vertex_spacing(p_vertex_spacing);
		region->set_modified(true);
	}
	update_mmis(-1, V2I_MAX, true);
}

void Terrain3DInstancer::_destroy_mmi_by_mesh(const int p_mesh_id) {
	LOG(DEBUG, "Deleting all MMIs in all regions with mesh_id: ", p_mesh_id);
	TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
	for (int i = 0; i < region_locations.size(); i++) {
		Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
		ma.is_valid() ? ma->set_instance_count(0) : void(); // Reset count for this mesh
		_destroy_mmi_by_location(region_locations[i], p_mesh_id);
	}
}

void Terrain3DInstancer::_destroy_mmi_by_location(const Vector2i &p_region_loc, const int p_mesh_id) {
	LOG(DEBUG, "Deleting all MMIs in region: ", p_region_loc, " for mesh_id: ", p_mesh_id);
	std::unordered_set<Vector2i, Vector2iHash> cells;
	if (_mmi_nodes.count(p_region_loc) > 0) {
		MeshMMIDict &mesh_mmi_dict = _mmi_nodes[p_region_loc];
		for (const auto &mesh_entry : mesh_mmi_dict) {
			const Vector2i &mesh_key = mesh_entry.first;
			if (mesh_key.x != p_mesh_id) {
				continue;
			}
			const CellMMIDict &cell_mmi_dict = mesh_entry.second;
			for (const auto &cell_entry : cell_mmi_dict) {
				cells.insert(cell_entry.first);
			}
		}
	}
	// Iterate over unique cells; each _destroy_mmi_by_cell will handle all LODs
	for (const auto &cell : cells) {
		_destroy_mmi_by_cell(p_region_loc, p_mesh_id, cell);
	}
}

void Terrain3DInstancer::_destroy_mmi_by_cell(const Vector2i &p_region_loc, const int p_mesh_id, const Vector2i p_cell, const int p_lod) {
	if (_mmi_nodes.count(p_region_loc) == 0) {
		return;
	}
	MeshMMIDict &mesh_mmi_dict = _mmi_nodes[p_region_loc];
	Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);

	for (int lod = Terrain3DMeshAsset::SHADOW_LOD_ID; lod < Terrain3DMeshAsset::MAX_LOD_COUNT; lod++) {
		// Skip if not all lods, or not matching lod
		if (p_lod != INT32_MAX && lod != p_lod) {
			continue;
		}
		Vector2i mesh_key(p_mesh_id, lod);
		if (mesh_mmi_dict.count(mesh_key) == 0) {
			continue;
		}
		CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
		if (cell_mmi_dict.count(p_cell) == 0) {
			continue;
		}
		MultiMeshInstance3D *mmi = cell_mmi_dict[p_cell];
		if (ma.is_valid() && mmi && mmi->get_multimesh().is_valid()) {
			if (lod == 0) {
				ma->update_instance_count(-mmi->get_multimesh()->get_instance_count());
			}
		}
		LOG(EXTREME, "Freeing ", ptr_to_str(mmi), " and erasing mmi cell ", p_cell);
		remove_from_tree(mmi);
		memdelete_safely(mmi);
		cell_mmi_dict.erase(p_cell);
		if (cell_mmi_dict.empty()) {
			LOG(EXTREME, "Removing mesh ", mesh_key, " from cell MMI dictionary");
			mesh_mmi_dict.erase(mesh_key); // invalidates cell_mmi_dict
		}
	}

	// Clean up region if we've removed the last MMI and cell
	if (mesh_mmi_dict.empty()) {
		LOG(EXTREME, "Removing region ", p_region_loc, " from mesh MMI dictionary");
		if (_mmi_containers.count(p_region_loc) > 0) {
			Node *node = _mmi_containers[p_region_loc];
			if (node && node->get_child_count() == 0) {
				LOG(EXTREME, "Removing ", node->get_name());
				_mmi_containers.erase(p_region_loc);
				remove_from_tree(node);
				memdelete_safely(node);
			}
		}
		// This invalidates mesh_mmi_dict here and for calling functions
		_mmi_nodes.erase(p_region_loc);
	}
}

void Terrain3DInstancer::_backup_region(const Ref<Terrain3DRegion> &p_region) {
	if (p_region.is_null()) {
		return;
	}
	if (_terrain && _terrain->get_editor() && _terrain->get_editor()->is_operating()) {
		_terrain->get_editor()->backup_region(p_region);
	} else {
		p_region->set_modified(true);
	}
}

Ref<MultiMesh> Terrain3DInstancer::_create_multimesh(const int p_mesh_id, const int p_lod, const TypedArray<Transform3D> &p_xforms, const PackedColorArray &p_colors) const {
	Ref<MultiMesh> mm;
	IS_INIT(mm);
	Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	if (mesh_asset.is_null()) {
		LOG(ERROR, "No mesh id ", p_mesh_id, " found");
		return mm;
	}
	Ref<Mesh> mesh = mesh_asset->get_mesh(p_lod);
	if (mesh.is_null()) {
		LOG(ERROR, "No LOD ", p_lod, " for mesh id ", p_mesh_id, " found. Max: ", mesh_asset->get_lod_count());
		return mm;
	}
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

Vector2i Terrain3DInstancer::_get_cell(const Vector3 &p_global_position, const int p_region_size) const {
	IS_INIT(V2I_ZERO);
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector2i cell;
	cell.x = UtilityFunctions::posmod(UtilityFunctions::floori(p_global_position.x / vertex_spacing), p_region_size) / CELL_SIZE;
	cell.y = UtilityFunctions::posmod(UtilityFunctions::floori(p_global_position.z / vertex_spacing), p_region_size) / CELL_SIZE;
	return cell;
}

// Get appropriate terrain height. Could find terrain (excluding slope or holes) or optional collision
Array Terrain3DInstancer::_get_usable_height(const Vector3 &p_global_position, const Vector2 &p_slope_range, const bool p_on_collision, const real_t p_raycast_start) const {
	IS_DATA_INIT(Array());
	const Terrain3DData *data = _terrain->get_data();
	real_t height = data->get_height(p_global_position);
	Dictionary raycast_result;
	bool raycast_hit = false;
	real_t raycast_height = FLT_MIN;
	Vector3 raycast_normal = V3_UP;
	// Raycast physics if using on_collision
	if (p_on_collision) {
		Vector3 start_pos = Vector3(p_global_position.x, height + p_raycast_start, p_global_position.z);
		raycast_result = _terrain->get_raycast_result(start_pos, Vector3(0.0f, -p_raycast_start - 1.0f, 0.0f), 0xFFFFFFFF, true);
		if (raycast_result.has("position")) {
			raycast_hit = true;
			raycast_height = ((Vector3)raycast_result["position"]).y;
			raycast_normal = raycast_result["normal"];
		}
	}
	// Hole, use collision if can or quit
	if (std::isnan(height)) {
		if (!raycast_hit) {
			return Array();
		}
		height = raycast_height;
	}
	// No hole, use collision if higher
	else if (raycast_hit && raycast_height > height) {
		height = raycast_height;
	}
	// No hole or collision, use height if in slope or quit
	if (!data->is_in_slope(p_global_position, p_slope_range, raycast_hit ? raycast_normal : V3_ZERO)) {
		return Array();
	}
	Array triple;
	triple.resize(3);
	triple[0] = height;
	triple[1] = raycast_hit;
	triple[2] = raycast_normal;
	return triple;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DInstancer::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	}
	IS_DATA_INIT_MESG("Terrain3D not initialized yet", VOID);
	LOG(INFO, "Initializing Instancer");
	update_mmis();
}

void Terrain3DInstancer::destroy() {
	IS_DATA_INIT(VOID);
	LOG(INFO, "Destroying all MMIs");
	int mesh_count = _terrain->get_assets()->get_mesh_count();
	for (int m = 0; m < mesh_count; m++) {
		_destroy_mmi_by_mesh(m);
	}
	_queued_updates.clear();
}

void Terrain3DInstancer::clear_by_mesh(const int p_mesh_id) {
	LOG(INFO, "Deleting Multimeshes in all regions with mesh_id: ", p_mesh_id);
	TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
	for (int i = 0; i < region_locations.size(); i++) {
		clear_by_location(region_locations[i], p_mesh_id);
	}
	Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	ma.is_valid() ? ma->set_instance_count(0) : void(); // Reset count for this mesh
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
	Dictionary mesh_inst_dict = p_region->get_instances();
	if (mesh_inst_dict.has(p_mesh_id)) {
		_backup_region(p_region);
		mesh_inst_dict.erase(p_mesh_id);
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
	real_t radius = brush_size * .5f;
	real_t strength = CLAMP(real_t(p_params.get("strength", .1f)), .01f, 100.f); // (premul) 1-10k%
	real_t fixed_scale = CLAMP(real_t(p_params.get("fixed_scale", 100.f)) * .01f, .01f, 100.f); // 1-10k%
	real_t random_scale = CLAMP(real_t(p_params.get("random_scale", 0.f)) * .01f, 0.f, 10.f); // +/- 1000%
	real_t density = CLAMP(.1f * brush_size * strength * mesh_asset->get_density() /
					MAX(0.01f, fixed_scale + .5f * random_scale),
			.001f, 1000.f);
	// Density based on strength, mesh AABB and input scale determines how many to place, even fractional
	uint32_t count = _get_density_count(density);
	if (count <= 0) {
		return;
	}
	LOG(EXTREME, "Adding ", count, " instances at ", p_global_position);

	real_t fixed_spin = CLAMP(real_t(p_params.get("fixed_spin", 0.f)), .0f, 360.f); // degrees
	real_t random_spin = CLAMP(real_t(p_params.get("random_spin", 360.f)), 0.f, 360.f); // degrees
	real_t fixed_tilt = CLAMP(real_t(p_params.get("fixed_tilt", 0.f)), -180.f, 180.f); // degrees
	real_t random_tilt = CLAMP(real_t(p_params.get("random_tilt", 10.f)), 0.f, 180.f); // degrees
	bool align_to_normal = bool(p_params.get("align_to_normal", false));

	real_t height_offset = CLAMP(real_t(p_params.get("height_offset", 0.f)), -100.0f, 100.f); // meters
	real_t random_height = CLAMP(real_t(p_params.get("random_height", 0.f)), 0.f, 100.f); // meters

	Color vertex_color = Color(p_params.get("vertex_color", COLOR_WHITE));
	real_t random_hue = CLAMP(real_t(p_params.get("random_hue", 0.f)) / 360.f, 0.f, 1.f); // degrees -> 0-1
	real_t random_darken = CLAMP(real_t(p_params.get("random_darken", 0.f)) * .01f, 0.f, 1.f); // 0-100%

	Vector2 slope_range = p_params.get("slope", Vector2(0.f, 90.f)); // 0-90 degrees
	slope_range.x = CLAMP(slope_range.x, 0.f, 90.f);
	slope_range.y = CLAMP(slope_range.y, 0.f, 90.f);
	bool on_collision = bool(p_params.get("on_collision", false));
	real_t raycast_height = p_params.get("raycast_height", 10.f);
	Terrain3DData *data = _terrain->get_data();

	TypedArray<Transform3D> xforms;
	PackedColorArray colors;
	for (int i = 0; i < count; i++) {
		Transform3D t;

		// Get random XZ position and height in a circle
		real_t r_radius = radius * sqrt(UtilityFunctions::randf());
		real_t r_theta = UtilityFunctions::randf() * Math_TAU;
		Vector3 rand_vec = Vector3(r_radius * cos(r_theta), 0.f, r_radius * sin(r_theta));
		Vector3 position = p_global_position + rand_vec;

		// Get height
		Array height_data = _get_usable_height(position, slope_range, on_collision, raycast_height);
		if (height_data.size() != 3) {
			continue;
		}
		position.y = height_data[0];
		bool raycast_hit = height_data[1];

		// Orientation
		Vector3 normal = V3_UP;
		if (align_to_normal) {
			// Use either collision normal or terrain normal
			normal = raycast_hit ? (Vector3)height_data[2] : data->get_normal(position);
			if (!normal.is_finite()) {
				normal = V3_UP;
			} else {
				normal = normal.normalized();
				Vector3 z_axis = Vector3(0.f, 0.f, 1.f);
				Vector3 x_axis = -z_axis.cross(normal);
				if (x_axis.length_squared() > 0.001f) {
					t.basis = Basis(x_axis, normal, z_axis).orthonormalized();
				}
			}
		}
		real_t spin = (fixed_spin + random_spin * UtilityFunctions::randf()) * Math_PI / 180.f;
		if (abs(spin) > 0.001f) {
			t.basis = t.basis.rotated(normal, spin);
		}
		real_t tilt = (fixed_tilt + random_tilt * (2.f * UtilityFunctions::randf() - 1.f)) * Math_PI / 180.f;
		if (abs(tilt) > 0.001f) {
			t.basis = t.basis.rotated(t.basis.get_column(0), tilt); // Rotate pitch, X-axis
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

	Terrain3DData *data = _terrain->get_data();
	int region_size = _terrain->get_region_size();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	bool modifier_shift = p_params.get("modifier_shift", false);
	real_t brush_size = CLAMP(real_t(p_params.get("size", 10.f)), .5f, 4096.f); // Meters
	real_t half_brush_size = brush_size * 0.5f + 1.f; // 1m margin
	real_t radius = brush_size * .5f;
	real_t strength = CLAMP(real_t(p_params.get("strength", .1f)), .01f, 100.f); // (premul) 1-10k%
	Vector2 slope_range = p_params.get("slope", Vector2(0.f, 90.f)); // 0-90 degrees
	slope_range.x = CLAMP(slope_range.x, 0.f, 90.f);
	slope_range.y = CLAMP(slope_range.y, 0.f, 90.f);
	bool on_collision = bool(p_params.get("on_collision", false));
	real_t raycast_height = p_params.get("raycast_height", 10.f);

	// Build list of potential regions to search, rather than searching the entire terrain, calculate possible regions covered
	// and check if they are valid; if so add that location to the dictionary keys.
	Dictionary r_locs;
	// Calculate step distance to ensure every region is checked inside the bounds of brush size.
	real_t step = brush_size / ceil(brush_size / real_t(region_size) / vertex_spacing);
	for (real_t x = p_global_position.x - half_brush_size; x <= p_global_position.x + half_brush_size; x += step) {
		for (real_t z = p_global_position.z - half_brush_size; z <= p_global_position.z + half_brush_size; z += step) {
			Vector2i region_loc = data->get_region_location(Vector3(x, 0.f, z));
			if (data->has_region(region_loc)) {
				r_locs[region_loc] = 1;
			}
		}
	}

	Array region_queue = r_locs.keys();
	if (region_queue.size() == 0) {
		return;
	}

	for (int r = 0; r < region_queue.size(); r++) {
		Vector2i region_loc = region_queue[r];
		Ref<Terrain3DRegion> region = data->get_region(region_loc);
		if (region.is_null()) {
			LOG(WARN, "Errant null region found at: ", region_loc);
			continue;
		}

		Dictionary mesh_inst_dict = region->get_instances();
		Array mesh_types = mesh_inst_dict.keys();
		if (mesh_types.size() == 0) {
			continue;
		}
		Vector3 global_local_offset = Vector3(region_loc.x * region_size * vertex_spacing, 0.f, region_loc.y * region_size * vertex_spacing);
		Vector2 localised_ring_center = Vector2(p_global_position.x - global_local_offset.x, p_global_position.z - global_local_offset.z);
		// For this mesh id, or all mesh ids
		for (int m = (modifier_shift ? 0 : mesh_id); m <= (modifier_shift ? mesh_count - 1 : mesh_id); m++) {
			// Ensure this region has this mesh
			if (!mesh_inst_dict.has(m)) {
				continue;
			}
			Dictionary cell_inst_dict = mesh_inst_dict[m];
			Array cell_locations = cell_inst_dict.keys();
			// This shouldnt be empty
			if (cell_locations.size() == 0) {
				LOG(WARN, "Region at: ", region_loc, " has instance dictionary for mesh id: ", m, " but has no cells.")
				continue;
			}
			// Check potential cells rather than searching the entire region, whilst marginally
			// slower if there are very few cells for the given mesh present. It is significantly
			// faster when a large number of cells are present.
			Dictionary c_locs;
			// Calculate step distance to ensure every cell is checked inside the bounds of brush size.
			real_t cell_step = brush_size / ceil(brush_size / real_t(CELL_SIZE) / vertex_spacing);
			for (real_t x = p_global_position.x - half_brush_size; x <= p_global_position.x + half_brush_size; x += cell_step) {
				for (real_t z = p_global_position.z - half_brush_size; z <= p_global_position.z + half_brush_size; z += cell_step) {
					Vector3 cell_pos = Vector3(x, 0.f, z) - global_local_offset;
					// Manually calculate cell pos without modulus, locations not in the current region will not be found.
					Vector2i cell_loc;
					cell_loc.x = UtilityFunctions::floori(cell_pos.x / vertex_spacing) / CELL_SIZE;
					cell_loc.y = UtilityFunctions::floori(cell_pos.z / vertex_spacing) / CELL_SIZE;
					if (cell_locations.has(cell_loc)) {
						c_locs[cell_loc] = 1;
					}
				}
			}
			Array cell_queue = c_locs.keys();
			if (cell_queue.size() == 0) {
				continue;
			}
			Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(m);
			real_t mesh_height_offset = mesh_asset->get_height_offset();
			for (int c = 0; c < cell_queue.size(); c++) {
				Vector2i cell = cell_queue[c];
				Array triple = cell_inst_dict[cell];
				TypedArray<Transform3D> xforms = triple[0];
				PackedColorArray colors = triple[1];
				TypedArray<Transform3D> updated_xforms;
				PackedColorArray updated_colors;
				// Remove transforms if inside ring radius
				for (int i = 0; i < xforms.size(); i++) {
					Transform3D t = xforms[i];
					// Use localised ring center
					real_t radial_distance = localised_ring_center.distance_to(Vector2(t.origin.x, t.origin.z));
					Vector3 height_offset = t.basis.get_column(1) * mesh_height_offset;
					if (radial_distance >= radius || UtilityFunctions::randf() >= CLAMP(0.175f * strength, 0.005f, 10.f)) {
						updated_xforms.push_back(t);
						updated_colors.push_back(colors[i]);
						continue;
					}
					Vector3 global_pos = t.origin + global_local_offset - t.basis.get_column(1) * mesh_height_offset;
					Array height_data = _get_usable_height(global_pos, slope_range, on_collision, raycast_height);
					if (height_data.size() != 3) {
						updated_xforms.push_back(t);
						updated_colors.push_back(colors[i]);
						continue;
					}
					_backup_region(region);
				}
				if (updated_xforms.size() > 0) {
					triple[0] = updated_xforms;
					triple[1] = updated_colors;
					triple[2] = true;
					cell_inst_dict[cell] = triple;
				} else {
					cell_inst_dict.erase(cell);
					_destroy_mmi_by_cell(region_loc, m, cell);
				}
			}
			if (cell_inst_dict.is_empty()) {
				mesh_inst_dict.erase(m);
			}
			update_mmis(m, region_loc);
		}
	}
}

void Terrain3DInstancer::add_multimesh(const int p_mesh_id, const Ref<MultiMesh> &p_multimesh, const Transform3D &p_xform, const bool p_update) {
	LOG(INFO, "Extracting ", p_multimesh->get_instance_count(), " transforms from multimesh");
	TypedArray<Transform3D> xforms;
	PackedColorArray colors;
	for (int i = 0; i < p_multimesh->get_instance_count(); i++) {
		xforms.push_back(p_xform * p_multimesh->get_instance_transform(i));
		Color c = COLOR_WHITE;
		if (p_multimesh->is_using_colors()) {
			c = p_multimesh->get_instance_color(i);
		}
		colors.push_back(c);
	}
	add_transforms(p_mesh_id, xforms, colors, p_update);
}

// Expects transforms in global space
void Terrain3DInstancer::add_transforms(const int p_mesh_id, const TypedArray<Transform3D> &p_xforms, const PackedColorArray &p_colors, const bool p_update) {
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

	// Separate incoming transforms/colors by region Dict{ region_loc => Array() }
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
			colors_dict[region_loc] = PackedColorArray();
		}
		TypedArray<Transform3D> xforms = xforms_dict[region_loc];
		PackedColorArray colors = colors_dict[region_loc];
		xforms.push_back(trns);
		colors.push_back(col);
		colors_dict[region_loc] = colors; // Note similar bug as godot-cpp#1149 needs this for PCA
	}

	// Merge incoming transforms with existing transforms
	Array region_locations = xforms_dict.keys();
	for (int i = 0; i < region_locations.size(); i++) {
		Vector2i region_loc = region_locations[i];
		TypedArray<Transform3D> xforms = xforms_dict[region_loc];
		PackedColorArray colors = colors_dict[region_loc];
		//LOG(MESG, "Appending ", xforms.size(), " xforms, ", colors, " colors to region location: ", region_loc);
		append_location(region_loc, p_mesh_id, xforms, colors, p_update);
	}
}

// Appends new global transforms to existing cells, offsetting transforms to region space, scaled by vertex spacing
void Terrain3DInstancer::append_location(const Vector2i &p_region_loc, const int p_mesh_id,
		const TypedArray<Transform3D> &p_xforms, const PackedColorArray &p_colors, const bool p_update) {
	IS_DATA_INIT(VOID);
	Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(p_region_loc);
	if (region.is_null()) {
		return;
	}
	int region_size = region->get_region_size();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector2 global_local_offset = Vector2(p_region_loc.x * region_size * vertex_spacing, p_region_loc.y * region_size * vertex_spacing);
	TypedArray<Transform3D> localised_xforms;
	for (int i = 0; i < p_xforms.size(); i++) {
		Transform3D t = p_xforms[i];
		// Localise the transform to "region space"
		t.origin.x -= global_local_offset.x;
		t.origin.z -= global_local_offset.y;
		localised_xforms.push_back(t);
	}
	append_region(region, p_mesh_id, localised_xforms, p_colors, p_update);
}

// append_region requires all transforms are in region space, 0 - region_size * vertex_spacing
void Terrain3DInstancer::append_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id,
		const TypedArray<Transform3D> &p_xforms, const PackedColorArray &p_colors, const bool p_update) {
	if (p_region.is_null()) {
		LOG(ERROR, "Null region provided. Doing nothing.");
		return;
	}
	if (p_xforms.size() == 0) {
		LOG(ERROR, "No transforms to add. Doing nothing.");
		return;
	}

	_backup_region(p_region);

	Dictionary cell_locations = p_region->get_instances()[p_mesh_id];
	int region_size = p_region->get_region_size();

	for (int i = 0; i < p_xforms.size(); i++) {
		Transform3D xform = p_xforms[i];
		Color col = p_colors[i];
		Vector2i cell = _get_cell(xform.origin, region_size);

		// Get current instance arrays or create if none
		Array triple = cell_locations[cell];
		bool modified = true;
		if (triple.size() != 3) {
			LOG(DEBUG, "No data at ", p_region->get_location(), ":", cell, ". Creating triple");
			triple.resize(3);
			triple[0] = TypedArray<Transform3D>();
			triple[1] = PackedColorArray();
			triple[2] = modified;
		}
		TypedArray<Transform3D> xforms = triple[0];
		PackedColorArray colors = triple[1];
		xforms.push_back(xform);
		colors.push_back(col);

		// Must write back since there are copy constructors somewhere
		// see godot-cpp#1149
		triple[0] = xforms;
		triple[1] = colors;
		triple[2] = modified;
		cell_locations[cell] = triple;
	}

	// Write back dictionary. See above comments
	p_region->get_instances()[p_mesh_id] = cell_locations;
	if (p_update) {
		update_mmis(p_mesh_id, p_region->get_location());
	}
}

// Review all transforms in one area and adjust their transforms w/ the current height
void Terrain3DInstancer::update_transforms(const AABB &p_aabb) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);
	Rect2 rect = aabb2rect(p_aabb);
	LOG(EXTREME, "Updating transforms within ", rect);
	Vector2 global_position = rect.get_center();
	Vector2 size = rect.get_size();
	Vector2 half_size = size * 0.5f + V2(1.f); // 1m margin
	if (size == V2_ZERO) {
		return;
	}

	Terrain3DData *data = _terrain->get_data();
	Dictionary params = _terrain->get_editor() ? _terrain->get_editor()->get_brush_data() : Dictionary();
	bool on_collision = params.get("on_collision", false);
	real_t raycast_height = params.get("raycast_height", 10.f);
	int region_size = _terrain->get_region_size();
	real_t vertex_spacing = _terrain->get_vertex_spacing();

	// Build list of valid regions within AABB; add the locations as dictionary keys.
	Dictionary r_locs;
	// Calculate step distance to ensure every region is checked inside the bounds of AABB size.
	Vector2 step = Vector2(size.x / ceil(size.x / real_t(region_size) / vertex_spacing), size.y / ceil(size.y / real_t(region_size) / vertex_spacing));
	for (real_t x = global_position.x - half_size.x; x <= global_position.x + half_size.x; x += step.x) {
		for (real_t z = global_position.y - half_size.y; z <= global_position.y + half_size.y; z += step.y) {
			Vector2i region_loc = data->get_region_location(Vector3(x, 0.f, z));
			if (data->has_region(region_loc)) {
				r_locs[region_loc] = 0;
			}
		}
	}

	Array region_queue = r_locs.keys();
	if (region_queue.size() == 0) {
		return;
	}

	for (int r = 0; r < region_queue.size(); r++) {
		Vector2i region_loc = region_queue[r];
		Ref<Terrain3DRegion> region = data->get_region(region_loc);
		_backup_region(region);

		Dictionary mesh_inst_dict = region->get_instances();
		Array mesh_types = mesh_inst_dict.keys();
		if (mesh_types.size() == 0) {
			continue;
		}
		Vector3 global_local_offset = Vector3(region_loc.x * region_size * vertex_spacing, 0.f, region_loc.y * region_size * vertex_spacing);

		// For this mesh id, or all mesh ids
		for (int m = 0; m < mesh_types.size(); m++) {
			// Check potential cells rather than searching the entire region, whilst marginally
			// slower if there are very few cells for the given mesh present it is significantly
			// faster when a very large number of cells are present.
			int region_mesh_id = mesh_types[m];
			Dictionary cell_inst_dict = mesh_inst_dict[region_mesh_id];
			Array cell_locations = cell_inst_dict.keys();
			if (cell_locations.size() == 0) {
				continue;
			}
			Dictionary c_locs;
			// Calculate step distance to ensure every cell is checked inside the bounds of brush size.
			Vector2 cell_step = Vector2(size.x / ceil(size.x / real_t(CELL_SIZE) / vertex_spacing), size.y / ceil(size.y / real_t(CELL_SIZE) / vertex_spacing));
			for (real_t x = global_position.x - half_size.x; x <= global_position.x + half_size.x; x += cell_step.x) {
				for (real_t z = global_position.y - half_size.y; z <= global_position.y + half_size.y; z += cell_step.y) {
					Vector3 cell_pos = Vector3(x, 0.f, z) - global_local_offset;
					// Manually calculate cell pos without modulus, locations not in the current region will not be found.
					Vector2i cell_loc;
					cell_loc.x = UtilityFunctions::floori(cell_pos.x / vertex_spacing) / CELL_SIZE;
					cell_loc.y = UtilityFunctions::floori(cell_pos.z / vertex_spacing) / CELL_SIZE;
					if (cell_locations.has(cell_loc)) {
						c_locs[cell_loc] = 0;
					}
				}
			}
			Array cell_queue = c_locs.keys();
			if (cell_queue.size() == 0) {
				continue;
			}
			Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(mesh_types[m]);
			real_t mesh_height_offset = mesh_asset->get_height_offset();
			for (int c = 0; c < cell_queue.size(); c++) {
				Vector2i cell = cell_queue[c];
				Array triple = cell_inst_dict[cell];
				TypedArray<Transform3D> xforms = triple[0];
				PackedColorArray colors = triple[1];
				TypedArray<Transform3D> updated_xforms;
				PackedColorArray updated_colors;
				for (int i = 0; i < xforms.size(); i++) {
					Transform3D t = xforms[i];
					Vector3 global_origin(t.origin + global_local_offset);
					if (rect.has_point(Vector2(global_origin.x, global_origin.z))) {
						Vector3 height_offset = t.basis.get_column(1) * mesh_height_offset;
						t.origin -= height_offset;
						Array height_data = _get_usable_height(global_origin, Vector2(0.f, 90.f), on_collision, raycast_height);
						if (height_data.size() != 3) {
							continue;
						}
						t.origin.y = height_data[0];
						t.origin += height_offset;
					}
					updated_xforms.push_back(t);
					updated_colors.push_back(colors[i]);
				}
				if (updated_xforms.size() > 0) {
					triple[0] = updated_xforms;
					triple[1] = updated_colors;
					triple[2] = true;
					cell_inst_dict[cell] = triple;
				} else {
					// Removed if a hole erased everything
					cell_inst_dict.erase(cell);
					_destroy_mmi_by_cell(region_loc, m, cell);
				}
				if (cell_inst_dict.is_empty()) {
					mesh_inst_dict.erase(region_mesh_id);
				}
			}
			update_mmis(m, region_loc);
		}
	}
}

int Terrain3DInstancer::get_closest_mesh_id(const Vector3 &p_global_position) const {
	LOG(INFO, "Finding mesh asset ID closest to specified position ", p_global_position);
	Vector2i region_loc = _terrain->get_data()->get_region_location(p_global_position);
	const Terrain3DRegion *region = _terrain->get_data()->get_region_ptr(region_loc);
	if (!region) {
		LOG(WARN, "No region found at position: ", p_global_position);
		return -1; // No region found
	}
	int region_size = region->get_region_size();
	Vector3 region_global_pos = v2iv3(region_loc) * real_t(region_size) * _terrain->get_vertex_spacing();
	Vector2i cell = _get_cell(p_global_position, region_size);
	Dictionary mesh_inst_dict = region->get_instances();
	if (mesh_inst_dict.is_empty()) {
		return -1; // No meshes found
	}
	if (mesh_inst_dict.size() == 1) {
		// Only one mesh type in this region, return it
		return mesh_inst_dict.keys()[0];
	}
	//Iterate through all mesh types looking for meshes in cell to find the closest transform
	int closest_id = -1;
	real_t closest_distance = FLT_MAX;
	Array mesh_instance_keys = mesh_inst_dict.keys();
	for (int i = 0; i < mesh_instance_keys.size(); i++) {
		int mesh_id = mesh_instance_keys[i];
		Dictionary cell_inst_dict = mesh_inst_dict[mesh_id];
		if (!cell_inst_dict.has(cell)) {
			continue; // No instances in this cell
		}
		Array triple = cell_inst_dict[cell];
		if (triple.size() != 3) {
			continue; // Invalid triple, skip
		}
		TypedArray<Transform3D> xforms = triple[0];
		if (xforms.is_empty()) {
			continue; // No transforms in this cell
		}
		for (int i = 0; i < xforms.size(); i++) {
			const Transform3D &instance_transform = xforms[i];
			Vector3 instance_origin = instance_transform.origin + region_global_pos; // Convert to global position
			real_t distance = instance_origin.distance_squared_to(p_global_position);
			if (distance < closest_distance) {
				closest_distance = distance;
				closest_id = mesh_id;
			}
		}
	}
	LOG(DEBUG, "Found closest Mesh Asset ID: ", closest_id, " at: ", closest_distance);
	return closest_id;
}

// Transfer foliage data from one region to another
// p_src_rect is the vertex/pixel offset into the region data, NOT a global position
// Need to update_mmis() after
void Terrain3DInstancer::copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2i &p_src_rect, const Terrain3DRegion *p_dst_region) {
	if (!p_src_region || !p_dst_region) {
		LOG(ERROR, "Source (", p_src_region, ") or destination (", p_dst_region, ") regions are null");
		return;
	}
	LOG(INFO, "Copying foliage data from src ", p_src_region->get_location(), " to dest ", p_dst_region->get_location());

	real_t vertex_spacing = _terrain->get_vertex_spacing();
	// Offset to dst from src
	Vector2i src_region_loc = p_src_region->get_location();
	int src_region_size = p_src_region->get_region_size();
	Vector2i src_offset = Vector2i(src_region_loc.x * src_region_size, src_region_loc.y * src_region_size);
	Vector2i dst_region_loc = p_dst_region->get_location();
	int dst_region_size = p_dst_region->get_region_size();
	Vector2i dst_offset = src_offset - Vector2i(dst_region_loc.x * dst_region_size, dst_region_loc.y * dst_region_size);
	Vector3 dst_translate = Vector3(dst_offset.x, 0.f, dst_offset.y) * vertex_spacing;

	// Get all Cell locations in rect, which is already in region space.
	Vector2i cell_start = p_src_rect.get_position() / CELL_SIZE;
	Vector2i steps = p_src_rect.get_size() / CELL_SIZE;
	Dictionary cells_to_copy;
	for (int x = cell_start.x; x < cell_start.x + steps.x; x++) {
		for (int y = cell_start.y; y < cell_start.y + steps.y; y++) {
			cells_to_copy[Vector2i(x, y)] = 0;
		}
	}

	// For each mesh, for each cell, if in rect, convert xforms to target region space, append to target region.
	Dictionary mesh_inst_dict = p_src_region->get_instances();
	Array mesh_types = mesh_inst_dict.keys();
	for (int m = 0; m < mesh_types.size(); m++) {
		TypedArray<Transform3D> xforms;
		PackedColorArray colors;
		Dictionary cell_inst_dict = p_src_region->get_instances()[m];
		Array cell_locs = cell_inst_dict.keys();
		for (int c = 0; c < cell_locs.size(); c++) {
			if (cells_to_copy.has(cell_locs[c])) {
				Array triple = cell_inst_dict[cell_locs[c]];
				TypedArray<Transform3D> cell_xforms = triple[0];
				PackedColorArray cell_colors = triple[1];
				for (int i = 0; i < cell_xforms.size(); i++) {
					Transform3D t = cell_xforms[i];
					t.origin += dst_translate;
					xforms.push_back(t);
					colors.push_back(cell_colors[i]);
				}
			}
		}
		if (xforms.size() == 0) {
			continue;
		}
		append_region(Ref<Terrain3DRegion>(p_dst_region), m, xforms, colors, false);
	}
}

// Changes the ID of a mesh, without changing the mesh on the ground
// Called when the mesh asset id has changed. Updates Multimeshes and MMIs dictionary keys
void Terrain3DInstancer::swap_ids(const int p_src_id, const int p_dst_id) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);
	Ref<Terrain3DAssets> assets = _terrain->get_assets();
	int mesh_count = assets->get_mesh_count();
	LOG(INFO, "Swapping IDs of multimeshes: ", p_src_id, " and ", p_dst_id);
	if (p_src_id >= 0 && p_src_id < mesh_count && p_dst_id >= 0 && p_dst_id < mesh_count) {
		TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
		for (int i = 0; i < region_locations.size(); i++) {
			Vector2i region_loc = region_locations[i];
			Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(region_loc);
			if (region.is_null()) {
				LOG(WARN, "No region found at: ", region_loc);
				continue;
			}

			// mesh_inst_dict could have src, src+dst, dst or nothing. All 4 must be considered
			Dictionary mesh_inst_dict = region->get_instances();
			Dictionary cells_inst_dict_src;
			Dictionary cells_inst_dict_dst;
			// Extract src dict
			if (mesh_inst_dict.has(p_src_id)) {
				_backup_region(region);
				cells_inst_dict_src = mesh_inst_dict[p_src_id];
				mesh_inst_dict.erase(p_src_id);
			}
			// Extract dest dict
			if (mesh_inst_dict.has(p_dst_id)) {
				_backup_region(region);
				cells_inst_dict_dst = mesh_inst_dict[p_dst_id];
				mesh_inst_dict.erase(p_dst_id);
			}
			// If src exists, insert into dst slot
			if (!cells_inst_dict_src.is_empty()) {
				_backup_region(region);
				mesh_inst_dict[p_dst_id] = cells_inst_dict_src;
			}
			// If dst exists, insert into src slot
			if (!cells_inst_dict_dst.is_empty()) {
				_backup_region(region);
				mesh_inst_dict[p_src_id] = cells_inst_dict_dst;
			}
			LOG(DEBUG, "Swapped mesh_ids for region: ", region_loc);
		}
		update_mmis(-1, V2I_MAX, true);
	}
}

// Defaults to update all regions, all meshes
// If rebuild is true, will destroy all MMIs, then build everything
// If region_loc == V2I_MAX, will do all regions for meshes specified
// If mesh_id < 0, will do all meshes in the specified region
// You safely can call multiple times per frame, and select any combo of options without fillling up the queue.
void Terrain3DInstancer::update_mmis(const int p_mesh_id, const Vector2i &p_region_loc, const bool p_rebuild) {
	LOG(INFO, "Queueing MMI update for mesh id: ", p_mesh_id < 0 ? "all" : String::num_int64(p_mesh_id),
			", region: ", p_region_loc == V2I_MAX ? "all" : String(p_region_loc),
			p_rebuild ? ", destroying first" : "");
	// Set to destroy and rebuild everything
	if (p_rebuild) {
		_queued_updates.clear();
		_queued_updates.emplace(V2I_MAX, -2);
		if (!RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates))) {
			LOG(DEBUG, "Connecting to RS::frame_pre_draw signal");
			RS->connect("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates));
		}
		return;
	}
	// If already set to destroy, build all, quit
	if (_queued_updates.find({ V2I_MAX, -2 }) != _queued_updates.end()) {
		return;
	}
	// If already set to build all, quit
	if (_queued_updates.find({ V2I_MAX, -1 }) != _queued_updates.end()) {
		return;
	}
	// If all meshes for region are queued, quit
	if (_queued_updates.find({ p_region_loc, -1 }) != _queued_updates.end()) {
		return;
	}
	// If all regions for mesh_id are queued, quit
	int mesh_id = CLAMP(p_mesh_id, -1, Terrain3DAssets::MAX_MESHES - 1);
	if (_queued_updates.find({ V2I_MAX, mesh_id }) != _queued_updates.end()) {
		return;
	}
	// Else queue up this region/mesh combo
	_queued_updates.emplace(p_region_loc, mesh_id);
	if (!RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates))) {
		LOG(DEBUG, "Connecting to RS::frame_pre_draw signal");
		RS->connect("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates));
	}
}

void Terrain3DInstancer::dump_mmis() {
	LOG(WARN, "Dumping MMI tree and node containers");
	LOG(MESG, "_mmi_containers size: ", int(_mmi_containers.size()));
	for (auto &it : _mmi_containers) {
		LOG(MESG, "_mmi_containers region: ", it.first, ", node ptr: ", ptr_to_str(it.second));
	}
	LOG(MESG, "_mmi tree: ");
	_terrain->get_mmi_parent()->print_tree();
	LOG(MESG, "_mmi_nodes size: ", int(_mmi_nodes.size()));
	for (auto &i : _mmi_nodes) {
		LOG(MESG, "_mmi_nodes region: ", i.first, ", dict ptr: ", ptr_to_str(&i.second));
		for (auto &j : i.second) {
			LOG(MESG, "mesh_mmi_dict mesh: ", j.first, ", dict ptr: ", ptr_to_str(&j.second));
			for (auto &k : j.second) {
				LOG(MESG, "cell_mmi_dict cell: ", k.first, ", mmi ptr: ", ptr_to_str(k.second));
			}
		}
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DInstancer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear_by_mesh", "mesh_id"), &Terrain3DInstancer::clear_by_mesh);
	ClassDB::bind_method(D_METHOD("clear_by_location", "region_location", "mesh_id"), &Terrain3DInstancer::clear_by_location);
	ClassDB::bind_method(D_METHOD("clear_by_region", "region", "mesh_id"), &Terrain3DInstancer::clear_by_region);
	ClassDB::bind_method(D_METHOD("add_instances", "global_position", "params"), &Terrain3DInstancer::add_instances);
	ClassDB::bind_method(D_METHOD("remove_instances", "global_position", "params"), &Terrain3DInstancer::remove_instances);
	ClassDB::bind_method(D_METHOD("add_multimesh", "mesh_id", "multimesh", "transform", "update"), &Terrain3DInstancer::add_multimesh, DEFVAL(Transform3D()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_transforms", "mesh_id", "transforms", "colors", "update"), &Terrain3DInstancer::add_transforms, DEFVAL(PackedColorArray()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("append_location", "region_location", "mesh_id", "transforms", "colors", "update"), &Terrain3DInstancer::append_location, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("append_region", "region", "mesh_id", "transforms", "colors", "update"), &Terrain3DInstancer::append_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("update_transforms", "aabb"), &Terrain3DInstancer::update_transforms);
	ClassDB::bind_method(D_METHOD("get_closest_mesh_id", "global_position"), &Terrain3DInstancer::get_closest_mesh_id);
	ClassDB::bind_method(D_METHOD("update_mmis", "mesh_id", "region_location", "rebuild_all"), &Terrain3DInstancer::update_mmis, DEFVAL(-1), DEFVAL(V2I_MAX), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("swap_ids", "src_id", "dest_id"), &Terrain3DInstancer::swap_ids);
	ClassDB::bind_method(D_METHOD("dump_mmis"), &Terrain3DInstancer::dump_mmis);
}
