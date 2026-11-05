using System;
using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== Runtime：静态结构 + 调用 ====================

internal sealed class Runtime
{
    public readonly List<Func<object?[], object?>> HostFuncs = new();
    public readonly Dictionary<string, int> HostFuncMap = new(); // 名 -> HostFuncs 序号
    public readonly Dictionary<string, int> MemberNameMap = new(); // 成员名 -> 成员 id
    public readonly List<FunctionInfo> Functions = new();
    public readonly List<ClassInfo> Classes = new();
    public readonly ObjectManager ObjMgr;
    public readonly DemoApi Api;

    public Runtime()
    {
        ObjMgr = new ObjectManager(this);
        Api = new DemoApi(ObjMgr);
    }

    public int NewMemberId(string nm)
    {
        if (MemberNameMap.TryGetValue(nm, out var id)) return id;
        id = MemberNameMap.Count;
        MemberNameMap[nm] = id;
        return id;
    }

    public ClassInfo NewClass()
    {
        var c = new ClassInfo { Id = Classes.Count };
        Classes.Add(c);
        return c;
    }

    public FunctionInfo? FindFunction(string nm)
    {
        foreach (var f in Functions)
            if (f.Name == nm)
                return f;
        return null;
    }

    public void AddHostFunction(string nm, Func<object?[], object?> fn)
    {
        HostFuncMap[nm] = HostFuncs.Count;
        HostFuncs.Add(fn);
    }

    // 方法调用：每层调用一个临时 State，随返回销毁 —— 嵌套调用就是 C# 的
    // 递归栈。Runtime 不保存调用栈（demo 6 做根扫描时才需要）。
    public object? InvokeMethod(MethodInfo m, MyObject obj, object?[] args)
    {
        var state = new State();
        state.SetApi(Api);
        state.SetProgram(m.Program);
        m.InitializeState(state, obj, args);
        foreach (var b in m.HostBinds)
            state.Variables[b[0]] = HostFuncs[b[1]];
        // self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
        // self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
        foreach (var b in m.SelfMethodBinds)
            state.Variables[b[0]] = ObjMgr.Bind(b[1], new Handle(obj));
        state.Run();
        foreach (var e in state.Errors) Console.WriteLine("  vm: " + e);
        // 返回前把 self: 槽位写回字段（只写实际引用的那几个）。
        foreach (var p in m.SelfProps)
            obj.Fields[p[1]] = state.Variables[p[0]];
        return state.Returns.Count > 0 ? state.Returns[0] : null;
    }

    // 装配入口函数：宿主函数、构造器描述符、obj:* 成员描述符绑进导出槽位。
    // 按名只发生在这里（装配期），state.Run() 期间零按名查找。
    public void BindEntry(State state, FunctionInfo entry)
    {
        foreach (var b in entry.HostBinds)
            state.Variables[b[0]] = HostFuncs[b[1]];
        foreach (var cls in Classes)
        {
            foreach (var kv in cls.ConstructorMap)
                BindExport(state, entry, cls.Name + ":" + kv.Key,
                    ObjMgr.NewCtorDesc(cls.Id, kv.Value));
            foreach (var prop in cls.Properties)
                BindExport(state, entry, "obj:" + prop,
                    ObjMgr.NewMemberDesc(NewMemberId(prop)));
            foreach (var m in cls.Methods)
            {
                if (m.Name == "" || cls.ConstructorMap.ContainsKey(m.Name))
                    continue; // <delete> 走 obj:delete；构造器不占 obj: 名
                BindExport(state, entry, "obj:" + m.Name,
                    ObjMgr.NewMemberDesc(NewMemberId(m.Name)));
            }
            if (cls.DeconstructorId >= 0)
                BindExport(state, entry, "obj:delete",
                    ObjMgr.NewMemberDesc(NewMemberId("delete")));
        }
    }

    private static void BindExport(State state, FunctionInfo entry, string nm, Handle handle)
    {
        if (!entry.Program.Exports.TryGetValue(nm, out var slot)) return;
        state.Variables[slot] = handle;
    }
}
