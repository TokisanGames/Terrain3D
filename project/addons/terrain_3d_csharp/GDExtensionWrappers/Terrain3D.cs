using System;
using Godot;

namespace GDExtension.Wrappers;

public partial class Terrain3D : Node3D
{
    public static readonly StringName GDExtensionName = "Terrain3D";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Node3D), please use the Instantiate() method instead.")]
    protected Terrain3D()
    {
    }

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

    #region Properties

    public string Version
    {
        get => (string)Get("version");
        set => Set("version", Variant.From(value));
    }

    protected Terrain3DStorage? terrain3DStorage;

    public Terrain3DStorage Storage
    {
        get => terrain3DStorage ??= Terrain3DStorage.Bind(Get("storage").AsGodotObject());
        set => Set("storage", Variant.From(terrain3DStorage = value));
    }

    public Terrain3DMaterial Material
    {
        get => Terrain3DMaterial.Bind(Get("material").AsGodotObject());
        set => Set("material", Variant.From(value));
    }

    public Terrain3DAssets Assets
    {
        get => Terrain3DAssets.Bind(Get("assets").AsGodotObject());
        set => Set("assets", Variant.From(value));
    }

    public Terrain3DInstancer? Instancer => Terrain3DInstancer.Bind(Call("get_instancer").AsGodotObject());

    public int RenderLayers
    {
        get => (int)Get("render_layers");
        set => Set("render_layers", Variant.From(value));
    }

    public int RenderMouseLayer
    {
        get => (int)Get("render_mouse_layer");
        set => Set("render_mouse_layer", Variant.From(value));
    }

    public long /*Off,On,Double-Sided,ShadowsOnly*/ RenderCastShadows
    {
        get => (long /*Off,On,Double-Sided,ShadowsOnly*/)Get("render_cast_shadows").As<Int64>();
        set => Set("render_cast_shadows", Variant.From(value));
    }

    public float RenderCullMargin
    {
        get => (float)Get("render_cull_margin");
        set => Set("render_cull_margin", Variant.From(value));
    }

    public bool CollisionEnabled
    {
        get => (bool)Get("collision_enabled");
        set => Set("collision_enabled", Variant.From(value));
    }

    public int CollisionLayer
    {
        get => (int)Get("collision_layer");
        set => Set("collision_layer", Variant.From(value));
    }

    public int CollisionMask
    {
        get => (int)Get("collision_mask");
        set => Set("collision_mask", Variant.From(value));
    }

    public float CollisionPriority
    {
        get => (float)Get("collision_priority");
        set => Set("collision_priority", Variant.From(value));
    }

    public int MeshLods
    {
        get => (int)Get("mesh_lods");
        set => Set("mesh_lods", Variant.From(value));
    }

    public int MeshSize
    {
        get => (int)Get("mesh_size");
        set => Set("mesh_size", Variant.From(value));
    }

    public float MeshVertexSpacing
    {
        get => (float)Get("mesh_vertex_spacing");
        set => Set("mesh_vertex_spacing", Variant.From(value));
    }

    public long DebugLevel
    {
        get => (long)Get("debug_level").As<Int64>();
        set => Set("debug_level", Variant.From(value));
    }

    public bool DebugShowCollision
    {
        get => (bool)Get("debug_show_collision");
        set => Set("debug_show_collision", Variant.From(value));
    }

    public Terrain3DTextureList TextureList
    {
        get => (Terrain3DTextureList)Get("texture_list");
        set => Set("texture_list", Variant.From(value));
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
            if (_materialChanged_backing == null)
            {
                _materialChanged_backing_callable = Callable.From(
                    () => { _materialChanged_backing?.Invoke(); }
                );
                Connect("material_changed", _materialChanged_backing_callable);
            }

            _materialChanged_backing += value;
        }
        remove
        {
            _materialChanged_backing -= value;

            if (_materialChanged_backing == null)
            {
                Disconnect("material_changed", _materialChanged_backing_callable);
                _materialChanged_backing_callable = default;
            }
        }
    }

    public delegate void StorageChangedHandler();

    private StorageChangedHandler _storageChanged_backing;
    private Callable _storageChanged_backing_callable;

    public event StorageChangedHandler StorageChanged
    {
        add
        {
            if (_storageChanged_backing == null)
            {
                _storageChanged_backing_callable = Callable.From(
                    () => { _storageChanged_backing?.Invoke(); }
                );
                Connect("storage_changed", _storageChanged_backing_callable);
            }

            _storageChanged_backing += value;
        }
        remove
        {
            _storageChanged_backing -= value;

            if (_storageChanged_backing == null)
            {
                Disconnect("storage_changed", _storageChanged_backing_callable);
                _storageChanged_backing_callable = default;
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
            if (_assetsChanged_backing == null)
            {
                _assetsChanged_backing_callable = Callable.From(
                    () => { _assetsChanged_backing?.Invoke(); }
                );
                Connect("assets_changed", _assetsChanged_backing_callable);
            }

            _assetsChanged_backing += value;
        }
        remove
        {
            _assetsChanged_backing -= value;

            if (_assetsChanged_backing == null)
            {
                Disconnect("assets_changed", _assetsChanged_backing_callable);
                _assetsChanged_backing_callable = default;
            }
        }
    }

    #endregion

    #region Methods

    public void SetPlugin(EditorPlugin plugin) => Call("set_plugin", plugin);

    public EditorPlugin GetPlugin() => Call("get_plugin").As<EditorPlugin>();

    public void SetCamera(Camera3D camera) => Call("set_camera", camera);

    public Camera3D GetCamera() => Call("get_camera").As<Camera3D>();

    public void SetMouseLayer(int layer) => Call("set_mouse_layer", layer);

    public int GetMouseLayer() => Call("get_mouse_layer").As<int>();

    public void SetCastShadows(int shadowCastingSetting) => Call("set_cast_shadows", shadowCastingSetting);

    public int GetCastShadows() => Call("get_cast_shadows").As<int>();

    public void SetCullMargin(float margin) => Call("set_cull_margin", margin);

    public float GetCullMargin() => Call("get_cull_margin").As<float>();

    public void SetShowDebugCollision(bool enabled) => Call("set_show_debug_collision", enabled);

    public bool GetShowDebugCollision() => Call("get_show_debug_collision").As<bool>();

    public Vector3 GetIntersection(Vector3 srcPos, Vector3 direction) => Call("get_intersection", srcPos, direction).As<Vector3>();

    public Mesh BakeMesh(int lod, int filter) => Call("bake_mesh", lod, filter).As<Mesh>();

    public Vector3[] GenerateNavMeshSourceGeometry(Aabb globalAabb, bool requireNav) => Call("generate_nav_mesh_source_geometry", globalAabb, requireNav).As<Vector3[]>();

    #endregion
}