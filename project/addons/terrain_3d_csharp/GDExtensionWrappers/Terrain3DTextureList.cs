using System;
using Godot;

namespace GDExtension.Wrappers;

public partial class Terrain3DTextureList : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DTextureList";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DTextureList() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DTextureList"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DTextureList Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DTextureList>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DTextureList"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DTextureList"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DTextureList"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DTextureList"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DTextureList Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DTextureList>(godotObject);
    }
#region Properties

    public Godot.Collections.Array<Terrain3DTextureAsset> Textures
    {
        get => (Godot.Collections.Array<Terrain3DTextureAsset>)Get("textures");
        set => Set("textures", Variant.From(value));
    }

#endregion

}