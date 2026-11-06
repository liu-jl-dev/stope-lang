using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== 数据结构 ====================

/// <summary>成员种类（对应 C++ 的 kMemberProp / kMemberMethod；demo 6 无 delete）。</summary>
internal enum MemberKind { Prop, Method }

/// <summary>链表节点的鸭子类型：MyObject 与 GcAnchor 都实现它。</summary>
internal interface IGcNode
{
    object? GcPrev { get; set; }
    object? GcNext { get; set; }
}

/// <summary>
/// 业务对象。gc 决定「何时判死」：&lt;delete&gt; 在判死时运行、时机确定；
/// 节点摘链后不可达，.NET 内存由引擎 GC 回收——没有 C++ 的 delete/trash
/// （对象不会地址复用，悬空指针不存在）。gc 头语义见 GcAllocator。
/// </summary>
internal sealed class MyObject : IGcNode
{
    public static long NextId = 1; // 诊断打印用（C++ 打指针；托管侧用自增 id）

    public long SelfId = NextId++;
    public int ClassId = -1;
    public List<object?> Fields = new(); // 下标对齐 ClassInfo.Properties
    // ---- gc 头 ----
    public object? GcPrev { get; set; } // 循环双向链表（哨兵是 GcAnchor）
    public object? GcNext { get; set; }
    public long RefCount; // 字段引用（精确）+ 根引用（安全点同步）
    public int Mark; // 0 未标记 / 1 已标记
    public bool Dead; // 已摘链判死：级联与 sweep 的回收名单重叠时防重复处理
}

/// <summary>链表哨兵：不占对象编号，与 MyObject 一样有 GcPrev / GcNext。</summary>
internal sealed class GcAnchor : IGcNode
{
    public object? GcPrev { get; set; }
    public object? GcNext { get; set; }
}

internal sealed class MemberRef
{
    public MemberKind Kind;
    public int Index; // 进 Properties 或 Methods
}

/// <summary>描述符（.NET GC 管理，不进 gc 链）。绑定描述符的 Obj 是普通
/// Handle——不持有对象：gc 只认「State 可达 + 字段引用 + 正在执行方法」。</summary>
internal sealed class MemberDesc
{
    public int MemberId = -1;
    public Handle? Obj; // null = 未绑定
}

internal sealed class CtorDesc
{
    public int ClsId = -1;
    public int CtorIdx = -1;
}
