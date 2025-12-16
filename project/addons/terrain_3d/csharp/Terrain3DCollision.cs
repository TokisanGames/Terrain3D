#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DCollision : GodotObject
{

	private new static readonly StringName NativeName = new StringName("Terrain3DCollision");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DCollision object), please use the Instantiate() method instead.")]
	protected Terrain3DCollision() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DCollision"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DCollision"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DCollision"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DCollision"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DCollision Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DCollision wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DCollision);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DCollision).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DCollision)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DCollision"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DCollision" type.</returns>
	public new static Terrain3DCollision Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum CollisionMode
	{
		Disabled = 0,
		DynamicGame = 1,
		DynamicEditor = 2,
		FullGame = 3,
		FullEditor = 4,
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName Mode = "mode";
		public new static readonly StringName ShapeSize = "shape_size";
		public new static readonly StringName Radius = "radius";
		public new static readonly StringName Layer = "layer";
		public new static readonly StringName Mask = "mask";
		public new static readonly StringName Priority = "priority";
		public new static readonly StringName PhysicsMaterial = "physics_material";
	}

	public new Variant Mode
	{
		get => Get(GDExtensionPropertyName.Mode).As<Variant>();
		set => Set(GDExtensionPropertyName.Mode, value);
	}

	public new long ShapeSize
	{
		get => Get(GDExtensionPropertyName.ShapeSize).As<long>();
		set => Set(GDExtensionPropertyName.ShapeSize, value);
	}

	public new long Radius
	{
		get => Get(GDExtensionPropertyName.Radius).As<long>();
		set => Set(GDExtensionPropertyName.Radius, value);
	}

	public new long Layer
	{
		get => Get(GDExtensionPropertyName.Layer).As<long>();
		set => Set(GDExtensionPropertyName.Layer, value);
	}

	public new long Mask
	{
		get => Get(GDExtensionPropertyName.Mask).As<long>();
		set => Set(GDExtensionPropertyName.Mask, value);
	}

	public new double Priority
	{
		get => Get(GDExtensionPropertyName.Priority).As<double>();
		set => Set(GDExtensionPropertyName.Priority, value);
	}

	public new PhysicsMaterial PhysicsMaterial
	{
		get => Get(GDExtensionPropertyName.PhysicsMaterial).As<PhysicsMaterial>();
		set => Set(GDExtensionPropertyName.PhysicsMaterial, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName Build = "build";
		public new static readonly StringName Update = "update";
		public new static readonly StringName Destroy = "destroy";
		public new static readonly StringName IsEnabled = "is_enabled";
		public new static readonly StringName IsEditorMode = "is_editor_mode";
		public new static readonly StringName IsDynamicMode = "is_dynamic_mode";
		public new static readonly StringName GetRid = "get_rid";
	}

	public new void Build() => 
		Call(GDExtensionMethodName.Build, []);

	public new void Update(bool rebuild = false) => 
		Call(GDExtensionMethodName.Update, [rebuild]);

	public new void Destroy() => 
		Call(GDExtensionMethodName.Destroy, []);

	public new bool IsEnabled() => 
		Call(GDExtensionMethodName.IsEnabled, []).As<bool>();

	public new bool IsEditorMode() => 
		Call(GDExtensionMethodName.IsEditorMode, []).As<bool>();

	public new bool IsDynamicMode() => 
		Call(GDExtensionMethodName.IsDynamicMode, []).As<bool>();

	public new Rid GetRid() => 
		Call(GDExtensionMethodName.GetRid, []).As<Rid>();

}
