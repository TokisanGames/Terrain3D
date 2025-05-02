using System;
using Godot;

namespace TokisanGames;

public partial class Terrain3DUtil : GodotObject
{
    public static readonly StringName GDExtensionName = "Terrain3DUtil";

    [Obsolete("Wrapper classes cannot be constructed with Ctor (it only instantiate the underlying GodotObject), please use the Instantiate() method instead.")]
    protected Terrain3DUtil() { }

    /// <summary>
    /// Creates an instance of the GDExtension <see cref="Terrain3DUtil"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static Terrain3DUtil Instantiate()
    {
        return GDExtensionHelper.Instantiate<Terrain3DUtil>(GDExtensionName);
    }

    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DUtil"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DUtil"/> wrapper type,
    /// a new instance of the <see cref="Terrain3DUtil"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <see cref="Terrain3DUtil"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static Terrain3DUtil Bind(GodotObject godotObject)
    {
        return GDExtensionHelper.Bind<Terrain3DUtil>(godotObject);
    }
#region Methods

    public static float AsFloat(int value) => GDExtensionHelper.Call(GDExtensionName, _cached_as_float, value).As<float>();

    public static int AsUint(float value) => GDExtensionHelper.Call(GDExtensionName, _cached_as_uint, value).As<int>();

    public static int GetBase(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_get_base, pixel).As<int>();

    public static int EncBase(int @base) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_base, @base).As<int>();

    public static int GetOverlay(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_get_overlay, pixel).As<int>();

    public static int EncOverlay(int overlay) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_overlay, overlay).As<int>();

    public static int GetBlend(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_get_blend, pixel).As<int>();

    public static int EncBlend(int blend) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_blend, blend).As<int>();

    public static int GetUvRotation(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_get_uv_rotation, pixel).As<int>();

    public static int EncUvRotation(int rotation) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_uv_rotation, rotation).As<int>();

    public static int GetUvScale(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_get_uv_scale, pixel).As<int>();

    public static int EncUvScale(int scale) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_uv_scale, scale).As<int>();

    public static bool IsHole(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_is_hole, pixel).As<bool>();

    public static int EncHole(bool pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_hole, pixel).As<int>();

    public static bool IsNav(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_is_nav, pixel).As<bool>();

    public static int EncNav(bool pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_nav, pixel).As<int>();

    public static bool IsAuto(int pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_is_auto, pixel).As<bool>();

    public static int EncAuto(bool pixel) => GDExtensionHelper.Call(GDExtensionName, _cached_enc_auto, pixel).As<int>();

    public static Vector2I FilenameToLocation(string filename) => GDExtensionHelper.Call(GDExtensionName, _cached_filename_to_location, filename).As<Vector2I>();

    public static string LocationToFilename(Vector2I regionLocation) => GDExtensionHelper.Call(GDExtensionName, _cached_location_to_filename, regionLocation).As<string>();

    public static Image BlackToAlpha(Image image) => GDExtensionHelper.Bind<Image>(GDExtensionHelper.Call(GDExtensionName, _cached_black_to_alpha, (Image)image).As<GodotObject>());

    public static Vector2 GetMinMax(Image image) => GDExtensionHelper.Call(GDExtensionName, _cached_get_min_max, (Image)image).As<Vector2>();

    public static Image GetThumbnail(Image image, Vector2I size) => GDExtensionHelper.Bind<Image>(GDExtensionHelper.Call(GDExtensionName, _cached_get_thumbnail, (Image)image, size).As<GodotObject>());

    public static Image GetFilledImage(Vector2I size, Color color, bool createMipmaps, int format) => GDExtensionHelper.Bind<Image>(GDExtensionHelper.Call(GDExtensionName, _cached_get_filled_image, size, color, createMipmaps, format).As<GodotObject>());

    public static Image LoadImage(string fileName, int cacheMode, Vector2 r16HeightRange, Vector2I r16Size) => GDExtensionHelper.Bind<Image>(GDExtensionHelper.Call(GDExtensionName, _cached_load_image, fileName, cacheMode, r16HeightRange, r16Size).As<GodotObject>());

    public static Image PackImage(Image srcRgb, Image srcA, bool invertGreen, bool invertAlpha, int alphaChannel) => GDExtensionHelper.Bind<Image>(GDExtensionHelper.Call(GDExtensionName, _cached_pack_image, (Image)srcRgb, (Image)srcA, invertGreen, invertAlpha, alphaChannel).As<GodotObject>());

    public static Image LuminanceToHeight(Image srcRgb) => GDExtensionHelper.Bind<Image>(GDExtensionHelper.Call(GDExtensionName, _cached_luminance_to_height, (Image)srcRgb).As<GodotObject>());

#endregion

    private static readonly StringName _cached_as_float = "as_float";
    private static readonly StringName _cached_as_uint = "as_uint";
    private static readonly StringName _cached_get_base = "get_base";
    private static readonly StringName _cached_enc_base = "enc_base";
    private static readonly StringName _cached_get_overlay = "get_overlay";
    private static readonly StringName _cached_enc_overlay = "enc_overlay";
    private static readonly StringName _cached_get_blend = "get_blend";
    private static readonly StringName _cached_enc_blend = "enc_blend";
    private static readonly StringName _cached_get_uv_rotation = "get_uv_rotation";
    private static readonly StringName _cached_enc_uv_rotation = "enc_uv_rotation";
    private static readonly StringName _cached_get_uv_scale = "get_uv_scale";
    private static readonly StringName _cached_enc_uv_scale = "enc_uv_scale";
    private static readonly StringName _cached_is_hole = "is_hole";
    private static readonly StringName _cached_enc_hole = "enc_hole";
    private static readonly StringName _cached_is_nav = "is_nav";
    private static readonly StringName _cached_enc_nav = "enc_nav";
    private static readonly StringName _cached_is_auto = "is_auto";
    private static readonly StringName _cached_enc_auto = "enc_auto";
    private static readonly StringName _cached_filename_to_location = "filename_to_location";
    private static readonly StringName _cached_location_to_filename = "location_to_filename";
    private static readonly StringName _cached_black_to_alpha = "black_to_alpha";
    private static readonly StringName _cached_get_min_max = "get_min_max";
    private static readonly StringName _cached_get_thumbnail = "get_thumbnail";
    private static readonly StringName _cached_get_filled_image = "get_filled_image";
    private static readonly StringName _cached_load_image = "load_image";
    private static readonly StringName _cached_pack_image = "pack_image";
    private static readonly StringName _cached_luminance_to_height = "luminance_to_height";
}