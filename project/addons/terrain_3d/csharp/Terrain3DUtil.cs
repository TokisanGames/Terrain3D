#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DUtil : GodotObject
{

	private new static readonly StringName NativeName = new StringName("Terrain3DUtil");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DUtil object), please use the Instantiate() method instead.")]
	protected Terrain3DUtil() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DUtil"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DUtil"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DUtil"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DUtil"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DUtil Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DUtil wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DUtil);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DUtil).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DUtil)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DUtil"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DUtil" type.</returns>
	public new static Terrain3DUtil Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName AsFloat = "as_float";
		public new static readonly StringName AsUint = "as_uint";
		public new static readonly StringName GetBase = "get_base";
		public new static readonly StringName EncBase = "enc_base";
		public new static readonly StringName GetOverlay = "get_overlay";
		public new static readonly StringName EncOverlay = "enc_overlay";
		public new static readonly StringName GetBlend = "get_blend";
		public new static readonly StringName EncBlend = "enc_blend";
		public new static readonly StringName GetUvRotation = "get_uv_rotation";
		public new static readonly StringName EncUvRotation = "enc_uv_rotation";
		public new static readonly StringName GetUvScale = "get_uv_scale";
		public new static readonly StringName EncUvScale = "enc_uv_scale";
		public new static readonly StringName IsHole = "is_hole";
		public new static readonly StringName EncHole = "enc_hole";
		public new static readonly StringName IsNav = "is_nav";
		public new static readonly StringName EncNav = "enc_nav";
		public new static readonly StringName IsAuto = "is_auto";
		public new static readonly StringName EncAuto = "enc_auto";
		public new static readonly StringName FilenameToLocation = "filename_to_location";
		public new static readonly StringName LocationToFilename = "location_to_filename";
		public new static readonly StringName BlackToAlpha = "black_to_alpha";
		public new static readonly StringName GetMinMax = "get_min_max";
		public new static readonly StringName GetThumbnail = "get_thumbnail";
		public new static readonly StringName GetFilledImage = "get_filled_image";
		public new static readonly StringName LoadImage = "load_image";
		public new static readonly StringName PackImage = "pack_image";
		public new static readonly StringName LuminanceToHeight = "luminance_to_height";
	}

	public new static double AsFloat(long value) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.AsFloat, [value]).As<double>();

	public new static long AsUint(double value) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.AsUint, [value]).As<long>();

	public new static long GetBase(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetBase, [pixel]).As<long>();

	public new static long EncBase(long @base) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncBase, [@base]).As<long>();

	public new static long GetOverlay(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetOverlay, [pixel]).As<long>();

	public new static long EncOverlay(long overlay) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncOverlay, [overlay]).As<long>();

	public new static long GetBlend(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetBlend, [pixel]).As<long>();

	public new static long EncBlend(long blend) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncBlend, [blend]).As<long>();

	public new static long GetUvRotation(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetUvRotation, [pixel]).As<long>();

	public new static long EncUvRotation(long rotation) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncUvRotation, [rotation]).As<long>();

	public new static long GetUvScale(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetUvScale, [pixel]).As<long>();

	public new static long EncUvScale(long scale) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncUvScale, [scale]).As<long>();

	public new static bool IsHole(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.IsHole, [pixel]).As<bool>();

	public new static long EncHole(bool pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncHole, [pixel]).As<long>();

	public new static bool IsNav(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.IsNav, [pixel]).As<bool>();

	public new static long EncNav(bool pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncNav, [pixel]).As<long>();

	public new static bool IsAuto(long pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.IsAuto, [pixel]).As<bool>();

	public new static long EncAuto(bool pixel) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.EncAuto, [pixel]).As<long>();

	public new static Vector2I FilenameToLocation(string filename) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.FilenameToLocation, [filename]).As<Vector2I>();

	public new static string LocationToFilename(Vector2I regionLocation) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.LocationToFilename, [regionLocation]).As<string>();

	public new static Image BlackToAlpha(Image image) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.BlackToAlpha, [image]).As<Image>();

	public new static Vector2 GetMinMax(Image image) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetMinMax, [image]).As<Vector2>();

	public new static Image GetThumbnail(Image image, Vector2I size = default) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetThumbnail, [image, size]).As<Image>();

	public new static Image GetFilledImage(Vector2I size, Color color, bool createMipmaps, Image.Format format) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetFilledImage, [size, color, createMipmaps, Variant.From(format)]).As<Image>();

	public new static Image LoadImage(string fileName, long cacheMode = 0, Vector2 r16HeightRange = default, Vector2I r16Size = default) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.LoadImage, [fileName, cacheMode, r16HeightRange, r16Size]).As<Image>();

	public new static Image PackImage(Image srcRgb, Image srcA, Image srcAo, bool invertGreen = false, bool invertAlpha = false, bool normalizeAlpha = false, long alphaChannel = 0, long aoChannel = 0) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.PackImage, [srcRgb, srcA, srcAo, invertGreen, invertAlpha, normalizeAlpha, alphaChannel, aoChannel]).As<Image>();

	public new static Image LuminanceToHeight(Image srcRgb) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.LuminanceToHeight, [srcRgb]).As<Image>();

}
