#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DInstancer : GodotObject
{

	private new static readonly StringName NativeName = new StringName("Terrain3DInstancer");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DInstancer object), please use the Instantiate() method instead.")]
	protected Terrain3DInstancer() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DInstancer"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DInstancer"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DInstancer"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DInstancer"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DInstancer Bind(GodotObject godotObject)
	{
		if (!IsInstanceValid(godotObject))
			return null;

		if (godotObject is Terrain3DInstancer wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DInstancer);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DInstancer).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DInstancer)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DInstancer"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DInstancer" type.</returns>
	public new static Terrain3DInstancer Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum InstancerMode
	{
		Normal = 1,
		Disabled = 0,
	}

	public new class GDExtensionSignalName : GodotObject.SignalName
	{
	}

	public new class GDExtensionPropertyName : GodotObject.PropertyName
	{
		/// <summary>
		/// Cached name for the 'mode' member.
		/// </summary>
		public new static readonly StringName Mode = "mode";
	}

	public new Terrain3DInstancer.InstancerMode Mode
	{
		get => Get(GDExtensionPropertyName.Mode).As<Terrain3DInstancer.InstancerMode>();
		set => Set(GDExtensionPropertyName.Mode, Variant.From(value));
	}

	public new class GDExtensionMethodName : GodotObject.MethodName
	{
		/// <summary>
		/// Cached name for the 'clear_by_mesh' member.
		/// </summary>
		public new static readonly StringName ClearByMesh = "clear_by_mesh";
		/// <summary>
		/// Cached name for the 'clear_by_location' member.
		/// </summary>
		public new static readonly StringName ClearByLocation = "clear_by_location";
		/// <summary>
		/// Cached name for the 'clear_by_region' member.
		/// </summary>
		public new static readonly StringName ClearByRegion = "clear_by_region";
		/// <summary>
		/// Cached name for the 'is_enabled' member.
		/// </summary>
		public new static readonly StringName IsEnabled = "is_enabled";
		/// <summary>
		/// Cached name for the 'add_instances' member.
		/// </summary>
		public new static readonly StringName AddInstances = "add_instances";
		/// <summary>
		/// Cached name for the 'remove_instances' member.
		/// </summary>
		public new static readonly StringName RemoveInstances = "remove_instances";
		/// <summary>
		/// Cached name for the 'add_multimesh' member.
		/// </summary>
		public new static readonly StringName AddMultimesh = "add_multimesh";
		/// <summary>
		/// Cached name for the 'add_transforms' member.
		/// </summary>
		public new static readonly StringName AddTransforms = "add_transforms";
		/// <summary>
		/// Cached name for the 'append_location' member.
		/// </summary>
		public new static readonly StringName AppendLocation = "append_location";
		/// <summary>
		/// Cached name for the 'append_region' member.
		/// </summary>
		public new static readonly StringName AppendRegion = "append_region";
		/// <summary>
		/// Cached name for the 'update_transforms' member.
		/// </summary>
		public new static readonly StringName UpdateTransforms = "update_transforms";
		/// <summary>
		/// Cached name for the 'get_closest_mesh_id' member.
		/// </summary>
		public new static readonly StringName GetClosestMeshId = "get_closest_mesh_id";
		/// <summary>
		/// Cached name for the 'update_mmis' member.
		/// </summary>
		public new static readonly StringName UpdateMmis = "update_mmis";
		/// <summary>
		/// Cached name for the 'swap_ids' member.
		/// </summary>
		public new static readonly StringName SwapIds = "swap_ids";
	}

	public new void ClearByMesh(long meshId) => 
		Call(GDExtensionMethodName.ClearByMesh, [meshId]);

	public new void ClearByLocation(Vector2I regionLocation, long meshId) => 
		Call(GDExtensionMethodName.ClearByLocation, [regionLocation, meshId]);

	public new void ClearByRegion(Terrain3DRegion region, long meshId) => 
		Call(GDExtensionMethodName.ClearByRegion, [region, meshId]);

	public new bool IsEnabled() => 
		Call(GDExtensionMethodName.IsEnabled, []).As<bool>();

	public new void AddInstances(Vector3 globalPosition, Godot.Collections.Dictionary @params) => 
		Call(GDExtensionMethodName.AddInstances, [globalPosition, @params]);

	public new void RemoveInstances(Vector3 globalPosition, Godot.Collections.Dictionary @params) => 
		Call(GDExtensionMethodName.RemoveInstances, [globalPosition, @params]);

	public new void AddMultimesh(long meshId, MultiMesh multimesh, Transform3D transform = default, bool update = true) => 
		Call(GDExtensionMethodName.AddMultimesh, [meshId, multimesh, transform, update]);

	public new void AddTransforms(long meshId, Godot.Collections.Array transforms, Color[] colors = default, bool update = true) => 
		Call(GDExtensionMethodName.AddTransforms, [meshId, transforms, colors, update]);

	public new void AppendLocation(Vector2I regionLocation, long meshId, Godot.Collections.Array transforms, Color[] colors, bool update = true) => 
		Call(GDExtensionMethodName.AppendLocation, [regionLocation, meshId, transforms, colors, update]);

	public new void AppendRegion(Terrain3DRegion region, long meshId, Godot.Collections.Array transforms, Color[] colors, bool update = true) => 
		Call(GDExtensionMethodName.AppendRegion, [region, meshId, transforms, colors, update]);

	public new void UpdateTransforms(Aabb aabb) => 
		Call(GDExtensionMethodName.UpdateTransforms, [aabb]);

	public new long GetClosestMeshId(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetClosestMeshId, [globalPosition]).As<long>();

	public new void UpdateMmis(long meshId = -1, Vector2I regionLocation = default, bool rebuildAll = false) => 
		Call(GDExtensionMethodName.UpdateMmis, [meshId, regionLocation, rebuildAll]);

	public new void SwapIds(long srcId, long destId) => 
		Call(GDExtensionMethodName.SwapIds, [srcId, destId]);

}

file static class InstancerModeExtensions
{
public static int SafeAsInt32(this Terrain3DInstancer.InstancerMode enumValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DInstancer.InstancerMode enumValue, int defaultValue) =>
Convert.ToInt32(enumValue);

public static int SafeAsInt32(this Terrain3DInstancer.InstancerMode? enumValue, int defaultValue = 0) =>
enumValue.HasValue ? Convert.ToInt32(enumValue.Value) : defaultValue;
}
