#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DTextureAsset : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DTextureAsset");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DTextureAsset object), please use the Instantiate() method instead.")]
	protected Terrain3DTextureAsset() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DTextureAsset"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DTextureAsset"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DTextureAsset"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DTextureAsset"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DTextureAsset Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DTextureAsset wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DTextureAsset);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DTextureAsset).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DTextureAsset)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DTextureAsset"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DTextureAsset" type.</returns>
	public new static Terrain3DTextureAsset Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public new static class GDExtensionSignalName
	{
		public new static readonly StringName IdChanged = "id_changed";
		public new static readonly StringName FileChanged = "file_changed";
		public new static readonly StringName SettingChanged = "setting_changed";
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

	public new delegate void FileChangedSignalHandler();
	private FileChangedSignalHandler _fileChangedSignal;
	private Callable _fileChangedSignalCallable;
	public event FileChangedSignalHandler FileChangedSignal
	{
		add
		{
			if (_fileChangedSignal is null)
			{
				_fileChangedSignalCallable = Callable.From(() => 
					_fileChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.FileChanged, _fileChangedSignalCallable);
			}
			_fileChangedSignal += value;
		}
		remove
		{
			_fileChangedSignal -= value;
			if (_fileChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.FileChanged, _fileChangedSignalCallable);
			_fileChangedSignalCallable = default;
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

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName Name = "name";
		public new static readonly StringName Id = "id";
		public new static readonly StringName AlbedoColor = "albedo_color";
		public new static readonly StringName AlbedoTexture = "albedo_texture";
		public new static readonly StringName NormalTexture = "normal_texture";
		public new static readonly StringName NormalDepth = "normal_depth";
		public new static readonly StringName AoStrength = "ao_strength";
		public new static readonly StringName AoLightAffect = "ao_light_affect";
		public new static readonly StringName Roughness = "roughness";
		public new static readonly StringName DisplacementScale = "displacement_scale";
		public new static readonly StringName DisplacementOffset = "displacement_offset";
		public new static readonly StringName UvScale = "uv_scale";
		public new static readonly StringName VerticalProjection = "vertical_projection";
		public new static readonly StringName DetilingRotation = "detiling_rotation";
		public new static readonly StringName DetilingShift = "detiling_shift";
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

	public new Color AlbedoColor
	{
		get => Get(GDExtensionPropertyName.AlbedoColor).As<Color>();
		set => Set(GDExtensionPropertyName.AlbedoColor, value);
	}

	public new Texture2D AlbedoTexture
	{
		get => Get(GDExtensionPropertyName.AlbedoTexture).As<Texture2D>();
		set => Set(GDExtensionPropertyName.AlbedoTexture, value);
	}

	public new Texture2D NormalTexture
	{
		get => Get(GDExtensionPropertyName.NormalTexture).As<Texture2D>();
		set => Set(GDExtensionPropertyName.NormalTexture, value);
	}

	public new double NormalDepth
	{
		get => Get(GDExtensionPropertyName.NormalDepth).As<double>();
		set => Set(GDExtensionPropertyName.NormalDepth, value);
	}

	public new double AoStrength
	{
		get => Get(GDExtensionPropertyName.AoStrength).As<double>();
		set => Set(GDExtensionPropertyName.AoStrength, value);
	}

	public new double AoLightAffect
	{
		get => Get(GDExtensionPropertyName.AoLightAffect).As<double>();
		set => Set(GDExtensionPropertyName.AoLightAffect, value);
	}

	public new double Roughness
	{
		get => Get(GDExtensionPropertyName.Roughness).As<double>();
		set => Set(GDExtensionPropertyName.Roughness, value);
	}

	public new double DisplacementScale
	{
		get => Get(GDExtensionPropertyName.DisplacementScale).As<double>();
		set => Set(GDExtensionPropertyName.DisplacementScale, value);
	}

	public new double DisplacementOffset
	{
		get => Get(GDExtensionPropertyName.DisplacementOffset).As<double>();
		set => Set(GDExtensionPropertyName.DisplacementOffset, value);
	}

	public new double UvScale
	{
		get => Get(GDExtensionPropertyName.UvScale).As<double>();
		set => Set(GDExtensionPropertyName.UvScale, value);
	}

	public new bool VerticalProjection
	{
		get => Get(GDExtensionPropertyName.VerticalProjection).As<bool>();
		set => Set(GDExtensionPropertyName.VerticalProjection, value);
	}

	public new double DetilingRotation
	{
		get => Get(GDExtensionPropertyName.DetilingRotation).As<double>();
		set => Set(GDExtensionPropertyName.DetilingRotation, value);
	}

	public new double DetilingShift
	{
		get => Get(GDExtensionPropertyName.DetilingShift).As<double>();
		set => Set(GDExtensionPropertyName.DetilingShift, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName Clear = "clear";
		public new static readonly StringName SetHighlighted = "set_highlighted";
		public new static readonly StringName IsHighlighted = "is_highlighted";
		public new static readonly StringName GetHighlightColor = "get_highlight_color";
		public new static readonly StringName GetThumbnail = "get_thumbnail";
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

}
