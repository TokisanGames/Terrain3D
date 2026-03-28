#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DMaterial : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DMaterial");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DMaterial object), please use the Instantiate() method instead.")]
	protected Terrain3DMaterial() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DMaterial"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DMaterial"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DMaterial"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DMaterial"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DMaterial Bind(GodotObject godotObject)
	{
		if (!IsInstanceValid(godotObject))
			return null;

		if (godotObject is Terrain3DMaterial wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DMaterial);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DMaterial).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DMaterial)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DMaterial"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DMaterial" type.</returns>
	public new static Terrain3DMaterial Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum WorldBackgroundEnum
	{
		None = 0,
		Flat = 1,
		Noise = 2,
	}

	public enum TextureFilteringEnum
	{
		LinearAnisotropic = 0,
		Linear = 1,
		NearestAnisotropic = 2,
		Nearest = 3,
	}

	public enum UpdateFlags
	{
		UniformsOnly = 0,
		TextureArrays = 1,
		RegionArrays = 2,
		Arrays = 3,
		FullRebuild = 7,
	}

	public new class GDExtensionSignalName : Resource.SignalName
	{
	}

	public new class GDExtensionPropertyName : Resource.PropertyName
	{
		/// <summary>
		/// Cached name for the 'world_background' member.
		/// </summary>
		public new static readonly StringName WorldBackground = "world_background";
		/// <summary>
		/// Cached name for the 'texture_filtering' member.
		/// </summary>
		public new static readonly StringName TextureFiltering = "texture_filtering";
		/// <summary>
		/// Cached name for the 'auto_shader_enabled' member.
		/// </summary>
		public new static readonly StringName AutoShaderEnabled = "auto_shader_enabled";
		/// <summary>
		/// Cached name for the 'dual_scaling_enabled' member.
		/// </summary>
		public new static readonly StringName DualScalingEnabled = "dual_scaling_enabled";
		/// <summary>
		/// Cached name for the 'macro_variation_enabled' member.
		/// </summary>
		public new static readonly StringName MacroVariationEnabled = "macro_variation_enabled";
		/// <summary>
		/// Cached name for the 'projection_enabled' member.
		/// </summary>
		public new static readonly StringName ProjectionEnabled = "projection_enabled";
		/// <summary>
		/// Cached name for the 'output_albedo' member.
		/// </summary>
		public new static readonly StringName OutputAlbedo = "output_albedo";
		/// <summary>
		/// Cached name for the 'output_roughness' member.
		/// </summary>
		public new static readonly StringName OutputRoughness = "output_roughness";
		/// <summary>
		/// Cached name for the 'output_normal_map' member.
		/// </summary>
		public new static readonly StringName OutputNormalMap = "output_normal_map";
		/// <summary>
		/// Cached name for the 'output_ambient_occlusion' member.
		/// </summary>
		public new static readonly StringName OutputAmbientOcclusion = "output_ambient_occlusion";
		/// <summary>
		/// Cached name for the 'shader_override_enabled' member.
		/// </summary>
		public new static readonly StringName ShaderOverrideEnabled = "shader_override_enabled";
		/// <summary>
		/// Cached name for the 'shader_override' member.
		/// </summary>
		public new static readonly StringName ShaderOverride = "shader_override";
		/// <summary>
		/// Cached name for the 'show_region_grid' member.
		/// </summary>
		public new static readonly StringName ShowRegionGrid = "show_region_grid";
		/// <summary>
		/// Cached name for the 'show_instancer_grid' member.
		/// </summary>
		public new static readonly StringName ShowInstancerGrid = "show_instancer_grid";
		/// <summary>
		/// Cached name for the 'show_vertex_grid' member.
		/// </summary>
		public new static readonly StringName ShowVertexGrid = "show_vertex_grid";
		/// <summary>
		/// Cached name for the 'show_contours' member.
		/// </summary>
		public new static readonly StringName ShowContours = "show_contours";
		/// <summary>
		/// Cached name for the 'show_navigation' member.
		/// </summary>
		public new static readonly StringName ShowNavigation = "show_navigation";
		/// <summary>
		/// Cached name for the 'displacement_scale' member.
		/// </summary>
		public new static readonly StringName DisplacementScale = "displacement_scale";
		/// <summary>
		/// Cached name for the 'displacement_sharpness' member.
		/// </summary>
		public new static readonly StringName DisplacementSharpness = "displacement_sharpness";
		/// <summary>
		/// Cached name for the 'buffer_shader_override_enabled' member.
		/// </summary>
		public new static readonly StringName BufferShaderOverrideEnabled = "buffer_shader_override_enabled";
		/// <summary>
		/// Cached name for the 'buffer_shader_override' member.
		/// </summary>
		public new static readonly StringName BufferShaderOverride = "buffer_shader_override";
		/// <summary>
		/// Cached name for the 'show_checkered' member.
		/// </summary>
		public new static readonly StringName ShowCheckered = "show_checkered";
		/// <summary>
		/// Cached name for the 'show_grey' member.
		/// </summary>
		public new static readonly StringName ShowGrey = "show_grey";
		/// <summary>
		/// Cached name for the 'show_heightmap' member.
		/// </summary>
		public new static readonly StringName ShowHeightmap = "show_heightmap";
		/// <summary>
		/// Cached name for the 'show_jaggedness' member.
		/// </summary>
		public new static readonly StringName ShowJaggedness = "show_jaggedness";
		/// <summary>
		/// Cached name for the 'show_autoshader' member.
		/// </summary>
		public new static readonly StringName ShowAutoshader = "show_autoshader";
		/// <summary>
		/// Cached name for the 'show_control_texture' member.
		/// </summary>
		public new static readonly StringName ShowControlTexture = "show_control_texture";
		/// <summary>
		/// Cached name for the 'show_control_blend' member.
		/// </summary>
		public new static readonly StringName ShowControlBlend = "show_control_blend";
		/// <summary>
		/// Cached name for the 'show_control_angle' member.
		/// </summary>
		public new static readonly StringName ShowControlAngle = "show_control_angle";
		/// <summary>
		/// Cached name for the 'show_control_scale' member.
		/// </summary>
		public new static readonly StringName ShowControlScale = "show_control_scale";
		/// <summary>
		/// Cached name for the 'show_colormap' member.
		/// </summary>
		public new static readonly StringName ShowColormap = "show_colormap";
		/// <summary>
		/// Cached name for the 'show_roughmap' member.
		/// </summary>
		public new static readonly StringName ShowRoughmap = "show_roughmap";
		/// <summary>
		/// Cached name for the 'show_texture_albedo' member.
		/// </summary>
		public new static readonly StringName ShowTextureAlbedo = "show_texture_albedo";
		/// <summary>
		/// Cached name for the 'show_texture_height' member.
		/// </summary>
		public new static readonly StringName ShowTextureHeight = "show_texture_height";
		/// <summary>
		/// Cached name for the 'show_texture_normal' member.
		/// </summary>
		public new static readonly StringName ShowTextureNormal = "show_texture_normal";
		/// <summary>
		/// Cached name for the 'show_texture_ao' member.
		/// </summary>
		public new static readonly StringName ShowTextureAo = "show_texture_ao";
		/// <summary>
		/// Cached name for the 'show_texture_rough' member.
		/// </summary>
		public new static readonly StringName ShowTextureRough = "show_texture_rough";
		/// <summary>
		/// Cached name for the 'show_displacement_buffer' member.
		/// </summary>
		public new static readonly StringName ShowDisplacementBuffer = "show_displacement_buffer";
	}

	public new Terrain3DMaterial.WorldBackgroundEnum WorldBackground
	{
		get => Get(GDExtensionPropertyName.WorldBackground).As<Terrain3DMaterial.WorldBackgroundEnum>();
		set => Set(GDExtensionPropertyName.WorldBackground, Variant.From(value));
	}

	public new Terrain3DMaterial.TextureFilteringEnum TextureFiltering
	{
		get => Get(GDExtensionPropertyName.TextureFiltering).As<Terrain3DMaterial.TextureFilteringEnum>();
		set => Set(GDExtensionPropertyName.TextureFiltering, Variant.From(value));
	}

	public new bool AutoShaderEnabled
	{
		get => Get(GDExtensionPropertyName.AutoShaderEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.AutoShaderEnabled, value);
	}

	public new bool DualScalingEnabled
	{
		get => Get(GDExtensionPropertyName.DualScalingEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.DualScalingEnabled, value);
	}

	public new bool MacroVariationEnabled
	{
		get => Get(GDExtensionPropertyName.MacroVariationEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.MacroVariationEnabled, value);
	}

	public new bool ProjectionEnabled
	{
		get => Get(GDExtensionPropertyName.ProjectionEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.ProjectionEnabled, value);
	}

	public new bool OutputAlbedo
	{
		get => Get(GDExtensionPropertyName.OutputAlbedo).As<bool>();
		set => Set(GDExtensionPropertyName.OutputAlbedo, value);
	}

	public new bool OutputRoughness
	{
		get => Get(GDExtensionPropertyName.OutputRoughness).As<bool>();
		set => Set(GDExtensionPropertyName.OutputRoughness, value);
	}

	public new bool OutputNormalMap
	{
		get => Get(GDExtensionPropertyName.OutputNormalMap).As<bool>();
		set => Set(GDExtensionPropertyName.OutputNormalMap, value);
	}

	public new bool OutputAmbientOcclusion
	{
		get => Get(GDExtensionPropertyName.OutputAmbientOcclusion).As<bool>();
		set => Set(GDExtensionPropertyName.OutputAmbientOcclusion, value);
	}

	public new bool ShaderOverrideEnabled
	{
		get => Get(GDExtensionPropertyName.ShaderOverrideEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.ShaderOverrideEnabled, value);
	}

	public new Shader ShaderOverride
	{
		get => Get(GDExtensionPropertyName.ShaderOverride).As<Shader>();
		set => Set(GDExtensionPropertyName.ShaderOverride, value);
	}

	public new bool ShowRegionGrid
	{
		get => Get(GDExtensionPropertyName.ShowRegionGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowRegionGrid, value);
	}

	public new bool ShowInstancerGrid
	{
		get => Get(GDExtensionPropertyName.ShowInstancerGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowInstancerGrid, value);
	}

	public new bool ShowVertexGrid
	{
		get => Get(GDExtensionPropertyName.ShowVertexGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowVertexGrid, value);
	}

	public new bool ShowContours
	{
		get => Get(GDExtensionPropertyName.ShowContours).As<bool>();
		set => Set(GDExtensionPropertyName.ShowContours, value);
	}

	public new bool ShowNavigation
	{
		get => Get(GDExtensionPropertyName.ShowNavigation).As<bool>();
		set => Set(GDExtensionPropertyName.ShowNavigation, value);
	}

	public new double DisplacementScale
	{
		get => Get(GDExtensionPropertyName.DisplacementScale).As<double>();
		set => Set(GDExtensionPropertyName.DisplacementScale, value);
	}

	public new double DisplacementSharpness
	{
		get => Get(GDExtensionPropertyName.DisplacementSharpness).As<double>();
		set => Set(GDExtensionPropertyName.DisplacementSharpness, value);
	}

	public new bool BufferShaderOverrideEnabled
	{
		get => Get(GDExtensionPropertyName.BufferShaderOverrideEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.BufferShaderOverrideEnabled, value);
	}

	public new Shader BufferShaderOverride
	{
		get => Get(GDExtensionPropertyName.BufferShaderOverride).As<Shader>();
		set => Set(GDExtensionPropertyName.BufferShaderOverride, value);
	}

	public new bool ShowCheckered
	{
		get => Get(GDExtensionPropertyName.ShowCheckered).As<bool>();
		set => Set(GDExtensionPropertyName.ShowCheckered, value);
	}

	public new bool ShowGrey
	{
		get => Get(GDExtensionPropertyName.ShowGrey).As<bool>();
		set => Set(GDExtensionPropertyName.ShowGrey, value);
	}

	public new bool ShowHeightmap
	{
		get => Get(GDExtensionPropertyName.ShowHeightmap).As<bool>();
		set => Set(GDExtensionPropertyName.ShowHeightmap, value);
	}

	public new bool ShowJaggedness
	{
		get => Get(GDExtensionPropertyName.ShowJaggedness).As<bool>();
		set => Set(GDExtensionPropertyName.ShowJaggedness, value);
	}

	public new bool ShowAutoshader
	{
		get => Get(GDExtensionPropertyName.ShowAutoshader).As<bool>();
		set => Set(GDExtensionPropertyName.ShowAutoshader, value);
	}

	public new bool ShowControlTexture
	{
		get => Get(GDExtensionPropertyName.ShowControlTexture).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlTexture, value);
	}

	public new bool ShowControlBlend
	{
		get => Get(GDExtensionPropertyName.ShowControlBlend).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlBlend, value);
	}

	public new bool ShowControlAngle
	{
		get => Get(GDExtensionPropertyName.ShowControlAngle).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlAngle, value);
	}

	public new bool ShowControlScale
	{
		get => Get(GDExtensionPropertyName.ShowControlScale).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlScale, value);
	}

	public new bool ShowColormap
	{
		get => Get(GDExtensionPropertyName.ShowColormap).As<bool>();
		set => Set(GDExtensionPropertyName.ShowColormap, value);
	}

	public new bool ShowRoughmap
	{
		get => Get(GDExtensionPropertyName.ShowRoughmap).As<bool>();
		set => Set(GDExtensionPropertyName.ShowRoughmap, value);
	}

	public new bool ShowTextureAlbedo
	{
		get => Get(GDExtensionPropertyName.ShowTextureAlbedo).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureAlbedo, value);
	}

	public new bool ShowTextureHeight
	{
		get => Get(GDExtensionPropertyName.ShowTextureHeight).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureHeight, value);
	}

	public new bool ShowTextureNormal
	{
		get => Get(GDExtensionPropertyName.ShowTextureNormal).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureNormal, value);
	}

	public new bool ShowTextureAo
	{
		get => Get(GDExtensionPropertyName.ShowTextureAo).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureAo, value);
	}

	public new bool ShowTextureRough
	{
		get => Get(GDExtensionPropertyName.ShowTextureRough).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureRough, value);
	}

	public new bool ShowDisplacementBuffer
	{
		get => Get(GDExtensionPropertyName.ShowDisplacementBuffer).As<bool>();
		set => Set(GDExtensionPropertyName.ShowDisplacementBuffer, value);
	}

	public new class GDExtensionMethodName : Resource.MethodName
	{
		/// <summary>
		/// Cached name for the 'update' member.
		/// </summary>
		public new static readonly StringName Update = "update";
		/// <summary>
		/// Cached name for the 'get_material_rid' member.
		/// </summary>
		public new static readonly StringName GetMaterialRid = "get_material_rid";
		/// <summary>
		/// Cached name for the 'get_shader_rid' member.
		/// </summary>
		public new static readonly StringName GetShaderRid = "get_shader_rid";
		/// <summary>
		/// Cached name for the 'get_buffer_material_rid' member.
		/// </summary>
		public new static readonly StringName GetBufferMaterialRid = "get_buffer_material_rid";
		/// <summary>
		/// Cached name for the 'get_buffer_shader_rid' member.
		/// </summary>
		public new static readonly StringName GetBufferShaderRid = "get_buffer_shader_rid";
		/// <summary>
		/// Cached name for the 'set_shader_param' member.
		/// </summary>
		public new static readonly StringName SetShaderParam = "set_shader_param";
		/// <summary>
		/// Cached name for the 'get_shader_param' member.
		/// </summary>
		public new static readonly StringName GetShaderParam = "get_shader_param";
		/// <summary>
		/// Cached name for the 'save' member.
		/// </summary>
		public new static readonly StringName Save = "save";
	}

	public new void Update(long flags = 0) => 
		Call(GDExtensionMethodName.Update, [flags]);

	public new Rid GetMaterialRid() => 
		Call(GDExtensionMethodName.GetMaterialRid, []).As<Rid>();

	public new Rid GetShaderRid() => 
		Call(GDExtensionMethodName.GetShaderRid, []).As<Rid>();

	public new Rid GetBufferMaterialRid() => 
		Call(GDExtensionMethodName.GetBufferMaterialRid, []).As<Rid>();

	public new Rid GetBufferShaderRid() => 
		Call(GDExtensionMethodName.GetBufferShaderRid, []).As<Rid>();

	public new void SetShaderParam(StringName name, Variant value) => 
		Call(GDExtensionMethodName.SetShaderParam, [name, value]);

	public new void GetShaderParam(StringName name) => 
		Call(GDExtensionMethodName.GetShaderParam, [name]);

	public new Error Save(string path = "") => 
		Call(GDExtensionMethodName.Save, [path]).As<Error>();

}

file static class WorldBackgroundEnumExtensions
{
public static int SafeAsInt32(this Terrain3DMaterial.WorldBackgroundEnum enumValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DMaterial.WorldBackgroundEnum enumValue, int defaultValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DMaterial.WorldBackgroundEnum? enumValue, int defaultValue = 0) =>
enumValue.HasValue ? Convert.ToInt32(enumValue.Value) : defaultValue;
}

file static class TextureFilteringEnumExtensions
{
public static int SafeAsInt32(this Terrain3DMaterial.TextureFilteringEnum enumValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DMaterial.TextureFilteringEnum enumValue, int defaultValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DMaterial.TextureFilteringEnum? enumValue, int defaultValue = 0) =>
enumValue.HasValue ? Convert.ToInt32(enumValue.Value) : defaultValue;
}

file static class UpdateFlagsExtensions
{
public static int SafeAsInt32(this Terrain3DMaterial.UpdateFlags enumValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DMaterial.UpdateFlags enumValue, int defaultValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DMaterial.UpdateFlags? enumValue, int defaultValue = 0) =>
enumValue.HasValue ? Convert.ToInt32(enumValue.Value) : defaultValue;
}
