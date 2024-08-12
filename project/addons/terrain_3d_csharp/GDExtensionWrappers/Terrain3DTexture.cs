using System;
using Godot;

namespace GDExtension.Wrappers;

public partial class Terrain3DTexture : Terrain3DTextureAsset
{
    public new static readonly StringName GDExtensionName = "Terrain3DTexture";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DTexture() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DTexture"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public new static Terrain3DTexture Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DTexture>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DTexture"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DTexture"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DTexture"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DTexture"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public new static Terrain3DTexture Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DTexture>(godotObject);
    }
#region Properties

    public int TextureId
    {
        get => (int)Get("texture_id");
        set => Set("texture_id", Variant.From(value));
    }

    public float UvRotation
    {
        get => (float)Get("uv_rotation");
        set => Set("uv_rotation", Variant.From(value));
    }

#endregion

}