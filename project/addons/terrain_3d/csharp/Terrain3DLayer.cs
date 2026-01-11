#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DLayer : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DLayer");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DLayer object), please use the Instantiate() method instead.")]
	protected Terrain3DLayer() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DLayer"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DLayer"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DLayer"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DLayer"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DLayer Bind(GodotObject godotObject)
	{
		if (!IsInstanceValid(godotObject))
			return null;

		if (godotObject is Terrain3DLayer wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DLayer);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DLayer).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DLayer)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DLayer"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DLayer" type.</returns>
	public new static Terrain3DLayer Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum BlendModeEnum
	{
		Add = 0,
		Subtract = 1,
		Replace = 2,
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName MapType = "map_type";
		public new static readonly StringName Enabled = "enabled";
		public new static readonly StringName Intensity = "intensity";
		public new static readonly StringName FeatherRadius = "feather_radius";
		public new static readonly StringName BlendMode = "blend_mode";
		public new static readonly StringName Coverage = "coverage";
		public new static readonly StringName Payload = "payload";
		public new static readonly StringName Alpha = "alpha";
		public new static readonly StringName GroupId = "group_id";
		public new static readonly StringName UserEditable = "user_editable";
	}

	public new Variant MapType
	{
		get => Get(GDExtensionPropertyName.MapType).As<Variant>();
		set => Set(GDExtensionPropertyName.MapType, value);
	}

	public new bool Enabled
	{
		get => Get(GDExtensionPropertyName.Enabled).As<bool>();
		set => Set(GDExtensionPropertyName.Enabled, value);
	}

	public new double Intensity
	{
		get => Get(GDExtensionPropertyName.Intensity).As<double>();
		set => Set(GDExtensionPropertyName.Intensity, value);
	}

	public new double FeatherRadius
	{
		get => Get(GDExtensionPropertyName.FeatherRadius).As<double>();
		set => Set(GDExtensionPropertyName.FeatherRadius, value);
	}

	public new Terrain3DLayer.BlendModeEnum BlendMode
	{
		get => Get(GDExtensionPropertyName.BlendMode).As<Terrain3DLayer.BlendModeEnum>();
		set => Set(GDExtensionPropertyName.BlendMode, Variant.From(value));
	}

	public new Rect2I Coverage
	{
		get => Get(GDExtensionPropertyName.Coverage).As<Rect2I>();
		set => Set(GDExtensionPropertyName.Coverage, value);
	}

	public new Image Payload
	{
		get => Get(GDExtensionPropertyName.Payload).As<Image>();
		set => Set(GDExtensionPropertyName.Payload, value);
	}

	public new Image Alpha
	{
		get => Get(GDExtensionPropertyName.Alpha).As<Image>();
		set => Set(GDExtensionPropertyName.Alpha, value);
	}

	public new long GroupId
	{
		get => Get(GDExtensionPropertyName.GroupId).As<long>();
		set => Set(GDExtensionPropertyName.GroupId, value);
	}

	public new bool UserEditable
	{
		get => Get(GDExtensionPropertyName.UserEditable).As<bool>();
		set => Set(GDExtensionPropertyName.UserEditable, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName MarkDirty = "mark_dirty";
	}

	public new void MarkDirty() => 
		Call(GDExtensionMethodName.MarkDirty, []);

}
