using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== 类 / 方法 / 函数：静态结构 + 槽位装配 ====================

internal sealed class MethodInfo
{
    public string Name = "";
    public List<string> Params = new();
    public Program Program = null!;
    // 装配期预计算的整数索引：运行中不做任何按名查找。
    public List<int[]> SelfProps = new(); // [槽位下标, 字段下标]
    public List<int[]> HostBinds = new(); // [槽位下标, 宿主函数序号]
    public List<int[]> SelfMethodBinds = new(); // [槽位下标, 成员 id]
    public List<int> ParamSlots = new(); // Params[i] -> 变量槽位下标

    public void InitializeState(State state, MyObject selfObj, object?[] args)
    {
        foreach (var p in SelfProps)
            state.Variables[p[0]] = selfObj.Fields[p[1]]; // 字段 -> 槽位
        for (int k = 0; k < ParamSlots.Count; ++k)
        {
            // 缺参静默：缺的槽位是 null（已知局限，见 docs §10）
            state.Variables[ParamSlots[k]] = k < args.Length ? args[k] : null;
        }
    }
}

internal sealed class FunctionInfo
{
    public string Name = "";
    public List<string> Params = new();
    public Program Program = null!;
    public List<int[]> HostBinds = new();
    public List<int> ParamSlots = new();

    public void InitializeState(State state, object?[] args)
    {
        for (int k = 0; k < ParamSlots.Count; ++k)
            state.Variables[ParamSlots[k]] = k < args.Length ? args[k] : null;
    }
}

internal sealed class ClassInfo
{
    public int Id = -1;
    public string Name = "";
    public List<string> Properties = new();
    public List<MethodInfo> Methods = new();
    public Dictionary<int, MemberRef> MemberById = new(); // 唯一的查找表
    public Dictionary<string, int> ConstructorMap = new(); // <new 名> -> methods 下标
    public int DeconstructorId = -1;
}
