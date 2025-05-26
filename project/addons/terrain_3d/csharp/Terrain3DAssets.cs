using System;
using Godot;

namespace TokisanGames;

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
        get => GDExtensionHelper.Cast<Terrain3DMeshAsset>((Godot.Collections.Array<Godot.GodotObject>)Get(_cached_mesh_list));
        set => Set(_cached_mesh_list, Variant.From(value));
    }

    public Godot.Collections.Array<Terrain3DTextureAsset> TextureList
    {
        get => GDExtensionHelper.Cast<Terrain3DTextureAsset>((Godot.Collections.Array<Godot.GodotObject>)Get(_cached_texture_list));
        set => Set(_cached_texture_list, Variant.From(value));
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
                Connect(_cached_meshes_changed, _meshesChanged_backing_callable);
            }
            _meshesChanged_backing += value;
        }
        remove
        {
            _meshesChanged_backing -= value;
            
            if(_meshesChanged_backing == null)
            {
                Disconnect(_cached_meshes_changed, _meshesChanged_backing_callable);
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
                Connect(_cached_textures_changed, _texturesChanged_backing_callable);
            }
            _texturesChanged_backing += value;
        }
        remove
        {
            _texturesChanged_backing -= value;
            
            if(_texturesChanged_backing == null)
            {
                Disconnect(_cached_textures_changed, _texturesChanged_backing_callable);
                _texturesChanged_backing_callable = default;
            }
        }
    }

#endregion

#region Methods

    public void SetTexture(int id, Terrain3DTextureAsset texture) => Call(_cached_set_texture, id, (Resource)texture);

    public Terrain3DTextureAsset GetTexture(int id) => GDExtensionHelper.Bind<Terrain3DTextureAsset>(Call(_cached_get_texture, id).As<GodotObject>());

    public void SetTextureList(Godot.Collections.Array<Terrain3DTextureAsset> textureList) => Call(_cached_set_texture_list, textureList);

    public Godot.Collections.Array<Terrain3DTextureAsset> GetTextureList() => GDExtensionHelper.Cast<Terrain3DTextureAsset>(Call(_cached_get_texture_list).As<Godot.Collections.Array<Godot.GodotObject>>());

    public int GetTextureCount() => Call(_cached_get_texture_count).As<int>();

    public Rid GetAlbedoArrayRid() => Call(_cached_get_albedo_array_rid).As<Rid>();

    public Rid GetNormalArrayRid() => Call(_cached_get_normal_array_rid).As<Rid>();

    public Color[] GetTextureColors() => Call(_cached_get_texture_colors).As<Color[]>();

    public float[] GetTextureNormalDepths() => Call(_cached_get_texture_normal_depths).As<float[]>();

    public float[] GetTextureAoStrengths() => Call(_cached_get_texture_ao_strengths).As<float[]>();

    public float[] GetTextureRoughnessMods() => Call(_cached_get_texture_roughness_mods).As<float[]>();

    public float[] GetTextureUvScales() => Call(_cached_get_texture_uv_scales).As<float[]>();

    public Vector2[] GetTextureDetiles() => Call(_cached_get_texture_detiles).As<Vector2[]>();

    public void ClearTextures(bool update) => Call(_cached_clear_textures, update);

    public void UpdateTextureList() => Call(_cached_update_texture_list);

    public void SetMeshAsset(int id, Terrain3DMeshAsset mesh) => Call(_cached_set_mesh_asset, id, (Resource)mesh);

    public Terrain3DMeshAsset GetMeshAsset(int id) => GDExtensionHelper.Bind<Terrain3DMeshAsset>(Call(_cached_get_mesh_asset, id).As<GodotObject>());

    public void SetMeshList(Godot.Collections.Array<Terrain3DMeshAsset> meshList) => Call(_cached_set_mesh_list, meshList);

    public Godot.Collections.Array<Terrain3DMeshAsset> GetMeshList() => GDExtensionHelper.Cast<Terrain3DMeshAsset>(Call(_cached_get_mesh_list).As<Godot.Collections.Array<Godot.GodotObject>>());

    public int GetMeshCount() => Call(_cached_get_mesh_count).As<int>();

    public void CreateMeshThumbnails(int id, Vector2I size) => Call(_cached_create_mesh_thumbnails, id, size);

    public void UpdateMeshList() => Call(_cached_update_mesh_list);

    public int Save(string path) => Call(_cached_save, path).As<int>();

#endregion

    private static readonly StringName _cached_mesh_list = "mesh_list";
    private static readonly StringName _cached_texture_list = "texture_list";
    private static readonly StringName _cached_set_texture = "set_texture";
    private static readonly StringName _cached_get_texture = "get_texture";
    private static readonly StringName _cached_set_texture_list = "set_texture_list";
    private static readonly StringName _cached_get_texture_list = "get_texture_list";
    private static readonly StringName _cached_get_texture_count = "get_texture_count";
    private static readonly StringName _cached_get_albedo_array_rid = "get_albedo_array_rid";
    private static readonly StringName _cached_get_normal_array_rid = "get_normal_array_rid";
    private static readonly StringName _cached_get_texture_colors = "get_texture_colors";
    private static readonly StringName _cached_get_texture_normal_depths = "get_texture_normal_depths";
    private static readonly StringName _cached_get_texture_ao_strengths = "get_texture_ao_strengths";
    private static readonly StringName _cached_get_texture_roughness_mods = "get_texture_roughness_mods";
    private static readonly StringName _cached_get_texture_uv_scales = "get_texture_uv_scales";
    private static readonly StringName _cached_get_texture_detiles = "get_texture_detiles";
    private static readonly StringName _cached_clear_textures = "clear_textures";
    private static readonly StringName _cached_update_texture_list = "update_texture_list";
    private static readonly StringName _cached_set_mesh_asset = "set_mesh_asset";
    private static readonly StringName _cached_get_mesh_asset = "get_mesh_asset";
    private static readonly StringName _cached_set_mesh_list = "set_mesh_list";
    private static readonly StringName _cached_get_mesh_list = "get_mesh_list";
    private static readonly StringName _cached_get_mesh_count = "get_mesh_count";
    private static readonly StringName _cached_create_mesh_thumbnails = "create_mesh_thumbnails";
    private static readonly StringName _cached_update_mesh_list = "update_mesh_list";
    private static readonly StringName _cached_save = "save";
    private static readonly StringName _cached_meshes_changed = "meshes_changed";
    private static readonly StringName _cached_textures_changed = "textures_changed";
}