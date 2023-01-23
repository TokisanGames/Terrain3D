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

void TerrainMaterial3D::_bind_methods()
{

}

void TerrainMaterial3D::_update_shader()
{
    if (shader.is_valid()) {
        RenderingServer::get_singleton()->free_rid(shader);
    }

    String code = "shader_type spatial;\n";

    code = code + "render_mode depth_draw_opaque, diffuse_burley;\n";

    // Uniforms
    code = code + "uniform float terrain_height = 64.0;\n";
    code = code + "uniform float terrain_size = 1024.0;\n";

    code = code + "uniform sampler2D terrain_heightmap : filter_linear_mipmap, repeat_disable;\n";
    code = code + "uniform sampler2D terrain_normalmap : filter_linear_mipmap, repeat_disable;\n";
    code = code + "uniform sampler2D terrain_controlmap : filter_linear_mipmap_anisotropic, repeat_disable;\n";

    code = code + "uniform sampler2DArray texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;\n";
    code = code + "uniform sampler2DArray texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;\n";

    code = code + "uniform vec3 texture_uv_scale_array[256];\n";
    code = code + "uniform vec3 texture_3d_projection_array[256];\n";
    code = code + "uniform vec4 texture_color_array[256];\n";
    code = code + "uniform int texture_array_normal_max;\n";

    code = code + "uniform float terrain_grid_scale = 1.0;\n";

    // Functions
    code = code + "vec3 unpack_normal(vec4 rgba) {\n";
    code = code + "    vec3 n = rgba.xzy * 2.0 - vec3(1.0);\n";
    code = code + "    n.z *= -1.0;\n";
    code = code + "    return n;\n";
    code = code + "}\n\n";

    code = code + "vec4 pack_normal(vec3 n, float a) {\n";
    code = code + "    n.z *= -1.0;\n";
    code = code + "    return vec4((n.xzy + vec3(1.0)) * 0.5, a);\n";
    code = code + "}\n\n";

    code = code + "float get_height(vec2 uv) {\n";
    code = code + "    return texture(terrain_heightmap, uv).r * terrain_height;\n";
    code = code + "}\n\n";

    code = code + "vec3 get_normal(vec2 uv) {\n";
    code = code + "    vec3 n = unpack_normal(texture(terrain_normalmap, uv));\n";
    code = code + "    return normalize(n);\n";
    code = code + "}\n\n";

    code = code + "vec4 depth_blend(vec4 a_value, float a_bump, vec4 b_value, float b_bump, float t) {\n";
    code = code + "    float ma = max(a_bump + (1.0 - t), b_bump + t) - 0.1;\n";
    code = code + "    float ba = max(a_bump + (1.0 - t) - ma, 0.0);\n";
    code = code + "    float bb = max(b_bump + t - ma, 0.0);\n";
    code = code + "    return (a_value * ba + b_value * bb) / (ba + bb);\n";
    code = code + "}\n\n";

    code = code + "float random(vec2 input) {\n";
    code = code + "    vec4 a = fract(input.xyxy * (2.0f * vec4(1.3442f, 1.0377f, 0.98848f, 0.75775f)) + input.yxyx);\n";
    code = code + "    return fract(dot(a * a, vec4(251.0)));\n";
    code = code + "}\n\n";

    code = code + "float blend_weights(float weight, float detail) {\n";
    code = code + "    weight = sqrt(weight * 0.2);\n";
    code = code + "    float detailContrast = 4.0f;\n";
    code = code + "    float result = max(0.1 * weight, detailContrast * (weight + detail) + 1.0f - (detail + detailContrast));\n";
    code = code + "    return pow(result, 2.0);\n";
    code = code + "}\n\n";

    code = code + "vec2 rotate(vec2 v, float cosa, float sina) {\n";
    code = code + "    return vec2(cosa * v.x - sina * v.y, sina * v.x + cosa * v.y);\n";
    code = code + "}\n\n";

    code = code + "vec4 get_material(vec2 uv, vec4 index, ivec2 uv_center, float weight, inout float scale, inout vec4 out_normal) {\n";
    code = code + "    float rand = random(vec2(uv_center)) * TAU;\n";
    code = code + "    float material = index.r * 255.0;\n";
    code = code + "    float materialOverlay = index.g * 255.0;\n";
    code = code + "    float materialBlend = index.b;\n";
    code = code + "    vec2 rot = normalize(vec2(sin(rand), cos(rand)));\n";
    code = code + "    vec2 matUV = rotate(uv, rot.x, rot.y) * texture_uv_scale_array[int(material)].xy;\n";
    code = code + "    vec2 ddx = dFdx(matUV);\n";
    code = code + "    vec2 ddy = dFdy(matUV);\n";
    code = code + "    vec4 col1 = textureGrad(texture_array_albedo, vec3(matUV, material), ddx, ddy);\n";
    code = code + "    vec4 col2 = textureGrad(texture_array_albedo, vec3(matUV, materialOverlay), ddx, ddy);\n";
    code = code + "    vec4 albedo = depth_blend(col1, col1.a, col2, col2.a, materialBlend);\n";
    code = code + "    vec4 nor1 = textureGrad(texture_array_normal, vec3(matUV, material), ddx, ddy);\n";
    code = code + "    vec4 nor2 = textureGrad(texture_array_normal, vec3(matUV, materialOverlay), ddx, ddy);\n";

    code = code + "    float nw = 1.0 - float(texture_array_normal_max >= int(material));\n";

    code = code + "    vec4 normal = depth_blend(nor1, col1.a, nor2, col2.a, materialBlend);\n";
    code = code + "    vec3 n = unpack_normal(normal);\n";
    code = code + "    n.xz = rotate(n.xz, rot.x, -rot.y);\n";
    code = code + "    normal = pack_normal(n, normal.a);\n";
    code = code + "    weight = blend_weights(weight, albedo.a);\n";
    code = code + "    out_normal += mix(normal, vec4(0.5, 0.5, 1.0, 1.0), nw) * weight;\n";
    code = code + "    scale += weight;\n";
    code = code + "    return albedo * weight;\n";
    code = code + "}\n\n";

    // Vertex Shader
    code = code + "void vertex(){\n";
    code = code + "   vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n";
    code = code + "   UV2 = (world_vertex.xz / vec2(terrain_size + 1.0)) + vec2(0.5);\n";;
    code = code + "   UV = world_vertex.xz * 0.5;\n";
    code = code + "   VERTEX.y = get_height(UV2) * VERTEX.y;\n";
    code = code + "   NORMAL = get_normal(UV2);\n";
    code = code + "   TANGENT = cross(NORMAL, vec3(0, 0, 1));\n";
    code = code + "   BINORMAL = cross(NORMAL, TANGENT);\n";
    code = code + "}\n\n";

    // Fragment Shader
    code = code + "void fragment(){\n";

    code = code + "   vec3 normal = vec3(0.5, 0.5, 1.0);\n";
    code = code + "   vec3 color = vec3(0.0);\n";
    code = code + "   float rough = 1.0;\n";

    code = code + "   NORMAL = mat3(VIEW_MATRIX) * get_normal(UV2);\n";

    if (grid_enabled) {
        code = code + "   vec2 p = UV * 4.0 * terrain_grid_scale;\n";
        code = code + "   vec2 ddx = dFdx(p);\n";
        code = code + "   vec2 ddy = dFdy(p);\n";
        code = code + "   vec2 w = max(abs(ddx), abs(ddy)) + 0.01;\n";
        code = code + "   vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;\n";
        code = code + "   color = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);\n";
    }
    else {

        code = code + "   vec2 texSize = vec2(textureSize(terrain_controlmap, 0));\n";
        code = code + "   vec2 pos_texel = UV2 * texSize + 0.5;\n";
        code = code + "   vec2 pos_texel00 = floor(pos_texel);\n";

        code = code + "   vec4 mirror = vec4(0.0, 0.0, 1.0, 1.0);\n";
        code = code + "   mirror.xy = fract(pos_texel00 * 0.5) * 2.0;\n";
        code = code + "   mirror.zw = vec2(1.0) - mirror.xy;\n";

        code = code + "   vec2 weights1 = clamp(pos_texel - pos_texel00, 0, 1);\n";
        code = code + "   weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);\n";

        code = code + "   vec2 weights0 = vec2(1.0) - weights1;\n";

        code = code + "   ivec2 index00UV = ivec2(pos_texel00 + mirror.xy);\n";
        code = code + "   ivec2 index01UV = ivec2(pos_texel00 + mirror.xw);\n";
        code = code + "   ivec2 index10UV = ivec2(pos_texel00 + mirror.zy);\n";
        code = code + "   ivec2 index11UV = ivec2(pos_texel00 + mirror.zw);\n";

        code = code + "   vec4 index00 = texelFetch(terrain_controlmap, index00UV, 0);\n";
        code = code + "   vec4 index01 = texelFetch(terrain_controlmap, index01UV, 0);\n";
        code = code + "   vec4 index10 = texelFetch(terrain_controlmap, index10UV, 0);\n";
        code = code + "   vec4 index11 = texelFetch(terrain_controlmap, index11UV, 0);\n";

        code = code + "   float scale = 0.0;\n";
        code = code + "   vec4 in_normal = vec4(0.0);\n";

        code = code + "   color = get_material(UV, index00, index00UV, weights0.x * weights0.y, scale, in_normal).rgb;\n";
        code = code + "   color += get_material(UV, index01, index01UV, weights0.x * weights1.y, scale, in_normal).rgb;\n";
        code = code + "   color += get_material(UV, index10, index10UV, weights1.x * weights0.y, scale, in_normal).rgb;\n";
        code = code + "   color += get_material(UV, index11, index11UV, weights1.x * weights1.y, scale, in_normal).rgb;\n";

        code = code + "   scale = 1.0 / scale;\n";
        code = code + "   rough = in_normal.a * scale;\n";
        code = code + "   normal = in_normal.rgb * scale;\n";
        code = code + "   color *= scale;\n";
    }

    code = code + "   ALBEDO = color;\n";;
    code = code + "   ROUGHNESS = rough;\n";;
    code = code + "   NORMAL_MAP = normal;\n";;
    code = code + "   NORMAL_MAP_DEPTH = 1.0;\n";;
    code = code + "}\n";

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
    code = code + "uniform vec4 albedo = vec4(1.0);\n";
    code = code + "uniform sampler2D albedo_texture : source_color,filter_linear_mipmap_anisotropic,repeat_enable;\n";
    code = code + "uniform sampler2D normal_texture : filter_linear_mipmap_anisotropic,repeat_enable;\n";
    code = code + "uniform float normal_scale : hint_range(-16.0, 16.0, 0.1);\n";
    code = code + "uniform vec3 uv_scale = vec3(1.0,1.0,1.0);\n";
    code = code + "uniform bool uv_anti_tile;\n\n";
    code = code + "void vertex(){\n";
    code = code + "	UV*=uv_scale.xy;\n";
    code = code + "}\n\n";
    code = code + "void fragment(){\n";
    code = code + "	ALBEDO=texture(albedo_texture, UV).rgb * albedo.rgb;\n";
    code = code + "	vec4 normal_map =texture(normal_texture, UV);\n";

    if (!normal_texture.is_null()) {
        code = code + "	NORMAL_MAP=normal_map.rgb;\n";
        code = code + "	ROUGHNESS=normal_map.a;\n";
    }

    code = code + "}\n";

    shader = RenderingServer::get_singleton()->shader_create();
    RenderingServer::get_singleton()->shader_set_code(shader, code);
    RenderingServer::get_singleton()->material_set_shader(get_rid(), shader);

}

void TerrainLayerMaterial3D::_bind_methods() {

}