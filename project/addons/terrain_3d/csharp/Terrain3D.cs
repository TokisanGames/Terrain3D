#pragma warning disable CS0109
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;
using Godot.Collections;

namespace TokisanGames;

[Tool]
public partial class Terrain3D : Node3D
{

	private new static readonly StringName NativeName = new StringName("Terrain3D");

	[Obsolete("Wrapper types cannot be constructed with constructors (it only instantiate the underlying Terrain3D object), please use the Instantiate() method instead.")]
	protected Terrain3D() { }

	private static CSharpScript _wrapperScriptAsset;

	/// <summary>
	/// Try to cast the script on the supplied <paramref name="godotObject"/> to the <see cref="Terrain3D"/> wrapper type,
	/// if no script has attached to the type, or the script attached to the type does not inherit the <see cref="Terrain3D"/> wrapper type,
	/// a new instance of the <see cref="Terrain3D"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
	/// </summary>
	/// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
	/// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
	/// <returns>The existing or a new instance of the <see cref="Terrain3D"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
	public new static Terrain3D Bind(GodotObject godotObject)
	{
#if DEBUG
		if (!IsInstanceValid(godotObject))
			throw new InvalidOperationException("The supplied GodotObject instance is not valid.");
#endif
		if (godotObject is Terrain3D wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(Terrain3D);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(expectedType.Name, currentObjectClassName))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(Terrain3D).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (Terrain3D)InstanceFromId(instanceId);
	}

	/// <summary>
	/// Creates an instance of the GDExtension <see cref="Terrain3D"/> type, and attaches a wrapper script instance to it.
	/// </summary>
	/// <returns>The wrapper instance linked to the underlying GDExtension "Terrain3D" type.</returns>
	public new static Terrain3D Instantiate() => Bind(ClassDB.Instantiate(NativeName).As<GodotObject>());

	public enum DebugLevelEnum
	{
		Error = 0,
		Info = 1,
		Debug = 2,
		Extreme = 3,
	}

	public enum RegionSizeEnum
	{
		Size64 = 64,
		Size128 = 128,
		Size256 = 256,
		Size512 = 512,
		Size1024 = 1024,
		Size2048 = 2048,
	}

	public new static class GDExtensionSignalName
	{
		public new static readonly StringName MaterialChanged = "material_changed";
		public new static readonly StringName AssetsChanged = "assets_changed";
	}

	public new delegate void MaterialChangedSignalHandler();
	private MaterialChangedSignalHandler _materialChangedSignal;
	private Callable _materialChangedSignalCallable;
	public event MaterialChangedSignalHandler MaterialChangedSignal
	{
		add
		{
			if (_materialChangedSignal is null)
			{
				_materialChangedSignalCallable = Callable.From(() => 
					_materialChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.MaterialChanged, _materialChangedSignalCallable);
			}
			_materialChangedSignal += value;
		}
		remove
		{
			_materialChangedSignal -= value;
			if (_materialChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.MaterialChanged, _materialChangedSignalCallable);
			_materialChangedSignalCallable = default;
		}
	}

	public new delegate void AssetsChangedSignalHandler();
	private AssetsChangedSignalHandler _assetsChangedSignal;
	private Callable _assetsChangedSignalCallable;
	public event AssetsChangedSignalHandler AssetsChangedSignal
	{
		add
		{
			if (_assetsChangedSignal is null)
			{
				_assetsChangedSignalCallable = Callable.From(() => 
					_assetsChangedSignal?.Invoke());
				Connect(GDExtensionSignalName.AssetsChanged, _assetsChangedSignalCallable);
			}
			_assetsChangedSignal += value;
		}
		remove
		{
			_assetsChangedSignal -= value;
			if (_assetsChangedSignal is not null) return;
			Disconnect(GDExtensionSignalName.AssetsChanged, _assetsChangedSignalCallable);
			_assetsChangedSignalCallable = default;
		}
	}

	public new static class GDExtensionPropertyName
	{
		public new static readonly StringName Version = "version";
		public new static readonly StringName DebugLevel = "debug_level";
		public new static readonly StringName DataDirectory = "data_directory";
		public new static readonly StringName Material = "material";
		public new static readonly StringName Assets = "assets";
		public new static readonly StringName Data = "data";
		public new static readonly StringName Collision = "collision";
		public new static readonly StringName Instancer = "instancer";
		public new static readonly StringName RegionSize = "region_size";
		public new static readonly StringName Save16Bit = "save_16_bit";
		public new static readonly StringName LabelDistance = "label_distance";
		public new static readonly StringName LabelSize = "label_size";
		public new static readonly StringName ShowGrid = "show_grid";
		public new static readonly StringName CollisionMode = "collision_mode";
		public new static readonly StringName CollisionShapeSize = "collision_shape_size";
		public new static readonly StringName CollisionRadius = "collision_radius";
		public new static readonly StringName CollisionTarget = "collision_target";
		public new static readonly StringName CollisionLayer = "collision_layer";
		public new static readonly StringName CollisionMask = "collision_mask";
		public new static readonly StringName CollisionPriority = "collision_priority";
		public new static readonly StringName PhysicsMaterial = "physics_material";
		public new static readonly StringName ClipmapTarget = "clipmap_target";
		public new static readonly StringName MeshLods = "mesh_lods";
		public new static readonly StringName MeshSize = "mesh_size";
		public new static readonly StringName VertexSpacing = "vertex_spacing";
		public new static readonly StringName TessellationLevel = "tessellation_level";
		public new static readonly StringName Displacement = "Displacement";
		public new static readonly StringName DisplacementScale = "displacement_scale";
		public new static readonly StringName DisplacementSharpness = "displacement_sharpness";
		public new static readonly StringName BufferShaderOverrideEnabled = "buffer_shader_override_enabled";
		public new static readonly StringName BufferShaderOverride = "buffer_shader_override";
		public new static readonly StringName RenderLayers = "render_layers";
		public new static readonly StringName MouseLayer = "mouse_layer";
		public new static readonly StringName CastShadows = "cast_shadows";
		public new static readonly StringName GiMode = "gi_mode";
		public new static readonly StringName CullMargin = "cull_margin";
		public new static readonly StringName FreeEditorTextures = "free_editor_textures";
		public new static readonly StringName InstancerMode = "instancer_mode";
		public new static readonly StringName ShowRegionGrid = "show_region_grid";
		public new static readonly StringName ShowInstancerGrid = "show_instancer_grid";
		public new static readonly StringName ShowVertexGrid = "show_vertex_grid";
		public new static readonly StringName ShowContours = "show_contours";
		public new static readonly StringName ShowNavigation = "show_navigation";
		public new static readonly StringName ShowCheckered = "show_checkered";
		public new static readonly StringName ShowGrey = "show_grey";
		public new static readonly StringName ShowHeightmap = "show_heightmap";
		public new static readonly StringName ShowJaggedness = "show_jaggedness";
		public new static readonly StringName ShowAutoshader = "show_autoshader";
		public new static readonly StringName ShowControlTexture = "show_control_texture";
		public new static readonly StringName ShowControlBlend = "show_control_blend";
		public new static readonly StringName ShowControlAngle = "show_control_angle";
		public new static readonly StringName ShowControlScale = "show_control_scale";
		public new static readonly StringName ShowColormap = "show_colormap";
		public new static readonly StringName ShowRoughmap = "show_roughmap";
		public new static readonly StringName ShowDisplacementBuffer = "show_displacement_buffer";
		public new static readonly StringName Pbr = "PBR";
		public new static readonly StringName ShowTextureAlbedo = "show_texture_albedo";
		public new static readonly StringName ShowTextureHeight = "show_texture_height";
		public new static readonly StringName ShowTextureNormal = "show_texture_normal";
		public new static readonly StringName ShowTextureRough = "show_texture_rough";
		public new static readonly StringName ShowTextureAo = "show_texture_ao";
	}

	public new string Version
	{
		get => Get(GDExtensionPropertyName.Version).As<string>();
	}

	public new Variant DebugLevel
	{
		get => Get(GDExtensionPropertyName.DebugLevel).As<Variant>();
		set => Set(GDExtensionPropertyName.DebugLevel, value);
	}

	public new string DataDirectory
	{
		get => Get(GDExtensionPropertyName.DataDirectory).As<string>();
		set => Set(GDExtensionPropertyName.DataDirectory, value);
	}

	public new Terrain3DMaterial Material
	{
		get => Terrain3DMaterial.Bind(Get(GDExtensionPropertyName.Material).As<Resource>());
		set => Set(GDExtensionPropertyName.Material, value);
	}

	public new Terrain3DAssets Assets
	{
		get => Terrain3DAssets.Bind(Get(GDExtensionPropertyName.Assets).As<Resource>());
		set => Set(GDExtensionPropertyName.Assets, value);
	}

	public new Terrain3DData Data
	{
		get => Terrain3DData.Bind(Get(GDExtensionPropertyName.Data).As<GodotObject>());
	}

	public new Terrain3DCollision Collision
	{
		get => Terrain3DCollision.Bind(Get(GDExtensionPropertyName.Collision).As<GodotObject>());
	}

	public new Terrain3DInstancer Instancer
	{
		get => Terrain3DInstancer.Bind(Get(GDExtensionPropertyName.Instancer).As<GodotObject>());
	}

	public new Variant RegionSize
	{
		get => Get(GDExtensionPropertyName.RegionSize).As<Variant>();
		set => Set(GDExtensionPropertyName.RegionSize, value);
	}

	public new bool Save16Bit
	{
		get => Get(GDExtensionPropertyName.Save16Bit).As<bool>();
		set => Set(GDExtensionPropertyName.Save16Bit, value);
	}

	public new double LabelDistance
	{
		get => Get(GDExtensionPropertyName.LabelDistance).As<double>();
		set => Set(GDExtensionPropertyName.LabelDistance, value);
	}

	public new long LabelSize
	{
		get => Get(GDExtensionPropertyName.LabelSize).As<long>();
		set => Set(GDExtensionPropertyName.LabelSize, value);
	}

	public new bool ShowGrid
	{
		get => Get(GDExtensionPropertyName.ShowGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowGrid, value);
	}

	public new Variant CollisionMode
	{
		get => Get(GDExtensionPropertyName.CollisionMode).As<Variant>();
		set => Set(GDExtensionPropertyName.CollisionMode, value);
	}

	public new long CollisionShapeSize
	{
		get => Get(GDExtensionPropertyName.CollisionShapeSize).As<long>();
		set => Set(GDExtensionPropertyName.CollisionShapeSize, value);
	}

	public new long CollisionRadius
	{
		get => Get(GDExtensionPropertyName.CollisionRadius).As<long>();
		set => Set(GDExtensionPropertyName.CollisionRadius, value);
	}

	public new Node3D CollisionTarget
	{
		get => Get(GDExtensionPropertyName.CollisionTarget).As<Node3D>();
		set => Set(GDExtensionPropertyName.CollisionTarget, value);
	}

	public new long CollisionLayer
	{
		get => Get(GDExtensionPropertyName.CollisionLayer).As<long>();
		set => Set(GDExtensionPropertyName.CollisionLayer, value);
	}

	public new long CollisionMask
	{
		get => Get(GDExtensionPropertyName.CollisionMask).As<long>();
		set => Set(GDExtensionPropertyName.CollisionMask, value);
	}

	public new double CollisionPriority
	{
		get => Get(GDExtensionPropertyName.CollisionPriority).As<double>();
		set => Set(GDExtensionPropertyName.CollisionPriority, value);
	}

	public new PhysicsMaterial PhysicsMaterial
	{
		get => Get(GDExtensionPropertyName.PhysicsMaterial).As<PhysicsMaterial>();
		set => Set(GDExtensionPropertyName.PhysicsMaterial, value);
	}

	public new Node3D ClipmapTarget
	{
		get => Get(GDExtensionPropertyName.ClipmapTarget).As<Node3D>();
		set => Set(GDExtensionPropertyName.ClipmapTarget, value);
	}

	public new long MeshLods
	{
		get => Get(GDExtensionPropertyName.MeshLods).As<long>();
		set => Set(GDExtensionPropertyName.MeshLods, value);
	}

	public new long MeshSize
	{
		get => Get(GDExtensionPropertyName.MeshSize).As<long>();
		set => Set(GDExtensionPropertyName.MeshSize, value);
	}

	public new double VertexSpacing
	{
		get => Get(GDExtensionPropertyName.VertexSpacing).As<double>();
		set => Set(GDExtensionPropertyName.VertexSpacing, value);
	}

	public new long TessellationLevel
	{
		get => Get(GDExtensionPropertyName.TessellationLevel).As<long>();
		set => Set(GDExtensionPropertyName.TessellationLevel, value);
	}

	public new double DisplacementScale
	{
		get => Get(GDExtensionPropertyName.DisplacementScale).As<double>();
		set => Set(GDExtensionPropertyName.DisplacementScale, value);
	}

	public new double DisplacementSharpness
	{
		get => Get(GDExtensionPropertyName.DisplacementSharpness).As<double>();
		set => Set(GDExtensionPropertyName.DisplacementSharpness, value);
	}

	public new bool BufferShaderOverrideEnabled
	{
		get => Get(GDExtensionPropertyName.BufferShaderOverrideEnabled).As<bool>();
		set => Set(GDExtensionPropertyName.BufferShaderOverrideEnabled, value);
	}

	public new Shader BufferShaderOverride
	{
		get => Get(GDExtensionPropertyName.BufferShaderOverride).As<Shader>();
		set => Set(GDExtensionPropertyName.BufferShaderOverride, value);
	}

	public new long RenderLayers
	{
		get => Get(GDExtensionPropertyName.RenderLayers).As<long>();
		set => Set(GDExtensionPropertyName.RenderLayers, value);
	}

	public new long MouseLayer
	{
		get => Get(GDExtensionPropertyName.MouseLayer).As<long>();
		set => Set(GDExtensionPropertyName.MouseLayer, value);
	}

	public new Variant CastShadows
	{
		get => Get(GDExtensionPropertyName.CastShadows).As<Variant>();
		set => Set(GDExtensionPropertyName.CastShadows, value);
	}

	public new long GiMode
	{
		get => Get(GDExtensionPropertyName.GiMode).As<long>();
		set => Set(GDExtensionPropertyName.GiMode, value);
	}

	public new double CullMargin
	{
		get => Get(GDExtensionPropertyName.CullMargin).As<double>();
		set => Set(GDExtensionPropertyName.CullMargin, value);
	}

	public new bool FreeEditorTextures
	{
		get => Get(GDExtensionPropertyName.FreeEditorTextures).As<bool>();
		set => Set(GDExtensionPropertyName.FreeEditorTextures, value);
	}

	public new Terrain3DInstancer.InstancerMode InstancerMode
	{
		get => Get(GDExtensionPropertyName.InstancerMode).As<Terrain3DInstancer.InstancerMode>();
		set => Set(GDExtensionPropertyName.InstancerMode, Variant.From(value));
	}

	public new bool ShowRegionGrid
	{
		get => Get(GDExtensionPropertyName.ShowRegionGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowRegionGrid, value);
	}

	public new bool ShowInstancerGrid
	{
		get => Get(GDExtensionPropertyName.ShowInstancerGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowInstancerGrid, value);
	}

	public new bool ShowVertexGrid
	{
		get => Get(GDExtensionPropertyName.ShowVertexGrid).As<bool>();
		set => Set(GDExtensionPropertyName.ShowVertexGrid, value);
	}

	public new bool ShowContours
	{
		get => Get(GDExtensionPropertyName.ShowContours).As<bool>();
		set => Set(GDExtensionPropertyName.ShowContours, value);
	}

	public new bool ShowNavigation
	{
		get => Get(GDExtensionPropertyName.ShowNavigation).As<bool>();
		set => Set(GDExtensionPropertyName.ShowNavigation, value);
	}

	public new bool ShowCheckered
	{
		get => Get(GDExtensionPropertyName.ShowCheckered).As<bool>();
		set => Set(GDExtensionPropertyName.ShowCheckered, value);
	}

	public new bool ShowGrey
	{
		get => Get(GDExtensionPropertyName.ShowGrey).As<bool>();
		set => Set(GDExtensionPropertyName.ShowGrey, value);
	}

	public new bool ShowHeightmap
	{
		get => Get(GDExtensionPropertyName.ShowHeightmap).As<bool>();
		set => Set(GDExtensionPropertyName.ShowHeightmap, value);
	}

	public new bool ShowJaggedness
	{
		get => Get(GDExtensionPropertyName.ShowJaggedness).As<bool>();
		set => Set(GDExtensionPropertyName.ShowJaggedness, value);
	}

	public new bool ShowAutoshader
	{
		get => Get(GDExtensionPropertyName.ShowAutoshader).As<bool>();
		set => Set(GDExtensionPropertyName.ShowAutoshader, value);
	}

	public new bool ShowControlTexture
	{
		get => Get(GDExtensionPropertyName.ShowControlTexture).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlTexture, value);
	}

	public new bool ShowControlBlend
	{
		get => Get(GDExtensionPropertyName.ShowControlBlend).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlBlend, value);
	}

	public new bool ShowControlAngle
	{
		get => Get(GDExtensionPropertyName.ShowControlAngle).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlAngle, value);
	}

	public new bool ShowControlScale
	{
		get => Get(GDExtensionPropertyName.ShowControlScale).As<bool>();
		set => Set(GDExtensionPropertyName.ShowControlScale, value);
	}

	public new bool ShowColormap
	{
		get => Get(GDExtensionPropertyName.ShowColormap).As<bool>();
		set => Set(GDExtensionPropertyName.ShowColormap, value);
	}

	public new bool ShowRoughmap
	{
		get => Get(GDExtensionPropertyName.ShowRoughmap).As<bool>();
		set => Set(GDExtensionPropertyName.ShowRoughmap, value);
	}

	public new bool ShowDisplacementBuffer
	{
		get => Get(GDExtensionPropertyName.ShowDisplacementBuffer).As<bool>();
		set => Set(GDExtensionPropertyName.ShowDisplacementBuffer, value);
	}

	public new bool ShowTextureAlbedo
	{
		get => Get(GDExtensionPropertyName.ShowTextureAlbedo).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureAlbedo, value);
	}

	public new bool ShowTextureHeight
	{
		get => Get(GDExtensionPropertyName.ShowTextureHeight).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureHeight, value);
	}

	public new bool ShowTextureNormal
	{
		get => Get(GDExtensionPropertyName.ShowTextureNormal).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureNormal, value);
	}

	public new bool ShowTextureRough
	{
		get => Get(GDExtensionPropertyName.ShowTextureRough).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureRough, value);
	}

	public new bool ShowTextureAo
	{
		get => Get(GDExtensionPropertyName.ShowTextureAo).As<bool>();
		set => Set(GDExtensionPropertyName.ShowTextureAo, value);
	}

	public new static class GDExtensionMethodName
	{
		public new static readonly StringName SetEditor = "set_editor";
		public new static readonly StringName GetEditor = "get_editor";
		public new static readonly StringName SetPlugin = "set_plugin";
		public new static readonly StringName GetPlugin = "get_plugin";
		public new static readonly StringName SetCamera = "set_camera";
		public new static readonly StringName GetCamera = "get_camera";
		public new static readonly StringName GetClipmapTargetPosition = "get_clipmap_target_position";
		public new static readonly StringName GetCollisionTargetPosition = "get_collision_target_position";
		public new static readonly StringName Snap = "snap";
		public new static readonly StringName GetIntersection = "get_intersection";
		public new static readonly StringName GetRaycastResult = "get_raycast_result";
		public new static readonly StringName BakeMesh = "bake_mesh";
		public new static readonly StringName GenerateNavMeshSourceGeometry = "generate_nav_mesh_source_geometry";
	}

	public new void SetEditor(Terrain3DEditor editor) => 
		Call(GDExtensionMethodName.SetEditor, [editor]);

	public new Terrain3DEditor GetEditor() => 
		Terrain3DEditor.Bind(Call(GDExtensionMethodName.GetEditor, []).As<GodotObject>());

	public new void SetPlugin(GodotObject plugin) => 
		Call(GDExtensionMethodName.SetPlugin, [plugin]);

	public new GodotObject GetPlugin() => 
		Call(GDExtensionMethodName.GetPlugin, []).As<GodotObject>();

	public new void SetCamera(Camera3D camera) => 
		Call(GDExtensionMethodName.SetCamera, [camera]);

	public new Camera3D GetCamera() => 
		Call(GDExtensionMethodName.GetCamera, []).As<Camera3D>();

	public new Vector3 GetClipmapTargetPosition() => 
		Call(GDExtensionMethodName.GetClipmapTargetPosition, []).As<Vector3>();

	public new Vector3 GetCollisionTargetPosition() => 
		Call(GDExtensionMethodName.GetCollisionTargetPosition, []).As<Vector3>();

	public new void Snap() => 
		Call(GDExtensionMethodName.Snap, []);

	public new Vector3 GetIntersection(Vector3 srcPos, Vector3 direction, bool gpuMode = false) => 
		Call(GDExtensionMethodName.GetIntersection, [srcPos, direction, gpuMode]).As<Vector3>();

	public new Godot.Collections.Dictionary GetRaycastResult(Vector3 srcPos, Vector3 direction, long collisionMask = 4294967295, bool excludeTerrain = false) => 
		Call(GDExtensionMethodName.GetRaycastResult, [srcPos, direction, collisionMask, excludeTerrain]).As<Godot.Collections.Dictionary>();

	public new Mesh BakeMesh(long lod, Terrain3DData.HeightFilter filter = Terrain3DData.HeightFilter.Nearest) => 
		Call(GDExtensionMethodName.BakeMesh, [lod, Variant.From(filter)]).As<Mesh>();

	public new Vector3[] GenerateNavMeshSourceGeometry(Aabb globalAabb, bool requireNav = true) => 
		Call(GDExtensionMethodName.GenerateNavMeshSourceGeometry, [globalAabb, requireNav]).As<Vector3[]>();

}
