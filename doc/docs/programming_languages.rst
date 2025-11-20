Programming Languages
=====================

Any language Godot supports should be able to work with Terrain3D via
the GDExtension interface. This includes
`C# <https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/index.html>`__,
and `several
others <https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/what_is_gdextension.html#supported-languages>`__.

Here are some tips for integrating with Terrain3D.

.. image:: images/integrating_gdextension.jpg
   :target: ../_images/integrating_gdextension.jpg

Detecting If Terrain3D Is Installed
-----------------------------------

To determine if Terrain3D is installed and active, `ask
Godot <https://docs.godotengine.org/en/stable/classes/class_editorinterface.html#class-editorinterface-method-is-plugin-enabled>`__. This works only in the editor for tool scripts and editor plugins.

C# might be different depending if you're using the generated bindings :doc:`Generating C# Bindings <generating_csharp_bindings>`.

.. tabs::
   .. tab:: GDScript
        .. code:: gdscript

            print("Terrain3D enabled: ", EditorInterface.is_plugin_enabled("terrain_3d"))

   .. tab:: C#
        .. code:: c#

            GD.Print("Terrain3D enabled: ", EditorInterface.Singleton.IsPluginEnabled("Terrain3D"));

   .. tab:: C# (Bindings)
        .. code:: c#

            using TokisanGames;
            ...
            GD.Print("Terrain3D enabled: ", EditorInterface.Singleton.IsPluginEnabled(nameof(Terrain3D)));


You can also ask ClassDB if the class exists:

.. tabs::
   .. tab:: GDScript
        .. code:: gdscript

            ClassDB.class_exists("Terrain3D")
            ClassDB.can_instantiate("Terrain3D")

   .. tab:: C#
        .. code:: c#

            ClassDB.ClassExists("Terrain3D");
            ClassDB.CanInstantiate("Terrain3D");

   .. tab:: C# (Bindings)
        .. code:: c#

            using TokisanGames;
            ...
            ClassDB.ClassExists(nameof(Terrain3D));
            ClassDB.CanInstantiate(nameof(Terrain3D));


Instantiating & Calling Terrain3D
---------------------------------

Terrain3D is instantiated and referenced like any other object.

See the ``CodeGeneratedDemo.tscn`` or `CodeGeneratedCSDemo.tscn` demos for examples of initiating
Terrain3D from script.

.. tabs::
   .. tab:: GDScript
        .. code:: gdscript

            var terrain: Terrain3D = Terrain3D.new()
            print(terrain.get_version())
            terrain.assets = Terrain3DAssets.new()

   .. tab:: C#
        .. code:: c#

            var terrain = ClassDB.Instantiate("Terrain3D");
            GD.Print("Terrain3D version: ", terrain.AsGodotObject().Call("get_version"));
            terrain.AsGodotObject().Set("assets", ClassDB.Instantiate("Terrain3DAssets"));

   .. tab:: C# (Bindings)
        .. code:: c#

            using TokisanGames;
            ...
            Terrain3D terrain = Terrain3D.Instantiate();
            GD.Print("Terrain3D version: ", terrain.Version);
            terrain.Assets = Terrain3DAssets.Instantiate();

You can also check if a node is a Terrain3D object:

.. tabs::
   .. tab:: GDScript
        .. code:: gdscript

            if node is Terrain3D:

   .. tab:: C#
        .. code:: c#

            if (myNode.IsClass("Terrain3D")) {

   .. tab:: C# (Bindings)
        .. code:: c#

            using TokisanGames;
            ...
            if (myNode.IsClass(nameof(Terrain3D))) {


For more information on C# and other languages, read `Cross-language
scripting <https://docs.godotengine.org/en/stable/tutorials/scripting/cross_language_scripting.html>`__
in the Godot docs.

Finding the Terrain3D Instance
------------------------------

These options are for programming scenarios where a user action is
intented to provide your code with the Terrain3D instance.

-  If collision is enabled in game (default) or in the editor (debug
   only), you can run a raycast and if it hits, it will return a
   ``Terrain3D`` object. See more in the
   `raycasting <collision.md#physics-based-collision-raycasting>`__
   section.

-  Your script can provide a NodePath and allow the user to select their
   Terrain3D node.

-  You can search the current scene tree for `nodes of
   type <https://docs.godotengine.org/en/stable/classes/class_node.html#class-node-method-find-children>`__
   “Terrain3D”.

.. tabs::
   .. tab:: GDScript
        .. code:: gdscript

            var terrain: Terrain3D # or Node if you aren't sure if it's installed
            if Engine.is_editor_hint(): # In editor
                terrain = get_tree().get_edited_scene_root().find_children("*", "Terrain3D").front()
            else: # In game
                terrain = get_tree().get_current_scene().find_children("*", "Terrain3D").front()
            if terrain:
                print("Found terrain")

   .. tab:: C# (Bindings)
        .. code:: c#

            using System.Linq;
            using TokisanGames;
            ...
            Terrain3D terrain;
            Node terrainNode;
            if (Engine.IsEditorHint())
                terrainNode = GetTree().GetEditedSceneRoot().FindChildren("*", nameof(Terrain3D)).FirstOrDefault();
            else
                terrainNode = GetTree().GetCurrentScene().FindChildren("*", nameof(Terrain3D)).FirstOrDefault();
            if (terrainNode != null)
            {
                terrain = Terrain3D.Bind(terrainNode);
                GD.Print("Found terrain: ", terrain);
            }

Detecting Terrain Height
------------------------

See `Collision <collision.md>`__ for several methods.

Getting Updates on Terrain Changes
----------------------------------

``Terrain3DData`` has
`signals <../api/class_terrain3ddata.rst#signals>`__ that fire when
updates occur. You can connect to them to receive updates.
