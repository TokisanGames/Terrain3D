using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DCollision : GodotObject
{
    public static readonly StringName GDExtensionName = "Terrain3DCollision";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying GodotObject), please use the Instantiate() method instead.")]
    protected Terrain3DCollision() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DCollision"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DCollision Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DCollision>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DCollision"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DCollision"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DCollision"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DCollision"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DCollision Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DCollision>(godotObject);
    }
#region Enums

    public enum CollisionMode : long
    {
        Disabled = 0,
        DynamicGame = 1,
        DynamicEditor = 2,
        FullGame = 3,
        FullEditor = 4,
    }

#endregion

#region Properties

    public long /*Disabled,Dynamic/Game,Dynamic/Editor,Full/Game,Full/Editor*/ Mode
    {
        get => (long /*Disabled,Dynamic/Game,Dynamic/Editor,Full/Game,Full/Editor*/)Get(_cached_mode).As<Int64>();
        set => Set(_cached_mode, Variant.From(value));
    }

    public int ShapeSize
    {
        get => (int)Get(_cached_shape_size);
        set => Set(_cached_shape_size, Variant.From(value));
    }

    public int Radius
    {
        get => (int)Get(_cached_radius);
        set => Set(_cached_radius, Variant.From(value));
    }

    public int Layer
    {
        get => (int)Get(_cached_layer);
        set => Set(_cached_layer, Variant.From(value));
    }

    public int Mask
    {
        get => (int)Get(_cached_mask);
        set => Set(_cached_mask, Variant.From(value));
    }

    public float Priority
    {
        get => (float)Get(_cached_priority);
        set => Set(_cached_priority, Variant.From(value));
    }

    public PhysicsMaterial PhysicsMaterial
    {
        get => (PhysicsMaterial)Get(_cached_physics_material);
        set => Set(_cached_physics_material, Variant.From(value));
    }

#endregion

#region Methods

    public void Build() => Call(_cached_build);

    public void Update(bool rebuild) => Call(_cached_update, rebuild);

    public void Destroy() => Call(_cached_destroy);

    public void SetMode(int mode) => Call(_cached_set_mode, mode);

    public int GetMode() => Call(_cached_get_mode).As<int>();

    public bool IsEnabled() => Call(_cached_is_enabled).As<bool>();

    public bool IsEditorMode() => Call(_cached_is_editor_mode).As<bool>();

    public bool IsDynamicMode() => Call(_cached_is_dynamic_mode).As<bool>();

    public void SetShapeSize(int size) => Call(_cached_set_shape_size, size);

    public int GetShapeSize() => Call(_cached_get_shape_size).As<int>();

    public void SetRadius(int radius) => Call(_cached_set_radius, radius);

    public int GetRadius() => Call(_cached_get_radius).As<int>();

    public void SetLayer(int layers) => Call(_cached_set_layer, layers);

    public int GetLayer() => Call(_cached_get_layer).As<int>();

    public void SetMask(int mask) => Call(_cached_set_mask, mask);

    public int GetMask() => Call(_cached_get_mask).As<int>();

    public void SetPriority(float priority) => Call(_cached_set_priority, priority);

    public float GetPriority() => Call(_cached_get_priority).As<float>();

    public void SetPhysicsMaterial(PhysicsMaterial material) => Call(_cached_set_physics_material, (PhysicsMaterial)material);

    public PhysicsMaterial GetPhysicsMaterial() => GDExtensionHelper.Bind<PhysicsMaterial>(Call(_cached_get_physics_material).As<GodotObject>());

    public Rid GetRid() => Call(_cached_get_rid).As<Rid>();

#endregion

    private static readonly StringName _cached_mode = "mode";
    private static readonly StringName _cached_shape_size = "shape_size";
    private static readonly StringName _cached_radius = "radius";
    private static readonly StringName _cached_layer = "layer";
    private static readonly StringName _cached_mask = "mask";
    private static readonly StringName _cached_priority = "priority";
    private static readonly StringName _cached_physics_material = "physics_material";
    private static readonly StringName _cached_build = "build";
    private static readonly StringName _cached_update = "update";
    private static readonly StringName _cached_destroy = "destroy";
    private static readonly StringName _cached_set_mode = "set_mode";
    private static readonly StringName _cached_get_mode = "get_mode";
    private static readonly StringName _cached_is_enabled = "is_enabled";
    private static readonly StringName _cached_is_editor_mode = "is_editor_mode";
    private static readonly StringName _cached_is_dynamic_mode = "is_dynamic_mode";
    private static readonly StringName _cached_set_shape_size = "set_shape_size";
    private static readonly StringName _cached_get_shape_size = "get_shape_size";
    private static readonly StringName _cached_set_radius = "set_radius";
    private static readonly StringName _cached_get_radius = "get_radius";
    private static readonly StringName _cached_set_layer = "set_layer";
    private static readonly StringName _cached_get_layer = "get_layer";
    private static readonly StringName _cached_set_mask = "set_mask";
    private static readonly StringName _cached_get_mask = "get_mask";
    private static readonly StringName _cached_set_priority = "set_priority";
    private static readonly StringName _cached_get_priority = "get_priority";
    private static readonly StringName _cached_set_physics_material = "set_physics_material";
    private static readonly StringName _cached_get_physics_material = "get_physics_material";
    private static readonly StringName _cached_get_rid = "get_rid";
}