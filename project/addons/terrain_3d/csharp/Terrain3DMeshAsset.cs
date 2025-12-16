#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DMeshAsset : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DMeshAsset");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DMeshAsset object), please use the Instantiate() method instead.")]
	protected Terrain3DMeshAsset() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DMeshAsset"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DMeshAsset"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DMeshAsset"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DMeshAsset"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DMeshAsset Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DMeshAsset wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DMeshAsset);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DMeshAsset).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DMeshAsset)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DMeshAsset"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DMeshAsset" type.</returns>
	public new static Terrain3DMeshAsset Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum GenType
	{
		None = 0,
		TextureCard = 1,
		Max = 2,
	}

	public new static class GDExtensionSignalName
	{
		public new static readonly StringName IdChanged = "id_changed";
		public new static readonly StringName SettingChanged = "setting_changed";
		public new static readonly StringName InstancerSettingChanged = "instancer_setting_changed";
		public new static readonly StringName InstanceCountChanged = "instance_count_changed";
	}

	public new delegate void IdChangedSignalHandler();
	private IdChangedSignalHandler _idChangedSignal;
	private Callable _idChangedSignalCallable;
	public event IdChangedSignalHandler IdChangedSignal
	{
		add
		{
			if (_idChangedSignal is null)
			{
				_idChangedSignalCallable = Callable.From(() => 
					_idChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.IdChanged, _idChangedSignalCallable);
			}
			_idChangedSignal += value;
		}
		remove
		{
			_idChangedSignal -= value;
			if (_idChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.IdChanged, _idChangedSignalCallable);
			_idChangedSignalCallable = default;
		}
	}

	public new delegate void SettingChangedSignalHandler();
	private SettingChangedSignalHandler _settingChangedSignal;
	private Callable _settingChangedSignalCallable;
	public event SettingChangedSignalHandler SettingChangedSignal
	{
		add
		{
			if (_settingChangedSignal is null)
			{
				_settingChangedSignalCallable = Callable.From(() => 
					_settingChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.SettingChanged, _settingChangedSignalCallable);
			}
			_settingChangedSignal += value;
		}
		remove
		{
			_settingChangedSignal -= value;
			if (_settingChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.SettingChanged, _settingChangedSignalCallable);
			_settingChangedSignalCallable = default;
		}
	}

	public new delegate void InstancerSettingChangedSignalHandler();
	private InstancerSettingChangedSignalHandler _instancerSettingChangedSignal;
	private Callable _instancerSettingChangedSignalCallable;
	public event InstancerSettingChangedSignalHandler InstancerSettingChangedSignal
	{
		add
		{
			if (_instancerSettingChangedSignal is null)
			{
				_instancerSettingChangedSignalCallable = Callable.From(() => 
					_instancerSettingChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.InstancerSettingChanged, _instancerSettingChangedSignalCallable);
			}
			_instancerSettingChangedSignal += value;
		}
		remove
		{
			_instancerSettingChangedSignal -= value;
			if (_instancerSettingChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.InstancerSettingChanged, _instancerSettingChangedSignalCallable);
			_instancerSettingChangedSignalCallable = default;
		}
	}

	public new delegate void InstanceCountChangedSignalHandler();
	private InstanceCountChangedSignalHandler _instanceCountChangedSignal;
	private Callable _instanceCountChangedSignalCallable;
	public event InstanceCountChangedSignalHandler InstanceCountChangedSignal
	{
		add
		{
			if (_instanceCountChangedSignal is null)
			{
				_instanceCountChangedSignalCallable = Callable.From(() => 
					_instanceCountChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.InstanceCountChanged, _instanceCountChangedSignalCallable);
			}
			_instanceCountChangedSignal += value;
		}
		remove
		{
			_instanceCountChangedSignal -= value;
			if (_instanceCountChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.InstanceCountChanged, _instanceCountChangedSignalCallable);
			_instanceCountChangedSignalCallable = default;
		}
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName Name = "name";
		public new static readonly StringName Id = "id";
		public new static readonly StringName Enabled = "enabled";
		public new static readonly StringName SceneFile = "scene_file";
		public new static readonly StringName GeneratedType = "generated_type";
		public new static readonly StringName HeightOffset = "height_offset";
		public new static readonly StringName Density = "density";
		public new static readonly StringName CastShadows = "cast_shadows";
		public new static readonly StringName VisibilityLayers = "visibility_layers";
		public new static readonly StringName MaterialOverride = "material_override";
		public new static readonly StringName MaterialOverlay = "material_overlay";
		public new static readonly StringName GeneratedFaces = "generated_faces";
		public new static readonly StringName GeneratedSize = "generated_size";
		public new static readonly StringName LodCount = "lod_count";
		public new static readonly StringName LastLod = "last_lod";
		public new static readonly StringName LastShadowLod = "last_shadow_lod";
		public new static readonly StringName ShadowImpostor = "shadow_impostor";
		public new static readonly StringName Lod0Range = "lod0_range";
		public new static readonly StringName Lod1Range = "lod1_range";
		public new static readonly StringName Lod2Range = "lod2_range";
		public new static readonly StringName Lod3Range = "lod3_range";
		public new static readonly StringName Lod4Range = "lod4_range";
		public new static readonly StringName Lod5Range = "lod5_range";
		public new static readonly StringName Lod6Range = "lod6_range";
		public new static readonly StringName Lod7Range = "lod7_range";
		public new static readonly StringName Lod8Range = "lod8_range";
		public new static readonly StringName Lod9Range = "lod9_range";
		public new static readonly StringName FadeMargin = "fade_margin";
	}

	public new string Name
	{
		get => Get(GDExtensionPropertyName.Name).As<string>();
		set => Set(GDExtensionPropertyName.Name, value);
	}

	public new long Id
	{
		get => Get(GDExtensionPropertyName.Id).As<long>();
		set => Set(GDExtensionPropertyName.Id, value);
	}

	public new bool Enabled
	{
		get => Get(GDExtensionPropertyName.Enabled).As<bool>();
		set => Set(GDExtensionPropertyName.Enabled, value);
	}

	public new PackedScene SceneFile
	{
		get => Get(GDExtensionPropertyName.SceneFile).As<PackedScene>();
		set => Set(GDExtensionPropertyName.SceneFile, value);
	}

	public new Variant GeneratedType
	{
		get => Get(GDExtensionPropertyName.GeneratedType).As<Variant>();
		set => Set(GDExtensionPropertyName.GeneratedType, value);
	}

	public new double HeightOffset
	{
		get => Get(GDExtensionPropertyName.HeightOffset).As<double>();
		set => Set(GDExtensionPropertyName.HeightOffset, value);
	}

	public new double Density
	{
		get => Get(GDExtensionPropertyName.Density).As<double>();
		set => Set(GDExtensionPropertyName.Density, value);
	}

	public new Variant CastShadows
	{
		get => Get(GDExtensionPropertyName.CastShadows).As<Variant>();
		set => Set(GDExtensionPropertyName.CastShadows, value);
	}

	public new long VisibilityLayers
	{
		get => Get(GDExtensionPropertyName.VisibilityLayers).As<long>();
		set => Set(GDExtensionPropertyName.VisibilityLayers, value);
	}

	public new Material MaterialOverride
	{
		get => Get(GDExtensionPropertyName.MaterialOverride).As<Material>();
		set => Set(GDExtensionPropertyName.MaterialOverride, value);
	}

	public new Material MaterialOverlay
	{
		get => Get(GDExtensionPropertyName.MaterialOverlay).As<Material>();
		set => Set(GDExtensionPropertyName.MaterialOverlay, value);
	}

	public new long GeneratedFaces
	{
		get => Get(GDExtensionPropertyName.GeneratedFaces).As<long>();
		set => Set(GDExtensionPropertyName.GeneratedFaces, value);
	}

	public new Vector2 GeneratedSize
	{
		get => Get(GDExtensionPropertyName.GeneratedSize).As<Vector2>();
		set => Set(GDExtensionPropertyName.GeneratedSize, value);
	}

	public new long LodCount
	{
		get => Get(GDExtensionPropertyName.LodCount).As<long>();
	}

	public new long LastLod
	{
		get => Get(GDExtensionPropertyName.LastLod).As<long>();
		set => Set(GDExtensionPropertyName.LastLod, value);
	}

	public new long LastShadowLod
	{
		get => Get(GDExtensionPropertyName.LastShadowLod).As<long>();
		set => Set(GDExtensionPropertyName.LastShadowLod, value);
	}

	public new long ShadowImpostor
	{
		get => Get(GDExtensionPropertyName.ShadowImpostor).As<long>();
		set => Set(GDExtensionPropertyName.ShadowImpostor, value);
	}

	public new double Lod0Range
	{
		get => Get(GDExtensionPropertyName.Lod0Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod0Range, value);
	}

	public new double Lod1Range
	{
		get => Get(GDExtensionPropertyName.Lod1Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod1Range, value);
	}

	public new double Lod2Range
	{
		get => Get(GDExtensionPropertyName.Lod2Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod2Range, value);
	}

	public new double Lod3Range
	{
		get => Get(GDExtensionPropertyName.Lod3Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod3Range, value);
	}

	public new double Lod4Range
	{
		get => Get(GDExtensionPropertyName.Lod4Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod4Range, value);
	}

	public new double Lod5Range
	{
		get => Get(GDExtensionPropertyName.Lod5Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod5Range, value);
	}

	public new double Lod6Range
	{
		get => Get(GDExtensionPropertyName.Lod6Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod6Range, value);
	}

	public new double Lod7Range
	{
		get => Get(GDExtensionPropertyName.Lod7Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod7Range, value);
	}

	public new double Lod8Range
	{
		get => Get(GDExtensionPropertyName.Lod8Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod8Range, value);
	}

	public new double Lod9Range
	{
		get => Get(GDExtensionPropertyName.Lod9Range).As<double>();
		set => Set(GDExtensionPropertyName.Lod9Range, value);
	}

	public new double FadeMargin
	{
		get => Get(GDExtensionPropertyName.FadeMargin).As<double>();
		set => Set(GDExtensionPropertyName.FadeMargin, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName Clear = "clear";
		public new static readonly StringName SetHighlighted = "set_highlighted";
		public new static readonly StringName IsHighlighted = "is_highlighted";
		public new static readonly StringName GetHighlightColor = "get_highlight_color";
		public new static readonly StringName GetThumbnail = "get_thumbnail";
		public new static readonly StringName GetMesh = "get_mesh";
		public new static readonly StringName SetLodRange = "set_lod_range";
		public new static readonly StringName GetLodRange = "get_lod_range";
		public new static readonly StringName GetInstanceCount = "get_instance_count";
	}

	public new void Clear() => 
		Call(GDExtensionMethodName.Clear, []);

	public new void SetHighlighted(bool enabled) => 
		Call(GDExtensionMethodName.SetHighlighted, [enabled]);

	public new bool IsHighlighted() => 
		Call(GDExtensionMethodName.IsHighlighted, []).As<bool>();

	public new Color GetHighlightColor() => 
		Call(GDExtensionMethodName.GetHighlightColor, []).As<Color>();

	public new Texture2D GetThumbnail() => 
		Call(GDExtensionMethodName.GetThumbnail, []).As<Texture2D>();

	public new Mesh GetMesh(long lod = 0) => 
		Call(GDExtensionMethodName.GetMesh, [lod]).As<Mesh>();

	public new void SetLodRange(long lod, double distance) => 
		Call(GDExtensionMethodName.SetLodRange, [lod, distance]);

	public new double GetLodRange(long lod) => 
		Call(GDExtensionMethodName.GetLodRange, [lod]).As<double>();

	public new long GetInstanceCount() => 
		Call(GDExtensionMethodName.GetInstanceCount, []).As<long>();

}
