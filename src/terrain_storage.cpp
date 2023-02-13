//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include <godot_cpp/core/class_db.hpp>

#include "terrain_logger.h"
#include "terrain_storage.h"

using namespace godot;

void Terrain3DStorage::Generated::create(const TypedArray<Image> &p_layers) {
	if (!p_layers.is_empty()) {
		rid = RenderingServer::get_singleton()->texture_2d_layered_create(p_layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
		dirty = false;
	} else {
		clear();
	}
}

void Terrain3DStorage::Generated::create(const Ref<Image> &p_image) {
	image = p_image;
	rid = RenderingServer::get_singleton()->texture_2d_create(image);
	dirty = false;
}

void Terrain3DStorage::Generated::clear() {
	if (rid.is_valid()) {
		RenderingServer::get_singleton()->free_rid(rid);
	}
	if (image.is_valid()) {
		image.unref();
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
		_clear();
	}
}

void Terrain3DStorage::_clear() {
	RenderingServer::get_singleton()->free_rid(material);
	RenderingServer::get_singleton()->free_rid(shader);

	generated_height_maps.clear();
	generated_control_maps.clear();
	generated_albedo_textures.clear();
	generated_normal_textures.clear();
	generated_region_map.clear();
}

void Terrain3DStorage::set_region_size(RegionSize p_size) {
	ERR_FAIL_COND(p_size < SIZE_64);
	ERR_FAIL_COND(p_size > SIZE_2048);

	region_size = p_size;
	RenderingServer::get_singleton()->material_set_param(material, "region_size", region_size);
	RenderingServer::get_singleton()->material_set_param(material, "region_pixel_size", 1.0f / float(region_size));
}

Vector2i Terrain3DStorage::_get_offset_from(Vector3 p_global_position) {
	return Vector2i((Vector2(p_global_position.x, p_global_position.z) / float(region_size) + Vector2(0.5, 0.5)).floor());
}

Error Terrain3DStorage::add_region(Vector3 p_global_position) {
	if (has_region(p_global_position)) {
		return FAILED;
	}
	Vector2i uv_offset = _get_offset_from(p_global_position);

	if (ABS(uv_offset.x) > REGION_MAP_SIZE / 2 || ABS(uv_offset.y) > REGION_MAP_SIZE / 2) {
		return FAILED;
	}

	Ref<Image> hmap_img = Image::create(region_size, region_size, false, Image::FORMAT_RH);
	Ref<Image> cmap_img = Image::create(region_size, region_size, false, Image::FORMAT_RGBA8);

	hmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));
	cmap_img->fill(Color(0.0, 0.0, 0.0, 1.0));

	height_maps.push_back(hmap_img);
	control_maps.push_back(cmap_img);
	region_offsets.push_back(uv_offset);

	generated_height_maps.clear();
	generated_control_maps.clear();
	generated_region_map.clear();

	_update_regions();

	notify_property_list_changed();
	emit_changed();

	return OK;
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
	generated_region_map.clear();

	_update_regions();

	notify_property_list_changed();
	emit_changed();
}

bool Terrain3DStorage::has_region(Vector3 p_global_position) {
	return get_region_index(p_global_position) != -1;
}

int Terrain3DStorage::get_region_index(Vector3 p_global_position) {
	Vector2i uv_offset = _get_offset_from(p_global_position);
	int index = -1;

	if (ABS(uv_offset.x) > REGION_MAP_SIZE / 2 || ABS(uv_offset.y) > REGION_MAP_SIZE / 2) {
		return index;
	}

	Ref<Image> img = generated_region_map.get_image();

	if (img.is_valid()) {
		index = int(img->get_pixelv(uv_offset + (Vector2i(REGION_MAP_SIZE, REGION_MAP_SIZE) / 2)).r * 255.0) - 1;
	} else {
		for (int i = 0; i < region_offsets.size(); i++) {
			Vector2i ofs = region_offsets[i];
			if (ofs == uv_offset) {
				index = i;
				break;
			}
		}
	}
	return index;
}

void Terrain3DStorage::set_region_offsets(const TypedArray<Vector2i> &p_array) {
	region_offsets = p_array;

	generated_region_map.clear();
	_update_regions();
}

Ref<Image> Terrain3DStorage::get_map(int p_region_index, MapType p_map_type) const {
	Ref<Image> map;

	switch (p_map_type) {
		case TYPE_HEIGHT:
			map = height_maps[p_region_index];
			break;
		case TYPE_CONTROL:
			map = control_maps[p_region_index];
			break;
		case TYPE_COLOR:
			break;
		case TYPE_ALL:
			break;
		default:
			break;
	}
	return map;
}

void Terrain3DStorage::force_update_maps(MapType p_map_type) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			generated_height_maps.clear();
			break;
		case TYPE_CONTROL:
			generated_control_maps.clear();
			break;
		case TYPE_COLOR:
			break;
		case TYPE_ALL:
		default:
			generated_height_maps.clear();
			generated_control_maps.clear();
			break;
	}

	_update_regions();
}

void Terrain3DStorage::set_height_maps(const TypedArray<Image> &p_maps) {
	height_maps = p_maps;
	force_update_maps(TYPE_HEIGHT);
}

TypedArray<Image> Terrain3DStorage::get_height_maps() const {
	return height_maps;
}

void Terrain3DStorage::set_control_maps(const TypedArray<Image> &p_maps) {
	control_maps = p_maps;
	force_update_maps(TYPE_CONTROL);
}

int Terrain3DStorage::get_region_count() const {
	return region_offsets.size();
}

void Terrain3DStorage::set_shader_override(const Ref<Shader> &p_shader) {
	shader_override = p_shader;
}

void Terrain3DStorage::set_noise_enabled(bool p_enabled) {
	noise_enabled = p_enabled;
	_update_material();
}

void Terrain3DStorage::set_noise_scale(float p_scale) {
	noise_scale = p_scale;
	RenderingServer::get_singleton()->material_set_param(material, "noise_scale", noise_scale);
}

void Terrain3DStorage::set_noise_height(float p_height) {
	noise_height = p_height;
	RenderingServer::get_singleton()->material_set_param(material, "noise_height", noise_height);
}

void Terrain3DStorage::set_noise_blend_near(float p_near) {
	noise_blend_near = p_near;
	if (noise_blend_near > noise_blend_far) {
		set_noise_blend_far(noise_blend_near);
	}
	RenderingServer::get_singleton()->material_set_param(material, "noise_blend_near", noise_blend_near);
}

void Terrain3DStorage::set_noise_blend_far(float p_far) {
	noise_blend_far = p_far;
	if (noise_blend_far < noise_blend_near) {
		set_noise_blend_near(noise_blend_far);
	}
	RenderingServer::get_singleton()->material_set_param(material, "noise_blend_far", noise_blend_far);
}

void Terrain3DStorage::set_surface(const Ref<Terrain3DSurface> &p_material, int p_index) {
	if (p_index < get_surface_count()) {
		if (p_material.is_null()) {
			Ref<Terrain3DSurface> m = surfaces[p_index];
			m->disconnect("texture_changed", Callable(this, "update_surface_textures"));
			m->disconnect("value_changed", Callable(this, "update_surface_values"));
			surfaces.remove_at(p_index);
		} else {
			surfaces[p_index] = p_material;
		}
	} else {
		surfaces.push_back(p_material);
	}
	generated_albedo_textures.clear();
	generated_normal_textures.clear();

	_update_surfaces();
	notify_property_list_changed();
}

void Terrain3DStorage::set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces) {
	surfaces = p_surfaces;
	generated_albedo_textures.clear();
	generated_normal_textures.clear();
	_update_surfaces();
}

int Terrain3DStorage::get_surface_count() const {
	return surfaces.size();
}

void Terrain3DStorage::update_surface_textures() {
	_update_surface_data(true, false);
}

void Terrain3DStorage::update_surface_values() {
	_update_surface_data(false, true);
}

void Terrain3DStorage::_update_surfaces() {
	LOG(INFO, "Generating material surfaces");

	for (int i = 0; i < get_surface_count(); i++) {
		Ref<Terrain3DSurface> m = surfaces[i];

		if (m.is_null()) {
			continue;
		}
		if (!m->is_connected("texture_changed", Callable(this, "update_surface_textures"))) {
			m->connect("texture_changed", Callable(this, "update_surface_textures"));
		}
		if (!m->is_connected("value_changed", Callable(this, "update_surface_values"))) {
			m->connect("value_changed", Callable(this, "update_surface_values"));
		}
	}
	_update_surface_data(true, true);
}

void Terrain3DStorage::_update_surface_data(bool p_update_textures, bool p_update_values) {
	LOG(INFO, "Generating terrain color and scale arrays");

	if (p_update_textures) {
		// Update materials to enable sub-materials if albedo is available
		// and 'surfaces_enabled' changes from previous state

		bool was_surfaces_enabled = surfaces_enabled;
		surfaces_enabled = false;

		Vector2i albedo_size = Vector2i(0, 0);
		Vector2i normal_size = Vector2i(0, 0);

		// Get image size
		for (int i = 0; i < get_surface_count(); i++) {
			Ref<Terrain3DSurface> m = surfaces[i];

			if (m.is_null()) {
				continue;
			}

			Ref<Texture2D> a = m->get_normal_texture();
			Ref<Texture2D> n = m->get_albedo_texture();

			if (a.is_valid()) {
				Vector2i s = a->get_image()->get_size();
				if (albedo_size.length() == 0.0) {
					albedo_size = s;
				} else {
					ERR_FAIL_COND_MSG(s.length() != albedo_size.length(), "Albedo textures do not have same size!");
				}
			}
			if (n.is_valid()) {
				Vector2i s = n->get_image()->get_size();
				if (normal_size.length() == 0.0) {
					normal_size = s;
				} else {
					ERR_FAIL_COND_MSG(s.length() != normal_size.length(), "Normal map textures do not have same size!");
				}
			}
		}

		// Generate TextureArrays and replace nulls with a empty image
		if (generated_albedo_textures.is_dirty() && albedo_size.length() > 0) {
			LOG(INFO, "Generating terrain albedo arrays");

			Array albedo_texture_array;

			for (int i = 0; i < get_surface_count(); i++) {
				Ref<Terrain3DSurface> m = surfaces[i];

				if (m.is_null()) {
					continue;
				}

				Ref<Texture2D> tex = m->get_albedo_texture();
				Ref<Image> img;

				if (tex.is_null()) {
					img = Image::create(albedo_size.x, albedo_size.y, true, Image::FORMAT_RGBA8);
					img->fill(Color(1.0, 0.0, 1.0, 1.0));
					img->compress(Image::COMPRESS_S3TC, Image::COMPRESS_SOURCE_SRGB);
				} else {
					img = tex->get_image();
				}

				albedo_texture_array.push_back(img);
			}

			if (!albedo_texture_array.is_empty()) {
				generated_albedo_textures.create(albedo_texture_array);
				surfaces_enabled = true;
			}
		}

		if (generated_normal_textures.is_dirty() && normal_size.length() > 0) {
			LOG(INFO, "Generating terrain normal arrays");

			Array normal_texture_array;

			for (int i = 0; i < get_surface_count(); i++) {
				Ref<Terrain3DSurface> m = surfaces[i];

				if (m.is_null()) {
					continue;
				}

				Ref<Texture2D> tex = m->get_normal_texture();
				Ref<Image> img;

				if (tex.is_null()) {
					img = Image::create(normal_size.x, normal_size.y, true, Image::FORMAT_RGBA8);
					img->fill(Color(0.5, 0.5, 1.0, 1.0));
					img->compress(Image::COMPRESS_S3TC, Image::COMPRESS_SOURCE_SRGB);
				} else {
					img = tex->get_image();
				}

				normal_texture_array.push_back(img);
			}
			if (!normal_texture_array.is_empty()) {
				generated_normal_textures.create(normal_texture_array);
			}
		}

		if (was_surfaces_enabled != surfaces_enabled) {
			_update_material();
		}

		RenderingServer::get_singleton()->material_set_param(material, "texture_array_albedo", generated_albedo_textures.get_rid());
		RenderingServer::get_singleton()->material_set_param(material, "texture_array_normal", generated_normal_textures.get_rid());
	}

	if (p_update_values) {
		PackedVector3Array uv_scales;
		PackedColorArray colors;

		for (int i = 0; i < get_surface_count(); i++) {
			Ref<Terrain3DSurface> m = surfaces[i];

			if (m.is_null()) {
				continue;
			}
			uv_scales.push_back(m->get_uv_scale());
			colors.push_back(m->get_albedo());
		}

		RenderingServer::get_singleton()->material_set_param(material, "texture_uv_scale_array", uv_scales);
		RenderingServer::get_singleton()->material_set_param(material, "texture_color_array", colors);
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

	if (generated_region_map.is_dirty()) {
		LOG(INFO, "Updating region map");

		Ref<Image> image = Image::create(REGION_MAP_SIZE, REGION_MAP_SIZE, false, Image::FORMAT_RG8);
		image->fill(Color(0.0, 0.0, 0.0, 1.0));

		for (int i = 0; i < region_offsets.size(); i++) {
			Vector2i ofs = region_offsets[i];

			Color col = Color(float(i + 1) / 255.0, 1.0, 0, 1);
			image->set_pixelv(ofs + (Vector2i(REGION_MAP_SIZE, REGION_MAP_SIZE) / 2), col);
		}
		generated_region_map.create(image);
	}
	RenderingServer::get_singleton()->material_set_param(material, "height_maps", generated_height_maps.get_rid());
	RenderingServer::get_singleton()->material_set_param(material, "control_maps", generated_control_maps.get_rid());

	RenderingServer::get_singleton()->material_set_param(material, "region_map", generated_region_map.get_rid());
	RenderingServer::get_singleton()->material_set_param(material, "region_map_size", REGION_MAP_SIZE);
	RenderingServer::get_singleton()->material_set_param(material, "region_offsets", region_offsets);
}

void Terrain3DStorage::_update_material() {
	LOG(INFO, "Updating material");

	if (!material.is_valid()) {
		material = RenderingServer::get_singleton()->material_create();
	}

	if (!shader.is_valid()) {
		shader = RenderingServer::get_singleton()->shader_create();
	}

	{
		String code = "shader_type spatial;\n";
		code += "render_mode depth_draw_opaque, diffuse_burley;\n";
		code += "\n";

		// Uniforms
		code += "uniform float terrain_height = 512.0;\n";
		code += "uniform float region_size = 1024.0;\n";
		code += "uniform float region_pixel_size = 1.0;\n";
		code += "uniform int region_map_size = 16;\n";
		code += "\n";

		code += "uniform sampler2D region_map : hint_default_black, filter_linear, repeat_disable;\n";
		code += "uniform vec2 region_offsets[256];\n";
		code += "uniform sampler2DArray height_maps : filter_linear_mipmap, repeat_disable;\n";
		code += "uniform sampler2DArray control_maps : filter_linear_mipmap, repeat_disable;\n";
		code += "\n";

		if (surfaces_enabled) {
			code += "uniform sampler2DArray texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;\n";
			code += "uniform sampler2DArray texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;\n";
			code += "uniform vec3 texture_uv_scale_array[256];\n";
			code += "uniform vec3 texture_3d_projection_array[256];\n";
			code += "uniform vec4 texture_color_array[256];\n";
			code += "\n";
		}

		if (noise_enabled) {
			code += "uniform float noise_scale = 2.0;\n";
			code += "uniform float noise_height = 1.0;\n";
			code += "uniform float noise_blend_near = 0.5;\n";
			code += "uniform float noise_blend_far = 1.0;\n";
			code += "\n";

			code += "float hashv2(vec2 v) {\n ";
			code += "	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x))));\n ";
			code += "}\n\n";

			code += "float noise2D(vec2 st) {\n";
			code += "	vec2 i = floor(st);\n";
			code += "	vec2 f = fract(st);\n";
			code += "\n";
			code += "	// Four corners in 2D of a tile\n";
			code += "	float a = hashv2(i);\n";
			code += "	float b = hashv2(i + vec2(1.0, 0.0));\n";
			code += "	float c = hashv2(i + vec2(0.0, 1.0));\n";
			code += "	float d = hashv2(i + vec2(1.0, 1.0));\n";
			code += "\n";
			code += "	// Cubic Hermine Curve.  Same as SmoothStep()\n";
			code += "	vec2 u = f * f * (3.0 - 2.0 * f);\n";
			code += "\n";
			code += "	// Mix 4 corners percentages\n";
			code += "	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;\n";
			code += "}\n\n";
		}
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
		code += "	float index = floor(texelFetch(region_map, ivec2(floor(uv))+(region_map_size/2), 0).r * 255.0);\n";
		code += "	float height = 0.0;\n";
		code += "	if (index > 0.0){\n";
		code += "		vec2 pos = region_offsets[int(index - 1.0)];\n";
		code += "		height = texture(height_maps, vec3(uv-pos, index - 1.0)).r;\n";
		code += "	}\n";

		if (noise_enabled) {
			code += "	float weight = texture(region_map, (uv/float(region_map_size))+0.5).g;\n";
			code += "	height = mix(height, noise2D(uv * noise_scale) * noise_height, \n";
			code += "		clamp(smoothstep(noise_blend_near, noise_blend_far, 1.0 - weight), 0.0, 1.0) );\n ";
		}

		code += "	return height * terrain_height;\n";
		code += "}\n\n";

		code += "vec3 get_normal(vec2 uv) {\n";
		code += "	float left = get_height(uv + vec2(-region_pixel_size, 0));\n";
		code += "	float right = get_height(uv + vec2(region_pixel_size, 0));\n";
		code += "	float back = get_height(uv + vec2(0, -region_pixel_size));\n";
		code += "	float fore = get_height(uv + vec2(0, region_pixel_size));\n";
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
		code += "	UV2 = (world_vertex.xz / vec2(region_size)) + vec2(0.5);\n";
		code += "	UV = world_vertex.xz * 0.5;\n";
		code += "	VERTEX.y = get_height(UV2);\n";
		code += "\n";
		code += "	NORMAL = vec3(0, 1, 0);\n";
		code += "	TANGENT = cross(NORMAL, vec3(0, 0, 1));\n";
		code += "	BINORMAL = cross(NORMAL, TANGENT);\n";
		code += "}\n\n";

		// Fragment Shader
		code += "void fragment() {\n";
		code += "	NORMAL = mat3(VIEW_MATRIX) * get_normal(UV2);\n";
		code += "\n";

		if (surfaces_enabled) {
			code += "	vec3 normal = vec3(0.5, 0.5, 1.0);\n";
			code += "	vec3 color = vec3(0.0);\n";
			code += "	float rough = 1.0;\n";
			code += "\n";

			code += "	ROUGHNESS = rough;\n";
			code += "	NORMAL_MAP = normal;\n";
			code += "	NORMAL_MAP_DEPTH = 1.0;\n";
		} else {
			code += "	vec2 p = UV * 4.0;\n";
			code += "	vec2 ddx = dFdx(p);\n";
			code += "	vec2 ddy = dFdy(p);\n";
			code += "	vec2 w = max(abs(ddx), abs(ddy)) + 0.01;\n";
			code += "	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;\n";
			code += "	ALBEDO = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);\n";
			code += "\n";
		}
		code += "}\n\n";

		String string_code = String(code);

		RenderingServer::get_singleton()->shader_set_code(shader, string_code);
		RenderingServer::get_singleton()->material_set_shader(material, shader_override.is_null() ? shader : shader_override->get_rid());
	}
	RenderingServer::get_singleton()->material_set_param(material, "terrain_height", TERRAIN_MAX_HEIGHT);
	RenderingServer::get_singleton()->material_set_param(material, "region_size", region_size);
	RenderingServer::get_singleton()->material_set_param(material, "region_pixel_size", 1.0f / float(region_size));
}

void Terrain3DStorage::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_HEIGHT);
	BIND_ENUM_CONSTANT(TYPE_CONTROL);
	BIND_ENUM_CONSTANT(TYPE_COLOR);
	BIND_ENUM_CONSTANT(TYPE_ALL);

	BIND_ENUM_CONSTANT(SIZE_64);
	BIND_ENUM_CONSTANT(SIZE_128);
	BIND_ENUM_CONSTANT(SIZE_256);
	BIND_ENUM_CONSTANT(SIZE_512);
	BIND_ENUM_CONSTANT(SIZE_1024);
	BIND_ENUM_CONSTANT(SIZE_2048);

	BIND_CONSTANT(REGION_MAP_SIZE);
	BIND_CONSTANT(TERRAIN_MAX_HEIGHT);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DStorage::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DStorage::get_region_size);

	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DStorage::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DStorage::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_noise_enabled", "texture"), &Terrain3DStorage::set_noise_enabled);
	ClassDB::bind_method(D_METHOD("get_noise_enabled"), &Terrain3DStorage::get_noise_enabled);
	ClassDB::bind_method(D_METHOD("set_noise_scale", "scale"), &Terrain3DStorage::set_noise_scale);
	ClassDB::bind_method(D_METHOD("get_noise_scale"), &Terrain3DStorage::get_noise_scale);
	ClassDB::bind_method(D_METHOD("set_noise_height", "height"), &Terrain3DStorage::set_noise_height);
	ClassDB::bind_method(D_METHOD("get_noise_height"), &Terrain3DStorage::get_noise_height);
	ClassDB::bind_method(D_METHOD("set_noise_blend_near", "fade"), &Terrain3DStorage::set_noise_blend_near);
	ClassDB::bind_method(D_METHOD("get_noise_blend_near"), &Terrain3DStorage::get_noise_blend_near);
	ClassDB::bind_method(D_METHOD("set_noise_blend_far", "sharpness"), &Terrain3DStorage::set_noise_blend_far);
	ClassDB::bind_method(D_METHOD("get_noise_blend_far"), &Terrain3DStorage::get_noise_blend_far);

	ClassDB::bind_method(D_METHOD("set_surface", "material", "index"), &Terrain3DStorage::set_surface);
	ClassDB::bind_method(D_METHOD("get_surface", "index"), &Terrain3DStorage::get_surface);
	ClassDB::bind_method(D_METHOD("set_surfaces", "surfaces"), &Terrain3DStorage::set_surfaces);
	ClassDB::bind_method(D_METHOD("get_surfaces"), &Terrain3DStorage::get_surfaces);

	ClassDB::bind_method(D_METHOD("update_surface_textures"), &Terrain3DStorage::update_surface_textures);
	ClassDB::bind_method(D_METHOD("update_surface_values"), &Terrain3DStorage::update_surface_values);

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

	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64, 128:128, 256:256, 512:512, 1024:1024, 2048:2048"), "set_region_size", "get_region_size");

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image")), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image")), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::VECTOR2, PROPERTY_HINT_NONE)), "set_region_offsets", "get_region_offsets");

	ADD_GROUP("Noise", "noise_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "noise_enabled", PROPERTY_HINT_NONE), "set_noise_enabled", "get_noise_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_scale", PROPERTY_HINT_RANGE, "0.0, 10.0"), "set_noise_scale", "get_noise_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_height", PROPERTY_HINT_RANGE, "0.0, 10.0"), "set_noise_height", "get_noise_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_near", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_blend_near", "get_noise_blend_near");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_far", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_blend_far", "get_noise_blend_far");

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "surfaces", PROPERTY_HINT_ARRAY_TYPE, vformat("%s/%s:%s", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DSurface")), "set_surfaces", "get_surfaces");
}
