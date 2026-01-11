#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DStampLayer : Terrain3DLayer
{

	private new static readonly StringName NativeName = new StringName("Terrain3DStampLayer");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DStampLayer object), please use the Instantiate() method instead.")]
	protected Terrain3DStampLayer() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DStampLayer"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DStampLayer"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DStampLayer"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DStampLayer"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DStampLayer Bind(GodotObject godotObject)
	{
		if (!IsInstanceValid(godotObject))
			return null;

		if (godotObject is Terrain3DStampLayer wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DStampLayer);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DStampLayer).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DStampLayer)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DStampLayer"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DStampLayer" type.</returns>
	public new static Terrain3DStampLayer Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

}
