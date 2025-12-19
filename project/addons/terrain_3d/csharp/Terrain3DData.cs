#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DData : GodotObject
{

	private new static readonly StringName NativeName = new StringName("Terrain3DData");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DData object), please use the Instantiate() method instead.")]
	protected Terrain3DData() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DData"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DData"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DData"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DData"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DData Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DData wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DData);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DData).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DData)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DData"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DData" type.</returns>
	public new static Terrain3DData Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum HeightFilter
	{
		Nearest = 0,
		Minimum = 1,
	}

	public new static class GDExtensionSignalName
	{
		public new static readonly StringName MapsChanged = "maps_changed";
		public new static readonly StringName RegionMapChanged = "region_map_changed";
		public new static readonly StringName HeightMapsChanged = "height_maps_changed";
		public new static readonly StringName ControlMapsChanged = "control_maps_changed";
		public new static readonly StringName ColorMapsChanged = "color_maps_changed";
		public new static readonly StringName MapsEdited = "maps_edited";
	}

	public new delegate void MapsChangedSignalHandler();
	private MapsChangedSignalHandler _mapsChangedSignal;
	private Callable _mapsChangedSignalCallable;
	public event MapsChangedSignalHandler MapsChangedSignal
	{
		add
		{
			if (_mapsChangedSignal is null)
			{
				_mapsChangedSignalCallable = Callable.From(() => 
					_mapsChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.MapsChanged, _mapsChangedSignalCallable);
			}
			_mapsChangedSignal += value;
		}
		remove
		{
			_mapsChangedSignal -= value;
			if (_mapsChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.MapsChanged, _mapsChangedSignalCallable);
			_mapsChangedSignalCallable = default;
		}
	}

	public new delegate void RegionMapChangedSignalHandler();
	private RegionMapChangedSignalHandler _regionMapChangedSignal;
	private Callable _regionMapChangedSignalCallable;
	public event RegionMapChangedSignalHandler RegionMapChangedSignal
	{
		add
		{
			if (_regionMapChangedSignal is null)
			{
				_regionMapChangedSignalCallable = Callable.From(() => 
					_regionMapChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.RegionMapChanged, _regionMapChangedSignalCallable);
			}
			_regionMapChangedSignal += value;
		}
		remove
		{
			_regionMapChangedSignal -= value;
			if (_regionMapChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.RegionMapChanged, _regionMapChangedSignalCallable);
			_regionMapChangedSignalCallable = default;
		}
	}

	public new delegate void HeightMapsChangedSignalHandler();
	private HeightMapsChangedSignalHandler _heightMapsChangedSignal;
	private Callable _heightMapsChangedSignalCallable;
	public event HeightMapsChangedSignalHandler HeightMapsChangedSignal
	{
		add
		{
			if (_heightMapsChangedSignal is null)
			{
				_heightMapsChangedSignalCallable = Callable.From(() => 
					_heightMapsChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.HeightMapsChanged, _heightMapsChangedSignalCallable);
			}
			_heightMapsChangedSignal += value;
		}
		remove
		{
			_heightMapsChangedSignal -= value;
			if (_heightMapsChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.HeightMapsChanged, _heightMapsChangedSignalCallable);
			_heightMapsChangedSignalCallable = default;
		}
	}

	public new delegate void ControlMapsChangedSignalHandler();
	private ControlMapsChangedSignalHandler _controlMapsChangedSignal;
	private Callable _controlMapsChangedSignalCallable;
	public event ControlMapsChangedSignalHandler ControlMapsChangedSignal
	{
		add
		{
			if (_controlMapsChangedSignal is null)
			{
				_controlMapsChangedSignalCallable = Callable.From(() => 
					_controlMapsChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.ControlMapsChanged, _controlMapsChangedSignalCallable);
			}
			_controlMapsChangedSignal += value;
		}
		remove
		{
			_controlMapsChangedSignal -= value;
			if (_controlMapsChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.ControlMapsChanged, _controlMapsChangedSignalCallable);
			_controlMapsChangedSignalCallable = default;
		}
	}

	public new delegate void ColorMapsChangedSignalHandler();
	private ColorMapsChangedSignalHandler _colorMapsChangedSignal;
	private Callable _colorMapsChangedSignalCallable;
	public event ColorMapsChangedSignalHandler ColorMapsChangedSignal
	{
		add
		{
			if (_colorMapsChangedSignal is null)
			{
				_colorMapsChangedSignalCallable = Callable.From(() => 
					_colorMapsChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.ColorMapsChanged, _colorMapsChangedSignalCallable);
			}
			_colorMapsChangedSignal += value;
		}
		remove
		{
			_colorMapsChangedSignal -= value;
			if (_colorMapsChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.ColorMapsChanged, _colorMapsChangedSignalCallable);
			_colorMapsChangedSignalCallable = default;
		}
	}

	public new delegate void MapsEditedSignalHandler(Aabb editedArea);
	private MapsEditedSignalHandler _mapsEditedSignal;
	private Callable _mapsEditedSignalCallable;
	public event MapsEditedSignalHandler MapsEditedSignal
	{
		add
		{
			if (_mapsEditedSignal is null)
			{
				_mapsEditedSignalCallable = Callable.From((Variant editedArea) => 
					_mapsEditedSignal?.Invoke(editedArea.As<Aabb>()));
				Connect(GDExtensionSignalName.MapsEdited, _mapsEditedSignalCallable);
			}
			_mapsEditedSignal += value;
		}
		remove
		{
			_mapsEditedSignal -= value;
			if (_mapsEditedSignal is not null) return;
			Disconnect(GDExtensionSignalName.MapsEdited, _mapsEditedSignalCallable);
			_mapsEditedSignalCallable = default;
		}
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName RegionLocations = "region_locations";
		public new static readonly StringName HeightMaps = "height_maps";
		public new static readonly StringName ControlMaps = "control_maps";
		public new static readonly StringName ColorMaps = "color_maps";
	}

	public new Godot.Collections.Array RegionLocations
	{
		get => Get(GDExtensionPropertyName.RegionLocations).As<Godot.Collections.Array>();
		set => Set(GDExtensionPropertyName.RegionLocations, value);
	}

	public new Godot.Collections.Array HeightMaps
	{
		get => Get(GDExtensionPropertyName.HeightMaps).As<Godot.Collections.Array>();
	}

	public new Godot.Collections.Array ControlMaps
	{
		get => Get(GDExtensionPropertyName.ControlMaps).As<Godot.Collections.Array>();
	}

	public new Godot.Collections.Array ColorMaps
	{
		get => Get(GDExtensionPropertyName.ColorMaps).As<Godot.Collections.Array>();
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName GetRegionCount = "get_region_count";
		public new static readonly StringName GetRegionsActive = "get_regions_active";
		public new static readonly StringName GetRegionsAll = "get_regions_all";
		public new static readonly StringName GetRegionMap = "get_region_map";
		public new static readonly StringName GetRegionMapIndex = "get_region_map_index";
		public new static readonly StringName DoForRegions = "do_for_regions";
		public new static readonly StringName ChangeRegionSize = "change_region_size";
		public new static readonly StringName GetRegionLocation = "get_region_location";
		public new static readonly StringName GetRegionId = "get_region_id";
		public new static readonly StringName GetRegionIdp = "get_region_idp";
		public new static readonly StringName HasRegion = "has_region";
		public new static readonly StringName HasRegionp = "has_regionp";
		public new static readonly StringName GetRegion = "get_region";
		public new static readonly StringName GetRegionp = "get_regionp";
		public new static readonly StringName SetRegionModified = "set_region_modified";
		public new static readonly StringName IsRegionModified = "is_region_modified";
		public new static readonly StringName SetRegionDeleted = "set_region_deleted";
		public new static readonly StringName IsRegionDeleted = "is_region_deleted";
		public new static readonly StringName AddRegionBlankp = "add_region_blankp";
		public new static readonly StringName AddRegionBlank = "add_region_blank";
		public new static readonly StringName AddRegion = "add_region";
		public new static readonly StringName RemoveRegionp = "remove_regionp";
		public new static readonly StringName RemoveRegionl = "remove_regionl";
		public new static readonly StringName RemoveRegion = "remove_region";
		public new static readonly StringName SaveDirectory = "save_directory";
		public new static readonly StringName SaveRegion = "save_region";
		public new static readonly StringName LoadDirectory = "load_directory";
		public new static readonly StringName LoadRegion = "load_region";
		public new static readonly StringName GetMaps = "get_maps";
		public new static readonly StringName UpdateMaps = "update_maps";
		public new static readonly StringName GetHeightMapsRid = "get_height_maps_rid";
		public new static readonly StringName GetControlMapsRid = "get_control_maps_rid";
		public new static readonly StringName GetColorMapsRid = "get_color_maps_rid";
		public new static readonly StringName SetPixel = "set_pixel";
		public new static readonly StringName GetPixel = "get_pixel";
		public new static readonly StringName SetHeight = "set_height";
		public new static readonly StringName GetHeight = "get_height";
		public new static readonly StringName SetColor = "set_color";
		public new static readonly StringName GetColor = "get_color";
		public new static readonly StringName SetControl = "set_control";
		public new static readonly StringName GetControl = "get_control";
		public new static readonly StringName SetRoughness = "set_roughness";
		public new static readonly StringName GetRoughness = "get_roughness";
		public new static readonly StringName SetControlBaseId = "set_control_base_id";
		public new static readonly StringName GetControlBaseId = "get_control_base_id";
		public new static readonly StringName SetControlOverlayId = "set_control_overlay_id";
		public new static readonly StringName GetControlOverlayId = "get_control_overlay_id";
		public new static readonly StringName SetControlBlend = "set_control_blend";
		public new static readonly StringName GetControlBlend = "get_control_blend";
		public new static readonly StringName SetControlAngle = "set_control_angle";
		public new static readonly StringName GetControlAngle = "get_control_angle";
		public new static readonly StringName SetControlScale = "set_control_scale";
		public new static readonly StringName GetControlScale = "get_control_scale";
		public new static readonly StringName SetControlHole = "set_control_hole";
		public new static readonly StringName GetControlHole = "get_control_hole";
		public new static readonly StringName SetControlNavigation = "set_control_navigation";
		public new static readonly StringName GetControlNavigation = "get_control_navigation";
		public new static readonly StringName SetControlAuto = "set_control_auto";
		public new static readonly StringName GetControlAuto = "get_control_auto";
		public new static readonly StringName GetNormal = "get_normal";
		public new static readonly StringName IsInSlope = "is_in_slope";
		public new static readonly StringName GetTextureId = "get_texture_id";
		public new static readonly StringName GetMeshVertex = "get_mesh_vertex";
		public new static readonly StringName GetHeightRange = "get_height_range";
		public new static readonly StringName CalcHeightRange = "calc_height_range";
		public new static readonly StringName ImportImages = "import_images";
		public new static readonly StringName ExportImage = "export_image";
		public new static readonly StringName LayeredToImage = "layered_to_image";
		public new static readonly StringName Dump = "dump";
	}

	public new long GetRegionCount() => 
		Call(GDExtensionMethodName.GetRegionCount, []).As<long>();

	public new Godot.Collections.Array GetRegionsActive(bool copy = false, bool deep = false) => 
		Call(GDExtensionMethodName.GetRegionsActive, [copy, deep]).As<Godot.Collections.Array>();

	public new Godot.Collections.Dictionary GetRegionsAll() => 
		Call(GDExtensionMethodName.GetRegionsAll, []).As<Godot.Collections.Dictionary>();

	public new int[] GetRegionMap() => 
		Call(GDExtensionMethodName.GetRegionMap, []).As<int[]>();

	public new static long GetRegionMapIndex(Vector2I regionLocation) => 
		ClassDB.ClassCallStatic(NativeName, GDExtensionMethodName.GetRegionMapIndex, [regionLocation]).As<long>();

	public new void DoForRegions(Rect2I area, Callable callback) => 
		Call(GDExtensionMethodName.DoForRegions, [area, callback]);

	public new void ChangeRegionSize(long regionSize) => 
		Call(GDExtensionMethodName.ChangeRegionSize, [regionSize]);

	public new Vector2I GetRegionLocation(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetRegionLocation, [globalPosition]).As<Vector2I>();

	public new long GetRegionId(Vector2I regionLocation) => 
		Call(GDExtensionMethodName.GetRegionId, [regionLocation]).As<long>();

	public new long GetRegionIdp(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetRegionIdp, [globalPosition]).As<long>();

	public new bool HasRegion(Vector2I regionLocation) => 
		Call(GDExtensionMethodName.HasRegion, [regionLocation]).As<bool>();

	public new bool HasRegionp(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.HasRegionp, [globalPosition]).As<bool>();

	public new Terrain3DRegion GetRegion(Vector2I regionLocation) => 
		Terrain3DRegion.Bind(Call(GDExtensionMethodName.GetRegion, [regionLocation]).As<Resource>());

	public new Terrain3DRegion GetRegionp(Vector3 globalPosition) => 
		Terrain3DRegion.Bind(Call(GDExtensionMethodName.GetRegionp, [globalPosition]).As<Resource>());

	public new void SetRegionModified(Vector2I regionLocation, bool modified) => 
		Call(GDExtensionMethodName.SetRegionModified, [regionLocation, modified]);

	public new bool IsRegionModified(Vector2I regionLocation) => 
		Call(GDExtensionMethodName.IsRegionModified, [regionLocation]).As<bool>();

	public new void SetRegionDeleted(Vector2I regionLocation, bool deleted) => 
		Call(GDExtensionMethodName.SetRegionDeleted, [regionLocation, deleted]);

	public new bool IsRegionDeleted(Vector2I regionLocation) => 
		Call(GDExtensionMethodName.IsRegionDeleted, [regionLocation]).As<bool>();

	public new Terrain3DRegion AddRegionBlankp(Vector3 globalPosition, bool update = true) => 
		Terrain3DRegion.Bind(Call(GDExtensionMethodName.AddRegionBlankp, [globalPosition, update]).As<Resource>());

	public new Terrain3DRegion AddRegionBlank(Vector2I regionLocation, bool update = true) => 
		Terrain3DRegion.Bind(Call(GDExtensionMethodName.AddRegionBlank, [regionLocation, update]).As<Resource>());

	public new Error AddRegion(Terrain3DRegion region, bool update = true) => 
		Call(GDExtensionMethodName.AddRegion, [region, update]).As<Error>();

	public new void RemoveRegionp(Vector3 globalPosition, bool update = true) => 
		Call(GDExtensionMethodName.RemoveRegionp, [globalPosition, update]);

	public new void RemoveRegionl(Vector2I regionLocation, bool update = true) => 
		Call(GDExtensionMethodName.RemoveRegionl, [regionLocation, update]);

	public new void RemoveRegion(Terrain3DRegion region, bool update = true) => 
		Call(GDExtensionMethodName.RemoveRegion, [region, update]);

	public new void SaveDirectory(string directory) => 
		Call(GDExtensionMethodName.SaveDirectory, [directory]);

	public new void SaveRegion(Vector2I regionLocation, string directory, bool save16Bit = false) => 
		Call(GDExtensionMethodName.SaveRegion, [regionLocation, directory, save16Bit]);

	public new void LoadDirectory(string directory) => 
		Call(GDExtensionMethodName.LoadDirectory, [directory]);

	public new void LoadRegion(Vector2I regionLocation, string directory, bool update = true) => 
		Call(GDExtensionMethodName.LoadRegion, [regionLocation, directory, update]);

	public new Godot.Collections.Array GetMaps(Terrain3DRegion.MapType mapType) => 
		Call(GDExtensionMethodName.GetMaps, [Variant.From(mapType)]).As<Godot.Collections.Array>();

	public new void UpdateMaps(Terrain3DRegion.MapType mapType = Terrain3DRegion.MapType.Max, bool allRegions = true, bool generateMipmaps = false) => 
		Call(GDExtensionMethodName.UpdateMaps, [Variant.From(mapType), allRegions, generateMipmaps]);

	public new Rid GetHeightMapsRid() => 
		Call(GDExtensionMethodName.GetHeightMapsRid, []).As<Rid>();

	public new Rid GetControlMapsRid() => 
		Call(GDExtensionMethodName.GetControlMapsRid, []).As<Rid>();

	public new Rid GetColorMapsRid() => 
		Call(GDExtensionMethodName.GetColorMapsRid, []).As<Rid>();

	public new void SetPixel(Terrain3DRegion.MapType mapType, Vector3 globalPosition, Color pixel) => 
		Call(GDExtensionMethodName.SetPixel, [Variant.From(mapType), globalPosition, pixel]);

	public new Color GetPixel(Terrain3DRegion.MapType mapType, Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetPixel, [Variant.From(mapType), globalPosition]).As<Color>();

	public new void SetHeight(Vector3 globalPosition, double height) => 
		Call(GDExtensionMethodName.SetHeight, [globalPosition, height]);

	public new double GetHeight(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetHeight, [globalPosition]).As<double>();

	public new void SetColor(Vector3 globalPosition, Color color) => 
		Call(GDExtensionMethodName.SetColor, [globalPosition, color]);

	public new Color GetColor(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetColor, [globalPosition]).As<Color>();

	public new void SetControl(Vector3 globalPosition, long control) => 
		Call(GDExtensionMethodName.SetControl, [globalPosition, control]);

	public new long GetControl(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControl, [globalPosition]).As<long>();

	public new void SetRoughness(Vector3 globalPosition, double roughness) => 
		Call(GDExtensionMethodName.SetRoughness, [globalPosition, roughness]);

	public new double GetRoughness(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetRoughness, [globalPosition]).As<double>();

	public new void SetControlBaseId(Vector3 globalPosition, long textureId) => 
		Call(GDExtensionMethodName.SetControlBaseId, [globalPosition, textureId]);

	public new long GetControlBaseId(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlBaseId, [globalPosition]).As<long>();

	public new void SetControlOverlayId(Vector3 globalPosition, long textureId) => 
		Call(GDExtensionMethodName.SetControlOverlayId, [globalPosition, textureId]);

	public new long GetControlOverlayId(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlOverlayId, [globalPosition]).As<long>();

	public new void SetControlBlend(Vector3 globalPosition, double blendValue) => 
		Call(GDExtensionMethodName.SetControlBlend, [globalPosition, blendValue]);

	public new double GetControlBlend(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlBlend, [globalPosition]).As<double>();

	public new void SetControlAngle(Vector3 globalPosition, double degrees) => 
		Call(GDExtensionMethodName.SetControlAngle, [globalPosition, degrees]);

	public new double GetControlAngle(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlAngle, [globalPosition]).As<double>();

	public new void SetControlScale(Vector3 globalPosition, double percentageModifier) => 
		Call(GDExtensionMethodName.SetControlScale, [globalPosition, percentageModifier]);

	public new double GetControlScale(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlScale, [globalPosition]).As<double>();

	public new void SetControlHole(Vector3 globalPosition, bool enable) => 
		Call(GDExtensionMethodName.SetControlHole, [globalPosition, enable]);

	public new bool GetControlHole(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlHole, [globalPosition]).As<bool>();

	public new void SetControlNavigation(Vector3 globalPosition, bool enable) => 
		Call(GDExtensionMethodName.SetControlNavigation, [globalPosition, enable]);

	public new bool GetControlNavigation(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlNavigation, [globalPosition]).As<bool>();

	public new void SetControlAuto(Vector3 globalPosition, bool enable) => 
		Call(GDExtensionMethodName.SetControlAuto, [globalPosition, enable]);

	public new bool GetControlAuto(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetControlAuto, [globalPosition]).As<bool>();

	public new Vector3 GetNormal(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetNormal, [globalPosition]).As<Vector3>();

	public new bool IsInSlope(Vector3 globalPosition, Vector2 slopeRange, Vector3 normal = default) => 
		Call(GDExtensionMethodName.IsInSlope, [globalPosition, slopeRange, normal]).As<bool>();

	public new Vector3 GetTextureId(Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetTextureId, [globalPosition]).As<Vector3>();

	public new Vector3 GetMeshVertex(long lod, Terrain3DData.HeightFilter filter, Vector3 globalPosition) => 
		Call(GDExtensionMethodName.GetMeshVertex, [lod, Variant.From(filter), globalPosition]).As<Vector3>();

	public new Vector2 GetHeightRange() => 
		Call(GDExtensionMethodName.GetHeightRange, []).As<Vector2>();

	public new void CalcHeightRange(bool recursive = false) => 
		Call(GDExtensionMethodName.CalcHeightRange, [recursive]);

	public new void ImportImages(Godot.Collections.Array images, Vector3 globalPosition = default, double offset = 0, double scale = 1) => 
		Call(GDExtensionMethodName.ImportImages, [images, globalPosition, offset, scale]);

	public new Error ExportImage(string fileName, Terrain3DRegion.MapType mapType) => 
		Call(GDExtensionMethodName.ExportImage, [fileName, Variant.From(mapType)]).As<Error>();

	public new Image LayeredToImage(Terrain3DRegion.MapType mapType) => 
		Call(GDExtensionMethodName.LayeredToImage, [Variant.From(mapType)]).As<Image>();

	public new void Dump(bool verbose = false) => 
		Call(GDExtensionMethodName.Dump, [verbose]);

}
