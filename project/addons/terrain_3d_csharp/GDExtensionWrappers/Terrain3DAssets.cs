using System;
using System.Linq;
using Godot;
using Godot.Collections;

namespace GDExtension.Wrappers;

public partial class Terrain3DAssets : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DAssets";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DAssets() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DAssets"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DAssets Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DAssets>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DAssets"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DAssets"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DAssets"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DAssets"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DAssets Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DAssets>(godotObject);
    }
#region Enums

    public enum AssetType : long
    {
        TypeTexture = 0,
        TypeMesh = 1,
    }

#endregion

#region Properties

    public Godot.Collections.Array<Terrain3DMeshAsset> MeshList
    {
        get => new(Get("mesh_list").AsGodotArray().Select(variant => Terrain3DMeshAsset.Bind(variant.AsGodotObject())));
        set => Set("mesh_list", Variant.From(value));
    }

    public Godot.Collections.Array<Terrain3DTextureAsset> TextureList
    {
        get => (Godot.Collections.Array<Terrain3DTextureAsset>)Get("texture_list");
        set => Set("texture_list", Variant.From(value));
    }

#endregion

#region Signals

    public delegate void MeshesChangedHandler();

    private MeshesChangedHandler _meshesChanged_backing;
    private Callable _meshesChanged_backing_callable;
    public event MeshesChangedHandler MeshesChanged
    {
        add
        {
            if(_meshesChanged_backing == null)
            {
                _meshesChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _meshesChanged_backing?.Invoke();
                    }
                );
                Connect("meshes_changed", _meshesChanged_backing_callable);
            }
            _meshesChanged_backing += value;
        }
        remove
        {
            _meshesChanged_backing -= value;
            
            if(_meshesChanged_backing == null)
            {
                Disconnect("meshes_changed", _meshesChanged_backing_callable);
                _meshesChanged_backing_callable = default;
            }
        }
    }

    public delegate void TexturesChangedHandler();

    private TexturesChangedHandler _texturesChanged_backing;
    private Callable _texturesChanged_backing_callable;
    public event TexturesChangedHandler TexturesChanged
    {
        add
        {
            if(_texturesChanged_backing == null)
            {
                _texturesChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _texturesChanged_backing?.Invoke();
                    }
                );
                Connect("textures_changed", _texturesChanged_backing_callable);
            }
            _texturesChanged_backing += value;
        }
        remove
        {
            _texturesChanged_backing -= value;
            
            if(_texturesChanged_backing == null)
            {
                Disconnect("textures_changed", _texturesChanged_backing_callable);
                _texturesChanged_backing_callable = default;
            }
        }
    }

#endregion

#region Methods

    public void SetMeshAsset(int id, Terrain3DMeshAsset mesh) => Call("set_mesh_asset", id, (Resource)mesh);

    public Terrain3DMeshAsset GetMeshAsset(int id) => GDExtensionHelper.Bind<Terrain3DMeshAsset>(Call("get_mesh_asset", id).As<GodotObject>());

    public int GetMeshCount() => Call("get_mesh_count").As<int>();

    public void CreateMeshThumbnails(int id, Vector2I size) => Call("create_mesh_thumbnails", id, size);

    public void SetTexture(int id, Terrain3DTextureAsset texture) => Call("set_texture", id, (Resource)texture);

    public Terrain3DTextureAsset GetTexture(int id) => GDExtensionHelper.Bind<Terrain3DTextureAsset>(Call("get_texture", id).As<GodotObject>());

    public int GetTextureCount() => Call("get_texture_count").As<int>();

    public void Save() => Call("save");

#endregion

}