using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DRegion : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DRegion";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DRegion() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DRegion"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DRegion Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DRegion>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DRegion"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DRegion"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DRegion"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DRegion"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DRegion Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DRegion>(godotObject);
    }
#region Enums

    public enum MapType : long
    {
        TypeHeight = 0,
        TypeControl = 1,
        TypeColor = 2,
        TypeMax = 3,
    }

#endregion

#region Properties

    public float Version
    {
        get => (float)Get(_cached_version);
        set => Set(_cached_version, Variant.From(value));
    }

    public int RegionSize
    {
        get => (int)Get(_cached_region_size);
        set => Set(_cached_region_size, Variant.From(value));
    }

    public float VertexSpacing
    {
        get => (float)Get(_cached_vertex_spacing);
        set => Set(_cached_vertex_spacing, Variant.From(value));
    }

    public Vector2 HeightRange
    {
        get => (Vector2)Get(_cached_height_range);
        set => Set(_cached_height_range, Variant.From(value));
    }

    public Image HeightMap
    {
        get => (Image)Get(_cached_height_map);
        set => Set(_cached_height_map, Variant.From(value));
    }

    public Image ControlMap
    {
        get => (Image)Get(_cached_control_map);
        set => Set(_cached_control_map, Variant.From(value));
    }

    public Image ColorMap
    {
        get => (Image)Get(_cached_color_map);
        set => Set(_cached_color_map, Variant.From(value));
    }

    public Godot.Collections.Dictionary Instances
    {
        get => (Godot.Collections.Dictionary)Get(_cached_instances);
        set => Set(_cached_instances, Variant.From(value));
    }

    public bool Edited
    {
        get => (bool)Get(_cached_edited);
        set => Set(_cached_edited, Variant.From(value));
    }

    public bool Deleted
    {
        get => (bool)Get(_cached_deleted);
        set => Set(_cached_deleted, Variant.From(value));
    }

    public bool Modified
    {
        get => (bool)Get(_cached_modified);
        set => Set(_cached_modified, Variant.From(value));
    }

    public Vector2I Location
    {
        get => (Vector2I)Get(_cached_location);
        set => Set(_cached_location, Variant.From(value));
    }

#endregion

#region Methods

    public void SetVersion(float version) => Call(_cached_set_version, version);

    public float GetVersion() => Call(_cached_get_version).As<float>();

    public void SetRegionSize(int regionSize) => Call(_cached_set_region_size, regionSize);

    public int GetRegionSize() => Call(_cached_get_region_size).As<int>();

    public void SetVertexSpacing(float vertexSpacing) => Call(_cached_set_vertex_spacing, vertexSpacing);

    public float GetVertexSpacing() => Call(_cached_get_vertex_spacing).As<float>();

    public void SetMap(int mapType, Image map) => Call(_cached_set_map, mapType, (Image)map);

    public Image GetMap(int mapType) => GDExtensionHelper.Bind<Image>(Call(_cached_get_map, mapType).As<GodotObject>());

    public void SetMaps(Godot.Collections.Array<Image> maps) => Call(_cached_set_maps, maps);

    public Godot.Collections.Array<Image> GetMaps() => GDExtensionHelper.Cast<Image>(Call(_cached_get_maps).As<Godot.Collections.Array<Godot.GodotObject>>());

    public void SetHeightMap(Image map) => Call(_cached_set_height_map, (Image)map);

    public Image GetHeightMap() => GDExtensionHelper.Bind<Image>(Call(_cached_get_height_map).As<GodotObject>());

    public void SetControlMap(Image map) => Call(_cached_set_control_map, (Image)map);

    public Image GetControlMap() => GDExtensionHelper.Bind<Image>(Call(_cached_get_control_map).As<GodotObject>());

    public void SetColorMap(Image map) => Call(_cached_set_color_map, (Image)map);

    public Image GetColorMap() => GDExtensionHelper.Bind<Image>(Call(_cached_get_color_map).As<GodotObject>());

    public void SanitizeMaps() => Call(_cached_sanitize_maps);

    public Image SanitizeMap(int mapType, Image map) => GDExtensionHelper.Bind<Image>(Call(_cached_sanitize_map, mapType, (Image)map).As<GodotObject>());

    public bool ValidateMapSize(Image map) => Call(_cached_validate_map_size, (Image)map).As<bool>();

    public void SetHeightRange(Vector2 range) => Call(_cached_set_height_range, range);

    public Vector2 GetHeightRange() => Call(_cached_get_height_range).As<Vector2>();

    public void UpdateHeight(float height) => Call(_cached_update_height, height);

    public void UpdateHeights(Vector2 lowHigh) => Call(_cached_update_heights, lowHigh);

    public void CalcHeightRange() => Call(_cached_calc_height_range);

    public void SetInstances(Godot.Collections.Dictionary instances) => Call(_cached_set_instances, instances);

    public Godot.Collections.Dictionary GetInstances() => Call(_cached_get_instances).As<Godot.Collections.Dictionary>();

    public int Save(string path, bool _16Bit) => Call(_cached_save, path, _16Bit).As<int>();

    public void SetDeleted(bool deleted) => Call(_cached_set_deleted, deleted);

    public bool IsDeleted() => Call(_cached_is_deleted).As<bool>();

    public void SetEdited(bool edited) => Call(_cached_set_edited, edited);

    public bool IsEdited() => Call(_cached_is_edited).As<bool>();

    public void SetModified(bool modified) => Call(_cached_set_modified, modified);

    public bool IsModified() => Call(_cached_is_modified).As<bool>();

    public void SetLocation(Vector2I location) => Call(_cached_set_location, location);

    public Vector2I GetLocation() => Call(_cached_get_location).As<Vector2I>();

    public void SetData(Godot.Collections.Dictionary data) => Call(_cached_set_data, data);

    public Godot.Collections.Dictionary GetData() => Call(_cached_get_data).As<Godot.Collections.Dictionary>();

    public Terrain3DRegion Duplicate(bool deep) => GDExtensionHelper.Bind<Terrain3DRegion>(Call(_cached_duplicate, deep).As<GodotObject>());

#endregion

    private static readonly StringName _cached_version = "version";
    private static readonly StringName _cached_region_size = "region_size";
    private static readonly StringName _cached_vertex_spacing = "vertex_spacing";
    private static readonly StringName _cached_height_range = "height_range";
    private static readonly StringName _cached_height_map = "height_map";
    private static readonly StringName _cached_control_map = "control_map";
    private static readonly StringName _cached_color_map = "color_map";
    private static readonly StringName _cached_instances = "instances";
    private static readonly StringName _cached_edited = "edited";
    private static readonly StringName _cached_deleted = "deleted";
    private static readonly StringName _cached_modified = "modified";
    private static readonly StringName _cached_location = "location";
    private static readonly StringName _cached_set_version = "set_version";
    private static readonly StringName _cached_get_version = "get_version";
    private static readonly StringName _cached_set_region_size = "set_region_size";
    private static readonly StringName _cached_get_region_size = "get_region_size";
    private static readonly StringName _cached_set_vertex_spacing = "set_vertex_spacing";
    private static readonly StringName _cached_get_vertex_spacing = "get_vertex_spacing";
    private static readonly StringName _cached_set_map = "set_map";
    private static readonly StringName _cached_get_map = "get_map";
    private static readonly StringName _cached_set_maps = "set_maps";
    private static readonly StringName _cached_get_maps = "get_maps";
    private static readonly StringName _cached_set_height_map = "set_height_map";
    private static readonly StringName _cached_get_height_map = "get_height_map";
    private static readonly StringName _cached_set_control_map = "set_control_map";
    private static readonly StringName _cached_get_control_map = "get_control_map";
    private static readonly StringName _cached_set_color_map = "set_color_map";
    private static readonly StringName _cached_get_color_map = "get_color_map";
    private static readonly StringName _cached_sanitize_maps = "sanitize_maps";
    private static readonly StringName _cached_sanitize_map = "sanitize_map";
    private static readonly StringName _cached_validate_map_size = "validate_map_size";
    private static readonly StringName _cached_set_height_range = "set_height_range";
    private static readonly StringName _cached_get_height_range = "get_height_range";
    private static readonly StringName _cached_update_height = "update_height";
    private static readonly StringName _cached_update_heights = "update_heights";
    private static readonly StringName _cached_calc_height_range = "calc_height_range";
    private static readonly StringName _cached_set_instances = "set_instances";
    private static readonly StringName _cached_get_instances = "get_instances";
    private static readonly StringName _cached_save = "save";
    private static readonly StringName _cached_set_deleted = "set_deleted";
    private static readonly StringName _cached_is_deleted = "is_deleted";
    private static readonly StringName _cached_set_edited = "set_edited";
    private static readonly StringName _cached_is_edited = "is_edited";
    private static readonly StringName _cached_set_modified = "set_modified";
    private static readonly StringName _cached_is_modified = "is_modified";
    private static readonly StringName _cached_set_location = "set_location";
    private static readonly StringName _cached_get_location = "get_location";
    private static readonly StringName _cached_set_data = "set_data";
    private static readonly StringName _cached_get_data = "get_data";
    private static readonly StringName _cached_duplicate = "duplicate";
}