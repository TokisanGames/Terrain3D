using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DInstancer : GodotObject
{
    public static readonly StringName GDExtensionName = "Terrain3DInstancer";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying GodotObject), please use the Instantiate() method instead.")]
    protected Terrain3DInstancer() { }

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
    public static Terrain3DInstancer Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DInstancer>(godotObject);
    }
#region Methods

    public void ClearByMesh(int meshId) => Call(_cached_clear_by_mesh, meshId);

    public void ClearByLocation(Vector2I regionLocation, int meshId) => Call(_cached_clear_by_location, regionLocation, meshId);

    public void ClearByRegion(Terrain3DRegion region, int meshId) => Call(_cached_clear_by_region, (Resource)region, meshId);

    public void AddInstances(Vector3 globalPosition, Godot.Collections.Dictionary @params) => Call(_cached_add_instances, globalPosition, @params);

    public void RemoveInstances(Vector3 globalPosition, Godot.Collections.Dictionary @params) => Call(_cached_remove_instances, globalPosition, @params);

    public void AddMultimesh(int meshId, MultiMesh multimesh, Transform3D transform, bool update) => Call(_cached_add_multimesh, meshId, (MultiMesh)multimesh, transform, update);

    public void AddTransforms(int meshId, Godot.Collections.Array<Transform3D> transforms, Color[] colors, bool update) => Call(_cached_add_transforms, meshId, transforms, colors, update);

    public void AppendLocation(Vector2I regionLocation, int meshId, Godot.Collections.Array<Transform3D> transforms, Color[] colors, bool update) => Call(_cached_append_location, regionLocation, meshId, transforms, colors, update);

    public void AppendRegion(Terrain3DRegion region, int meshId, Godot.Collections.Array<Transform3D> transforms, Color[] colors, bool update) => Call(_cached_append_region, (Resource)region, meshId, transforms, colors, update);

    public void UpdateTransforms(Aabb aabb) => Call(_cached_update_transforms, aabb);

    public void UpdateMmis(bool rebuild) => Call(_cached_update_mmis, rebuild);

    public void SwapIds(int srcId, int destId) => Call(_cached_swap_ids, srcId, destId);

    public void DumpData() => Call(_cached_dump_data);

    public void DumpMmis() => Call(_cached_dump_mmis);

#endregion

    private static readonly StringName _cached_clear_by_mesh = "clear_by_mesh";
    private static readonly StringName _cached_clear_by_location = "clear_by_location";
    private static readonly StringName _cached_clear_by_region = "clear_by_region";
    private static readonly StringName _cached_add_instances = "add_instances";
    private static readonly StringName _cached_remove_instances = "remove_instances";
    private static readonly StringName _cached_add_multimesh = "add_multimesh";
    private static readonly StringName _cached_add_transforms = "add_transforms";
    private static readonly StringName _cached_append_location = "append_location";
    private static readonly StringName _cached_append_region = "append_region";
    private static readonly StringName _cached_update_transforms = "update_transforms";
    private static readonly StringName _cached_update_mmis = "update_mmis";
    private static readonly StringName _cached_swap_ids = "swap_ids";
    private static readonly StringName _cached_dump_data = "dump_data";
    private static readonly StringName _cached_dump_mmis = "dump_mmis";
}