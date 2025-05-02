using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DData : GodotObject
{
    public static readonly StringName GDExtensionName = "Terrain3DData";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying GodotObject), please use the Instantiate() method instead.")]
    protected Terrain3DData() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DData"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DData Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DData>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DData"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DData"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DData"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DData"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DData Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DData>(godotObject);
    }
#region Enums

    public enum HeightFilter : long
    {
        Nearest = 0,
        Minimum = 1,
    }

#endregion

#region Properties

    public Godot.Collections.Array<Vector2I> RegionLocations
    {
        get => (Godot.Collections.Array<Vector2I>)Get(_cached_region_locations);
        set => Set(_cached_region_locations, Variant.From(value));
    }

    public Godot.Collections.Array<Image> HeightMaps
    {
        get => GDExtensionHelper.Cast<Image>((Godot.Collections.Array<Godot.GodotObject>)Get(_cached_height_maps));
        set => Set(_cached_height_maps, Variant.From(value));
    }

    public Godot.Collections.Array<Image> ControlMaps
    {
        get => GDExtensionHelper.Cast<Image>((Godot.Collections.Array<Godot.GodotObject>)Get(_cached_control_maps));
        set => Set(_cached_control_maps, Variant.From(value));
    }

    public Godot.Collections.Array<Image> ColorMaps
    {
        get => GDExtensionHelper.Cast<Image>((Godot.Collections.Array<Godot.GodotObject>)Get(_cached_color_maps));
        set => Set(_cached_color_maps, Variant.From(value));
    }

#endregion

#region Signals

    public delegate void MapsChangedHandler();

    private MapsChangedHandler _mapsChanged_backing;
    private Callable _mapsChanged_backing_callable;
    public event MapsChangedHandler MapsChanged
    {
        add
        {
            if(_mapsChanged_backing == null)
            {
                _mapsChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _mapsChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_maps_changed, _mapsChanged_backing_callable);
            }
            _mapsChanged_backing += value;
        }
        remove
        {
            _mapsChanged_backing -= value;
            
            if(_mapsChanged_backing == null)
            {
                Disconnect(_cached_maps_changed, _mapsChanged_backing_callable);
                _mapsChanged_backing_callable = default;
            }
        }
    }

    public delegate void RegionMapChangedHandler();

    private RegionMapChangedHandler _regionMapChanged_backing;
    private Callable _regionMapChanged_backing_callable;
    public event RegionMapChangedHandler RegionMapChanged
    {
        add
        {
            if(_regionMapChanged_backing == null)
            {
                _regionMapChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _regionMapChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_region_map_changed, _regionMapChanged_backing_callable);
            }
            _regionMapChanged_backing += value;
        }
        remove
        {
            _regionMapChanged_backing -= value;
            
            if(_regionMapChanged_backing == null)
            {
                Disconnect(_cached_region_map_changed, _regionMapChanged_backing_callable);
                _regionMapChanged_backing_callable = default;
            }
        }
    }

    public delegate void HeightMapsChangedHandler();

    private HeightMapsChangedHandler _heightMapsChanged_backing;
    private Callable _heightMapsChanged_backing_callable;
    public event HeightMapsChangedHandler HeightMapsChanged
    {
        add
        {
            if(_heightMapsChanged_backing == null)
            {
                _heightMapsChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _heightMapsChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_height_maps_changed, _heightMapsChanged_backing_callable);
            }
            _heightMapsChanged_backing += value;
        }
        remove
        {
            _heightMapsChanged_backing -= value;
            
            if(_heightMapsChanged_backing == null)
            {
                Disconnect(_cached_height_maps_changed, _heightMapsChanged_backing_callable);
                _heightMapsChanged_backing_callable = default;
            }
        }
    }

    public delegate void ControlMapsChangedHandler();

    private ControlMapsChangedHandler _controlMapsChanged_backing;
    private Callable _controlMapsChanged_backing_callable;
    public event ControlMapsChangedHandler ControlMapsChanged
    {
        add
        {
            if(_controlMapsChanged_backing == null)
            {
                _controlMapsChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _controlMapsChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_control_maps_changed, _controlMapsChanged_backing_callable);
            }
            _controlMapsChanged_backing += value;
        }
        remove
        {
            _controlMapsChanged_backing -= value;
            
            if(_controlMapsChanged_backing == null)
            {
                Disconnect(_cached_control_maps_changed, _controlMapsChanged_backing_callable);
                _controlMapsChanged_backing_callable = default;
            }
        }
    }

    public delegate void ColorMapsChangedHandler();

    private ColorMapsChangedHandler _colorMapsChanged_backing;
    private Callable _colorMapsChanged_backing_callable;
    public event ColorMapsChangedHandler ColorMapsChanged
    {
        add
        {
            if(_colorMapsChanged_backing == null)
            {
                _colorMapsChanged_backing_callable = Callable.From(
                    () =>
                    {
                        _colorMapsChanged_backing?.Invoke();
                    }
                );
                Connect(_cached_color_maps_changed, _colorMapsChanged_backing_callable);
            }
            _colorMapsChanged_backing += value;
        }
        remove
        {
            _colorMapsChanged_backing -= value;
            
            if(_colorMapsChanged_backing == null)
            {
                Disconnect(_cached_color_maps_changed, _colorMapsChanged_backing_callable);
                _colorMapsChanged_backing_callable = default;
            }
        }
    }

    public delegate void MapsEditedHandler(Aabb editedArea);

    private MapsEditedHandler _mapsEdited_backing;
    private Callable _mapsEdited_backing_callable;
    public event MapsEditedHandler MapsEdited
    {
        add
        {
            if(_mapsEdited_backing == null)
            {
                _mapsEdited_backing_callable = Callable.From<Variant>(
                    (arg0_variant) =>
                    {
                        var arg0 = arg0_variant.As<Aabb>();
                        _mapsEdited_backing?.Invoke(arg0);
                    }
                );
                Connect(_cached_maps_edited, _mapsEdited_backing_callable);
            }
            _mapsEdited_backing += value;
        }
        remove
        {
            _mapsEdited_backing -= value;
            
            if(_mapsEdited_backing == null)
            {
                Disconnect(_cached_maps_edited, _mapsEdited_backing_callable);
                _mapsEdited_backing_callable = default;
            }
        }
    }

#endregion

#region Methods

    public int GetRegionCount() => Call(_cached_get_region_count).As<int>();

    public void SetRegionLocations(Godot.Collections.Array<Vector2I> regionLocations) => Call(_cached_set_region_locations, regionLocations);

    public Godot.Collections.Array<Vector2I> GetRegionLocations() => Call(_cached_get_region_locations).As<Godot.Collections.Array<Vector2I>>();

    public Godot.Collections.Array<Terrain3DRegion> GetRegionsActive(bool copy, bool deep) => GDExtensionHelper.Cast<Terrain3DRegion>(Call(_cached_get_regions_active, copy, deep).As<Godot.Collections.Array<Godot.GodotObject>>());

    public Godot.Collections.Dictionary GetRegionsAll() => Call(_cached_get_regions_all).As<Godot.Collections.Dictionary>();

    public int[] GetRegionMap() => Call(_cached_get_region_map).As<int[]>();

    public static int GetRegionMapIndex(Vector2I regionLocation) => GDExtensionHelper.Call(GDExtensionName, _cached_get_region_map_index, regionLocation).As<int>();

    public void DoForRegions(Rect2I area, Callable callback) => Call(_cached_do_for_regions, area, callback);

    public void ChangeRegionSize(int regionSize) => Call(_cached_change_region_size, regionSize);

    public Vector2I GetRegionLocation(Vector3 globalPosition) => Call(_cached_get_region_location, globalPosition).As<Vector2I>();

    public int GetRegionId(Vector2I regionLocation) => Call(_cached_get_region_id, regionLocation).As<int>();

    public int GetRegionIdp(Vector3 globalPosition) => Call(_cached_get_region_idp, globalPosition).As<int>();

    public bool HasRegion(Vector2I regionLocation) => Call(_cached_has_region, regionLocation).As<bool>();

    public bool HasRegionp(Vector3 globalPosition) => Call(_cached_has_regionp, globalPosition).As<bool>();

    public Terrain3DRegion GetRegion(Vector2I regionLocation) => GDExtensionHelper.Bind<Terrain3DRegion>(Call(_cached_get_region, regionLocation).As<GodotObject>());

    public Terrain3DRegion GetRegionp(Vector3 globalPosition) => GDExtensionHelper.Bind<Terrain3DRegion>(Call(_cached_get_regionp, globalPosition).As<GodotObject>());

    public void SetRegionModified(Vector2I regionLocation, bool modified) => Call(_cached_set_region_modified, regionLocation, modified);

    public bool IsRegionModified(Vector2I regionLocation) => Call(_cached_is_region_modified, regionLocation).As<bool>();

    public void SetRegionDeleted(Vector2I regionLocation, bool deleted) => Call(_cached_set_region_deleted, regionLocation, deleted);

    public bool IsRegionDeleted(Vector2I regionLocation) => Call(_cached_is_region_deleted, regionLocation).As<bool>();

    public Terrain3DRegion AddRegionBlankp(Vector3 globalPosition, bool update) => GDExtensionHelper.Bind<Terrain3DRegion>(Call(_cached_add_region_blankp, globalPosition, update).As<GodotObject>());

    public Terrain3DRegion AddRegionBlank(Vector2I regionLocation, bool update) => GDExtensionHelper.Bind<Terrain3DRegion>(Call(_cached_add_region_blank, regionLocation, update).As<GodotObject>());

    public int AddRegion(Terrain3DRegion region, bool update) => Call(_cached_add_region, (Resource)region, update).As<int>();

    public void RemoveRegionp(Vector3 globalPosition, bool update) => Call(_cached_remove_regionp, globalPosition, update);

    public void RemoveRegionl(Vector2I regionLocation, bool update) => Call(_cached_remove_regionl, regionLocation, update);

    public void RemoveRegion(Terrain3DRegion region, bool update) => Call(_cached_remove_region, (Resource)region, update);

    public void SaveDirectory(string directory) => Call(_cached_save_directory, directory);

    public void SaveRegion(Vector2I regionLocation, string directory, bool _16Bit) => Call(_cached_save_region, regionLocation, directory, _16Bit);

    public void LoadDirectory(string directory) => Call(_cached_load_directory, directory);

    public void LoadRegion(Vector2I regionLocation, string directory, bool update) => Call(_cached_load_region, regionLocation, directory, update);

    public Godot.Collections.Array<Image> GetHeightMaps() => GDExtensionHelper.Cast<Image>(Call(_cached_get_height_maps).As<Godot.Collections.Array<Godot.GodotObject>>());

    public Godot.Collections.Array<Image> GetControlMaps() => GDExtensionHelper.Cast<Image>(Call(_cached_get_control_maps).As<Godot.Collections.Array<Godot.GodotObject>>());

    public Godot.Collections.Array<Image> GetColorMaps() => GDExtensionHelper.Cast<Image>(Call(_cached_get_color_maps).As<Godot.Collections.Array<Godot.GodotObject>>());

    public Godot.Collections.Array<Image> GetMaps(int mapType) => GDExtensionHelper.Cast<Image>(Call(_cached_get_maps, mapType).As<Godot.Collections.Array<Godot.GodotObject>>());

    public void UpdateMaps(int mapType, bool allMaps, bool generateMipmaps) => Call(_cached_update_maps, mapType, allMaps, generateMipmaps);

    public Rid GetHeightMapsRid() => Call(_cached_get_height_maps_rid).As<Rid>();

    public Rid GetControlMapsRid() => Call(_cached_get_control_maps_rid).As<Rid>();

    public Rid GetColorMapsRid() => Call(_cached_get_color_maps_rid).As<Rid>();

    public void SetPixel(int mapType, Vector3 globalPosition, Color pixel) => Call(_cached_set_pixel, mapType, globalPosition, pixel);

    public Color GetPixel(int mapType, Vector3 globalPosition) => Call(_cached_get_pixel, mapType, globalPosition).As<Color>();

    public void SetHeight(Vector3 globalPosition, float height) => Call(_cached_set_height, globalPosition, height);

    public float GetHeight(Vector3 globalPosition) => Call(_cached_get_height, globalPosition).As<float>();

    public void SetColor(Vector3 globalPosition, Color color) => Call(_cached_set_color, globalPosition, color);

    public Color GetColor(Vector3 globalPosition) => Call(_cached_get_color, globalPosition).As<Color>();

    public void SetControl(Vector3 globalPosition, int control) => Call(_cached_set_control, globalPosition, control);

    public int GetControl(Vector3 globalPosition) => Call(_cached_get_control, globalPosition).As<int>();

    public void SetRoughness(Vector3 globalPosition, float roughness) => Call(_cached_set_roughness, globalPosition, roughness);

    public float GetRoughness(Vector3 globalPosition) => Call(_cached_get_roughness, globalPosition).As<float>();

    public void SetControlBaseId(Vector3 globalPosition, int textureId) => Call(_cached_set_control_base_id, globalPosition, textureId);

    public int GetControlBaseId(Vector3 globalPosition) => Call(_cached_get_control_base_id, globalPosition).As<int>();

    public void SetControlOverlayId(Vector3 globalPosition, int textureId) => Call(_cached_set_control_overlay_id, globalPosition, textureId);

    public int GetControlOverlayId(Vector3 globalPosition) => Call(_cached_get_control_overlay_id, globalPosition).As<int>();

    public void SetControlBlend(Vector3 globalPosition, float blendValue) => Call(_cached_set_control_blend, globalPosition, blendValue);

    public float GetControlBlend(Vector3 globalPosition) => Call(_cached_get_control_blend, globalPosition).As<float>();

    public void SetControlAngle(Vector3 globalPosition, float degrees) => Call(_cached_set_control_angle, globalPosition, degrees);

    public float GetControlAngle(Vector3 globalPosition) => Call(_cached_get_control_angle, globalPosition).As<float>();

    public void SetControlScale(Vector3 globalPosition, float percentageModifier) => Call(_cached_set_control_scale, globalPosition, percentageModifier);

    public float GetControlScale(Vector3 globalPosition) => Call(_cached_get_control_scale, globalPosition).As<float>();

    public void SetControlHole(Vector3 globalPosition, bool enable) => Call(_cached_set_control_hole, globalPosition, enable);

    public bool GetControlHole(Vector3 globalPosition) => Call(_cached_get_control_hole, globalPosition).As<bool>();

    public void SetControlNavigation(Vector3 globalPosition, bool enable) => Call(_cached_set_control_navigation, globalPosition, enable);

    public bool GetControlNavigation(Vector3 globalPosition) => Call(_cached_get_control_navigation, globalPosition).As<bool>();

    public void SetControlAuto(Vector3 globalPosition, bool enable) => Call(_cached_set_control_auto, globalPosition, enable);

    public bool GetControlAuto(Vector3 globalPosition) => Call(_cached_get_control_auto, globalPosition).As<bool>();

    public Vector3 GetNormal(Vector3 globalPosition) => Call(_cached_get_normal, globalPosition).As<Vector3>();

    public bool IsInSlope(Vector3 globalPosition, Vector2 slopeRange, bool invert) => Call(_cached_is_in_slope, globalPosition, slopeRange, invert).As<bool>();

    public Vector3 GetTextureId(Vector3 globalPosition) => Call(_cached_get_texture_id, globalPosition).As<Vector3>();

    public Vector3 GetMeshVertex(int lod, int filter, Vector3 globalPosition) => Call(_cached_get_mesh_vertex, lod, filter, globalPosition).As<Vector3>();

    public Vector2 GetHeightRange() => Call(_cached_get_height_range).As<Vector2>();

    public void CalcHeightRange(bool recursive) => Call(_cached_calc_height_range, recursive);

    public void ImportImages(Godot.Collections.Array<Image> images, Vector3 globalPosition, float offset, float scale) => Call(_cached_import_images, images, globalPosition, offset, scale);

    public int ExportImage(string fileName, int mapType) => Call(_cached_export_image, fileName, mapType).As<int>();

    public Image LayeredToImage(int mapType) => GDExtensionHelper.Bind<Image>(Call(_cached_layered_to_image, mapType).As<GodotObject>());

#endregion

    private static readonly StringName _cached_region_locations = "region_locations";
    private static readonly StringName _cached_height_maps = "height_maps";
    private static readonly StringName _cached_control_maps = "control_maps";
    private static readonly StringName _cached_color_maps = "color_maps";
    private static readonly StringName _cached_get_region_count = "get_region_count";
    private static readonly StringName _cached_set_region_locations = "set_region_locations";
    private static readonly StringName _cached_get_region_locations = "get_region_locations";
    private static readonly StringName _cached_get_regions_active = "get_regions_active";
    private static readonly StringName _cached_get_regions_all = "get_regions_all";
    private static readonly StringName _cached_get_region_map = "get_region_map";
    private static readonly StringName _cached_get_region_map_index = "get_region_map_index";
    private static readonly StringName _cached_do_for_regions = "do_for_regions";
    private static readonly StringName _cached_change_region_size = "change_region_size";
    private static readonly StringName _cached_get_region_location = "get_region_location";
    private static readonly StringName _cached_get_region_id = "get_region_id";
    private static readonly StringName _cached_get_region_idp = "get_region_idp";
    private static readonly StringName _cached_has_region = "has_region";
    private static readonly StringName _cached_has_regionp = "has_regionp";
    private static readonly StringName _cached_get_region = "get_region";
    private static readonly StringName _cached_get_regionp = "get_regionp";
    private static readonly StringName _cached_set_region_modified = "set_region_modified";
    private static readonly StringName _cached_is_region_modified = "is_region_modified";
    private static readonly StringName _cached_set_region_deleted = "set_region_deleted";
    private static readonly StringName _cached_is_region_deleted = "is_region_deleted";
    private static readonly StringName _cached_add_region_blankp = "add_region_blankp";
    private static readonly StringName _cached_add_region_blank = "add_region_blank";
    private static readonly StringName _cached_add_region = "add_region";
    private static readonly StringName _cached_remove_regionp = "remove_regionp";
    private static readonly StringName _cached_remove_regionl = "remove_regionl";
    private static readonly StringName _cached_remove_region = "remove_region";
    private static readonly StringName _cached_save_directory = "save_directory";
    private static readonly StringName _cached_save_region = "save_region";
    private static readonly StringName _cached_load_directory = "load_directory";
    private static readonly StringName _cached_load_region = "load_region";
    private static readonly StringName _cached_get_height_maps = "get_height_maps";
    private static readonly StringName _cached_get_control_maps = "get_control_maps";
    private static readonly StringName _cached_get_color_maps = "get_color_maps";
    private static readonly StringName _cached_get_maps = "get_maps";
    private static readonly StringName _cached_update_maps = "update_maps";
    private static readonly StringName _cached_get_height_maps_rid = "get_height_maps_rid";
    private static readonly StringName _cached_get_control_maps_rid = "get_control_maps_rid";
    private static readonly StringName _cached_get_color_maps_rid = "get_color_maps_rid";
    private static readonly StringName _cached_set_pixel = "set_pixel";
    private static readonly StringName _cached_get_pixel = "get_pixel";
    private static readonly StringName _cached_set_height = "set_height";
    private static readonly StringName _cached_get_height = "get_height";
    private static readonly StringName _cached_set_color = "set_color";
    private static readonly StringName _cached_get_color = "get_color";
    private static readonly StringName _cached_set_control = "set_control";
    private static readonly StringName _cached_get_control = "get_control";
    private static readonly StringName _cached_set_roughness = "set_roughness";
    private static readonly StringName _cached_get_roughness = "get_roughness";
    private static readonly StringName _cached_set_control_base_id = "set_control_base_id";
    private static readonly StringName _cached_get_control_base_id = "get_control_base_id";
    private static readonly StringName _cached_set_control_overlay_id = "set_control_overlay_id";
    private static readonly StringName _cached_get_control_overlay_id = "get_control_overlay_id";
    private static readonly StringName _cached_set_control_blend = "set_control_blend";
    private static readonly StringName _cached_get_control_blend = "get_control_blend";
    private static readonly StringName _cached_set_control_angle = "set_control_angle";
    private static readonly StringName _cached_get_control_angle = "get_control_angle";
    private static readonly StringName _cached_set_control_scale = "set_control_scale";
    private static readonly StringName _cached_get_control_scale = "get_control_scale";
    private static readonly StringName _cached_set_control_hole = "set_control_hole";
    private static readonly StringName _cached_get_control_hole = "get_control_hole";
    private static readonly StringName _cached_set_control_navigation = "set_control_navigation";
    private static readonly StringName _cached_get_control_navigation = "get_control_navigation";
    private static readonly StringName _cached_set_control_auto = "set_control_auto";
    private static readonly StringName _cached_get_control_auto = "get_control_auto";
    private static readonly StringName _cached_get_normal = "get_normal";
    private static readonly StringName _cached_is_in_slope = "is_in_slope";
    private static readonly StringName _cached_get_texture_id = "get_texture_id";
    private static readonly StringName _cached_get_mesh_vertex = "get_mesh_vertex";
    private static readonly StringName _cached_get_height_range = "get_height_range";
    private static readonly StringName _cached_calc_height_range = "calc_height_range";
    private static readonly StringName _cached_import_images = "import_images";
    private static readonly StringName _cached_export_image = "export_image";
    private static readonly StringName _cached_layered_to_image = "layered_to_image";
    private static readonly StringName _cached_maps_changed = "maps_changed";
    private static readonly StringName _cached_region_map_changed = "region_map_changed";
    private static readonly StringName _cached_height_maps_changed = "height_maps_changed";
    private static readonly StringName _cached_control_maps_changed = "control_maps_changed";
    private static readonly StringName _cached_color_maps_changed = "color_maps_changed";
    private static readonly StringName _cached_maps_edited = "maps_edited";
}