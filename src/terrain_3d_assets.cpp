// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_assets.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DAssets::_swap_ids(const AssetType p_type, const int p_src_id, const int p_dst_id) {
	LOG(INFO, "Swapping asset id: ", p_src_id, " and id: ", p_dst_id);
	Array list;
	switch (p_type) {
		case TYPE_TEXTURE:
			list = _texture_list;
			break;
		case TYPE_MESH:
			list = _mesh_list;
			break;
		default:
			return;
	}

	if (p_src_id < 0 || p_src_id >= list.size()) {
		LOG(ERROR, "Source id out of range: ", p_src_id);
		return;
	}
	Ref<Terrain3DAssetResource> res_a = list[p_src_id];
	int dst_id = CLAMP(p_dst_id, 0, list.size() - 1);
	if (dst_id == p_src_id) {
		// Res_a new id was likely out of range, reset it
		res_a->_id = p_src_id;
		return;
	}

	Ref<Terrain3DAssetResource> res_b = list[dst_id];
	res_a->_id = dst_id;
	res_b->_id = p_src_id;
	list[dst_id] = res_a;
	list[p_src_id] = res_b;

	switch (p_type) {
		case TYPE_TEXTURE:
			update_texture_list();
			break;
		case TYPE_MESH:
			_terrain->get_instancer()->swap_ids(p_src_id, dst_id);
			update_mesh_list();
			break;
		default:
			return;
	}
}

/**
 * _set_asset_list attempts to keep the asset id as saved in the resource file.
 * But if an ID is invalid or already taken, the new ID is changed to the next available one
 */
void Terrain3DAssets::_set_asset_list(const AssetType p_type, const TypedArray<Terrain3DAssetResource> &p_list) {
	Array list;
	int max_size;
	switch (p_type) {
		case TYPE_TEXTURE:
			list = _texture_list;
			max_size = MAX_TEXTURES;
			break;
		case TYPE_MESH:
			list = _mesh_list;
			max_size = MAX_MESHES;
			break;
		default:
			return;
	}

	int array_size = CLAMP(p_list.size(), 0, max_size);
	list.resize(array_size);
	int filled_id = -1;
	// For all provided textures up to MAX SIZE
	for (int i = 0; i < array_size; i++) {
		Ref<Terrain3DAssetResource> res = p_list[i];
		int id = res->get_id();
		// If saved texture id is in range and doesn't exist, add it
		if (id >= 0 && id < array_size && !list[id]) {
			list[id] = res;
		} else {
			// Else texture id is invalid or slot is already taken, insert in next available
			for (int j = filled_id + 1; j < array_size; j++) {
				if (!list[j]) {
					res->set_id(j);
					list[j] = res;
					filled_id = j;
					break;
				}
			}
		}
		if (!res->is_connected("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids))) {
			LOG(DEBUG, "Connecting to id_changed");
			res->connect("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids));
		}
	}
}

void Terrain3DAssets::_set_asset(const AssetType p_type, const int p_id, const Ref<Terrain3DAssetResource> &p_asset) {
	Array list;
	int max_size;
	switch (p_type) {
		case TYPE_TEXTURE:
			list = _texture_list;
			max_size = MAX_TEXTURES;
			break;
		case TYPE_MESH:
			list = _mesh_list;
			max_size = MAX_MESHES;
			break;
		default:
			return;
	}

	if (p_id < 0 || p_id >= max_size) {
		LOG(ERROR, "Invalid asset id: ", p_id, " range is 0-", max_size);
		return;
	}
	// Delete asset if null
	if (p_asset.is_null()) {
		// If final asset, remove it
		if (p_id == list.size() - 1) {
			LOG(DEBUG, "Deleting asset id: ", p_id);
			list.pop_back();
		} else if (p_id < list.size()) {
			// Else just clear it
			Ref<Terrain3DAssetResource> res = list[p_id];
			res->clear();
			res->_id = p_id;
		}
	} else {
		// Else Insert/Add Asset at end if a high number
		if (p_id >= list.size()) {
			p_asset->_id = list.size();
			list.push_back(p_asset);
			if (!p_asset->is_connected("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids))) {
				LOG(DEBUG, "Connecting to id_changed");
				p_asset->connect("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids));
			}
		} else {
			// Else overwrite an existing slot
			list[p_id] = p_asset;
		}
	}
}

void Terrain3DAssets::_update_texture_files() {
	IS_INIT(VOID);
	LOG(DEBUG, "Received texture_changed signal");
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();
	if (_texture_list.is_empty()) {
		emit_signal("textures_changed");
		return;
	}

	// Detect image sizes and formats
	LOG(DEBUG, "Validating texture sizes");
	Vector2i albedo_size = V2I_ZERO;
	Vector2i normal_size = V2I_ZERO;
	Image::Format albedo_format = Image::FORMAT_MAX;
	Image::Format normal_format = Image::FORMAT_MAX;
	bool albedo_mipmaps = true;
	bool normal_mipmaps = true;
	_terrain->set_warning(WARN_ALL, false);

	for (int i = 0; i < _texture_list.size(); i++) {
		Ref<Terrain3DTextureAsset> texture_set = _texture_list[i];
		if (texture_set.is_null()) {
			continue;
		}

		Ref<Texture2D> albedo_tex = texture_set->_albedo_texture;
		if (albedo_tex.is_valid()) {
			Vector2i tex_size = albedo_tex->get_size();
			Ref<Image> img = albedo_tex->get_image();
			Image::Format format = img->get_format();
			bool mipmaps = img->has_mipmaps();

			// If this is the first valid texture, set expected size and format for the arrays
			if (albedo_format == Image::FORMAT_MAX) {
				albedo_size = tex_size;
				albedo_format = format;
				albedo_mipmaps = mipmaps;
			} else { // else validate against first texture
				if (tex_size != albedo_size) {
					_terrain->set_warning(WARN_MISMATCHED_SIZE, true);
					LOG(ERROR, "Texture ID ", i, " albedo size: ", tex_size, " doesn't match size of first texture: ", albedo_size, ". They must be identical. Read Texture Prep in docs.");
				}
				if (format != albedo_format) {
					_terrain->set_warning(WARN_MISMATCHED_FORMAT, true);
					LOG(ERROR, "Texture ID ", i, " albedo format: ", format, " doesn't match format of first texture: ", albedo_format, ". They must be identical. Read Texture Prep in docs.");
				}
				if (mipmaps != albedo_mipmaps) {
					_terrain->set_warning(WARN_MISMATCHED_MIPMAPS, true);
					LOG(ERROR, "Texture ID ", i, " albedo mipmap setting (", mipmaps, ") doesn't match first texture (", albedo_mipmaps, "). They must be identical. Read Texture Prep in docs.");
				}
			}
		}

		Ref<Texture2D> normal_tex = texture_set->_normal_texture;
		if (normal_tex.is_valid()) {
			Vector2i tex_size = normal_tex->get_size();
			Ref<Image> img = normal_tex->get_image();
			Image::Format format = img->get_format();
			bool mipmaps = img->has_mipmaps();

			// If this is the first valid texture, set expected size and format for the arrays
			if (normal_format == Image::FORMAT_MAX) {
				normal_size = tex_size;
				normal_format = format;
				normal_mipmaps = mipmaps;
			} else { // else validate against first texture
				if (tex_size != normal_size) {
					_terrain->set_warning(WARN_MISMATCHED_SIZE, true);
					LOG(ERROR, "Texture ID ", i, " normal size: ", tex_size, " doesn't match size of first texture: ", normal_size, ". They must be identical. Read Texture Prep in docs.");
				}
				if (format != normal_format) {
					_terrain->set_warning(WARN_MISMATCHED_FORMAT, true);
					LOG(ERROR, "Texture ID ", i, " normal format: ", format, " doesn't match format of first texture: ", normal_format, ". They must be identical. Read Texture Prep in docs.");
				}
				if (mipmaps != normal_mipmaps) {
					_terrain->set_warning(WARN_MISMATCHED_MIPMAPS, true);
					LOG(ERROR, "Texture ID ", i, " normal mipmap setting (", mipmaps, ") doesn't match first texture (", albedo_mipmaps, "). They must be identical. Read Texture Prep in docs.");
				}
			}
		}
	}
	if (_terrain->get_warnings()) {
		return;
	}

	// Setup defaults for generated texture
	if (normal_size == V2I_ZERO) {
		normal_size = albedo_size;
	} else if (albedo_size == V2I_ZERO) {
		albedo_size = normal_size;
	}
	if (albedo_size == V2I_ZERO) {
		albedo_size = Vector2i(1024, 1024);
		normal_size = Vector2i(1024, 1024);
	}

	// Generate TextureArrays and replace nulls with a empty image

	if (_generated_albedo_textures.is_dirty() && albedo_size != V2I_ZERO) {
		LOG(INFO, "Regenerating albedo texture array");
		Array albedo_texture_array;
		for (int i = 0; i < _texture_list.size(); i++) {
			Ref<Terrain3DTextureAsset> texture_set = _texture_list[i];
			if (texture_set.is_null()) {
				continue;
			}
			Ref<Texture2D> tex = texture_set->_albedo_texture;
			Ref<Image> img;

			if (tex.is_null()) {
				img = Util::get_filled_image(albedo_size, COLOR_CHECKED, albedo_mipmaps, albedo_format);
				LOG(DEBUG, "ID ", i, " albedo texture is null. Creating a new one. Format: ", img->get_format());
				texture_set->_albedo_texture = ImageTexture::create_from_image(img);
			} else {
				img = tex->get_image();
				LOG(DEBUG, "ID ", i, " albedo texture is valid. Format: ", img->get_format());
				if (!IS_EDITOR && tex->get_path().contains("ImageTexture")) {
					LOG(WARN, "ID ", i, " albedo texture is not connected to a file.");
				}
			}
			albedo_texture_array.push_back(img);
		}
		if (!albedo_texture_array.is_empty()) {
			_generated_albedo_textures.create(albedo_texture_array);
		}
	}

	if (_generated_normal_textures.is_dirty() && normal_size != V2I_ZERO) {
		LOG(INFO, "Regenerating normal texture arrays");

		Array normal_texture_array;

		for (int i = 0; i < _texture_list.size(); i++) {
			Ref<Terrain3DTextureAsset> texture_set = _texture_list[i];
			if (texture_set.is_null()) {
				continue;
			}
			Ref<Texture2D> tex = texture_set->_normal_texture;
			Ref<Image> img;

			if (tex.is_null()) {
				img = Util::get_filled_image(normal_size, COLOR_NORMAL, normal_mipmaps, normal_format);
				LOG(DEBUG, "ID ", i, " normal texture is null. Creating a new one. Format: ", img->get_format());
				texture_set->_normal_texture = ImageTexture::create_from_image(img);
			} else {
				img = tex->get_image();
				LOG(DEBUG, "ID ", i, " Normal texture is valid. Format: ", img->get_format());
				if (!IS_EDITOR && tex->get_path().contains("ImageTexture")) {
					LOG(WARN, "ID ", i, " normal texture is not connected to a file.");
				}
			}
			normal_texture_array.push_back(img);
		}
		if (!normal_texture_array.is_empty()) {
			_generated_normal_textures.create(normal_texture_array);
		}
	}
	emit_signal("textures_changed");
}

void Terrain3DAssets::_update_texture_settings() {
	LOG(DEBUG, "Received setting_changed signal");
	if (!_texture_list.is_empty()) {
		LOG(INFO, "Updating terrain color and scale arrays");
		_texture_colors.clear();
		_texture_normal_depths.clear();
		_texture_ao_strengths.clear();
		_texture_roughness_mods.clear();
		_texture_uv_scales.clear();
		_texture_detiles.clear();

		for (int i = 0; i < _texture_list.size(); i++) {
			Ref<Terrain3DTextureAsset> texture_set = _texture_list[i];
			if (texture_set.is_null()) {
				continue;
			}
			_texture_colors.push_back(texture_set->get_albedo_color());
			_texture_normal_depths.push_back(texture_set->get_normal_depth());
			_texture_ao_strengths.push_back(texture_set->get_ao_strength());
			_texture_roughness_mods.push_back(texture_set->get_roughness());
			_texture_uv_scales.push_back(texture_set->get_uv_scale());
			_texture_detiles.push_back(Vector2(texture_set->get_detiling_rotation(), texture_set->get_detiling_shift()));
		}
	}
	emit_signal("textures_changed");
}

void Terrain3DAssets::_update_thumbnail(const Ref<Terrain3DMeshAsset> &p_mesh_asset) {
	if (p_mesh_asset.is_valid()) {
		create_mesh_thumbnails(p_mesh_asset->get_id());
	}
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DAssets::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing assets");

	// Setup Mesh preview environment
	_scenario = RS->scenario_create();

	_viewport = RS->viewport_create();
	RS->viewport_set_update_mode(_viewport, RenderingServer::VIEWPORT_UPDATE_DISABLED);
	RS->viewport_set_scenario(_viewport, _scenario);
	RS->viewport_set_size(_viewport, 128, 128);
	RS->viewport_set_transparent_background(_viewport, true);
	RS->viewport_set_active(_viewport, true);
	_viewport_texture = RS->viewport_get_texture(_viewport);

	_camera = RS->camera_create();
	RS->viewport_attach_camera(_viewport, _camera);
	RS->camera_set_transform(_camera, Transform3D(Basis(), Vector3(0, 0, 3)));
	RS->camera_set_orthogonal(_camera, 1.0, 0.01, 1000.0);

	_key_light = RS->directional_light_create();
	_key_light_instance = RS->instance_create2(_key_light, _scenario);
	RS->instance_set_transform(_key_light_instance, Transform3D().looking_at(Vector3(-1, -1, -1), Vector3(0, 1, 0)));

	_fill_light = RS->directional_light_create();
	RS->light_set_color(_fill_light, Color(0.3, 0.3, 0.3));
	_fill_light_instance = RS->instance_create2(_fill_light, _scenario);
	RS->instance_set_transform(_fill_light_instance, Transform3D().looking_at(Vector3(0, 1, 0), Vector3(0, 0, 1)));

	_mesh_instance = RS->instance_create();
	RS->instance_set_scenario(_mesh_instance, _scenario);

	// Update assets
	update_texture_list();
	update_mesh_list();
}

void Terrain3DAssets::uninitialize() {
	LOG(INFO, "Uninitializing assets");
	_terrain = nullptr;
}

void Terrain3DAssets::destroy() {
	IS_INIT(VOID);
	LOG(INFO, "Destroying assets");
	_terrain = nullptr;
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();
	RS->free_rid(_mesh_instance);
	RS->free_rid(_fill_light_instance);
	RS->free_rid(_fill_light);
	RS->free_rid(_key_light_instance);
	RS->free_rid(_key_light);
	RS->free_rid(_camera);
	RS->free_rid(_viewport);
	RS->free_rid(_scenario);
}

void Terrain3DAssets::set_texture(const int p_id, const Ref<Terrain3DTextureAsset> &p_texture) {
	if (_texture_list.size() <= p_id || p_texture != _texture_list[p_id]) {
		LOG(INFO, "Setting texture id: ", p_id);
		_set_asset(TYPE_TEXTURE, p_id, p_texture);
		update_texture_list();
	}
}

void Terrain3DAssets::set_texture_list(const TypedArray<Terrain3DTextureAsset> &p_texture_list) {
	LOG(INFO, "Setting texture list with ", p_texture_list.size(), " entries");
	_set_asset_list(TYPE_TEXTURE, p_texture_list);
	update_texture_list();
}

void Terrain3DAssets::clear_textures(const bool p_update) {
	LOG(INFO, "Clearing texture list");
	_texture_list.clear();
	if (p_update) {
		update_texture_list();
	}
}

void Terrain3DAssets::update_texture_list() {
	LOG(INFO, "Reconnecting texture signals");
	for (int i = 0; i < _texture_list.size(); i++) {
		Ref<Terrain3DTextureAsset> texture_set = _texture_list[i];
		if (texture_set.is_null()) {
			LOG(ERROR, "Texture id ", i, " is null, but shouldn't be.");
			continue;
		}
		if (!texture_set->is_connected("file_changed", callable_mp(this, &Terrain3DAssets::_update_texture_files))) {
			LOG(DEBUG, "Connecting file_changed signal");
			texture_set->connect("file_changed", callable_mp(this, &Terrain3DAssets::_update_texture_files));
		}
		if (!texture_set->is_connected("setting_changed", callable_mp(this, &Terrain3DAssets::_update_texture_settings))) {
			LOG(DEBUG, "Connecting setting_changed signal");
			texture_set->connect("setting_changed", callable_mp(this, &Terrain3DAssets::_update_texture_settings));
		}
	}
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();
	_update_texture_files();
	_update_texture_settings();
}

void Terrain3DAssets::set_mesh_asset(const int p_id, const Ref<Terrain3DMeshAsset> &p_mesh_asset) {
	LOG(INFO, "Setting mesh id: ", p_id, ", ", p_mesh_asset);
	_set_asset(TYPE_MESH, p_id, p_mesh_asset);
	if (p_mesh_asset.is_null()) {
		IS_INSTANCER_INIT(VOID);
		_terrain->get_instancer()->clear_by_mesh(p_id);
	}
	update_mesh_list();
}

Ref<Terrain3DMeshAsset> Terrain3DAssets::get_mesh_asset(const int p_id) const {
	if (p_id >= 0 && p_id < _mesh_list.size()) {
		return _mesh_list[p_id];
	}
	return Ref<Terrain3DMeshAsset>();
}

void Terrain3DAssets::set_mesh_list(const TypedArray<Terrain3DMeshAsset> &p_mesh_list) {
	LOG(INFO, "Setting mesh list with ", p_mesh_list.size(), " entries");
	_set_asset_list(TYPE_MESH, p_mesh_list);
	update_mesh_list();
}

// p_id = -1 for all meshes
// Adapted from godot\editor\plugins\editor_preview_plugins.cpp:EditorMeshPreviewPlugin
void Terrain3DAssets::create_mesh_thumbnails(const int p_id, const Vector2i &p_size) {
	int start, end;
	int max = get_mesh_count();
	if (p_id < 0) {
		start = 0;
		end = max;
	} else {
		start = CLAMP(p_id, 0, max - 1);
		end = CLAMP(p_id + 1, 0, max);
	}
	Vector2i size = CLAMP(p_size, Vector2i(1, 1), Vector2i(4096, 4096));

	LOG(INFO, "Creating thumbnails for ids: ", start, " through ", end - 1);
	for (int i = start; i < end; i++) {
		Ref<Terrain3DMeshAsset> ma = get_mesh_asset(i);
		if (ma.is_null()) {
			LOG(WARN, i, ": Terrain3DMeshAsset is null");
			continue;
		}
		// Setup mesh
		LOG(DEBUG, i, ": Getting Terrain3DMeshAsset: ", String::num_uint64(ma->get_instance_id()));
		Ref<Mesh> mesh = ma->get_mesh(0);
		LOG(DEBUG, i, ": Getting Mesh 0: ", mesh);
		if (mesh.is_null()) {
			LOG(WARN, i, ": Mesh is null");
			continue;
		}
		RS->instance_set_base(_mesh_instance, mesh->get_rid());

		// Setup material
		Ref<Material> mat = ma->get_material_override();
		RID rid = mat.is_valid() ? mat->get_rid() : RID();
		RS->instance_geometry_set_material_override(_mesh_instance, rid);
		mat = ma->get_material_overlay();
		rid = mat.is_valid() ? mat->get_rid() : RID();
		RS->instance_geometry_set_material_overlay(_mesh_instance, rid);

		// Setup scene
		AABB aabb = mesh->get_aabb();
		Vector3 ofs = aabb.get_center();
		aabb.position -= ofs;
		Transform3D xform;
		xform.basis = Basis().rotated(Vector3(0.f, 1.f, 0.f), -Math_PI * 0.125f);
		xform.basis = Basis().rotated(Vector3(1.f, 0.f, 0.f), Math_PI * 0.125f) * xform.basis;
		AABB rot_aabb = xform.xform(aabb);
		real_t m = MAX(rot_aabb.size.x, rot_aabb.size.y) * 0.5f;
		if (m == 0.f) {
			m = 1.f;
		}
		m = .5f / m;
		xform.basis.scale(Vector3(m, m, m));
		xform.origin = -xform.basis.xform(ofs);
		xform.origin.z -= rot_aabb.size.z * 2.f;
		RS->instance_set_transform(_mesh_instance, xform);

		RS->viewport_set_size(_viewport, size.x, size.y);
		RS->viewport_set_update_mode(_viewport, RenderingServer::VIEWPORT_UPDATE_ONCE);
		RS->force_draw();

		Ref<Image> img = RS->texture_2d_get(_viewport_texture);
		RS->instance_set_base(_mesh_instance, RID());

		if (img.is_valid()) {
			LOG(DEBUG, i, ": Retrieving image: ", img, " size: ", img->get_size(), " format: ", img->get_format());
		} else {
			LOG(WARN, "_viewport_texture is null");
			continue;
		}

		ma->_thumbnail = ImageTexture::create_from_image(img);
	}
	return;
}

void Terrain3DAssets::update_mesh_list() {
	IS_INSTANCER_INIT(VOID);
	LOG(INFO, "Updating mesh list");
	if (_mesh_list.size() == 0) {
		LOG(DEBUG, "Mesh list empty, clearing instancer and adding a default mesh");
		_terrain->get_instancer()->destroy();
		Ref<Terrain3DMeshAsset> new_mesh;
		new_mesh.instantiate();
		new_mesh->set_generated_type(Terrain3DMeshAsset::TYPE_TEXTURE_CARD);
		set_mesh_asset(0, new_mesh);
	}
	LOG(DEBUG, "Reconnecting mesh instance signals");
	for (int i = 0; i < _mesh_list.size(); i++) {
		Ref<Terrain3DMeshAsset> mesh_asset = _mesh_list[i];
		if (mesh_asset.is_null()) {
			LOG(ERROR, "Terrain3DMeshAsset id ", i, " is null, but shouldn't be.");
			continue;
		}
		if (mesh_asset->get_mesh().is_null()) {
			LOG(DEBUG, "Terrain3DMeshAsset has no mesh, adding a default");
			mesh_asset->set_generated_type(Terrain3DMeshAsset::TYPE_TEXTURE_CARD);
		}
		if (!mesh_asset->is_connected("file_changed", callable_mp(this, &Terrain3DAssets::update_mesh_list))) {
			LOG(DEBUG, "Connecting file_changed signal to self");
			mesh_asset->connect("file_changed", callable_mp(this, &Terrain3DAssets::update_mesh_list));
		}
		if (!mesh_asset->is_connected("setting_changed", callable_mp(this, &Terrain3DAssets::update_mesh_list))) {
			LOG(DEBUG, "Connecting setting_changed signal to self");
			mesh_asset->connect("setting_changed", callable_mp(this, &Terrain3DAssets::update_mesh_list));
		}
		if (!mesh_asset->is_connected("file_changed", callable_mp(this, &Terrain3DAssets::_update_thumbnail).bind(mesh_asset))) {
			LOG(DEBUG, "Connecting file_changed signal to _update_thumbnail");
			mesh_asset->connect("file_changed", callable_mp(this, &Terrain3DAssets::_update_thumbnail).bind(mesh_asset));
		}
		if (!mesh_asset->is_connected("setting_changed", callable_mp(this, &Terrain3DAssets::_update_thumbnail).bind(mesh_asset))) {
			LOG(DEBUG, "Connecting setting_changed signal to _update_thumbnail");
			mesh_asset->connect("setting_changed", callable_mp(this, &Terrain3DAssets::_update_thumbnail).bind(mesh_asset));
		}
		if (!mesh_asset->is_connected("instancer_setting_changed", callable_mp(_terrain->get_instancer(), &Terrain3DInstancer::update_mmis).bind(true))) {
			LOG(DEBUG, "Connecting instancer_setting_changed signal to _update_mmis");
			mesh_asset->connect("instancer_setting_changed", callable_mp(_terrain->get_instancer(), &Terrain3DInstancer::update_mmis).bind(true));
		}
	}
	LOG(DEBUG, "Emitting meshes_changed");
	emit_signal("meshes_changed");
}

Error Terrain3DAssets::save(const String &p_path) {
	if (p_path.is_empty() && get_path().is_empty()) {
		return ERR_FILE_NOT_FOUND;
	}
	if (!p_path.is_empty()) {
		LOG(DEBUG, "Setting file path to ", p_path);
		take_over_path(p_path);
	}
	// Save to external resource file if specified
	Error err = OK;
	String path = get_path();
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save external file: " + path);
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		if (err == OK) {
			LOG(INFO, "File saved successfully: ", path);
		} else {
			LOG(ERROR, "Cannot save file: ", path, ". Error code: ", ERROR, ". Look up @GlobalScope Error enum in the Godot docs");
		}
	}
	return err;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DAssets::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_TEXTURE);
	BIND_ENUM_CONSTANT(TYPE_MESH);
	BIND_CONSTANT(MAX_TEXTURES);
	BIND_CONSTANT(MAX_MESHES);

	ClassDB::bind_method(D_METHOD("set_texture", "id", "texture"), &Terrain3DAssets::set_texture);
	ClassDB::bind_method(D_METHOD("get_texture", "id"), &Terrain3DAssets::get_texture);
	ClassDB::bind_method(D_METHOD("set_texture_list", "texture_list"), &Terrain3DAssets::set_texture_list);
	ClassDB::bind_method(D_METHOD("get_texture_list"), &Terrain3DAssets::get_texture_list);
	ClassDB::bind_method(D_METHOD("get_texture_count"), &Terrain3DAssets::get_texture_count);
	ClassDB::bind_method(D_METHOD("get_albedo_array_rid"), &Terrain3DAssets::get_albedo_array_rid);
	ClassDB::bind_method(D_METHOD("get_normal_array_rid"), &Terrain3DAssets::get_normal_array_rid);
	ClassDB::bind_method(D_METHOD("get_texture_colors"), &Terrain3DAssets::get_texture_colors);
	ClassDB::bind_method(D_METHOD("get_texture_normal_depths"), &Terrain3DAssets::get_texture_normal_depths);
	ClassDB::bind_method(D_METHOD("get_texture_ao_strengths"), &Terrain3DAssets::get_texture_ao_strengths);
	ClassDB::bind_method(D_METHOD("get_texture_roughness_mods"), &Terrain3DAssets::get_texture_roughness_mods);
	ClassDB::bind_method(D_METHOD("get_texture_uv_scales"), &Terrain3DAssets::get_texture_uv_scales);
	ClassDB::bind_method(D_METHOD("get_texture_detiles"), &Terrain3DAssets::get_texture_detiles);
	ClassDB::bind_method(D_METHOD("clear_textures", "update"), &Terrain3DAssets::clear_textures, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("update_texture_list"), &Terrain3DAssets::update_texture_list);

	ClassDB::bind_method(D_METHOD("set_mesh_asset", "id", "mesh"), &Terrain3DAssets::set_mesh_asset);
	ClassDB::bind_method(D_METHOD("get_mesh_asset", "id"), &Terrain3DAssets::get_mesh_asset);
	ClassDB::bind_method(D_METHOD("set_mesh_list", "mesh_list"), &Terrain3DAssets::set_mesh_list);
	ClassDB::bind_method(D_METHOD("get_mesh_list"), &Terrain3DAssets::get_mesh_list);
	ClassDB::bind_method(D_METHOD("get_mesh_count"), &Terrain3DAssets::get_mesh_count);
	ClassDB::bind_method(D_METHOD("create_mesh_thumbnails", "id", "size"), &Terrain3DAssets::create_mesh_thumbnails, DEFVAL(-1), DEFVAL(Vector2i(128, 128)));
	ClassDB::bind_method(D_METHOD("update_mesh_list"), &Terrain3DAssets::update_mesh_list);

	ClassDB::bind_method(D_METHOD("save", "path"), &Terrain3DAssets::save, DEFVAL(""));

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "mesh_list", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DMeshAsset"), ro_flags), "set_mesh_list", "get_mesh_list");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "texture_list", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DTextureAsset"), ro_flags), "set_texture_list", "get_texture_list");

	ADD_SIGNAL(MethodInfo("meshes_changed"));
	ADD_SIGNAL(MethodInfo("textures_changed"));
}
