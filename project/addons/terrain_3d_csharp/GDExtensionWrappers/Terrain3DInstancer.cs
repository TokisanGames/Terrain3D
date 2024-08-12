using System;
using Godot;

namespace GDExtension.Wrappers;

public partial class Terrain3DInstancer : GodotObject
{
    public static readonly StringName GDExtensionName = "Terrain3DInstancer";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying GodotObject), please use the Instantiate() method instead.")]
    protected Terrain3DInstancer()
    {
    }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DInstancer"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DInstancer Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DInstancer>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DInstancer"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DInstancer"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DInstancer"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DInstancer"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DInstancer? Bind(GodotObject? godotObject)
    {
        return godotObject == null
            ? null
            : GDExtensionHelper.Bind<Terrain3DInstancer>(godotObject);
    }

    #region Methods

    public void Initialize(Terrain3D terrain3D) => Call("initialize", terrain3D);
    
    public void ClearByMesh(int meshId) => Call("clear_by_mesh", meshId);

    public void ClearByRegionId(int regionId, int meshId) => Call("clear_by_region_id", regionId, meshId);

    public void ClearByOffset(Vector2I regionOffset, int meshId) => Call("clear_by_offset", regionOffset, meshId);

    public void AddInstances(Vector3 globalPosition, Godot.Collections.Dictionary @params) => Call("add_instances", globalPosition, @params);

    public void RemoveInstances(Vector3 globalPosition, Godot.Collections.Dictionary @params) => Call("remove_instances", globalPosition, @params);

    public void AddTransforms(int meshId, Godot.Collections.Array<Transform3D> transforms, Godot.Collections.Array<Color> colors) => Call("add_transforms", meshId, transforms, colors);

    public void AddMultimesh(int meshId, MultiMesh multimesh, Transform3D transform) => Call("add_multimesh", meshId, multimesh, transform);

    public void SetCastShadows(int meshId, int mode) => Call("set_cast_shadows", meshId, mode);

    #endregion
}