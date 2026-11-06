using System;
using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== 类 / 方法 / 函数：静态结构 + 槽位装配 ====================
// （对应 cpp/demo/06-gc/ 的 Class.* / Function.*；与 demo 5 的差异：
//   MethodInfo 多一个 ExportBinds。）

internal sealed class MethodInfo
{
    public string Name = "";
    public List<string> Params = new();
    public Program Program = null!;
    public List<int[]> SelfProps = new(); // [槽位下标, 字段下标]
    public List<int[]> HostBinds = new(); // [槽位下标, 宿主函数序号]
    public List<int[]> SelfMethodBinds = new(); // [槽位下标, 成员 id]
    // 方法体里的 <类名>:<构造名> / obj:<名> 描述符：[槽位下标, Handle]。
    // 方法有独立的 program，这些名字是它自己的隐式导出——每个 State 都要
    // 各自绑。描述符被本列表引用着，引擎 GC 保证存活。
    public List<object?[]> ExportBinds = new(); // [槽位下标, Handle]
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
