using Godot;
using System;
using System.Threading.Tasks;

namespace TokisanGames
{
	public partial class CodeGenerated : Node
	{
		private Terrain3D terrain;

		public override void _Ready()
		{
			var ui = GetNode<Control>("UI");
			var player = GetNode<CharacterBody3D>("Player");
			ui.Set("player", player);

			if (HasNode("RunThisSceneLabel3D"))
			{
				GetNode<Label3D>("RunThisSceneLabel3D").QueueFree();
			}
			
			_ = CreateTerrainAsync();
		}

		private async Task CreateTerrainAsync()
		{
			terrain = await CreateAndConfigureTerrain();
			
			var baker = GetNode<Node>("RuntimeNavigationBaker");
			if (baker != null)
			{
				baker.Set("terrain", terrain);
				baker.Set("enabled", true);
			}
			else
			{
				GD.Print("ERROR: RuntimeNavigationBaker node not found!");
			}
		}

		private async Task<Terrain3D> CreateAndConfigureTerrain()
		{
			var greenGr = new Gradient();
			greenGr.SetColor(0, Color.FromHsv(100f / 360f, 0.35f, 0.3f));
			greenGr.SetColor(1, Color.FromHsv(120f / 360f, 0.4f, 0.37f));
			var greenTa = await CreateTextureAsset("Grass", greenGr, 1024);
			greenTa.Set("uv_scale", 0.02f);

			var brownGr = new Gradient();
			brownGr.SetColor(0, Color.FromHsv(30f / 360f, 0.4f, 0.3f));
			brownGr.SetColor(1, Color.FromHsv(30f / 360f, 0.4f, 0.4f));
			var brownTa = await CreateTextureAsset("Dirt", brownGr, 1024);
			brownTa.Set("uv_scale", 0.03f);

			var grassMa = CreateMeshAsset("Grass", Color.FromHsv(120f / 360f, 0.4f, 0.37f));
			
			var terrain = Terrain3D.Instantiate();
			terrain.Name = "Terrain3D";
			AddChild(terrain);
			
			var assets = Terrain3DAssets.Instantiate();
			terrain.Assets = assets;
			assets.SetTexture(0, greenTa);
			assets.SetTexture(1, brownTa);
			assets.SetMeshAsset(0, grassMa);
			
			var material = Terrain3DMaterial.Instantiate();
			terrain.Material = material;
			material.WorldBackground = Terrain3DMaterial.WorldBackgroundEnum.None;
			material.AutoShaderEnabled = true;
			material.SetShaderParam("auto_slope", 10f);
			material.SetShaderParam("blend_sharpness", 0.975f);
			
			var noise = new FastNoiseLite { Frequency = 0.0005f };
			var img = Image.CreateEmpty(2048, 2048, false, Image.Format.Rf);
			for (int x = 0; x < img.GetWidth(); x++)
			{
				for (int y = 0; y < img.GetHeight(); y++)
				{
					img.SetPixel(x, y, new Color(noise.GetNoise2D(x, y), 0f, 0f, 1f));
				}
			}
			terrain.RegionSize = 1024;
			
			var data = terrain.Get("data").As<GodotObject>();
			var images = new Godot.Collections.Array { img, new Variant(), new Variant() };
			data.Call("import_images", images, new Vector3(-1024, 0, -1024), 0.0, 150.0);
			var instancer = terrain.Get("instancer").As<GodotObject>();
			var xforms = new Godot.Collections.Array();
			int width = 100;
			int step = 2;
			for (int x = 0; x < width; x += step)
			{
				for (int z = 0; z < width; z += step)
				{
					var pos = new Vector3(x, 0, z) - new Vector3(width, 0, width) * 0.5f;
					pos.Y = data.Call("get_height", pos).As<float>();
					xforms.Add(new Transform3D(Basis.Identity, pos));
				}
			}
			instancer.Call("add_transforms", 0, xforms);
			
			return terrain;
		}

		private async Task<Terrain3DTextureAsset> CreateTextureAsset(string assetName, Gradient gradient, int textureSize = 512)
		{
			var fnl = new FastNoiseLite { Frequency = 0.004f };

			var albNoiseTex = new NoiseTexture2D
			{
				Width = textureSize,
				Height = textureSize,
				Seamless = true,
				Noise = fnl,
				ColorRamp = gradient
			};
			await ToSignal(albNoiseTex, NoiseTexture2D.SignalName.Changed);
			var albNoiseImg = albNoiseTex.GetImage();
			
			for (int x = 0; x < albNoiseImg.GetWidth(); x++)
			{
				for (int y = 0; y < albNoiseImg.GetHeight(); y++)
				{
					var clr = albNoiseImg.GetPixel(x, y);
					clr.A = clr.V;
					albNoiseImg.SetPixel(x, y, clr);
				}
			}
			albNoiseImg.GenerateMipmaps();
			var albedo = ImageTexture.CreateFromImage(albNoiseImg);
			
			var nrmNoiseTex = new NoiseTexture2D
			{
				Width = textureSize,
				Height = textureSize,
				AsNormalMap = true,
				Seamless = true,
				Noise = fnl
			};
			await ToSignal(nrmNoiseTex, NoiseTexture2D.SignalName.Changed);
			var nrmNoiseImg = nrmNoiseTex.GetImage();
			for (int x = 0; x < nrmNoiseImg.GetWidth(); x++)
			{
				for (int y = 0; y < nrmNoiseImg.GetHeight(); y++)
				{
					var normalRgh = nrmNoiseImg.GetPixel(x, y);
					normalRgh.A = 0.8f;
					nrmNoiseImg.SetPixel(x, y, normalRgh);
				}
			}
			nrmNoiseImg.GenerateMipmaps();
			var normal = ImageTexture.CreateFromImage(nrmNoiseImg);
			
			var ta = (Terrain3DTextureAsset)Terrain3DTextureAsset.Instantiate();
			ta.Name = assetName;
			ta.AlbedoTexture = albedo;
			ta.NormalTexture = normal;
			return ta;
		}

		private Terrain3DMeshAsset CreateMeshAsset(string assetName, Color color)
		{
			var ma = (Terrain3DMeshAsset)Terrain3DMeshAsset.Instantiate();
			ma.Name = assetName;
			ma.Set("generated_type", 1);
			if (ma.MaterialOverride is StandardMaterial3D material)
			{
				material.AlbedoColor = color;
			}
			return ma;
		}
	}
}
