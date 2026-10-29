#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public abstract partial class Terrain3DAssetResource : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DAssetResource");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DAssetResource object), please use the Instantiate() method instead.")]
	protected Terrain3DAssetResource() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DAssetResource"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DAssetResource"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DAssetResource"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DAssetResource"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DAssetResource Bind(GodotObject godotObject)
	{
		if (!IsInstanceValid(godotObject))
			return null;

		if (godotObject is Terrain3DAssetResource wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DAssetResource);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DAssetResource).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DAssetResource)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Loads the resource at the specified path, then attaches the corresponding wrapper script instance.
	/// </summary>
	/// <param name="path">The resource path to load.</param>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DAssetResource" type.</returns>
	public new static Terrain3DAssetResource Load(string path) => Bind(ResourceLoader.Load(path));

	public new class GDExtensionSignalName : Resource.SignalName
	{
	}

	public new class GDExtensionPropertyName : Resource.PropertyName
	{
	}

	public new class GDExtensionMethodName : Resource.MethodName
	{
	}

}
