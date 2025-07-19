using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DTextureAsset : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DTextureAsset";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DTextureAsset() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DTextureAsset"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DTextureAsset Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DTextureAsset>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DTextureAsset"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DTextureAsset"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DTextureAsset"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DTextureAsset"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DTextureAsset Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DTextureAsset>(godotObject);
    }
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

    public Color AlbedoColor
    {
        get => (Color)Get(_cached_albedo_color);
        set => Set(_cached_albedo_color, Variant.From(value));
    }

    public Texture2D /*ImageTexture,CompressedTexture2D*/ AlbedoTexture
    {
        get => (Texture2D /*ImageTexture,CompressedTexture2D*/)Get(_cached_albedo_texture);
        set => Set(_cached_albedo_texture, Variant.From(value));
    }

    public Texture2D /*ImageTexture,CompressedTexture2D*/ NormalTexture
    {
        get => (Texture2D /*ImageTexture,CompressedTexture2D*/)Get(_cached_normal_texture);
        set => Set(_cached_normal_texture, Variant.From(value));
    }

    public float NormalDepth
    {
        get => (float)Get(_cached_normal_depth);
        set => Set(_cached_normal_depth, Variant.From(value));
    }

    public float AoStrength
    {
        get => (float)Get(_cached_ao_strength);
        set => Set(_cached_ao_strength, Variant.From(value));
    }

    public float Roughness
    {
        get => (float)Get(_cached_roughness);
        set => Set(_cached_roughness, Variant.From(value));
    }

    public float UvScale
    {
        get => (float)Get(_cached_uv_scale);
        set => Set(_cached_uv_scale, Variant.From(value));
    }

    public float DetilingRotation
    {
        get => (float)Get(_cached_detiling_rotation);
        set => Set(_cached_detiling_rotation, Variant.From(value));
    }

    public float DetilingShift
    {
        get => (float)Get(_cached_detiling_shift);
        set => Set(_cached_detiling_shift, Variant.From(value));
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

#endregion

#region Methods

    public void Clear() => Call(_cached_clear);

    public void SetName(string name) => Call(_cached_set_name, name);

    public string GetName() => Call(_cached_get_name).As<string>();

    public void SetId(int id) => Call(_cached_set_id, id);

    public int GetId() => Call(_cached_get_id).As<int>();

    public void SetAlbedoColor(Color color) => Call(_cached_set_albedo_color, color);

    public Color GetAlbedoColor() => Call(_cached_get_albedo_color).As<Color>();

    public void SetAlbedoTexture(Texture2D texture) => Call(_cached_set_albedo_texture, (Texture2D)texture);

    public Texture2D GetAlbedoTexture() => GDExtensionHelper.Bind<Texture2D>(Call(_cached_get_albedo_texture).As<GodotObject>());

    public void SetNormalTexture(Texture2D texture) => Call(_cached_set_normal_texture, (Texture2D)texture);

    public Texture2D GetNormalTexture() => GDExtensionHelper.Bind<Texture2D>(Call(_cached_get_normal_texture).As<GodotObject>());

    public void SetNormalDepth(float normalDepth) => Call(_cached_set_normal_depth, normalDepth);

    public float GetNormalDepth() => Call(_cached_get_normal_depth).As<float>();

    public void SetAoStrength(float aoStrength) => Call(_cached_set_ao_strength, aoStrength);

    public float GetAoStrength() => Call(_cached_get_ao_strength).As<float>();

    public void SetRoughness(float roughness) => Call(_cached_set_roughness, roughness);

    public float GetRoughness() => Call(_cached_get_roughness).As<float>();

    public void SetUvScale(float scale) => Call(_cached_set_uv_scale, scale);

    public float GetUvScale() => Call(_cached_get_uv_scale).As<float>();

    public void SetDetilingRotation(float detilingRotation) => Call(_cached_set_detiling_rotation, detilingRotation);

    public float GetDetilingRotation() => Call(_cached_get_detiling_rotation).As<float>();

    public void SetDetilingShift(float detilingShift) => Call(_cached_set_detiling_shift, detilingShift);

    public float GetDetilingShift() => Call(_cached_get_detiling_shift).As<float>();

#endregion

    private static readonly StringName _cached_name = "name";
    private static readonly StringName _cached_id = "id";
    private static readonly StringName _cached_albedo_color = "albedo_color";
    private static readonly StringName _cached_albedo_texture = "albedo_texture";
    private static readonly StringName _cached_normal_texture = "normal_texture";
    private static readonly StringName _cached_normal_depth = "normal_depth";
    private static readonly StringName _cached_ao_strength = "ao_strength";
    private static readonly StringName _cached_roughness = "roughness";
    private static readonly StringName _cached_uv_scale = "uv_scale";
    private static readonly StringName _cached_detiling_rotation = "detiling_rotation";
    private static readonly StringName _cached_detiling_shift = "detiling_shift";
    private static readonly StringName _cached_clear = "clear";
    private static readonly StringName _cached_set_name = "set_name";
    private static readonly StringName _cached_get_name = "get_name";
    private static readonly StringName _cached_set_id = "set_id";
    private static readonly StringName _cached_get_id = "get_id";
    private static readonly StringName _cached_set_albedo_color = "set_albedo_color";
    private static readonly StringName _cached_get_albedo_color = "get_albedo_color";
    private static readonly StringName _cached_set_albedo_texture = "set_albedo_texture";
    private static readonly StringName _cached_get_albedo_texture = "get_albedo_texture";
    private static readonly StringName _cached_set_normal_texture = "set_normal_texture";
    private static readonly StringName _cached_get_normal_texture = "get_normal_texture";
    private static readonly StringName _cached_set_normal_depth = "set_normal_depth";
    private static readonly StringName _cached_get_normal_depth = "get_normal_depth";
    private static readonly StringName _cached_set_ao_strength = "set_ao_strength";
    private static readonly StringName _cached_get_ao_strength = "get_ao_strength";
    private static readonly StringName _cached_set_roughness = "set_roughness";
    private static readonly StringName _cached_get_roughness = "get_roughness";
    private static readonly StringName _cached_set_uv_scale = "set_uv_scale";
    private static readonly StringName _cached_get_uv_scale = "get_uv_scale";
    private static readonly StringName _cached_set_detiling_rotation = "set_detiling_rotation";
    private static readonly StringName _cached_get_detiling_rotation = "get_detiling_rotation";
    private static readonly StringName _cached_set_detiling_shift = "set_detiling_shift";
    private static readonly StringName _cached_get_detiling_shift = "get_detiling_shift";
    private static readonly StringName _cached_id_changed = "id_changed";
    private static readonly StringName _cached_file_changed = "file_changed";
    private static readonly StringName _cached_setting_changed = "setting_changed";
}