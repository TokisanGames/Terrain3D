using System;
using Godot;

namespace GDExtension.Wrappers;

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

    public static float AsFloat(int value) => GDExtensionHelper.Call("Terrain3DUtil", "as_float", value).As<float>();

    public static int AsUint(float value) => GDExtensionHelper.Call("Terrain3DUtil", "as_uint", value).As<int>();

    public static int GetBase(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "get_base", pixel).As<int>();

    public static int EncBase(int @base) => GDExtensionHelper.Call("Terrain3DUtil", "enc_base", @base).As<int>();

    public static int GetOverlay(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "get_overlay", pixel).As<int>();

    public static int EncOverlay(int overlay) => GDExtensionHelper.Call("Terrain3DUtil", "enc_overlay", overlay).As<int>();

    public static int GetBlend(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "get_blend", pixel).As<int>();

    public static int EncBlend(int blend) => GDExtensionHelper.Call("Terrain3DUtil", "enc_blend", blend).As<int>();

    public static bool IsHole(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "is_hole", pixel).As<bool>();

    public static int EncHole(bool pixel) => GDExtensionHelper.Call("Terrain3DUtil", "enc_hole", pixel).As<int>();

    public static bool IsNav(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "is_nav", pixel).As<bool>();

    public static int EncNav(bool pixel) => GDExtensionHelper.Call("Terrain3DUtil", "enc_nav", pixel).As<int>();

    public static bool IsAuto(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "is_auto", pixel).As<bool>();

    public static int EncAuto(bool pixel) => GDExtensionHelper.Call("Terrain3DUtil", "enc_auto", pixel).As<int>();

    public static int GetUvRotation(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "get_uv_rotation", pixel).As<int>();

    public static int EncUvRotation(int rotation) => GDExtensionHelper.Call("Terrain3DUtil", "enc_uv_rotation", rotation).As<int>();

    public static int GetUvScale(int pixel) => GDExtensionHelper.Call("Terrain3DUtil", "get_uv_scale", pixel).As<int>();

    public static int EncUvScale(int scale) => GDExtensionHelper.Call("Terrain3DUtil", "enc_uv_scale", scale).As<int>();

    public static Image BlackToAlpha(Image image) => GDExtensionHelper.Call("Terrain3DUtil", "black_to_alpha", image).As<Image>();

    public static Vector2 GetMinMax(Image image) => GDExtensionHelper.Call("Terrain3DUtil", "get_min_max", image).As<Vector2>();

    public static Image GetThumbnail(Image image, Vector2I size) => GDExtensionHelper.Call("Terrain3DUtil", "get_thumbnail", image, size).As<Image>();

    public static Image GetFilledImage(Vector2I size, Color color, bool createMipmaps, int format) => GDExtensionHelper.Call("Terrain3DUtil", "get_filled_image", size, color, createMipmaps, format).As<Image>();

    public static Image LoadImage(string fileName, int cacheMode, Vector2 r16HeightRange, Vector2I r16Size) => GDExtensionHelper.Call("Terrain3DUtil", "load_image", fileName, cacheMode, r16HeightRange, r16Size).As<Image>();

    public static Image PackImage(Image srcRgb, Image srcR, bool invertGreenChannel) => GDExtensionHelper.Call("Terrain3DUtil", "pack_image", srcRgb, srcR, invertGreenChannel).As<Image>();

#endregion

}