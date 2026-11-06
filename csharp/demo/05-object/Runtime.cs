using System;
using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== Frame：一个执行帧 ====================
// 一个 State 加「弹栈时怎么收尾」的元数据。Runtime.Frames 是显式帧栈，
// RunSteps 每次只跑栈顶帧——方法调用压帧、返回弹帧，调用方在栈里压住等
// 返回值（对应 C++ demo 05 的 Frame）。

internal sealed class Frame
{
    public State State = null!;
    public MethodInfo? Method; // null = 入口帧（main）：弹栈不回写不回填
    public MyObject? SelfObj; // 方法帧的 self（selfProps 回写目标）
    public bool WantsReturn; // true = 弹栈时把 Returns[0] 回填调用方栈顶
}

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

    // ---------- 显式帧栈：把 State 显式放在一个栈里，驱动循环只跑栈顶帧 ----------
    // 调用栈从 C# 调用栈搬进 Frames 成员：方法调用压帧、返回弹帧，调用方在
    // 栈里压住等返回值。换来 RunSteps(maxSteps)「每帧限步」与 RunAll()
    // 「一口气跑完」两种驱动，随时可切。
    public readonly List<Frame> Frames = new();
    public bool HadErrors; // 任一帧出错置位（错误已打印，供入口返回码用）

    // 装配入口函数并压帧：宿主函数、构造器描述符、obj:* 成员描述符绑进导出
    // 槽位。按名只发生在这里（装配期），执行期间零按名查找。
    public void PushEntryFrame(FunctionInfo entry)
    {
        var state = new State();
        state.SetApi(Api);
        state.SetProgram(entry.Program);
        entry.InitializeState(state, Array.Empty<object?>());
        BindEntry(state, entry);
        Frames.Add(new Frame { State = state, Method = null, SelfObj = null, WantsReturn = false });
    }

    // 装配方法 State（PushMethodFrame / InvokeMethod 共用）。
    private void SetupMethodState(MethodInfo m, MyObject obj, object?[] args, State state)
    {
        state.SetApi(Api);
        state.SetProgram(m.Program);
        m.InitializeState(state, obj, args);
        foreach (var b in m.HostBinds)
            state.Variables[b[0]] = HostFuncs[b[1]];
        // self:<方法名> 槽位绑 self 的绑定方法描述符——创建即绑定 self，
        // self:Greet() 无需 [对象]；去重缓存保证递归调用不重复分配。
        foreach (var b in m.SelfMethodBinds)
            state.Variables[b[0]] = ObjMgr.Bind(b[1], new Handle(obj));
    }

    // 压入方法帧，不执行——RunSteps 自然切到栈顶帧。调用方（call 开口的
    // 发起方）停在 Call 的下一条；开口返回的占位 null 会被 op_call 压到调用
    // 方栈顶，弹帧收尾时用真正的返回值覆盖。
    public void PushMethodFrame(MethodInfo m, MyObject obj, object?[] args, bool wantsReturn)
    {
        var state = new State();
        SetupMethodState(m, obj, args, state);
        Frames.Add(new Frame { State = state, Method = m, SelfObj = obj, WantsReturn = wantsReturn });
    }

    // 每帧限步驱动：只跑栈顶帧，至多 maxSteps 条指令；帧弹栈（Return / 指令
    // 流走完 / 出错中止当前函数）不消耗步数。返回 false = 帧栈已空。
    public bool RunSteps(int maxSteps)
    {
        while (maxSteps > 0 && Frames.Count > 0)
        {
            var s = Frames[^1].State;
            if (s.I >= s.Program.Opcodes.Count)
            {
                FinishTopFrame(); // Return 已把返回值备好；弹栈不消耗步数
                continue;
            }
            if (s.Step() != Result.Success)
            {
                FinishTopFrame(); // 运行期错误：只中止当前函数，调用方继续
                continue;
            }
            --maxSteps;
        }
        return Frames.Count > 0;
    }

    // 直接执行：一口气跑到帧栈清空。与 RunSteps 随时可切。
    public void RunAll()
    {
        while (RunSteps(int.MaxValue)) { }
    }

    // 摘出栈顶帧并收尾。
    private void FinishTopFrame()
    {
        var f = Frames[^1];
        Frames.RemoveAt(Frames.Count - 1);
        FinishFrame(f);
    }

    // 帧收尾：错误打印、self: 槽位写回字段、返回值回填调用方栈顶（op_call
    // 已把占位 null 压到那里，覆盖即可）。
    private void FinishFrame(Frame f)
    {
        foreach (var e in f.State.Errors)
        {
            Console.WriteLine("  vm: " + e);
            HadErrors = true;
        }
        if (f.Method == null) return; // 入口帧：没有 selfProps / 返回值
        // 返回前把 self: 槽位写回字段——selfProps 只含方法体实际引用的属性。
        foreach (var p in f.Method.SelfProps)
            f.SelfObj!.Fields[p[1]] = f.State.Variables[p[0]];
        // 回填调用方栈顶（wantsReturn 帧）。构造器帧返回的是新对象本身，不走这里。
        if (f.WantsReturn && Frames.Count > 0 && f.State.Returns.Count > 0)
        {
            var caller = Frames[^1].State;
            caller.Stack[^1] = f.State.Returns[0];
        }
    }

    // 同步执行整个方法（obj:delete 的析构路径）：装配 + Run + 收尾。Delete
    // 的清理序列中间不能让出执行权——析构跑完后还要驱逐描述符、delete 对象。
    // 析构里再调方法也走这条路：压帧没人跑（此刻正停在 Step 中间）。
    public object? InvokeMethod(MethodInfo m, MyObject obj, object?[] args)
    {
        var state = new State();
        SetupMethodState(m, obj, args, state);
        state.Run();
        foreach (var e in state.Errors)
        {
            Console.WriteLine("  vm: " + e);
            HadErrors = true;
        }
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
