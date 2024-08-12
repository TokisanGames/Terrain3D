using System;
using System.Linq;
using System.Reflection;
using System.Collections.Concurrent;
using Godot;

public static class GDExtensionHelper
{
    private static readonly ConcurrentDictionary<string, GodotObject> _instances = new ();
    private static readonly ConcurrentDictionary<Type,Variant> _scripts = new ();
    /// <summary>
    /// Calls a static method within the given type.
    /// </summary>
    /// <param name="className">The type name.</param>
    /// <param name="method">The method name.</param>
    /// <param name="arguments">The arguments.</param>
    /// <returns>The return value of the method.</returns>
    public static Variant Call(string className, string method, params Variant[] arguments)
    {
        return _instances.GetOrAdd(className,InstantiateStaticFactory).Call(method, arguments);
    }
    
    private static GodotObject InstantiateStaticFactory(string className) => ClassDB.Instantiate(className).As<GodotObject>();
    
    /// <summary>
    /// Try to cast the script on the supplied <paramref name="godotObject"/> to the <typeparamref name="T"/> wrapper type,
    /// if no script has attached to the type, or the script attached to the type does not inherit the <typeparamref name="T"/> wrapper type,
    /// a new instance of the <typeparamref name="T"/> wrapper script will get attaches to the <paramref name="godotObject"/>.
    /// </summary>
    /// <remarks>The developer should only supply the <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</remarks>
    /// <param name="godotObject">The <paramref name="godotObject"/> that represents the correct underlying GDExtension type.</param>
    /// <returns>The existing or a new instance of the <typeparamref name="T"/> wrapper script attached to the supplied <paramref name="godotObject"/>.</returns>
    public static T Bind<T>(GodotObject godotObject) where T : GodotObject
    {
#if DEBUG
        if (!GodotObject.IsInstanceValid(godotObject)) throw new ArgumentException(nameof(godotObject),"The supplied GodotObject is not valid.");
#endif
        if (godotObject is T wrapperScript) return wrapperScript;
        var type = typeof(T);
#if DEBUG
        var className = godotObject.GetClass();
        if (!ClassDB.IsParentClass(type.Name, className)) throw new ArgumentException(nameof(godotObject),$"The supplied GodotObject {className} is not a {type.Name}.");
#endif
        var script =_scripts.GetOrAdd(type,GetScriptFactory);
        var instanceId = godotObject.GetInstanceId();
        godotObject.SetScript(script);
        return (T)GodotObject.InstanceFromId(instanceId);
    }
    
    private static Variant GetScriptFactory(Type type)
    {
        var scriptPath = type.GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
        return scriptPath is null ? null : ResourceLoader.Load(scriptPath.Path);
    }

    public static Godot.Collections.Array<T> Cast<[MustBeVariant]T>(Godot.Collections.Array<GodotObject> godotObjects) where T : GodotObject
    {
        return new Godot.Collections.Array<T>(godotObjects.Select(Bind<T>));
    }
    
    /// <summary>
    /// Creates an instance of the GDExtension <typeparam name="T"/> type, and attaches the wrapper script to it.
    /// </summary>
    /// <returns>The wrapper instance linked to the underlying GDExtension type.</returns>
    public static T Instantiate<T>(StringName className) where T : GodotObject
    {
        return Bind<T>(ClassDB.Instantiate(className).As<GodotObject>());
    }
}