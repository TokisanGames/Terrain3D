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
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
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
		Linear = 0,
		Nearest = 1,
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName ShaderParameters = "_shader_parameters";
		public new static readonly StringName WorldBackground = "world_background";
		public new static readonly StringName TextureFiltering = "texture_filtering";
		public new static readonly StringName AutoShaderEnabled = "auto_shader_enabled";
		public new static readonly StringName DualScalingEnabled = "dual_scaling_enabled";
		public new static readonly StringName ShaderOverrideEnabled = "shader_override_enabled";
		public new static readonly StringName ShaderOverride = "shader_override";
		public new static readonly StringName ShowRegionGrid = "show_region_grid";
		public new static readonly StringName ShowInstancerGrid = "show_instancer_grid";
		public new static readonly StringName ShowVertexGrid = "show_vertex_grid";
		public new static readonly StringName ShowContours = "show_contours";
		public new static readonly StringName ShowNavigation = "show_navigation";
		public new static readonly StringName DisplacementScale = "displacement_scale";
		public new static readonly StringName DisplacementSharpness = "displacement_sharpness";
		public new static readonly StringName BufferShaderOverrideEnabled = "buffer_shader_override_enabled";
		public new static readonly StringName BufferShaderOverride = "buffer_shader_override";
		public new static readonly StringName ShowCheckered = "show_checkered";
		public new static readonly StringName ShowGrey = "show_grey";
		public new static readonly StringName ShowHeightmap = "show_heightmap";
		public new static readonly StringName ShowJaggedness = "show_jaggedness";
		public new static readonly StringName ShowAutoshader = "show_autoshader";
		public new static readonly StringName ShowControlTexture = "show_control_texture";
		public new static readonly StringName ShowControlBlend = "show_control_blend";
		public new static readonly StringName ShowControlAngle = "show_control_angle";
		public new static readonly StringName ShowControlScale = "show_control_scale";
		public new static readonly StringName ShowColormap = "show_colormap";
		public new static readonly StringName ShowRoughmap = "show_roughmap";
		public new static readonly StringName ShowTextureAlbedo = "show_texture_albedo";
		public new static readonly StringName ShowTextureHeight = "show_texture_height";
		public new static readonly StringName ShowTextureNormal = "show_texture_normal";
		public new static readonly StringName ShowTextureAo = "show_texture_ao";
		public new static readonly StringName ShowTextureRough = "show_texture_rough";
		public new static readonly StringName ShowDisplacementBuffer = "show_displacement_buffer";
	}

	public new Godot.Collections.Dictionary ShaderParameters
	{
		get => Get(GDExtensionPropertyName.ShaderParameters).As<Godot.Collections.Dictionary>();
		set => Set(GDExtensionPropertyName.ShaderParameters, value);
	}

	public new Terrain3DMaterial.WorldBackgroundEnum WorldBackground
	{
		get => Get(GDExtensionPropertyName.WorldBackground).As<Terrain3DMaterial.WorldBackgroundEnum>();
		set => Set(GDExtensionPropertyName.WorldBackground, Variant.From(value));
	}

	public new long TextureFiltering
	{
		get => Get(GDExtensionPropertyName.TextureFiltering).As<long>();
		set => Set(GDExtensionPropertyName.TextureFiltering, value);
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

	public new Variant BufferShaderOverride
	{
		get => Get(GDExtensionPropertyName.BufferShaderOverride).As<Variant>();
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

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName Update = "update";
		public new static readonly StringName GetMaterialRid = "get_material_rid";
		public new static readonly StringName GetShaderRid = "get_shader_rid";
		public new static readonly StringName GetBufferMaterialRid = "get_buffer_material_rid";
		public new static readonly StringName GetBufferShaderRid = "get_buffer_shader_rid";
		public new static readonly StringName SetShaderParam = "set_shader_param";
		public new static readonly StringName GetShaderParam = "get_shader_param";
		public new static readonly StringName Save = "save";
	}

	public new void Update(bool full = false) => 
		Call(GDExtensionMethodName.Update, [full]);

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
