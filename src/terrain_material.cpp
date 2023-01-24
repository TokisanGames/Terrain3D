//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#include "terrain_material.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

TerrainMaterial3D::TerrainMaterial3D()
{
    if (!_initialized) {
        _update_shader();
        _initialized = true;
    }
}

TerrainMaterial3D::~TerrainMaterial3D()
{
    if (_initialized) {
        RenderingServer::get_singleton()->free_rid(shader);
    }
}


Shader::Mode TerrainMaterial3D::_get_shader_mode() const
{
	return Shader::MODE_SPATIAL;
}

RID TerrainMaterial3D::_get_shader_rid()
{
	return shader;
}

void TerrainMaterial3D::set_maps(const Ref<Texture2DArray>& p_height, const Ref<Texture2DArray>& p_control, const Array& p_offsets)
{
    RID hrid = p_height.is_valid() ? p_height->get_rid() : RID();
    RID crid = p_control.is_valid() ? p_control->get_rid() : RID();
    RenderingServer::get_singleton()->material_set_param(get_rid(), "height_maps", hrid);
    RenderingServer::get_singleton()->material_set_param(get_rid(), "control_maps", crid);
    RenderingServer::get_singleton()->material_set_param(get_rid(), "map_offsets", p_offsets);
}

void TerrainMaterial3D::_bind_methods()
{

}

void TerrainMaterial3D::_update_shader()
{
    if (shader.is_valid()) {
        RenderingServer::get_singleton()->free_rid(shader);
    }

    String code = "shader_type spatial;\n";

    code += "render_mode depth_draw_opaque, diffuse_burley;\n";

    // Uniforms
    code += "uniform float terrain_height = 512.0;\n";
    code += "uniform float terrain_size = 1024.0;\n";

    code += "uniform sampler2DArray height_maps : filter_linear_mipmap, repeat_disable;\n";
    code += "uniform sampler2DArray control_maps : filter_linear_mipmap, repeat_disable;\n";
    code += "uniform vec2 map_offsets[16];\n";
  
    code += "uniform sampler2DArray texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;\n";
    code += "uniform sampler2DArray texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;\n";

    code += "uniform vec3 texture_uv_scale_array[256];\n";
    code += "uniform vec3 texture_3d_projection_array[256];\n";
    code += "uniform vec4 texture_color_array[256];\n";
    code += "uniform int texture_array_normal_max;\n";

    code += "uniform float terrain_grid_scale = 1.0;\n";

    // Functions
    code += "vec3 unpack_normal(vec4 rgba) {\n";
    code += "    vec3 n = rgba.xzy * 2.0 - vec3(1.0);\n";
    code += "    n.z *= -1.0;\n";
    code += "    return n;\n";
    code += "}\n\n";

    code += "vec4 pack_normal(vec3 n, float a) {\n";
    code += "    n.z *= -1.0;\n";
    code += "    return vec4((n.xzy + vec3(1.0)) * 0.5, a);\n";
    code += "}\n\n";

    code += "float get_height(vec2 uv) {\n";
    code += "   float index = 0.0;\n";
    code += "   for (int i = 0; i < 16; i++){ vec2 pos = map_offsets[i]; vec2 max_pos = pos + 1.0;\n";
    code += "       if (uv.x > pos.x && uv.x < max_pos.x && uv.y > pos.y && uv.y < max_pos.y){\n";
    code += "           index = float(i); uv -= pos; break;}}\n";
    code += "   return texture(height_maps, vec3(uv, index)).r * terrain_height;\n";
    code += "}\n\n";

    code += "vec3 get_normal(vec2 uv) {\n";
    code += "    return vec3(0, 1, 0);\n";
    code += "}\n\n";

    // Vertex Shader
    code += "void vertex(){\n";
    code += "   vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n";
    code += "   UV2 = (world_vertex.xz / vec2(terrain_size + 1.0)) + vec2(0.5);\n";;
    code += "   UV = world_vertex.xz * 0.5;\n";
    code += "   VERTEX.y = get_height(UV2);\n";

    code += "   NORMAL = vec3(0, 1, 0);\n";
    code += "   TANGENT = cross(NORMAL, vec3(0, 0, 1));\n";
    code += "   BINORMAL = cross(NORMAL, TANGENT);\n";
    code += "}\n\n";

    // Fragment Shader
    code += "void fragment(){\n";

    code += "   vec3 normal = vec3(0.5, 0.5, 1.0);\n";
    code += "   vec3 color = vec3(0.0);\n";
    code += "   float rough = 1.0;\n";

    //code += "   NORMAL = mat3(VIEW_MATRIX) * get_normal(UV2);\n";

    code += "   vec2 p = UV * 4.0 * terrain_grid_scale;\n";
    code += "   vec2 ddx = dFdx(p);\n";
    code += "   vec2 ddy = dFdy(p);\n";
    code += "   vec2 w = max(abs(ddx), abs(ddy)) + 0.01;\n";
    code += "   vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;\n";
    code += "   color = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);\n";
    
    code += "   ALBEDO = color;\n";;
    code += "   ROUGHNESS = rough;\n";;
    code += "   NORMAL_MAP = normal;\n";;
    code += "   NORMAL_MAP_DEPTH = 1.0;\n";;
    code += "}\n";

    String string_code = String(code);

    shader = RenderingServer::get_singleton()->shader_create();
    RenderingServer::get_singleton()->shader_set_code(shader, string_code);
    RenderingServer::get_singleton()->material_set_shader(get_rid(), shader);
}

////////////////////////////
// TerrainLayerMaterial3D //
////////////////////////////

TerrainLayerMaterial3D::TerrainLayerMaterial3D()
{
}

TerrainLayerMaterial3D::~TerrainLayerMaterial3D()
{
}

Shader::Mode TerrainLayerMaterial3D::_get_shader_mode() const
{
    return Shader::MODE_SPATIAL;
}

RID TerrainLayerMaterial3D::_get_shader_rid()
{
    return shader;
}

void TerrainLayerMaterial3D::set_albedo(Color p_color)
{
    albedo = p_color;
    RenderingServer::get_singleton()->material_set_param(get_rid(), "albedo", albedo);
}

Color TerrainLayerMaterial3D::get_albedo() const
{
    return albedo;
}

void TerrainLayerMaterial3D::set_albedo_texture(Ref<Texture2D>& p_texture)
{
    if (_texture_is_valid(p_texture)) {
        albedo_texture = p_texture;
        RID rid = albedo_texture.is_valid() ? albedo_texture->get_rid() : RID();
        RenderingServer::get_singleton()->material_set_param(get_rid(), "albedo_texture", rid);
    }
}

Ref<Texture2D> TerrainLayerMaterial3D::get_albedo_texture() const
{
    return albedo_texture;
}

void TerrainLayerMaterial3D::set_normal_texture(Ref<Texture2D>& p_texture)
{
    if (_texture_is_valid(p_texture)) {
        normal_texture = p_texture;
        RID rid = normal_texture.is_valid() ? normal_texture->get_rid() : RID();
        RenderingServer::get_singleton()->material_set_param(get_rid(), "normal_texture", rid);
    }
}

Ref<Texture2D> TerrainLayerMaterial3D::get_normal_texture() const
{
    return normal_texture;
}

void TerrainLayerMaterial3D::set_uv_scale(Vector3 p_scale)
{
    uv_scale = p_scale;
    RenderingServer::get_singleton()->material_set_param(get_rid(), "uv_scale", uv_scale);
}

Vector3 TerrainLayerMaterial3D::get_uv_scale() const
{
    return uv_scale;
}

bool TerrainLayerMaterial3D::_texture_is_valid(Ref<Texture2D>& p_texture) const
{
    if (p_texture.is_null()) {
        return true;
    }

    int format = p_texture->get_image()->get_format();

    if (format != Image::FORMAT_RGBA8) {
        WARN_PRINT("Invalid format. Expected DXT5 RGBA8.");
        return false;
    }

    return true;
}

void TerrainLayerMaterial3D::_update_shader()
{
    if (shader.is_valid()) {
        RenderingServer::get_singleton()->free_rid(shader);
    }

    String code = "shader_type spatial;\n";
    code += "uniform vec4 albedo = vec4(1.0);\n";
    code += "uniform sampler2D albedo_texture : source_color,filter_linear_mipmap_anisotropic,repeat_enable;\n";
    code += "uniform sampler2D normal_texture : filter_linear_mipmap_anisotropic,repeat_enable;\n";
    code += "uniform float normal_scale : hint_range(-16.0, 16.0, 0.1);\n";
    code += "uniform vec3 uv_scale = vec3(1.0,1.0,1.0);\n";
    code += "uniform bool uv_anti_tile;\n\n";
    code += "void vertex(){\n";
    code += "	UV*=uv_scale.xy;\n";
    code += "}\n\n";
    code += "void fragment(){\n";
    code += "	ALBEDO=texture(albedo_texture, UV).rgb * albedo.rgb;\n";
    code += "	vec4 normal_map =texture(normal_texture, UV);\n";

    if (!normal_texture.is_null()) {
        code += "	NORMAL_MAP=normal_map.rgb;\n";
        code += "	ROUGHNESS=normal_map.a;\n";
    }

    code += "}\n";

    shader = RenderingServer::get_singleton()->shader_create();
    RenderingServer::get_singleton()->shader_set_code(shader, code);
    RenderingServer::get_singleton()->material_set_shader(get_rid(), shader);

}

void TerrainLayerMaterial3D::_bind_methods() {

}