#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DCurveLayer : Terrain3DLayer
{

	private new static readonly StringName NativeName = new StringName("Terrain3DCurveLayer");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DCurveLayer object), please use the Instantiate() method instead.")]
	protected Terrain3DCurveLayer() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DCurveLayer"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DCurveLayer"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DCurveLayer"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DCurveLayer"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DCurveLayer Bind(GodotObject godotObject)
	{
		if (!IsInstanceValid(godotObject))
			return null;

		if (godotObject is Terrain3DCurveLayer wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DCurveLayer);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DCurveLayer).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DCurveLayer)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DCurveLayer"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DCurveLayer" type.</returns>
	public new static Terrain3DCurveLayer Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName Points = "points";
		public new static readonly StringName Width = "width";
		public new static readonly StringName Depth = "depth";
		public new static readonly StringName DualGroove = "dual_groove";
		public new static readonly StringName FalloffCurve = "falloff_curve";
	}

	public new Godot.Collections.Array Points
	{
		get => Get(GDExtensionPropertyName.Points).As<Godot.Collections.Array>();
		set => Set(GDExtensionPropertyName.Points, value);
	}

	public new double Width
	{
		get => Get(GDExtensionPropertyName.Width).As<double>();
		set => Set(GDExtensionPropertyName.Width, value);
	}

	public new double Depth
	{
		get => Get(GDExtensionPropertyName.Depth).As<double>();
		set => Set(GDExtensionPropertyName.Depth, value);
	}

	public new bool DualGroove
	{
		get => Get(GDExtensionPropertyName.DualGroove).As<bool>();
		set => Set(GDExtensionPropertyName.DualGroove, value);
	}

	public new Curve FalloffCurve
	{
		get => Get(GDExtensionPropertyName.FalloffCurve).As<Curve>();
		set => Set(GDExtensionPropertyName.FalloffCurve, value);
	}

}
