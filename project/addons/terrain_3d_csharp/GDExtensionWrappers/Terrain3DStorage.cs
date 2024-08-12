using System;
using Godot;
using Godot.Collections;

namespace GDExtension.Wrappers;

[Tool]
public partial class Terrain3DStorage : Resource
{
    public static readonly StringName GDExtensionName = "Terrain3DStorage";
    private static readonly StringName region_size_name = "region_size";
    private static readonly StringName height_range_name = "height_range";
    private static readonly StringName color_maps_name = "color_maps";
    private static readonly StringName region_offsets_name = "region_offsets";
    private static readonly StringName control_maps_name = "control_maps";
    private static readonly StringName height_maps_name = "height_maps";
    private static readonly StringName set_height_name = "set_height";
    private static readonly StringName get_control_name = "get_control";
    private static readonly StringName set_control_name = "set_control";
    private static readonly StringName force_update_maps_name = "force_update_maps";
    private static readonly StringName save_16_bit_name = "save_16_bit";
    private static readonly StringName version_name = "version";
    private static readonly StringName add_region_name = "add_region";
    private static readonly StringName export_image_name = "export_image";
    private static readonly StringName get_color_name = "get_color";
    private static readonly StringName get_height_name = "get_height";
    private static readonly StringName get_map_region_name = "get_map_region";
    private static readonly StringName get_maps_name = "get_maps";
    private static readonly StringName get_maps_copy_name = "get_maps_copy";
    private static readonly StringName get_mesh_vertex_name = "get_mesh_vertex";
    private static readonly StringName get_normal_name = "get_normal";
    private static readonly StringName get_pixel_name = "get_pixel";
    private static readonly StringName get_region_count_name = "get_region_count";
    private static readonly StringName get_region_index_name = "get_region_index";
    private static readonly StringName get_region_offset_name = "get_region_offset";
    private static readonly StringName get_roughness_name = "get_roughness";
    private static readonly StringName get_texture_id_name = "get_texture_id";
    private static readonly StringName has_region_name = "has_region";
    private static readonly StringName import_images_name = "import_images";
    private static readonly StringName layered_to_image_name = "layered_to_image";
    private static readonly StringName remove_region_name = "remove_region";
    private static readonly StringName save_name = "save";
    private static readonly StringName set_color_name = "set_color";
    private static readonly StringName set_map_region_name = "set_map_region";
    private static readonly StringName set_maps_name = "set_maps";
    private static readonly StringName set_pixel_name = "set_pixel";
    private static readonly StringName set_roughness_name = "set_roughness";
    private static readonly StringName update_height_range_name = "update_height_range";
    private static readonly StringName multimeshes_name = "multimeshes";
    private static readonly StringName height_maps_changed_name = "height_maps_changed";
    private static readonly StringName region_size_changed_name = "region_size_changed";
    private static readonly StringName regions_changed_name = "regions_changed";
    private static readonly StringName maps_edited_name = "maps_edited";
    private static readonly StringName multimeshes_changed_name = "multimeshes_changed";
    private static readonly StringName get_region_offset_from_index_name = "get_region_offset_from_index";
    private static readonly StringName get_region_index_from_offset_name = "get_region_index_from_offset";
    private static readonly StringName get_angle_name = "get_angle";
    private static readonly StringName get_scale_name = "get_scale";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying Resource), please use the Instantiate() method instead.")]
    protected Terrain3DStorage()
    {
    }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DStorage"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DStorage Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DStorage>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DStorage"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DStorage"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DStorage"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DStorage"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DStorage Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DStorage>(godotObject);
    }

    #region Enums

    public enum MapType : long
    {
        TypeHeight = 0,
        TypeControl = 1,
        TypeColor = 2,
        TypeMax = 3,
    }

    public enum RegionSizeEnum : long
    {
        Size1024 = 1024,
    }

    public enum HeightFilter : long
    {
        Nearest = 0,
        Minimum = 1,
    }

    #endregion

    #region Properties

    public float Version
    {
        get => (float)Get(version_name);
        set => Set(version_name, Variant.From(value));
    }

    public RegionSizeEnum RegionSize
    {
        get => (RegionSizeEnum)Get(region_size_name).As<Int64>();
        set => Set(region_size_name, Variant.From(value));
    }

    public bool Save16Bit
    {
        get => (bool)Get(save_16_bit_name);
        set => Set(save_16_bit_name, Variant.From(value));
    }

    public Vector2 HeightRange
    {
        get => (Vector2)Get(height_range_name);
        set => Set(height_range_name, Variant.From(value));
    }

    public Array<Vector2I> RegionOffsets
    {
        get => (Array<Vector2I>)Get(region_offsets_name);
        set => Set(region_offsets_name, Variant.From(value));
    }

    public Array<Image> HeightMaps
    {
        get => (Array<Image>)Get(height_maps_name);
        set => Set(height_maps_name, Variant.From(value));
    }

    public Array<Image> ControlMaps
    {
        get => (Array<Image>)Get(control_maps_name);
        set => Set(control_maps_name, Variant.From(value));
    }

    public Array<Image> ColorMaps
    {
        get => (Array<Image>)Get(color_maps_name);
        set => Set(color_maps_name, Variant.From(value));
    }

    public Dictionary Multimeshes
    {
        get => (Dictionary)Get(multimeshes_name);
        set => Set(multimeshes_name, Variant.From(value));
    }

    #endregion

    #region Signals

    public delegate void HeightMapsChangedHandler();

    private HeightMapsChangedHandler? _heightMapsChanged_backing;
    private Callable _heightMapsChanged_backing_callable;

    public event HeightMapsChangedHandler HeightMapsChanged
    {
        add
        {
            if (_heightMapsChanged_backing == null)
            {
                _heightMapsChanged_backing_callable = Callable.From(
                    () => { _heightMapsChanged_backing?.Invoke(); }
                );
                Connect(height_maps_changed_name, _heightMapsChanged_backing_callable);
            }

            _heightMapsChanged_backing += value;
        }
        remove
        {
            _heightMapsChanged_backing -= value;

            if (_heightMapsChanged_backing == null)
            {
                Disconnect(height_maps_changed_name, _heightMapsChanged_backing_callable);
                _heightMapsChanged_backing_callable = default;
            }
        }
    }


    public delegate void RegionSizeChangedHandler();

    private RegionSizeChangedHandler? _regionSizeChanged_backing;
    private Callable _regionSizeChanged_backing_callable;

    public event RegionSizeChangedHandler RegionSizeChanged
    {
        add
        {
            if (_regionSizeChanged_backing == null)
            {
                _regionSizeChanged_backing_callable = Callable.From(
                    () => { _regionSizeChanged_backing?.Invoke(); }
                );
                Connect(region_size_changed_name, _regionSizeChanged_backing_callable);
            }

            _regionSizeChanged_backing += value;
        }
        remove
        {
            _regionSizeChanged_backing -= value;

            if (_regionSizeChanged_backing == null)
            {
                Disconnect(region_size_changed_name, _regionSizeChanged_backing_callable);
                _regionSizeChanged_backing_callable = default;
            }
        }
    }


    public delegate void RegionsChangedHandler();

    private RegionsChangedHandler? _regionsChanged_backing;
    private Callable _regionsChanged_backing_callable;

    public event RegionsChangedHandler RegionsChanged
    {
        add
        {
            if (_regionsChanged_backing == null)
            {
                _regionsChanged_backing_callable = Callable.From(
                    () => { _regionsChanged_backing?.Invoke(); }
                );
                Connect(regions_changed_name, _regionsChanged_backing_callable);
            }

            _regionsChanged_backing += value;
        }
        remove
        {
            _regionsChanged_backing -= value;

            if (_regionsChanged_backing == null)
            {
                Disconnect(regions_changed_name, _regionsChanged_backing_callable);
                _regionsChanged_backing_callable = default;
            }
        }
    }


    public delegate void MapsEditedHandler(Aabb editedArea);

    private MapsEditedHandler? _mapsEdited_backing;
    private Callable _mapsEdited_backing_callable;

    public event MapsEditedHandler MapsEdited
    {
        add
        {
            if (_mapsEdited_backing == null)
            {
                _mapsEdited_backing_callable = Callable.From<Variant>(
                    (arg0_variant) =>
                    {
                        var arg0 = arg0_variant.As<Aabb>();
                        _mapsEdited_backing?.Invoke(arg0);
                    }
                );
                Connect(maps_edited_name, _mapsEdited_backing_callable);
            }

            _mapsEdited_backing += value;
        }
        remove
        {
            _mapsEdited_backing -= value;

            if (_mapsEdited_backing == null)
            {
                Disconnect(maps_edited_name, _mapsEdited_backing_callable);
                _mapsEdited_backing_callable = default;
            }
        }
    }


    public delegate void MultimeshesChangedHandler();

    private MultimeshesChangedHandler? _multimeshesChanged_backing;
    private Callable _multimeshesChanged_backing_callable;

    public event MultimeshesChangedHandler MultimeshesChanged
    {
        add
        {
            if (_multimeshesChanged_backing == null)
            {
                _multimeshesChanged_backing_callable = Callable.From(
                    () => { _multimeshesChanged_backing?.Invoke(); }
                );
                Connect(multimeshes_changed_name, _multimeshesChanged_backing_callable);
            }

            _multimeshesChanged_backing += value;
        }
        remove
        {
            _multimeshesChanged_backing -= value;

            if (_multimeshesChanged_backing == null)
            {
                Disconnect(multimeshes_changed_name, _multimeshesChanged_backing_callable);
                _multimeshesChanged_backing_callable = default;
            }
        }
    }


    #endregion

    #region Methods

    public void UpdateHeightRange() => Call(update_height_range_name);

    public int GetRegionCount() => Call(get_region_count_name).As<int>();

    public Vector2I GetRegionOffset(Vector3 globalPosition) => Call(get_region_offset_name, globalPosition).As<Vector2I>();

    public Vector2I GetRegionOffsetFromIndex(int regionIndex) => Call(get_region_offset_from_index_name, regionIndex).As<Vector2I>();

    public int GetRegionIndex(Vector3 globalPosition) => Call(get_region_index_name, globalPosition).As<int>();

    public int GetRegionIndexFromOffset(Vector2I regionOffset) => Call(get_region_index_from_offset_name, regionOffset).As<int>();

    public bool HasRegion(Vector3 globalPosition) => Call(has_region_name, globalPosition).As<bool>();

    public Error AddRegion(Vector3 globalPosition, Image[]? images = default, bool update = true)
    {
        images ??= System.Array.Empty<Image>();
        var imageArray = new Array<Image>();
        imageArray.AddRange(images);
        return Call(add_region_name, Variant.From(globalPosition), imageArray, update).As<Error>();
    }

    public void RemoveRegion(Vector3 globalPosition, bool update) => Call(remove_region_name, globalPosition, update);

    public void SetMapRegion(int mapType, int regionIndex, Image image) => Call(set_map_region_name, mapType, regionIndex, image);

    public Image GetMapRegion(int mapType, int regionIndex) => Call(get_map_region_name, mapType, regionIndex).As<Image>();

    public void SetMaps(int mapType, Array<Image> maps) => Call(set_maps_name, mapType, maps);

    public Array<Image> GetMaps(int mapType) => Call(get_maps_name, mapType).As<Array<Image>>();

    public Array<Image> GetMapsCopy(int mapType) => Call(get_maps_copy_name, mapType).As<Array<Image>>();

    public void SetPixel(int mapType, Vector3 globalPosition, Color pixel) => Call(set_pixel_name, mapType, globalPosition, pixel);

    public Color GetPixel(int mapType, Vector3 globalPosition) => Call(get_pixel_name, mapType, globalPosition).As<Color>();

    public void SetHeight(Vector3 globalPosition, float height) => CallDeferred(set_height_name, globalPosition, height);

    public float GetHeight(Vector3 globalPosition) => Call(get_height_name, globalPosition).As<float>();

    public void SetColor(Vector3 globalPosition, Color color) => Call(set_color_name, globalPosition, color);

    public Color GetColor(Vector3 globalPosition) => Call(get_color_name, globalPosition).As<Color>();

    public void SetControl(Vector3 globalPosition, int control) => CallDeferred(set_control_name, globalPosition, control);

    public int GetControl(Vector3 globalPosition) => Call(get_control_name, globalPosition).As<int>();

    public void SetRoughness(Vector3 globalPosition, float roughness) => Call(set_roughness_name, globalPosition, roughness);

    public float GetRoughness(Vector3 globalPosition) => Call(get_roughness_name, globalPosition).As<float>();

    public Vector3 GetTextureId(Vector3 globalPosition) => Call(get_texture_id_name, globalPosition).As<Vector3>();

    public float GetAngle(Vector3 globalPosition) => Call(get_angle_name, globalPosition).As<float>();

    public float GetScale(Vector3 globalPosition) => Call(get_scale_name, globalPosition).As<float>();

    public void ForceUpdateMaps(int mapType) => Call(force_update_maps_name, mapType);

    public void Save() => Call(save_name);

    public void ImportImages(Array<Image> images, Vector3 globalPosition, float offset, float scale) => Call(import_images_name, images, globalPosition, offset, scale);

    public int ExportImage(string fileName, int mapType) => Call(export_image_name, fileName, mapType).As<int>();

    public Image LayeredToImage(int mapType) => Call(layered_to_image_name, mapType).As<Image>();

    public Vector3 GetMeshVertex(int lod, int filter, Vector3 globalPosition) => Call(get_mesh_vertex_name, lod, filter, globalPosition).As<Vector3>();

    public Vector3 GetNormal(Vector3 globalPosition) => Call(get_normal_name, globalPosition).As<Vector3>();

    #endregion
}