using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== 数据结构 ====================

/// <summary>成员种类（对应 C++ 的 kMemberProp / kMemberMethod / kMemberDelete）。</summary>
internal enum MemberKind { Prop, Method, Delete }

/// <summary>业务对象。GC 管内存：Deleted 标记 + 使用检测模拟手动管理的纪律。</summary>
internal sealed class MyObject
{
    public int ClassId = -1;
    public List<object?> Fields = new(); // 下标对齐 ClassInfo.Properties
    public bool Deleted;
}

internal sealed class MemberRef
{
    public MemberKind Kind;
    public int Index; // 进 Properties 或 Methods
}

/// <summary>成员描述符：MemberId + Obj（绑定后才有，Handle）。</summary>
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
