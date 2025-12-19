#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3DAssets : Resource
{

	private new static readonly StringName NativeName = new StringName("Terrain3DAssets");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3DAssets object), please use the Instantiate() method instead.")]
	protected Terrain3DAssets() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3DAssets"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3DAssets"/> wrapper type,
	/// a new instance of the <see cref="Terrain3DAssets"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3DAssets"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3DAssets Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3DAssets wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3DAssets);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3DAssets).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3DAssets)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3DAssets"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3DAssets" type.</returns>
	public new static Terrain3DAssets Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum AssetType
	{
		Texture = 0,
		Mesh = 1,
	}

	public new static class GDExtensionSignalName
	{
		public new static readonly StringName MeshesChanged = "meshes_changed";
		public new static readonly StringName TexturesChanged = "textures_changed";
	}

	public new delegate void MeshesChangedSignalHandler();
	private MeshesChangedSignalHandler _meshesChangedSignal;
	private Callable _meshesChangedSignalCallable;
	public event MeshesChangedSignalHandler MeshesChangedSignal
	{
		add
		{
			if (_meshesChangedSignal is null)
			{
				_meshesChangedSignalCallable = Callable.From(() => 
					_meshesChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.MeshesChanged, _meshesChangedSignalCallable);
			}
			_meshesChangedSignal += value;
		}
		remove
		{
			_meshesChangedSignal -= value;
			if (_meshesChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.MeshesChanged, _meshesChangedSignalCallable);
			_meshesChangedSignalCallable = default;
		}
	}

	public new delegate void TexturesChangedSignalHandler();
	private TexturesChangedSignalHandler _texturesChangedSignal;
	private Callable _texturesChangedSignalCallable;
	public event TexturesChangedSignalHandler TexturesChangedSignal
	{
		add
		{
			if (_texturesChangedSignal is null)
			{
				_texturesChangedSignalCallable = Callable.From(() => 
					_texturesChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.TexturesChanged, _texturesChangedSignalCallable);
			}
			_texturesChangedSignal += value;
		}
		remove
		{
			_texturesChangedSignal -= value;
			if (_texturesChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.TexturesChanged, _texturesChangedSignalCallable);
			_texturesChangedSignalCallable = default;
		}
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName MeshList = "mesh_list";
		public new static readonly StringName TextureList = "texture_list";
	}

	public new Godot.Collections.Array MeshList
	{
		get => Get(GDExtensionPropertyName.MeshList).As<Godot.Collections.Array>();
		set => Set(GDExtensionPropertyName.MeshList, value);
	}

	public new Godot.Collections.Array TextureList
	{
		get => Get(GDExtensionPropertyName.TextureList).As<Godot.Collections.Array>();
		set => Set(GDExtensionPropertyName.TextureList, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName SetTextureAsset = "set_texture_asset";
		public new static readonly StringName GetTextureAsset = "get_texture_asset";
		public new static readonly StringName GetTextureCount = "get_texture_count";
		public new static readonly StringName GetAlbedoArrayRid = "get_albedo_array_rid";
		public new static readonly StringName GetNormalArrayRid = "get_normal_array_rid";
		public new static readonly StringName GetTextureColors = "get_texture_colors";
		public new static readonly StringName GetTextureNormalDepths = "get_texture_normal_depths";
		public new static readonly StringName GetTextureAoStrengths = "get_texture_ao_strengths";
		public new static readonly StringName GetTextureAoLightAffects = "get_texture_ao_light_affects";
		public new static readonly StringName GetTextureRoughnessMods = "get_texture_roughness_mods";
		public new static readonly StringName GetTextureUvScales = "get_texture_uv_scales";
		public new static readonly StringName GetTextureVerticalProjections = "get_texture_vertical_projections";
		public new static readonly StringName GetTextureDetiles = "get_texture_detiles";
		public new static readonly StringName GetTextureDisplacements = "get_texture_displacements";
		public new static readonly StringName ClearTextures = "clear_textures";
		public new static readonly StringName UpdateTextureList = "update_texture_list";
		public new static readonly StringName SetMeshAsset = "set_mesh_asset";
		public new static readonly StringName GetMeshAsset = "get_mesh_asset";
		public new static readonly StringName GetMeshCount = "get_mesh_count";
		public new static readonly StringName CreateMeshThumbnails = "create_mesh_thumbnails";
		public new static readonly StringName UpdateMeshList = "update_mesh_list";
		public new static readonly StringName Save = "save";
	}

	public new void SetTextureAsset(long id, Terrain3DTextureAsset texture) => 
		Call(GDExtensionMethodName.SetTextureAsset, [id, texture]);

	public new Terrain3DTextureAsset GetTextureAsset(long id) => 
		Terrain3DTextureAsset.Bind(Call(GDExtensionMethodName.GetTextureAsset, [id]).As<Resource>());

	public new long GetTextureCount() => 
		Call(GDExtensionMethodName.GetTextureCount, []).As<long>();

	public new Rid GetAlbedoArrayRid() => 
		Call(GDExtensionMethodName.GetAlbedoArrayRid, []).As<Rid>();

	public new Rid GetNormalArrayRid() => 
		Call(GDExtensionMethodName.GetNormalArrayRid, []).As<Rid>();

	public new Color[] GetTextureColors() => 
		Call(GDExtensionMethodName.GetTextureColors, []).As<Color[]>();

	public new float[] GetTextureNormalDepths() => 
		Call(GDExtensionMethodName.GetTextureNormalDepths, []).As<float[]>();

	public new float[] GetTextureAoStrengths() => 
		Call(GDExtensionMethodName.GetTextureAoStrengths, []).As<float[]>();

	public new float[] GetTextureAoLightAffects() => 
		Call(GDExtensionMethodName.GetTextureAoLightAffects, []).As<float[]>();

	public new float[] GetTextureRoughnessMods() => 
		Call(GDExtensionMethodName.GetTextureRoughnessMods, []).As<float[]>();

	public new float[] GetTextureUvScales() => 
		Call(GDExtensionMethodName.GetTextureUvScales, []).As<float[]>();

	public new long GetTextureVerticalProjections() => 
		Call(GDExtensionMethodName.GetTextureVerticalProjections, []).As<long>();

	public new Vector2[] GetTextureDetiles() => 
		Call(GDExtensionMethodName.GetTextureDetiles, []).As<Vector2[]>();

	public new Vector2[] GetTextureDisplacements() => 
		Call(GDExtensionMethodName.GetTextureDisplacements, []).As<Vector2[]>();

	public new void ClearTextures(bool update = false) => 
		Call(GDExtensionMethodName.ClearTextures, [update]);

	public new void UpdateTextureList() => 
		Call(GDExtensionMethodName.UpdateTextureList, []);

	public new void SetMeshAsset(long id, Terrain3DMeshAsset mesh) => 
		Call(GDExtensionMethodName.SetMeshAsset, [id, mesh]);

	public new Terrain3DMeshAsset GetMeshAsset(long id) => 
		Terrain3DMeshAsset.Bind(Call(GDExtensionMethodName.GetMeshAsset, [id]).As<Resource>());

	public new long GetMeshCount() => 
		Call(GDExtensionMethodName.GetMeshCount, []).As<long>();

	public new void CreateMeshThumbnails(long id = -1, Vector2I size = default, bool force = false) => 
		Call(GDExtensionMethodName.CreateMeshThumbnails, [id, size, force]);

	public new void UpdateMeshList() => 
		Call(GDExtensionMethodName.UpdateMeshList, []);

	public new Error Save(string path = "") => 
		Call(GDExtensionMethodName.Save, [path]).As<Error>();

}
