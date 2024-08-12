using System;
using Godot;

namespace GDExtension.Wrappers;

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
        get => (string)Get("name");
        set => Set("name", Variant.From(value));
    }

    public int Id
    {
        get => (int)Get("id");
        set => Set("id", Variant.From(value));
    }

    public Color AlbedoColor
    {
        get => (Color)Get("albedo_color");
        set => Set("albedo_color", Variant.From(value));
    }

    public Texture2D AlbedoTexture
    {
        get => (Texture2D)Get("albedo_texture");
        set => Set("albedo_texture", Variant.From(value));
    }

    public Texture2D NormalTexture
    {
        get => (Texture2D)Get("normal_texture");
        set => Set("normal_texture", Variant.From(value));
    }

    public float UvScale
    {
        get => (float)Get("uv_scale");
        set => Set("uv_scale", Variant.From(value));
    }

    public float Detiling
    {
        get => (float)Get("detiling");
        set => Set("detiling", Variant.From(value));
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
                Connect("id_changed", _idChanged_backing_callable);
            }
            _idChanged_backing += value;
        }
        remove
        {
            _idChanged_backing -= value;
            
            if(_idChanged_backing == null)
            {
                Disconnect("id_changed", _idChanged_backing_callable);
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
                Connect("file_changed", _fileChanged_backing_callable);
            }
            _fileChanged_backing += value;
        }
        remove
        {
            _fileChanged_backing -= value;
            
            if(_fileChanged_backing == null)
            {
                Disconnect("file_changed", _fileChanged_backing_callable);
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
                Connect("setting_changed", _settingChanged_backing_callable);
            }
            _settingChanged_backing += value;
        }
        remove
        {
            _settingChanged_backing -= value;
            
            if(_settingChanged_backing == null)
            {
                Disconnect("setting_changed", _settingChanged_backing_callable);
                _settingChanged_backing_callable = default;
            }
        }
    }

#endregion

#region Methods

    public void Clear() => Call("clear");

#endregion

}