using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DMaterial : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DMaterial";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DMaterial() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DMaterial"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DMaterial Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DMaterial>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DMaterial"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DMaterial"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DMaterial"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DMaterial"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DMaterial Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DMaterial>(godotObject);
    }
#region Enums

    public enum WorldBackgroundEnum : long
    {
        None = 0,
        Flat = 1,
        Noise = 2,
    }

    public enum TextureFilteringEnum : long
    {
        Linear = 0,
        Nearest = 1,
    }

#endregion

#region Properties

    public Godot.Collections.Dictionary ShaderParameters
    {
        get => (Godot.Collections.Dictionary)Get(_cached__shader_parameters);
        set => Set(_cached__shader_parameters, Variant.From(value));
    }

    public long /*None,Flat,Noise*/ WorldBackground
    {
        get => (long /*None,Flat,Noise*/)Get(_cached_world_background).As<Int64>();
        set => Set(_cached_world_background, Variant.From(value));
    }

    public long /*Linear,Nearest*/ TextureFiltering
    {
        get => (long /*Linear,Nearest*/)Get(_cached_texture_filtering).As<Int64>();
        set => Set(_cached_texture_filtering, Variant.From(value));
    }

    public bool AutoShader
    {
        get => (bool)Get(_cached_auto_shader);
        set => Set(_cached_auto_shader, Variant.From(value));
    }

    public bool DualScaling
    {
        get => (bool)Get(_cached_dual_scaling);
        set => Set(_cached_dual_scaling, Variant.From(value));
    }

    public bool ShaderOverrideEnabled
    {
        get => (bool)Get(_cached_shader_override_enabled);
        set => Set(_cached_shader_override_enabled, Variant.From(value));
    }

    public Shader ShaderOverride
    {
        get => (Shader)Get(_cached_shader_override);
        set => Set(_cached_shader_override, Variant.From(value));
    }

    public bool ShowRegionGrid
    {
        get => (bool)Get(_cached_show_region_grid);
        set => Set(_cached_show_region_grid, Variant.From(value));
    }

    public bool ShowInstancerGrid
    {
        get => (bool)Get(_cached_show_instancer_grid);
        set => Set(_cached_show_instancer_grid, Variant.From(value));
    }

    public bool ShowVertexGrid
    {
        get => (bool)Get(_cached_show_vertex_grid);
        set => Set(_cached_show_vertex_grid, Variant.From(value));
    }

    public bool ShowContours
    {
        get => (bool)Get(_cached_show_contours);
        set => Set(_cached_show_contours, Variant.From(value));
    }

    public bool ShowNavigation
    {
        get => (bool)Get(_cached_show_navigation);
        set => Set(_cached_show_navigation, Variant.From(value));
    }

    public bool ShowCheckered
    {
        get => (bool)Get(_cached_show_checkered);
        set => Set(_cached_show_checkered, Variant.From(value));
    }

    public bool ShowGrey
    {
        get => (bool)Get(_cached_show_grey);
        set => Set(_cached_show_grey, Variant.From(value));
    }

    public bool ShowHeightmap
    {
        get => (bool)Get(_cached_show_heightmap);
        set => Set(_cached_show_heightmap, Variant.From(value));
    }

    public bool ShowColormap
    {
        get => (bool)Get(_cached_show_colormap);
        set => Set(_cached_show_colormap, Variant.From(value));
    }

    public bool ShowRoughmap
    {
        get => (bool)Get(_cached_show_roughmap);
        set => Set(_cached_show_roughmap, Variant.From(value));
    }

    public bool ShowControlTexture
    {
        get => (bool)Get(_cached_show_control_texture);
        set => Set(_cached_show_control_texture, Variant.From(value));
    }

    public bool ShowControlAngle
    {
        get => (bool)Get(_cached_show_control_angle);
        set => Set(_cached_show_control_angle, Variant.From(value));
    }

    public bool ShowControlScale
    {
        get => (bool)Get(_cached_show_control_scale);
        set => Set(_cached_show_control_scale, Variant.From(value));
    }

    public bool ShowControlBlend
    {
        get => (bool)Get(_cached_show_control_blend);
        set => Set(_cached_show_control_blend, Variant.From(value));
    }

    public bool ShowAutoshader
    {
        get => (bool)Get(_cached_show_autoshader);
        set => Set(_cached_show_autoshader, Variant.From(value));
    }

    public bool ShowTextureHeight
    {
        get => (bool)Get(_cached_show_texture_height);
        set => Set(_cached_show_texture_height, Variant.From(value));
    }

    public bool ShowTextureNormal
    {
        get => (bool)Get(_cached_show_texture_normal);
        set => Set(_cached_show_texture_normal, Variant.From(value));
    }

    public bool ShowTextureRough
    {
        get => (bool)Get(_cached_show_texture_rough);
        set => Set(_cached_show_texture_rough, Variant.From(value));
    }

#endregion

#region Methods

    public void SetShaderParameters(Godot.Collections.Dictionary dict) => Call(_cached__set_shader_parameters, dict);

    public Godot.Collections.Dictionary GetShaderParameters() => Call(_cached__get_shader_parameters).As<Godot.Collections.Dictionary>();

    public void Update() => Call(_cached_update);

    public Rid GetMaterialRid() => Call(_cached_get_material_rid).As<Rid>();

    public Rid GetShaderRid() => Call(_cached_get_shader_rid).As<Rid>();

    public void SetWorldBackground(int background) => Call(_cached_set_world_background, background);

    public int GetWorldBackground() => Call(_cached_get_world_background).As<int>();

    public void SetTextureFiltering(int filtering) => Call(_cached_set_texture_filtering, filtering);

    public int GetTextureFiltering() => Call(_cached_get_texture_filtering).As<int>();

    public void SetAutoShader(bool enabled) => Call(_cached_set_auto_shader, enabled);

    public bool GetAutoShader() => Call(_cached_get_auto_shader).As<bool>();

    public void SetDualScaling(bool enabled) => Call(_cached_set_dual_scaling, enabled);

    public bool GetDualScaling() => Call(_cached_get_dual_scaling).As<bool>();

    public void EnableShaderOverride(bool enabled) => Call(_cached_enable_shader_override, enabled);

    public bool IsShaderOverrideEnabled() => Call(_cached_is_shader_override_enabled).As<bool>();

    public void SetShaderOverride(Shader shader) => Call(_cached_set_shader_override, (Shader)shader);

    public Shader GetShaderOverride() => GDExtensionHelper.Bind<Shader>(Call(_cached_get_shader_override).As<GodotObject>());

    public void SetShaderParam(StringName name, Variant? value) => Call(_cached_set_shader_param, name, value ?? new Variant());

    public void GetShaderParam(StringName name) => Call(_cached_get_shader_param, name);

    public void SetShowRegionGrid(bool enabled) => Call(_cached_set_show_region_grid, enabled);

    public bool GetShowRegionGrid() => Call(_cached_get_show_region_grid).As<bool>();

    public void SetShowInstancerGrid(bool enabled) => Call(_cached_set_show_instancer_grid, enabled);

    public bool GetShowInstancerGrid() => Call(_cached_get_show_instancer_grid).As<bool>();

    public void SetShowVertexGrid(bool enabled) => Call(_cached_set_show_vertex_grid, enabled);

    public bool GetShowVertexGrid() => Call(_cached_get_show_vertex_grid).As<bool>();

    public void SetShowContours(bool enabled) => Call(_cached_set_show_contours, enabled);

    public bool GetShowContours() => Call(_cached_get_show_contours).As<bool>();

    public void SetShowNavigation(bool enabled) => Call(_cached_set_show_navigation, enabled);

    public bool GetShowNavigation() => Call(_cached_get_show_navigation).As<bool>();

    public void SetShowCheckered(bool enabled) => Call(_cached_set_show_checkered, enabled);

    public bool GetShowCheckered() => Call(_cached_get_show_checkered).As<bool>();

    public void SetShowGrey(bool enabled) => Call(_cached_set_show_grey, enabled);

    public bool GetShowGrey() => Call(_cached_get_show_grey).As<bool>();

    public void SetShowHeightmap(bool enabled) => Call(_cached_set_show_heightmap, enabled);

    public bool GetShowHeightmap() => Call(_cached_get_show_heightmap).As<bool>();

    public void SetShowColormap(bool enabled) => Call(_cached_set_show_colormap, enabled);

    public bool GetShowColormap() => Call(_cached_get_show_colormap).As<bool>();

    public void SetShowRoughmap(bool enabled) => Call(_cached_set_show_roughmap, enabled);

    public bool GetShowRoughmap() => Call(_cached_get_show_roughmap).As<bool>();

    public void SetShowControlTexture(bool enabled) => Call(_cached_set_show_control_texture, enabled);

    public bool GetShowControlTexture() => Call(_cached_get_show_control_texture).As<bool>();

    public void SetShowControlAngle(bool enabled) => Call(_cached_set_show_control_angle, enabled);

    public bool GetShowControlAngle() => Call(_cached_get_show_control_angle).As<bool>();

    public void SetShowControlScale(bool enabled) => Call(_cached_set_show_control_scale, enabled);

    public bool GetShowControlScale() => Call(_cached_get_show_control_scale).As<bool>();

    public void SetShowControlBlend(bool enabled) => Call(_cached_set_show_control_blend, enabled);

    public bool GetShowControlBlend() => Call(_cached_get_show_control_blend).As<bool>();

    public void SetShowAutoshader(bool enabled) => Call(_cached_set_show_autoshader, enabled);

    public bool GetShowAutoshader() => Call(_cached_get_show_autoshader).As<bool>();

    public void SetShowTextureHeight(bool enabled) => Call(_cached_set_show_texture_height, enabled);

    public bool GetShowTextureHeight() => Call(_cached_get_show_texture_height).As<bool>();

    public void SetShowTextureNormal(bool enabled) => Call(_cached_set_show_texture_normal, enabled);

    public bool GetShowTextureNormal() => Call(_cached_get_show_texture_normal).As<bool>();

    public void SetShowTextureRough(bool enabled) => Call(_cached_set_show_texture_rough, enabled);

    public bool GetShowTextureRough() => Call(_cached_get_show_texture_rough).As<bool>();

    public int Save(string path) => Call(_cached_save, path).As<int>();

#endregion

    private static readonly StringName _cached__shader_parameters = "_shader_parameters";
    private static readonly StringName _cached_world_background = "world_background";
    private static readonly StringName _cached_texture_filtering = "texture_filtering";
    private static readonly StringName _cached_auto_shader = "auto_shader";
    private static readonly StringName _cached_dual_scaling = "dual_scaling";
    private static readonly StringName _cached_shader_override_enabled = "shader_override_enabled";
    private static readonly StringName _cached_shader_override = "shader_override";
    private static readonly StringName _cached_show_region_grid = "show_region_grid";
    private static readonly StringName _cached_show_instancer_grid = "show_instancer_grid";
    private static readonly StringName _cached_show_vertex_grid = "show_vertex_grid";
    private static readonly StringName _cached_show_contours = "show_contours";
    private static readonly StringName _cached_show_navigation = "show_navigation";
    private static readonly StringName _cached_show_checkered = "show_checkered";
    private static readonly StringName _cached_show_grey = "show_grey";
    private static readonly StringName _cached_show_heightmap = "show_heightmap";
    private static readonly StringName _cached_show_colormap = "show_colormap";
    private static readonly StringName _cached_show_roughmap = "show_roughmap";
    private static readonly StringName _cached_show_control_texture = "show_control_texture";
    private static readonly StringName _cached_show_control_angle = "show_control_angle";
    private static readonly StringName _cached_show_control_scale = "show_control_scale";
    private static readonly StringName _cached_show_control_blend = "show_control_blend";
    private static readonly StringName _cached_show_autoshader = "show_autoshader";
    private static readonly StringName _cached_show_texture_height = "show_texture_height";
    private static readonly StringName _cached_show_texture_normal = "show_texture_normal";
    private static readonly StringName _cached_show_texture_rough = "show_texture_rough";
    private static readonly StringName _cached__set_shader_parameters = "_set_shader_parameters";
    private static readonly StringName _cached__get_shader_parameters = "_get_shader_parameters";
    private static readonly StringName _cached_update = "update";
    private static readonly StringName _cached_get_material_rid = "get_material_rid";
    private static readonly StringName _cached_get_shader_rid = "get_shader_rid";
    private static readonly StringName _cached_set_world_background = "set_world_background";
    private static readonly StringName _cached_get_world_background = "get_world_background";
    private static readonly StringName _cached_set_texture_filtering = "set_texture_filtering";
    private static readonly StringName _cached_get_texture_filtering = "get_texture_filtering";
    private static readonly StringName _cached_set_auto_shader = "set_auto_shader";
    private static readonly StringName _cached_get_auto_shader = "get_auto_shader";
    private static readonly StringName _cached_set_dual_scaling = "set_dual_scaling";
    private static readonly StringName _cached_get_dual_scaling = "get_dual_scaling";
    private static readonly StringName _cached_enable_shader_override = "enable_shader_override";
    private static readonly StringName _cached_is_shader_override_enabled = "is_shader_override_enabled";
    private static readonly StringName _cached_set_shader_override = "set_shader_override";
    private static readonly StringName _cached_get_shader_override = "get_shader_override";
    private static readonly StringName _cached_set_shader_param = "set_shader_param";
    private static readonly StringName _cached_get_shader_param = "get_shader_param";
    private static readonly StringName _cached_set_show_region_grid = "set_show_region_grid";
    private static readonly StringName _cached_get_show_region_grid = "get_show_region_grid";
    private static readonly StringName _cached_set_show_instancer_grid = "set_show_instancer_grid";
    private static readonly StringName _cached_get_show_instancer_grid = "get_show_instancer_grid";
    private static readonly StringName _cached_set_show_vertex_grid = "set_show_vertex_grid";
    private static readonly StringName _cached_get_show_vertex_grid = "get_show_vertex_grid";
    private static readonly StringName _cached_set_show_contours = "set_show_contours";
    private static readonly StringName _cached_get_show_contours = "get_show_contours";
    private static readonly StringName _cached_set_show_navigation = "set_show_navigation";
    private static readonly StringName _cached_get_show_navigation = "get_show_navigation";
    private static readonly StringName _cached_set_show_checkered = "set_show_checkered";
    private static readonly StringName _cached_get_show_checkered = "get_show_checkered";
    private static readonly StringName _cached_set_show_grey = "set_show_grey";
    private static readonly StringName _cached_get_show_grey = "get_show_grey";
    private static readonly StringName _cached_set_show_heightmap = "set_show_heightmap";
    private static readonly StringName _cached_get_show_heightmap = "get_show_heightmap";
    private static readonly StringName _cached_set_show_colormap = "set_show_colormap";
    private static readonly StringName _cached_get_show_colormap = "get_show_colormap";
    private static readonly StringName _cached_set_show_roughmap = "set_show_roughmap";
    private static readonly StringName _cached_get_show_roughmap = "get_show_roughmap";
    private static readonly StringName _cached_set_show_control_texture = "set_show_control_texture";
    private static readonly StringName _cached_get_show_control_texture = "get_show_control_texture";
    private static readonly StringName _cached_set_show_control_angle = "set_show_control_angle";
    private static readonly StringName _cached_get_show_control_angle = "get_show_control_angle";
    private static readonly StringName _cached_set_show_control_scale = "set_show_control_scale";
    private static readonly StringName _cached_get_show_control_scale = "get_show_control_scale";
    private static readonly StringName _cached_set_show_control_blend = "set_show_control_blend";
    private static readonly StringName _cached_get_show_control_blend = "get_show_control_blend";
    private static readonly StringName _cached_set_show_autoshader = "set_show_autoshader";
    private static readonly StringName _cached_get_show_autoshader = "get_show_autoshader";
    private static readonly StringName _cached_set_show_texture_height = "set_show_texture_height";
    private static readonly StringName _cached_get_show_texture_height = "get_show_texture_height";
    private static readonly StringName _cached_set_show_texture_normal = "set_show_texture_normal";
    private static readonly StringName _cached_get_show_texture_normal = "get_show_texture_normal";
    private static readonly StringName _cached_set_show_texture_rough = "set_show_texture_rough";
    private static readonly StringName _cached_get_show_texture_rough = "get_show_texture_rough";
    private static readonly StringName _cached_save = "save";
}