using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3D : Node3D
{
    public static readonly StringName GDExtensionName = "Terrain3D";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Node3D), please use the Instantiate() method instead.")]
    protected Terrain3D() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3D"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3D Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3D>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3D"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3D"/> wrapper type,
    /// a new instance of the <see cref="Terrain3D"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3D"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3D Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3D>(godotObject);
    }
#region Enums

    public enum DebugLevelEnum : long
    {
        Error = 0,
        Info = 1,
        Debug = 2,
        Extreme = 3,
    }

    public enum RegionSizeEnum : long
    {
        Size64 = 64,
        Size128 = 128,
        Size256 = 256,
        Size512 = 512,
        Size1024 = 1024,
        Size2048 = 2048,
    }

#endregion

#region Properties

    public string Version
    {
        get => (string)Get(_cached_version);
        set => Set(_cached_version, Variant.From(value));
    }

    public DebugLevelEnum DebugLevel
    {
        get => (DebugLevelEnum)Get(_cached_debug_level).As<Int64>();
        set => Set(_cached_debug_level, Variant.From(value));
    }

    public string DataDirectory
    {
        get => (string)Get(_cached_data_directory);
        set => Set(_cached_data_directory, Variant.From(value));
    }

    public Terrain3DData Data
    {
        get => (Terrain3DData)Get(_cached_data);
        set => Set(_cached_data, Variant.From(value));
    }

    public Terrain3DMaterial Material
    {
        get => (Terrain3DMaterial)Get(_cached_material);
        set => Set(_cached_material, Variant.From(value));
    }

    public Terrain3DAssets Assets
    {
        get => (Terrain3DAssets)Get(_cached_assets);
        set => Set(_cached_assets, Variant.From(value));
    }

    public Terrain3DCollision Collision
    {
        get => (Terrain3DCollision)Get(_cached_collision);
        set => Set(_cached_collision, Variant.From(value));
    }

    public Terrain3DInstancer Instancer
    {
        get => (Terrain3DInstancer)Get(_cached_instancer);
        set => Set(_cached_instancer, Variant.From(value));
    }

    public long /*64:64,128:128,256:256,512:512,1024:1024,2048:2048*/ RegionSize
    {
        get => (long /*64:64,128:128,256:256,512:512,1024:1024,2048:2048*/)Get(_cached_region_size).As<Int64>();
        set => Set(_cached_region_size, Variant.From(value));
    }

    public bool Save16Bit
    {
        get => (bool)Get(_cached_save_16_bit);
        set => Set(_cached_save_16_bit, Variant.From(value));
    }

    public float LabelDistance
    {
        get => (float)Get(_cached_label_distance);
        set => Set(_cached_label_distance, Variant.From(value));
    }

    public int LabelSize
    {
        get => (int)Get(_cached_label_size);
        set => Set(_cached_label_size, Variant.From(value));
    }

    public bool ShowGrid
    {
        get => (bool)Get(_cached_show_grid);
        set => Set(_cached_show_grid, Variant.From(value));
    }

    public long /*Disabled,Dynamic/Game,Dynamic/Editor,Full/Game,Full/Editor*/ CollisionMode
    {
        get => (long /*Disabled,Dynamic/Game,Dynamic/Editor,Full/Game,Full/Editor*/)Get(_cached_collision_mode).As<Int64>();
        set => Set(_cached_collision_mode, Variant.From(value));
    }

    public int CollisionShapeSize
    {
        get => (int)Get(_cached_collision_shape_size);
        set => Set(_cached_collision_shape_size, Variant.From(value));
    }

    public int CollisionRadius
    {
        get => (int)Get(_cached_collision_radius);
        set => Set(_cached_collision_radius, Variant.From(value));
    }

    public int CollisionLayer
    {
        get => (int)Get(_cached_collision_layer);
        set => Set(_cached_collision_layer, Variant.From(value));
    }

    public int CollisionMask
    {
        get => (int)Get(_cached_collision_mask);
        set => Set(_cached_collision_mask, Variant.From(value));
    }

    public float CollisionPriority
    {
        get => (float)Get(_cached_collision_priority);
        set => Set(_cached_collision_priority, Variant.From(value));
    }

    public PhysicsMaterial PhysicsMaterial
    {
        get => (PhysicsMaterial)Get(_cached_physics_material);
        set => Set(_cached_physics_material, Variant.From(value));
    }

    public int MeshLods
    {
        get => (int)Get(_cached_mesh_lods);
        set => Set(_cached_mesh_lods, Variant.From(value));
    }

    public int MeshSize
    {
        get => (int)Get(_cached_mesh_size);
        set => Set(_cached_mesh_size, Variant.From(value));
    }

    public float VertexSpacing
    {
        get => (float)Get(_cached_vertex_spacing);
        set => Set(_cached_vertex_spacing, Variant.From(value));
    }

    public int RenderLayers
    {
        get => (int)Get(_cached_render_layers);
        set => Set(_cached_render_layers, Variant.From(value));
    }

    public int MouseLayer
    {
        get => (int)Get(_cached_mouse_layer);
        set => Set(_cached_mouse_layer, Variant.From(value));
    }

    public long /*Off,On,Double-Sided,ShadowsOnly*/ CastShadows
    {
        get => (long /*Off,On,Double-Sided,ShadowsOnly*/)Get(_cached_cast_shadows).As<Int64>();
        set => Set(_cached_cast_shadows, Variant.From(value));
    }

    public long /*Disabled,Static,Dynamic*/ GiMode
    {
        get => (long /*Disabled,Static,Dynamic*/)Get(_cached_gi_mode).As<Int64>();
        set => Set(_cached_gi_mode, Variant.From(value));
    }

    public float CullMargin
    {
        get => (float)Get(_cached_cull_margin);
        set => Set(_cached_cull_margin, Variant.From(value));
    }

    public bool FreeEditorTextures
    {
        get => (bool)Get(_cached_free_editor_textures);
        set => Set(_cached_free_editor_textures, Variant.From(value));
    }

    public bool ShowInstances
    {
        get => (bool)Get(_cached_show_instances);
        set => Set(_cached_show_instances, Variant.From(value));
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

#region Signals

    public delegate void MaterialChangedHandler();

    private MaterialChangedHandler _materialChanged_backing;
    private Callable _materialChanged_backing_callable;
    public event MaterialChangedHandler MaterialChanged
    {
        add
        {
            if(_materialChanged_backing == null)
            {
                _materialChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _materialChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_material_changed, _materialChanged_backing_callable);
            }
            _materialChanged_backing += value;
        }
        remove
        {
            _materialChanged_backing -= value;
            
            if(_materialChanged_backing == null)
            {
                Disconnect(_cached_material_changed, _materialChanged_backing_callable);
                _materialChanged_backing_callable = default;
            }
        }
    }

    public delegate void AssetsChangedHandler();

    private AssetsChangedHandler _assetsChanged_backing;
    private Callable _assetsChanged_backing_callable;
    public event AssetsChangedHandler AssetsChanged
    {
        add
        {
            if(_assetsChanged_backing == null)
            {
                _assetsChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _assetsChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_assets_changed, _assetsChanged_backing_callable);
            }
            _assetsChanged_backing += value;
        }
        remove
        {
            _assetsChanged_backing -= value;
            
            if(_assetsChanged_backing == null)
            {
                Disconnect(_cached_assets_changed, _assetsChanged_backing_callable);
                _assetsChanged_backing_callable = default;
            }
        }
    }

#endregion

#region Methods

    public string GetVersion() => Call(_cached_get_version).As<string>();

    public void SetDebugLevel(int level) => Call(_cached_set_debug_level, level);

    public int GetDebugLevel() => Call(_cached_get_debug_level).As<int>();

    public void SetDataDirectory(string directory) => Call(_cached_set_data_directory, directory);

    public string GetDataDirectory() => Call(_cached_get_data_directory).As<string>();

    public Terrain3DData GetData() => GDExtensionHelper.Bind<Terrain3DData>(Call(_cached_get_data).As<GodotObject>());

    public void SetMaterial(Terrain3DMaterial material) => Call(_cached_set_material, (Resource)material);

    public Terrain3DMaterial GetMaterial() => GDExtensionHelper.Bind<Terrain3DMaterial>(Call(_cached_get_material).As<GodotObject>());

    public void SetAssets(Terrain3DAssets assets) => Call(_cached_set_assets, (Resource)assets);

    public Terrain3DAssets GetAssets() => GDExtensionHelper.Bind<Terrain3DAssets>(Call(_cached_get_assets).As<GodotObject>());

    public Terrain3DCollision GetCollision() => GDExtensionHelper.Bind<Terrain3DCollision>(Call(_cached_get_collision).As<GodotObject>());

    public Terrain3DInstancer GetInstancer() => GDExtensionHelper.Bind<Terrain3DInstancer>(Call(_cached_get_instancer).As<GodotObject>());

    public void SetEditor(Terrain3DEditor editor) => Call(_cached_set_editor, (GodotObject)editor);

    public Terrain3DEditor GetEditor() => GDExtensionHelper.Bind<Terrain3DEditor>(Call(_cached_get_editor).As<GodotObject>());

    public void SetPlugin(EditorPlugin plugin) => Call(_cached_set_plugin, (EditorPlugin)plugin);

    public EditorPlugin GetPlugin() => GDExtensionHelper.Bind<EditorPlugin>(Call(_cached_get_plugin).As<GodotObject>());

    public void SetCamera(Camera3D camera) => Call(_cached_set_camera, (Camera3D)camera);

    public Camera3D GetCamera() => GDExtensionHelper.Bind<Camera3D>(Call(_cached_get_camera).As<GodotObject>());

    public void ChangeRegionSize(int size) => Call(_cached_change_region_size, size);

    public int GetRegionSize() => Call(_cached_get_region_size).As<int>();

    public void SetSave16Bit(bool enabled) => Call(_cached_set_save_16_bit, enabled);

    public bool GetSave16Bit() => Call(_cached_get_save_16_bit).As<bool>();

    public void SetLabelDistance(float distance) => Call(_cached_set_label_distance, distance);

    public float GetLabelDistance() => Call(_cached_get_label_distance).As<float>();

    public void SetLabelSize(int size) => Call(_cached_set_label_size, size);

    public int GetLabelSize() => Call(_cached_get_label_size).As<int>();

    public void SetCollisionMode(int mode) => Call(_cached_set_collision_mode, mode);

    public int GetCollisionMode() => Call(_cached_get_collision_mode).As<int>();

    public void SetCollisionShapeSize(int size) => Call(_cached_set_collision_shape_size, size);

    public int GetCollisionShapeSize() => Call(_cached_get_collision_shape_size).As<int>();

    public void SetCollisionRadius(int radius) => Call(_cached_set_collision_radius, radius);

    public int GetCollisionRadius() => Call(_cached_get_collision_radius).As<int>();

    public void SetCollisionLayer(int layers) => Call(_cached_set_collision_layer, layers);

    public int GetCollisionLayer() => Call(_cached_get_collision_layer).As<int>();

    public void SetCollisionMask(int mask) => Call(_cached_set_collision_mask, mask);

    public int GetCollisionMask() => Call(_cached_get_collision_mask).As<int>();

    public void SetCollisionPriority(float priority) => Call(_cached_set_collision_priority, priority);

    public float GetCollisionPriority() => Call(_cached_get_collision_priority).As<float>();

    public void SetPhysicsMaterial(PhysicsMaterial material) => Call(_cached_set_physics_material, (PhysicsMaterial)material);

    public PhysicsMaterial GetPhysicsMaterial() => GDExtensionHelper.Bind<PhysicsMaterial>(Call(_cached_get_physics_material).As<GodotObject>());

    public void SetMeshLods(int count) => Call(_cached_set_mesh_lods, count);

    public int GetMeshLods() => Call(_cached_get_mesh_lods).As<int>();

    public void SetMeshSize(int size) => Call(_cached_set_mesh_size, size);

    public int GetMeshSize() => Call(_cached_get_mesh_size).As<int>();

    public void SetVertexSpacing(float scale) => Call(_cached_set_vertex_spacing, scale);

    public float GetVertexSpacing() => Call(_cached_get_vertex_spacing).As<float>();

    public Vector3 GetSnappedPosition() => Call(_cached_get_snapped_position).As<Vector3>();

    public void SetRenderLayers(int layers) => Call(_cached_set_render_layers, layers);

    public int GetRenderLayers() => Call(_cached_get_render_layers).As<int>();

    public void SetMouseLayer(int layer) => Call(_cached_set_mouse_layer, layer);

    public int GetMouseLayer() => Call(_cached_get_mouse_layer).As<int>();

    public void SetCastShadows(int shadowCastingSetting) => Call(_cached_set_cast_shadows, shadowCastingSetting);

    public int GetCastShadows() => Call(_cached_get_cast_shadows).As<int>();

    public void SetGiMode(int giMode) => Call(_cached_set_gi_mode, giMode);

    public int GetGiMode() => Call(_cached_get_gi_mode).As<int>();

    public void SetCullMargin(float margin) => Call(_cached_set_cull_margin, margin);

    public float GetCullMargin() => Call(_cached_get_cull_margin).As<float>();

    public void SetFreeEditorTextures(bool unnamedArg0) => Call(_cached_set_free_editor_textures, unnamedArg0);

    public bool GetFreeEditorTextures() => Call(_cached_get_free_editor_textures).As<bool>();

    public void SetShowInstances(bool visible) => Call(_cached_set_show_instances, visible);

    public bool GetShowInstances() => Call(_cached_get_show_instances).As<bool>();

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

    public Vector3 GetIntersection(Vector3 srcPos, Vector3 direction, bool gpuMode) => Call(_cached_get_intersection, srcPos, direction, gpuMode).As<Vector3>();

    public Mesh BakeMesh(int lod, int filter) => GDExtensionHelper.Bind<Mesh>(Call(_cached_bake_mesh, lod, filter).As<GodotObject>());

    public Vector3[] GenerateNavMeshSourceGeometry(Aabb globalAabb, bool requireNav) => Call(_cached_generate_nav_mesh_source_geometry, globalAabb, requireNav).As<Vector3[]>();

#endregion

    private static readonly StringName _cached_version = "version";
    private static readonly StringName _cached_debug_level = "debug_level";
    private static readonly StringName _cached_data_directory = "data_directory";
    private static readonly StringName _cached_data = "data";
    private static readonly StringName _cached_material = "material";
    private static readonly StringName _cached_assets = "assets";
    private static readonly StringName _cached_collision = "collision";
    private static readonly StringName _cached_instancer = "instancer";
    private static readonly StringName _cached_region_size = "region_size";
    private static readonly StringName _cached_save_16_bit = "save_16_bit";
    private static readonly StringName _cached_label_distance = "label_distance";
    private static readonly StringName _cached_label_size = "label_size";
    private static readonly StringName _cached_show_grid = "show_grid";
    private static readonly StringName _cached_collision_mode = "collision_mode";
    private static readonly StringName _cached_collision_shape_size = "collision_shape_size";
    private static readonly StringName _cached_collision_radius = "collision_radius";
    private static readonly StringName _cached_collision_layer = "collision_layer";
    private static readonly StringName _cached_collision_mask = "collision_mask";
    private static readonly StringName _cached_collision_priority = "collision_priority";
    private static readonly StringName _cached_physics_material = "physics_material";
    private static readonly StringName _cached_mesh_lods = "mesh_lods";
    private static readonly StringName _cached_mesh_size = "mesh_size";
    private static readonly StringName _cached_vertex_spacing = "vertex_spacing";
    private static readonly StringName _cached_render_layers = "render_layers";
    private static readonly StringName _cached_mouse_layer = "mouse_layer";
    private static readonly StringName _cached_cast_shadows = "cast_shadows";
    private static readonly StringName _cached_gi_mode = "gi_mode";
    private static readonly StringName _cached_cull_margin = "cull_margin";
    private static readonly StringName _cached_free_editor_textures = "free_editor_textures";
    private static readonly StringName _cached_show_instances = "show_instances";
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
    private static readonly StringName _cached_get_version = "get_version";
    private static readonly StringName _cached_set_debug_level = "set_debug_level";
    private static readonly StringName _cached_get_debug_level = "get_debug_level";
    private static readonly StringName _cached_set_data_directory = "set_data_directory";
    private static readonly StringName _cached_get_data_directory = "get_data_directory";
    private static readonly StringName _cached_get_data = "get_data";
    private static readonly StringName _cached_set_material = "set_material";
    private static readonly StringName _cached_get_material = "get_material";
    private static readonly StringName _cached_set_assets = "set_assets";
    private static readonly StringName _cached_get_assets = "get_assets";
    private static readonly StringName _cached_get_collision = "get_collision";
    private static readonly StringName _cached_get_instancer = "get_instancer";
    private static readonly StringName _cached_set_editor = "set_editor";
    private static readonly StringName _cached_get_editor = "get_editor";
    private static readonly StringName _cached_set_plugin = "set_plugin";
    private static readonly StringName _cached_get_plugin = "get_plugin";
    private static readonly StringName _cached_set_camera = "set_camera";
    private static readonly StringName _cached_get_camera = "get_camera";
    private static readonly StringName _cached_change_region_size = "change_region_size";
    private static readonly StringName _cached_get_region_size = "get_region_size";
    private static readonly StringName _cached_set_save_16_bit = "set_save_16_bit";
    private static readonly StringName _cached_get_save_16_bit = "get_save_16_bit";
    private static readonly StringName _cached_set_label_distance = "set_label_distance";
    private static readonly StringName _cached_get_label_distance = "get_label_distance";
    private static readonly StringName _cached_set_label_size = "set_label_size";
    private static readonly StringName _cached_get_label_size = "get_label_size";
    private static readonly StringName _cached_set_collision_mode = "set_collision_mode";
    private static readonly StringName _cached_get_collision_mode = "get_collision_mode";
    private static readonly StringName _cached_set_collision_shape_size = "set_collision_shape_size";
    private static readonly StringName _cached_get_collision_shape_size = "get_collision_shape_size";
    private static readonly StringName _cached_set_collision_radius = "set_collision_radius";
    private static readonly StringName _cached_get_collision_radius = "get_collision_radius";
    private static readonly StringName _cached_set_collision_layer = "set_collision_layer";
    private static readonly StringName _cached_get_collision_layer = "get_collision_layer";
    private static readonly StringName _cached_set_collision_mask = "set_collision_mask";
    private static readonly StringName _cached_get_collision_mask = "get_collision_mask";
    private static readonly StringName _cached_set_collision_priority = "set_collision_priority";
    private static readonly StringName _cached_get_collision_priority = "get_collision_priority";
    private static readonly StringName _cached_set_physics_material = "set_physics_material";
    private static readonly StringName _cached_get_physics_material = "get_physics_material";
    private static readonly StringName _cached_set_mesh_lods = "set_mesh_lods";
    private static readonly StringName _cached_get_mesh_lods = "get_mesh_lods";
    private static readonly StringName _cached_set_mesh_size = "set_mesh_size";
    private static readonly StringName _cached_get_mesh_size = "get_mesh_size";
    private static readonly StringName _cached_set_vertex_spacing = "set_vertex_spacing";
    private static readonly StringName _cached_get_vertex_spacing = "get_vertex_spacing";
    private static readonly StringName _cached_get_snapped_position = "get_snapped_position";
    private static readonly StringName _cached_set_render_layers = "set_render_layers";
    private static readonly StringName _cached_get_render_layers = "get_render_layers";
    private static readonly StringName _cached_set_mouse_layer = "set_mouse_layer";
    private static readonly StringName _cached_get_mouse_layer = "get_mouse_layer";
    private static readonly StringName _cached_set_cast_shadows = "set_cast_shadows";
    private static readonly StringName _cached_get_cast_shadows = "get_cast_shadows";
    private static readonly StringName _cached_set_gi_mode = "set_gi_mode";
    private static readonly StringName _cached_get_gi_mode = "get_gi_mode";
    private static readonly StringName _cached_set_cull_margin = "set_cull_margin";
    private static readonly StringName _cached_get_cull_margin = "get_cull_margin";
    private static readonly StringName _cached_set_free_editor_textures = "set_free_editor_textures";
    private static readonly StringName _cached_get_free_editor_textures = "get_free_editor_textures";
    private static readonly StringName _cached_set_show_instances = "set_show_instances";
    private static readonly StringName _cached_get_show_instances = "get_show_instances";
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
    private static readonly StringName _cached_get_intersection = "get_intersection";
    private static readonly StringName _cached_bake_mesh = "bake_mesh";
    private static readonly StringName _cached_generate_nav_mesh_source_geometry = "generate_nav_mesh_source_geometry";
    private static readonly StringName _cached_material_changed = "material_changed";
    private static readonly StringName _cached_assets_changed = "assets_changed";
}