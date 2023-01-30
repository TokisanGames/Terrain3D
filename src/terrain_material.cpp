//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include <godot_cpp/core/class_db.hpp>

#include "terrain_logger.h"
#include "terrain_material.h"

using namespace godot;

TerrainLayerMaterial3D::TerrainLayerMaterial3D() {
}

TerrainLayerMaterial3D::~TerrainLayerMaterial3D() {
}

Shader::Mode TerrainLayerMaterial3D::_get_shader_mode() const {
	return Shader::MODE_SPATIAL;
}

RID TerrainLayerMaterial3D::_get_shader_rid() {
	return shader;
}

void TerrainLayerMaterial3D::set_albedo(Color p_color) {
	albedo = p_color;
	RenderingServer::get_singleton()->material_set_param(get_rid(), "albedo", albedo);
}

Color TerrainLayerMaterial3D::get_albedo() const {
	return albedo;
}

void TerrainLayerMaterial3D::set_albedo_texture(Ref<Texture2D> &p_texture) {
	if (_texture_is_valid(p_texture)) {
		albedo_texture = p_texture;
		RID rid = albedo_texture.is_valid() ? albedo_texture->get_rid() : RID();
		RenderingServer::get_singleton()->material_set_param(get_rid(), "albedo_texture", rid);
	}
}

Ref<Texture2D> TerrainLayerMaterial3D::get_albedo_texture() const {
	return albedo_texture;
}

void TerrainLayerMaterial3D::set_normal_texture(Ref<Texture2D> &p_texture) {
	if (_texture_is_valid(p_texture)) {
		normal_texture = p_texture;
		RID rid = normal_texture.is_valid() ? normal_texture->get_rid() : RID();
		RenderingServer::get_singleton()->material_set_param(get_rid(), "normal_texture", rid);
	}
}

Ref<Texture2D> TerrainLayerMaterial3D::get_normal_texture() const {
	return normal_texture;
}

void TerrainLayerMaterial3D::set_uv_scale(Vector3 p_scale) {
	uv_scale = p_scale;
	RenderingServer::get_singleton()->material_set_param(get_rid(), "uv_scale", uv_scale);
}

Vector3 TerrainLayerMaterial3D::get_uv_scale() const {
	return uv_scale;
}

bool TerrainLayerMaterial3D::_texture_is_valid(Ref<Texture2D> &p_texture) const {
	if (p_texture.is_null()) {
		return true;
	}

	int format = p_texture->get_image()->get_format();

	if (format != Image::FORMAT_RGBA8) {
		LOG(WARN, "Invalid format. Expected DXT5 RGBA8.");
		return false;
	}

	return true;
}

void TerrainLayerMaterial3D::_update_shader() {
	if (shader.is_valid()) {
		RenderingServer::get_singleton()->free_rid(shader);
	}

	String code = "shader_type spatial;\n";
	code += "\n";
	code += "uniform vec4 albedo = vec4(1.0);\n";
	code += "uniform sampler2D albedo_texture : source_color,filter_linear_mipmap_anisotropic,repeat_enable;\n";
	code += "uniform sampler2D normal_texture : filter_linear_mipmap_anisotropic,repeat_enable;\n";
	code += "uniform float normal_scale : hint_range(-16.0, 16.0, 0.1);\n";
	code += "uniform vec3 uv_scale = vec3(1.0,1.0,1.0);\n";
	code += "uniform bool uv_anti_tile;\n";
	code += "\n";

	code += "void vertex(){\n";
	code += "	UV *= uv_scale.xy;\n";
	code += "}\n\n";

	code += "void fragment(){\n";
	code += "	ALBEDO = texture(albedo_texture, UV).rgb * albedo.rgb;\n";
	code += "	vec4 normal_map = texture(normal_texture, UV);\n";

	if (!normal_texture.is_null()) {
		code += "	NORMAL_MAP = normal_map.rgb;\n";
		code += "	ROUGHNESS = normal_map.a;\n";
	}

	code += "}\n\n";

	shader = RenderingServer::get_singleton()->shader_create();
	RenderingServer::get_singleton()->shader_set_code(shader, code);
	RenderingServer::get_singleton()->material_set_shader(get_rid(), shader);
}

void TerrainLayerMaterial3D::_bind_methods() {
}