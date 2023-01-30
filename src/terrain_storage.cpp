//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include <godot_cpp/core/class_db.hpp>

#include "terrain_logger.h"
#include "terrain_storage.h"

using namespace godot;

void Terrain3DStorage::GeneratedTextureArray::create(const TypedArray<Image> &p_layers) {
	if (!p_layers.is_empty()) {
		rid = RenderingServer::get_singleton()->texture_2d_layered_create(p_layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
		dirty = false;
	} else {
		clear();
	}
}

void Terrain3DStorage::GeneratedTextureArray::clear() {
	if (rid.is_valid()) {
		RenderingServer::get_singleton()->free_rid(rid);
	}
	rid = RID();
	dirty = true;
}

Terrain3DStorage::Terrain3DStorage() {
	if (!_initialized) {
		_update_material();
		_initialized = true;
	}
}

Terrain3DStorage::~Terrain3DStorage() {
	if (_initialized) {
		RenderingServer::get_singleton()->free_rid(material);
		RenderingServer::get_singleton()->free_rid(shader);
		_clear_generated_data();
	}
}

void Terrain3DStorage::_clear_generated_data() {
	generated_height_maps.clear();
	generated_control_maps.clear();
	generated_albedo_textures.clear();
	generated_normal_textures.clear();
}

void Terrain3DStorage::set_region_size(int p_size) {
	region_size = p_size;
}

int Terrain3DStorage::get_region_size() const {
	return region_size;
}

void Terrain3DStorage::set_max_height(int p_height) {
	max_height = p_height;
}

int Terrain3DStorage::get_max_height() const {
	return max_height;
}

Vector2 Terrain3DStorage::_global_position_to_uv_offset(Vector3 p_global_position) {
	return (Vector2(p_global_position.x, p_global_position.z) / float(region_size) + Vector2(0.5, 0.5)).floor();
}

void Terrain3DStorage::add_region(Vector3 p_global_position) {
	ERR_FAIL_COND(has_region(p_global_position));

	Ref<Image> hmap_img = Image::create(region_size, region_size, false, Image::FORMAT_RH);
	hmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
	height_maps.push_back(hmap_img);

	Ref<Image> cmap_img = Image::create(region_size, region_size, false, Image::FORMAT_RGBA8);
	cmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
	control_maps.push_back(cmap_img);

	Vector2 uv_offset = _global_position_to_uv_offset(p_global_position);
	region_offsets.push_back(uv_offset);

	generated_height_maps.clear();
	generated_control_maps.clear();

	_update_material();

	notify_property_list_changed();
	emit_changed();
}

void Terrain3DStorage::remove_region(Vector3 p_global_position) {
	if (get_region_count() == 1) {
		return;
	}

	int index = get_region_index(p_global_position);

	ERR_FAIL_COND_MSG(index == -1, "Map does not exist.");

	region_offsets.remove_at(index);
	height_maps.remove_at(index);
	control_maps.remove_at(index);

	generated_height_maps.clear();
	generated_control_maps.clear();

	_update_material();

	notify_property_list_changed();
	emit_changed();
}

bool Terrain3DStorage::has_region(Vector3 p_global_position) {
	return get_region_index(p_global_position) != -1;
}

int Terrain3DStorage::get_region_index(Vector3 p_global_position) {
	Vector2 uv_offset = _global_position_to_uv_offset(p_global_position);
	int index = -1;

	for (int i = 0; i < region_offsets.size(); i++) {
		Vector2 pos = region_offsets[i];
		if (pos == uv_offset) {
			index = i;
			break;
		}
	}
	return index;
}

Ref<Image> Terrain3DStorage::get_map(int p_region_index, MapType p_map_type) const {
	Ref<Image> map;

	if (p_map_type == MapType::HEIGHT) {
		map = height_maps[p_region_index];
	}

	if (p_map_type == MapType::CONTROL) {
		map = control_maps[p_region_index];
	}
	return map;
}

void Terrain3DStorage::force_update_maps(MapType p_map_type) {
	switch (p_map_type) {
		case Terrain3DStorage::HEIGHT:
			generated_height_maps.clear();
			break;
		case Terrain3DStorage::CONTROL:
			generated_control_maps.clear();
			break;
		case Terrain3DStorage::MAX:
		default:
			generated_height_maps.clear();
			generated_control_maps.clear();
			break;
	}
	_update_material();
}

void Terrain3DStorage::set_height_maps(const TypedArray<Image> &p_maps) {
	height_maps = p_maps;
	generated_height_maps.clear();
	_update_material();
}

TypedArray<Image> Terrain3DStorage::get_height_maps() const {
	return height_maps;
}

void Terrain3DStorage::set_control_maps(const TypedArray<Image> &p_maps) {
	control_maps = p_maps;
	generated_control_maps.clear();
	_update_material();
}

TypedArray<Image> Terrain3DStorage::get_control_maps() const {
	return control_maps;
}

void Terrain3DStorage::set_region_offsets(const Array &p_offsets) {
	region_offsets = p_offsets;
	_update_material();
}

Array Terrain3DStorage::get_region_offsets() const {
	return region_offsets;
}

int Terrain3DStorage::get_region_count() const {
	return region_offsets.size();
}

RID Terrain3DStorage::get_material() const {
	return material;
}

void Terrain3DStorage::set_shader_override(const Ref<Shader> &p_shader) {
	shader_override = p_shader;
}

Ref<Shader> Terrain3DStorage::get_shader_override() const {
	return shader_override;
}

void Terrain3DStorage::set_noise_texture(const Ref<Texture2D> &p_texture) {
	bool update = false;

	// If noise was already present and a new one is assigned, there is no need to update material
	if (noise_texture.is_valid() && p_texture.is_valid()) {
		RenderingServer::get_singleton()->material_set_param(material, "noise", p_texture->get_rid());
	} else {
		update = true;
	}

	noise_texture = p_texture;

	if (update) {
		_update_material();
	}
}

Ref<Texture2D> Terrain3DStorage::get_noise_texture() const {
	return noise_texture;
}

void Terrain3DStorage::set_noise_scale(float p_scale) {
	noise_scale = p_scale;
	RenderingServer::get_singleton()->material_set_param(material, "noise_scale", noise_scale);
}

void Terrain3DStorage::set_noise_height(float p_height) {
	noise_height = p_height;
	RenderingServer::get_singleton()->material_set_param(material, "noise_height", noise_height);
}

void Terrain3DStorage::set_layer(const Ref<TerrainLayerMaterial3D> &p_material, int p_index) {
	if (p_index < layers.size()) {
		if (p_material.is_null()) {
			Ref<TerrainLayerMaterial3D> material_to_remove = layers[p_index];
			material_to_remove->disconnect("texture_changed", Callable(this, "_update_textures"));
			material_to_remove->disconnect("value_changed", Callable(this, "_update_arrays"));
			layers.remove_at(p_index);
		} else {
			layers[p_index] = p_material;
		}
	} else {
		layers.push_back(p_material);
	}
	generated_albedo_textures.clear();
	generated_normal_textures.clear();

	_update_layers();
	notify_property_list_changed();
}

Ref<TerrainLayerMaterial3D> Terrain3DStorage::get_layer(int p_index) const {
	return layers[p_index];
}

void Terrain3DStorage::set_layers(const TypedArray<TerrainLayerMaterial3D> &p_layers) {
	layers = p_layers;
	generated_albedo_textures.clear();
	generated_normal_textures.clear();
	_update_layers();
}

TypedArray<TerrainLayerMaterial3D> Terrain3DStorage::get_layers() const {
	return layers;
}

int Terrain3DStorage::get_layer_count() const {
	return layers.size();
}

void Terrain3DStorage::_update_layers() {
	LOG(INFO, "Generating material layers");
	for (int i = 0; i < layers.size(); i++) {
		Ref<TerrainLayerMaterial3D> l_material = layers[i];

		if (!l_material->is_connected("texture_changed", Callable(this, "_update_textures"))) {
			l_material->connect("texture_changed", Callable(this, "_update_textures"));
		}
		if (!l_material->is_connected("value_changed", Callable(this, "_update_values"))) {
			l_material->connect("value_changed", Callable(this, "_update_values"));
		}
	}
	_update_material();
}

void Terrain3DStorage::_update_arrays() {
	LOG(INFO, "Generating terrain color and scale arrays");
	PackedVector3Array uv_scales;
	PackedColorArray colors;

	for (int i = 0; i < layers.size(); i++) {
		Ref<TerrainLayerMaterial3D> l_material = layers[i];

		uv_scales.push_back(l_material->get_uv_scale());
		colors.push_back(l_material->get_albedo());
	}

	emit_changed();
}

void Terrain3DStorage::_update_textures() {
	if (generated_albedo_textures.is_dirty()) {
		LOG(INFO, "Generating terrain albedo arrays");
		Array albedo_texture_array;
		for (int i = 0; i < layers.size(); i++) {
			Ref<TerrainLayerMaterial3D> l_material = layers[i];
			albedo_texture_array.push_back(l_material->get_albedo_texture());
		}
		generated_albedo_textures.create(albedo_texture_array);
	}

	if (generated_normal_textures.is_dirty()) {
		LOG(INFO, "Generating terrain normal arrays");
		Array normal_texture_array;
		for (int i = 0; i < layers.size(); i++) {
			Ref<TerrainLayerMaterial3D> l_material = layers[i];
			normal_texture_array.push_back(l_material->get_normal_texture());
		}
		generated_normal_textures.create(normal_texture_array);
	}
}

void Terrain3DStorage::_update_regions() {
	if (generated_height_maps.is_dirty()) {
		LOG(INFO, "Updating height maps");
		generated_height_maps.create(height_maps);
	}
	if (generated_control_maps.is_dirty()) {
		LOG(INFO, "Updating control maps");
		generated_control_maps.create(control_maps);
	}
}

void Terrain3DStorage::_update_material() {
	LOG(INFO, "Updating material");

	if (!material.is_valid()) {
		material = RenderingServer::get_singleton()->material_create();
	}

	if (!shader.is_valid()) {
		shader = RenderingServer::get_singleton()->shader_create();
	}

	_update_regions();
	_update_textures();

	RID previous_noise_rid = RenderingServer::get_singleton()->material_get_param(material, "noise");
	int previous_region_count = RenderingServer::get_singleton()->material_get_param(material , "region_count");
	RID new_noise_rid = noise_texture.is_valid() ? noise_texture->get_rid() : RID();
	int new_region_count = Math::max(get_region_count(), 1);

	bool use_noise = noise_texture.is_valid();
	
	// Update shader code if something important has changed
	bool update_shader = previous_noise_rid != new_noise_rid || previous_region_count != new_region_count;
	
	if (update_shader) {
		String code = "shader_type spatial;\n";
		code += "render_mode depth_draw_opaque, diffuse_burley;\n";
		code += "\n";

		// Uniforms
		code += "uniform float terrain_height = 512.0;\n";
		code += "uniform float terrain_size = 1024.0;\n";
		code += "\n";
		code += "uniform sampler2DArray height_maps : filter_linear_mipmap, repeat_disable;\n";
		code += "uniform sampler2DArray control_maps : filter_linear_mipmap, repeat_disable;\n";
		code += "uniform int region_count = " + String::num_int64(new_region_count) + ";\n";
		code += "uniform vec2 region_offsets[" + String::num_int64(new_region_count) + "];\n";
		code += "\n";

		// For some reason 'hint_default_black' doesn't work when shader is build from code.
		if (use_noise) {
			code += "uniform sampler2D noise : filter_linear_mipmap_anisotropic, hint_default_black;\n";
			code += "uniform float noise_scale = 1.0;\n";
			code += "uniform float noise_height = 1.0;\n";
		}

		code += "uniform sampler2DArray texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;\n";
		code += "uniform sampler2DArray texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;\n";
		code += "\n";
		code += "uniform vec3 texture_uv_scale_array[256];\n";
		code += "uniform vec3 texture_3d_projection_array[256];\n";
		code += "uniform vec4 texture_color_array[256];\n";
		code += "uniform int texture_array_normal_max;\n";
		code += "\n";
		code += "uniform float terrain_grid_scale = 1.0;\n";
		code += "\n";

		// Functions
		code += "vec3 unpack_normal(vec4 rgba) {\n";
		code += "	vec3 n = rgba.xzy * 2.0 - vec3(1.0);\n";
		code += "	n.z *= -1.0;\n";
		code += "	return n;\n";
		code += "}\n\n";

		code += "vec4 pack_normal(vec3 n, float a) {\n";
		code += "	n.z *= -1.0;\n";
		code += "	return vec4((n.xzy + vec3(1.0)) * 0.5, a);\n";
		code += "}\n\n";

		code += "float get_height(vec2 uv) {\n";
		code += "	float index = -1.0;\n";
		code += "	float h = 1.0;\n";
		code += "	for (int i = 0; i < region_count; i++) { \n";
		code += "		vec2 pos = region_offsets[i];\n";
		code += "		vec2 max_pos = pos + 1.0;\n";
		code += "		if (uv.x > pos.x && uv.x < max_pos.x && uv.y > pos.y && uv.y < max_pos.y) {\n";
		code += "			index = float(i);\n";
		code += "			uv -= pos;\n";
		code += "			break;\n";
		code += "		}\n";
		code += "		float r = length(max(abs(uv-pos-0.5) - 0.333,0.0));\n";
		code += "		h *= smoothstep(0.0, 1.0, pow(r * 0.5, 2.0));\n";
		code += "	}\n";
		code += "	if (index >= 0.0) {\n";
		code += "		h = texture(height_maps, vec3(uv, index)).r;\n";
		code += "	} else {\n";

		if (use_noise) {
			code += "		h *= texture(noise, uv * noise_scale).r * noise_height;\n";
		} else {
			code += "		h *= 0.0;\n";
		}

		code += "	}\n";
		code += "	return h * terrain_height;\n";
		code += "}\n\n";

		code += "vec3 get_normal(vec2 uv) {\n";
		code += "	vec2 ps = vec2(1.0) / terrain_size;\n"; // TODO can be precalculated
		code += "\n";
		code += "	float left = get_height(uv + vec2(-ps.x, 0));\n";
		code += "	float right = get_height(uv + vec2(ps.x, 0));\n";
		code += "	float back = get_height(uv + vec2(0, -ps.y));\n";
		code += "	float fore = get_height(uv + vec2(0, ps.y));\n";
		code += "\n";
		code += "	vec3 horizontal = vec3(2.0, right - left, 0.0);\n";
		code += "	vec3 vertical = vec3(0.0, back - fore, 2.0);\n";
		code += "	vec3 normal = normalize(cross(vertical, horizontal));\n";
		code += "	normal.z *= -1.0;\n";
		code += "	return normal;\n";
		code += "}\n\n";

		// Vertex Shader
		code += "void vertex() {\n";
		code += "	vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n";
		code += "	UV2 = (world_vertex.xz / vec2(terrain_size + 1.0)) + vec2(0.5);\n";
		code += "	UV = world_vertex.xz * 0.5;\n";
		code += "	VERTEX.y = get_height(UV2);\n";
		code += "\n";
		code += "	NORMAL = vec3(0, 1, 0);\n";
		code += "	TANGENT = cross(NORMAL, vec3(0, 0, 1));\n";
		code += "	BINORMAL = cross(NORMAL, TANGENT);\n";
		code += "}\n\n";

		// Fragment Shader
		code += "void fragment() {\n";
		code += "	vec3 normal = vec3(0.5, 0.5, 1.0);\n";
		code += "	vec3 color = vec3(0.0);\n";
		code += "	float rough = 1.0;\n";
		code += "\n";
		code += "	NORMAL = mat3(VIEW_MATRIX) * get_normal(UV2);\n";
		code += "\n";
		code += "	vec2 p = UV * 4.0 * terrain_grid_scale;\n";
		code += "	vec2 ddx = dFdx(p);\n";
		code += "	vec2 ddy = dFdy(p);\n";
		code += "	vec2 w = max(abs(ddx), abs(ddy)) + 0.01;\n";
		code += "	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;\n";
		code += "	color = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);\n";
		code += "\n";
		code += "	ALBEDO = color;\n";
		code += "	ROUGHNESS = rough;\n";
		code += "	NORMAL_MAP = normal;\n";
		code += "	NORMAL_MAP_DEPTH = 1.0;\n";
		code += "\n";
		code += "}\n\n";

		String string_code = String(code);

		RenderingServer::get_singleton()->shader_set_code(shader, string_code);
		RenderingServer::get_singleton()->material_set_shader(material, shader_override.is_null() ? shader : shader_override->get_rid());
	}

	RenderingServer::get_singleton()->material_set_param(material, "height_maps", generated_height_maps.get_rid());
	RenderingServer::get_singleton()->material_set_param(material, "control_maps", generated_control_maps.get_rid());
	RenderingServer::get_singleton()->material_set_param(material, "region_offsets", region_offsets);
	RenderingServer::get_singleton()->material_set_param(material, "noise", new_noise_rid);
	RenderingServer::get_singleton()->material_set_param(material, "noise_scale", noise_scale);
	RenderingServer::get_singleton()->material_set_param(material, "noise_height", noise_height);
}

void Terrain3DStorage::_bind_methods() {
	BIND_ENUM_CONSTANT(HEIGHT);
	BIND_ENUM_CONSTANT(CONTROL);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DStorage::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DStorage::get_region_size);
	ClassDB::bind_method(D_METHOD("set_max_height", "height"), &Terrain3DStorage::set_max_height);
	ClassDB::bind_method(D_METHOD("get_max_height"), &Terrain3DStorage::get_max_height);

	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DStorage::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DStorage::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_noise_texture", "texture"), &Terrain3DStorage::set_noise_texture);
	ClassDB::bind_method(D_METHOD("get_noise_texture"), &Terrain3DStorage::get_noise_texture);
	ClassDB::bind_method(D_METHOD("set_noise_scale", "scale"), &Terrain3DStorage::set_noise_scale);
	ClassDB::bind_method(D_METHOD("get_noise_scale"), &Terrain3DStorage::get_noise_scale);
	ClassDB::bind_method(D_METHOD("set_noise_height", "height"), &Terrain3DStorage::set_noise_height);
	ClassDB::bind_method(D_METHOD("get_noise_height"), &Terrain3DStorage::get_noise_height);

	ClassDB::bind_method(D_METHOD("set_layer", "material", "index"), &Terrain3DStorage::set_layer);
	ClassDB::bind_method(D_METHOD("get_layer", "index"), &Terrain3DStorage::get_layer);
	ClassDB::bind_method(D_METHOD("set_layers", "layers"), &Terrain3DStorage::set_layers);
	ClassDB::bind_method(D_METHOD("get_layers"), &Terrain3DStorage::get_layers);

	ClassDB::bind_method(D_METHOD("add_region", "global_position"), &Terrain3DStorage::add_region);
	ClassDB::bind_method(D_METHOD("remove_region", "global_position"), &Terrain3DStorage::remove_region);
	ClassDB::bind_method(D_METHOD("has_region", "global_position"), &Terrain3DStorage::has_region);
	ClassDB::bind_method(D_METHOD("get_region_index", "global_position"), &Terrain3DStorage::get_region_index);
	ClassDB::bind_method(D_METHOD("force_update_maps", "map_type"), &Terrain3DStorage::force_update_maps);
	ClassDB::bind_method(D_METHOD("get_map", "region_index", "map_type"), &Terrain3DStorage::get_map);

	ClassDB::bind_method(D_METHOD("set_height_maps", "maps"), &Terrain3DStorage::set_height_maps);
	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DStorage::get_height_maps);
	ClassDB::bind_method(D_METHOD("set_control_maps", "maps"), &Terrain3DStorage::set_control_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DStorage::get_control_maps);
	ClassDB::bind_method(D_METHOD("set_region_offsets", "offsets"), &Terrain3DStorage::set_region_offsets);
	ClassDB::bind_method(D_METHOD("get_region_offsets"), &Terrain3DStorage::get_region_offsets);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64, 128:128, 256:256, 512:512, 1024:1024"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_height", PROPERTY_HINT_RANGE, "1, 1024, 1"), "set_max_height", "get_max_height");

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image")), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image")), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::VECTOR2, PROPERTY_HINT_NONE)), "set_region_offsets", "get_region_offsets");

	ADD_GROUP("Noise", "noise_");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "noise_texture", PROPERTY_HINT_RESOURCE_TYPE, "Texture2D"), "set_noise_texture", "get_noise_texture");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_scale", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_scale", "get_noise_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_height", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_height", "get_noise_height");

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "layers", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "TerrainLayerMaterial3D")), "set_layers", "get_layers");
}
