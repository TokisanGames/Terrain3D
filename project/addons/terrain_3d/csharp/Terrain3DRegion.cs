#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DRegion : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DRegion");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DRegion object), please use the Instantiate() method instead.")]
	protected Terrain3DRegion() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DRegion"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DRegion"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DRegion"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DRegion"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DRegion Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DRegion wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DRegion);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DRegion).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DRegion)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DRegion"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DRegion" type.</returns>
	public new static Terrain3DRegion Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum MapType
	{
		Height = 0,
		Control = 1,
		Color = 2,
		Max = 3,
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName Version = "version";
		public new static readonly StringName RegionSize = "region_size";
		public new static readonly StringName VertexSpacing = "vertex_spacing";
		public new static readonly StringName HeightRange = "height_range";
		public new static readonly StringName HeightMap = "height_map";
		public new static readonly StringName ControlMap = "control_map";
		public new static readonly StringName ColorMap = "color_map";
		public new static readonly StringName Instances = "instances";
		public new static readonly StringName Edited = "edited";
		public new static readonly StringName Deleted = "deleted";
		public new static readonly StringName Modified = "modified";
		public new static readonly StringName Location = "location";
	}

	public new double Version
	{
		get => Get(GDExtensionPropertyName.Version).As<double>();
		set => Set(GDExtensionPropertyName.Version, value);
	}

	public new long RegionSize
	{
		get => Get(GDExtensionPropertyName.RegionSize).As<long>();
		set => Set(GDExtensionPropertyName.RegionSize, value);
	}

	public new double VertexSpacing
	{
		get => Get(GDExtensionPropertyName.VertexSpacing).As<double>();
		set => Set(GDExtensionPropertyName.VertexSpacing, value);
	}

	public new Vector2 HeightRange
	{
		get => Get(GDExtensionPropertyName.HeightRange).As<Vector2>();
		set => Set(GDExtensionPropertyName.HeightRange, value);
	}

	public new Image HeightMap
	{
		get => Get(GDExtensionPropertyName.HeightMap).As<Image>();
		set => Set(GDExtensionPropertyName.HeightMap, value);
	}

	public new Image ControlMap
	{
		get => Get(GDExtensionPropertyName.ControlMap).As<Image>();
		set => Set(GDExtensionPropertyName.ControlMap, value);
	}

	public new Image ColorMap
	{
		get => Get(GDExtensionPropertyName.ColorMap).As<Image>();
		set => Set(GDExtensionPropertyName.ColorMap, value);
	}

	public new Godot.Collections.Dictionary Instances
	{
		get => Get(GDExtensionPropertyName.Instances).As<Godot.Collections.Dictionary>();
		set => Set(GDExtensionPropertyName.Instances, value);
	}

	public new bool Edited
	{
		get => Get(GDExtensionPropertyName.Edited).As<bool>();
		set => Set(GDExtensionPropertyName.Edited, value);
	}

	public new bool Deleted
	{
		get => Get(GDExtensionPropertyName.Deleted).As<bool>();
		set => Set(GDExtensionPropertyName.Deleted, value);
	}

	public new bool Modified
	{
		get => Get(GDExtensionPropertyName.Modified).As<bool>();
		set => Set(GDExtensionPropertyName.Modified, value);
	}

	public new Vector2I Location
	{
		get => Get(GDExtensionPropertyName.Location).As<Vector2I>();
		set => Set(GDExtensionPropertyName.Location, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName Clear = "clear";
		public new static readonly StringName SetMap = "set_map";
		public new static readonly StringName GetMap = "get_map";
		public new static readonly StringName SetMaps = "set_maps";
		public new static readonly StringName GetMaps = "get_maps";
		public new static readonly StringName SanitizeMaps = "sanitize_maps";
		public new static readonly StringName SanitizeMap = "sanitize_map";
		public new static readonly StringName ValidateMapSize = "validate_map_size";
		public new static readonly StringName UpdateHeight = "update_height";
		public new static readonly StringName UpdateHeights = "update_heights";
		public new static readonly StringName CalcHeightRange = "calc_height_range";
		public new static readonly StringName Save = "save";
		public new static readonly StringName SetData = "set_data";
		public new static readonly StringName GetData = "get_data";
		public new static readonly StringName Duplicate = "duplicate";
		public new static readonly StringName Dump = "dump";
	}

	public new void Clear() => 
		Call(GDExtensionMethodName.Clear, []);

	public new void SetMap(Terrain3DRegion.MapType mapType, Image map) => 
		Call(GDExtensionMethodName.SetMap, [Variant.From(mapType), map]);

	public new Image GetMap(Terrain3DRegion.MapType mapType) => 
		Call(GDExtensionMethodName.GetMap, [Variant.From(mapType)]).As<Image>();

	public new void SetMaps(Godot.Collections.Array maps) => 
		Call(GDExtensionMethodName.SetMaps, [maps]);

	public new Godot.Collections.Array GetMaps() => 
		Call(GDExtensionMethodName.GetMaps, []).As<Godot.Collections.Array>();

	public new void SanitizeMaps() => 
		Call(GDExtensionMethodName.SanitizeMaps, []);

	public new Image SanitizeMap(Terrain3DRegion.MapType mapType, Image map) => 
		Call(GDExtensionMethodName.SanitizeMap, [Variant.From(mapType), map]).As<Image>();

	public new bool ValidateMapSize(Image map) => 
		Call(GDExtensionMethodName.ValidateMapSize, [map]).As<bool>();

	public new void UpdateHeight(double height) => 
		Call(GDExtensionMethodName.UpdateHeight, [height]);

	public new void UpdateHeights(Vector2 lowHigh) => 
		Call(GDExtensionMethodName.UpdateHeights, [lowHigh]);

	public new void CalcHeightRange() => 
		Call(GDExtensionMethodName.CalcHeightRange, []);

	public new Error Save(string path = "", bool save16Bit = false) => 
		Call(GDExtensionMethodName.Save, [path, save16Bit]).As<Error>();

	public new void SetData(Godot.Collections.Dictionary data) => 
		Call(GDExtensionMethodName.SetData, [data]);

	public new Godot.Collections.Dictionary GetData() => 
		Call(GDExtensionMethodName.GetData, []).As<Godot.Collections.Dictionary>();

	public new Terrain3DRegion Duplicate(bool deep = false) => 
		Terrain3DRegion.Bind(Call(GDExtensionMethodName.Duplicate, [deep]).As<Resource>());

	public new void Dump(bool verbose = false) => 
		Call(GDExtensionMethodName.Dump, [verbose]);

}
