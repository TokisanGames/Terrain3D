using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DMeshAsset : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DMeshAsset";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DMeshAsset() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DMeshAsset"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DMeshAsset Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DMeshAsset>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DMeshAsset"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DMeshAsset"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DMeshAsset"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DMeshAsset"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DMeshAsset Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DMeshAsset>(godotObject);
    }
#region Enums

    public enum GenType : long
    {
        TypeNone = 0,
        TypeTextureCard = 1,
        TypeMax = 2,
    }

#endregion

#region Properties

    public string Name
    {
        get => (string)Get(_cached_name);
        set => Set(_cached_name, Variant.From(value));
    }

    public int Id
    {
        get => (int)Get(_cached_id);
        set => Set(_cached_id, Variant.From(value));
    }

    public bool Enabled
    {
        get => (bool)Get(_cached_enabled);
        set => Set(_cached_enabled, Variant.From(value));
    }

    public PackedScene SceneFile
    {
        get => (PackedScene)Get(_cached_scene_file);
        set => Set(_cached_scene_file, Variant.From(value));
    }

    public long /*None,TextureCard*/ GeneratedType
    {
        get => (long /*None,TextureCard*/)Get(_cached_generated_type).As<Int64>();
        set => Set(_cached_generated_type, Variant.From(value));
    }

    public float HeightOffset
    {
        get => (float)Get(_cached_height_offset);
        set => Set(_cached_height_offset, Variant.From(value));
    }

    public float Density
    {
        get => (float)Get(_cached_density);
        set => Set(_cached_density, Variant.From(value));
    }

    public long /*Off,On,Double-Sided,ShadowsOnly*/ CastShadows
    {
        get => (long /*Off,On,Double-Sided,ShadowsOnly*/)Get(_cached_cast_shadows).As<Int64>();
        set => Set(_cached_cast_shadows, Variant.From(value));
    }

    public Material /*BaseMaterial3D,ShaderMaterial*/ MaterialOverride
    {
        get => (Material /*BaseMaterial3D,ShaderMaterial*/)Get(_cached_material_override);
        set => Set(_cached_material_override, Variant.From(value));
    }

    public Material /*BaseMaterial3D,ShaderMaterial*/ MaterialOverlay
    {
        get => (Material /*BaseMaterial3D,ShaderMaterial*/)Get(_cached_material_overlay);
        set => Set(_cached_material_overlay, Variant.From(value));
    }

    public int GeneratedFaces
    {
        get => (int)Get(_cached_generated_faces);
        set => Set(_cached_generated_faces, Variant.From(value));
    }

    public Vector2 GeneratedSize
    {
        get => (Vector2)Get(_cached_generated_size);
        set => Set(_cached_generated_size, Variant.From(value));
    }

    public int LodCount
    {
        get => (int)Get(_cached_lod_count);
        set => Set(_cached_lod_count, Variant.From(value));
    }

    public int LastLod
    {
        get => (int)Get(_cached_last_lod);
        set => Set(_cached_last_lod, Variant.From(value));
    }

    public int LastShadowLod
    {
        get => (int)Get(_cached_last_shadow_lod);
        set => Set(_cached_last_shadow_lod, Variant.From(value));
    }

    public int ShadowImpostor
    {
        get => (int)Get(_cached_shadow_impostor);
        set => Set(_cached_shadow_impostor, Variant.From(value));
    }

    public float Lod0Range
    {
        get => (float)Get(_cached_lod0_range);
        set => Set(_cached_lod0_range, Variant.From(value));
    }

    public float Lod1Range
    {
        get => (float)Get(_cached_lod1_range);
        set => Set(_cached_lod1_range, Variant.From(value));
    }

    public float Lod2Range
    {
        get => (float)Get(_cached_lod2_range);
        set => Set(_cached_lod2_range, Variant.From(value));
    }

    public float Lod3Range
    {
        get => (float)Get(_cached_lod3_range);
        set => Set(_cached_lod3_range, Variant.From(value));
    }

    public float Lod4Range
    {
        get => (float)Get(_cached_lod4_range);
        set => Set(_cached_lod4_range, Variant.From(value));
    }

    public float Lod5Range
    {
        get => (float)Get(_cached_lod5_range);
        set => Set(_cached_lod5_range, Variant.From(value));
    }

    public float Lod6Range
    {
        get => (float)Get(_cached_lod6_range);
        set => Set(_cached_lod6_range, Variant.From(value));
    }

    public float Lod7Range
    {
        get => (float)Get(_cached_lod7_range);
        set => Set(_cached_lod7_range, Variant.From(value));
    }

    public float Lod8Range
    {
        get => (float)Get(_cached_lod8_range);
        set => Set(_cached_lod8_range, Variant.From(value));
    }

    public float Lod9Range
    {
        get => (float)Get(_cached_lod9_range);
        set => Set(_cached_lod9_range, Variant.From(value));
    }

    public float FadeMargin
    {
        get => (float)Get(_cached_fade_margin);
        set => Set(_cached_fade_margin, Variant.From(value));
    }

#endregion

#region Signals

    public delegate void IdChangedHandler();

    private IdChangedHandler _idChanged_backing;
    private Callable _idChanged_backing_callable;
    public event IdChangedHandler IdChanged
    {
        add
        {
            if(_idChanged_backing == null)
            {
                _idChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _idChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_id_changed, _idChanged_backing_callable);
            }
            _idChanged_backing += value;
        }
        remove
        {
            _idChanged_backing -= value;
            
            if(_idChanged_backing == null)
            {
                Disconnect(_cached_id_changed, _idChanged_backing_callable);
                _idChanged_backing_callable = default;
            }
        }
    }

    public delegate void FileChangedHandler();

    private FileChangedHandler _fileChanged_backing;
    private Callable _fileChanged_backing_callable;
    public event FileChangedHandler FileChanged
    {
        add
        {
            if(_fileChanged_backing == null)
            {
                _fileChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _fileChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_file_changed, _fileChanged_backing_callable);
            }
            _fileChanged_backing += value;
        }
        remove
        {
            _fileChanged_backing -= value;
            
            if(_fileChanged_backing == null)
            {
                Disconnect(_cached_file_changed, _fileChanged_backing_callable);
                _fileChanged_backing_callable = default;
            }
        }
    }

    public delegate void SettingChangedHandler();

    private SettingChangedHandler _settingChanged_backing;
    private Callable _settingChanged_backing_callable;
    public event SettingChangedHandler SettingChanged
    {
        add
        {
            if(_settingChanged_backing == null)
            {
                _settingChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _settingChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_setting_changed, _settingChanged_backing_callable);
            }
            _settingChanged_backing += value;
        }
        remove
        {
            _settingChanged_backing -= value;
            
            if(_settingChanged_backing == null)
            {
                Disconnect(_cached_setting_changed, _settingChanged_backing_callable);
                _settingChanged_backing_callable = default;
            }
        }
    }

    public delegate void InstancerSettingChangedHandler();

    private InstancerSettingChangedHandler _instancerSettingChanged_backing;
    private Callable _instancerSettingChanged_backing_callable;
    public event InstancerSettingChangedHandler InstancerSettingChanged
    {
        add
        {
            if(_instancerSettingChanged_backing == null)
            {
                _instancerSettingChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _instancerSettingChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_instancer_setting_changed, _instancerSettingChanged_backing_callable);
            }
            _instancerSettingChanged_backing += value;
        }
        remove
        {
            _instancerSettingChanged_backing -= value;
            
            if(_instancerSettingChanged_backing == null)
            {
                Disconnect(_cached_instancer_setting_changed, _instancerSettingChanged_backing_callable);
                _instancerSettingChanged_backing_callable = default;
            }
        }
    }

#endregion

#region Methods

    public void Clear() => Call(_cached_clear);

    public void SetName(string name) => Call(_cached_set_name, name);

    public string GetName() => Call(_cached_get_name).As<string>();

    public void SetId(int id) => Call(_cached_set_id, id);

    public int GetId() => Call(_cached_get_id).As<int>();

    public void SetEnabled(bool enabled) => Call(_cached_set_enabled, enabled);

    public bool IsEnabled() => Call(_cached_is_enabled).As<bool>();

    public void SetSceneFile(PackedScene sceneFile) => Call(_cached_set_scene_file, (PackedScene)sceneFile);

    public PackedScene GetSceneFile() => GDExtensionHelper.Bind<PackedScene>(Call(_cached_get_scene_file).As<GodotObject>());

    public void SetGeneratedType(int type) => Call(_cached_set_generated_type, type);

    public int GetGeneratedType() => Call(_cached_get_generated_type).As<int>();

    public Mesh GetMesh(int lod) => GDExtensionHelper.Bind<Mesh>(Call(_cached_get_mesh, lod).As<GodotObject>());

    public Texture2D GetThumbnail() => GDExtensionHelper.Bind<Texture2D>(Call(_cached_get_thumbnail).As<GodotObject>());

    public void SetHeightOffset(float offset) => Call(_cached_set_height_offset, offset);

    public float GetHeightOffset() => Call(_cached_get_height_offset).As<float>();

    public void SetDensity(float density) => Call(_cached_set_density, density);

    public float GetDensity() => Call(_cached_get_density).As<float>();

    public void SetCastShadows(int mode) => Call(_cached_set_cast_shadows, mode);

    public int GetCastShadows() => Call(_cached_get_cast_shadows).As<int>();

    public void SetMaterialOverride(Material material) => Call(_cached_set_material_override, (Material)material);

    public Material GetMaterialOverride() => GDExtensionHelper.Bind<Material>(Call(_cached_get_material_override).As<GodotObject>());

    public void SetMaterialOverlay(Material material) => Call(_cached_set_material_overlay, (Material)material);

    public Material GetMaterialOverlay() => GDExtensionHelper.Bind<Material>(Call(_cached_get_material_overlay).As<GodotObject>());

    public void SetGeneratedFaces(int count) => Call(_cached_set_generated_faces, count);

    public int GetGeneratedFaces() => Call(_cached_get_generated_faces).As<int>();

    public void SetGeneratedSize(Vector2 size) => Call(_cached_set_generated_size, size);

    public Vector2 GetGeneratedSize() => Call(_cached_get_generated_size).As<Vector2>();

    public int GetLodCount() => Call(_cached_get_lod_count).As<int>();

    public void SetLastLod(int lod) => Call(_cached_set_last_lod, lod);

    public int GetLastLod() => Call(_cached_get_last_lod).As<int>();

    public void SetLastShadowLod(int lod) => Call(_cached_set_last_shadow_lod, lod);

    public int GetLastShadowLod() => Call(_cached_get_last_shadow_lod).As<int>();

    public void SetShadowImpostor(int lod) => Call(_cached_set_shadow_impostor, lod);

    public int GetShadowImpostor() => Call(_cached_get_shadow_impostor).As<int>();

    public void SetLodRange(int lod, float distance) => Call(_cached_set_lod_range, lod, distance);

    public float GetLodRange(int lod) => Call(_cached_get_lod_range, lod).As<float>();

    public void SetLod0Range(float distance) => Call(_cached_set_lod0_range, distance);

    public float GetLod0Range() => Call(_cached_get_lod0_range).As<float>();

    public void SetLod1Range(float distance) => Call(_cached_set_lod1_range, distance);

    public float GetLod1Range() => Call(_cached_get_lod1_range).As<float>();

    public void SetLod2Range(float distance) => Call(_cached_set_lod2_range, distance);

    public float GetLod2Range() => Call(_cached_get_lod2_range).As<float>();

    public void SetLod3Range(float distance) => Call(_cached_set_lod3_range, distance);

    public float GetLod3Range() => Call(_cached_get_lod3_range).As<float>();

    public void SetLod4Range(float distance) => Call(_cached_set_lod4_range, distance);

    public float GetLod4Range() => Call(_cached_get_lod4_range).As<float>();

    public void SetLod5Range(float distance) => Call(_cached_set_lod5_range, distance);

    public float GetLod5Range() => Call(_cached_get_lod5_range).As<float>();

    public void SetLod6Range(float distance) => Call(_cached_set_lod6_range, distance);

    public float GetLod6Range() => Call(_cached_get_lod6_range).As<float>();

    public void SetLod7Range(float distance) => Call(_cached_set_lod7_range, distance);

    public float GetLod7Range() => Call(_cached_get_lod7_range).As<float>();

    public void SetLod8Range(float distance) => Call(_cached_set_lod8_range, distance);

    public float GetLod8Range() => Call(_cached_get_lod8_range).As<float>();

    public void SetLod9Range(float distance) => Call(_cached_set_lod9_range, distance);

    public float GetLod9Range() => Call(_cached_get_lod9_range).As<float>();

    public void SetFadeMargin(float distance) => Call(_cached_set_fade_margin, distance);

    public float GetFadeMargin() => Call(_cached_get_fade_margin).As<float>();

#endregion

    private static readonly StringName _cached_name = "name";
    private static readonly StringName _cached_id = "id";
    private static readonly StringName _cached_enabled = "enabled";
    private static readonly StringName _cached_scene_file = "scene_file";
    private static readonly StringName _cached_generated_type = "generated_type";
    private static readonly StringName _cached_height_offset = "height_offset";
    private static readonly StringName _cached_density = "density";
    private static readonly StringName _cached_cast_shadows = "cast_shadows";
    private static readonly StringName _cached_material_override = "material_override";
    private static readonly StringName _cached_material_overlay = "material_overlay";
    private static readonly StringName _cached_generated_faces = "generated_faces";
    private static readonly StringName _cached_generated_size = "generated_size";
    private static readonly StringName _cached_lod_count = "lod_count";
    private static readonly StringName _cached_last_lod = "last_lod";
    private static readonly StringName _cached_last_shadow_lod = "last_shadow_lod";
    private static readonly StringName _cached_shadow_impostor = "shadow_impostor";
    private static readonly StringName _cached_lod0_range = "lod0_range";
    private static readonly StringName _cached_lod1_range = "lod1_range";
    private static readonly StringName _cached_lod2_range = "lod2_range";
    private static readonly StringName _cached_lod3_range = "lod3_range";
    private static readonly StringName _cached_lod4_range = "lod4_range";
    private static readonly StringName _cached_lod5_range = "lod5_range";
    private static readonly StringName _cached_lod6_range = "lod6_range";
    private static readonly StringName _cached_lod7_range = "lod7_range";
    private static readonly StringName _cached_lod8_range = "lod8_range";
    private static readonly StringName _cached_lod9_range = "lod9_range";
    private static readonly StringName _cached_fade_margin = "fade_margin";
    private static readonly StringName _cached_clear = "clear";
    private static readonly StringName _cached_set_name = "set_name";
    private static readonly StringName _cached_get_name = "get_name";
    private static readonly StringName _cached_set_id = "set_id";
    private static readonly StringName _cached_get_id = "get_id";
    private static readonly StringName _cached_set_enabled = "set_enabled";
    private static readonly StringName _cached_is_enabled = "is_enabled";
    private static readonly StringName _cached_set_scene_file = "set_scene_file";
    private static readonly StringName _cached_get_scene_file = "get_scene_file";
    private static readonly StringName _cached_set_generated_type = "set_generated_type";
    private static readonly StringName _cached_get_generated_type = "get_generated_type";
    private static readonly StringName _cached_get_mesh = "get_mesh";
    private static readonly StringName _cached_get_thumbnail = "get_thumbnail";
    private static readonly StringName _cached_set_height_offset = "set_height_offset";
    private static readonly StringName _cached_get_height_offset = "get_height_offset";
    private static readonly StringName _cached_set_density = "set_density";
    private static readonly StringName _cached_get_density = "get_density";
    private static readonly StringName _cached_set_cast_shadows = "set_cast_shadows";
    private static readonly StringName _cached_get_cast_shadows = "get_cast_shadows";
    private static readonly StringName _cached_set_material_override = "set_material_override";
    private static readonly StringName _cached_get_material_override = "get_material_override";
    private static readonly StringName _cached_set_material_overlay = "set_material_overlay";
    private static readonly StringName _cached_get_material_overlay = "get_material_overlay";
    private static readonly StringName _cached_set_generated_faces = "set_generated_faces";
    private static readonly StringName _cached_get_generated_faces = "get_generated_faces";
    private static readonly StringName _cached_set_generated_size = "set_generated_size";
    private static readonly StringName _cached_get_generated_size = "get_generated_size";
    private static readonly StringName _cached_get_lod_count = "get_lod_count";
    private static readonly StringName _cached_set_last_lod = "set_last_lod";
    private static readonly StringName _cached_get_last_lod = "get_last_lod";
    private static readonly StringName _cached_set_last_shadow_lod = "set_last_shadow_lod";
    private static readonly StringName _cached_get_last_shadow_lod = "get_last_shadow_lod";
    private static readonly StringName _cached_set_shadow_impostor = "set_shadow_impostor";
    private static readonly StringName _cached_get_shadow_impostor = "get_shadow_impostor";
    private static readonly StringName _cached_set_lod_range = "set_lod_range";
    private static readonly StringName _cached_get_lod_range = "get_lod_range";
    private static readonly StringName _cached_set_lod0_range = "set_lod0_range";
    private static readonly StringName _cached_get_lod0_range = "get_lod0_range";
    private static readonly StringName _cached_set_lod1_range = "set_lod1_range";
    private static readonly StringName _cached_get_lod1_range = "get_lod1_range";
    private static readonly StringName _cached_set_lod2_range = "set_lod2_range";
    private static readonly StringName _cached_get_lod2_range = "get_lod2_range";
    private static readonly StringName _cached_set_lod3_range = "set_lod3_range";
    private static readonly StringName _cached_get_lod3_range = "get_lod3_range";
    private static readonly StringName _cached_set_lod4_range = "set_lod4_range";
    private static readonly StringName _cached_get_lod4_range = "get_lod4_range";
    private static readonly StringName _cached_set_lod5_range = "set_lod5_range";
    private static readonly StringName _cached_get_lod5_range = "get_lod5_range";
    private static readonly StringName _cached_set_lod6_range = "set_lod6_range";
    private static readonly StringName _cached_get_lod6_range = "get_lod6_range";
    private static readonly StringName _cached_set_lod7_range = "set_lod7_range";
    private static readonly StringName _cached_get_lod7_range = "get_lod7_range";
    private static readonly StringName _cached_set_lod8_range = "set_lod8_range";
    private static readonly StringName _cached_get_lod8_range = "get_lod8_range";
    private static readonly StringName _cached_set_lod9_range = "set_lod9_range";
    private static readonly StringName _cached_get_lod9_range = "get_lod9_range";
    private static readonly StringName _cached_set_fade_margin = "set_fade_margin";
    private static readonly StringName _cached_get_fade_margin = "get_fade_margin";
    private static readonly StringName _cached_id_changed = "id_changed";
    private static readonly StringName _cached_file_changed = "file_changed";
    private static readonly StringName _cached_setting_changed = "setting_changed";
    private static readonly StringName _cached_instancer_setting_changed = "instancer_setting_changed";
}