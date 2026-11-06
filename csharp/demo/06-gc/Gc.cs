using System;
using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== GcAllocator：对象分配器 ====================
// （对应 cpp/demo/06-gc/ 的 ObjectAllocator；JS 版同名文件的 C# 化。）
//
// 引用计数的口径（与 C++ 版逐字对应，详见 cpp/docs/gc.md）：
//   * VM 对 Handle 的复制不通知宿主（Clear2/Copy 对 Handle 是无操作——缝的
//     设计），所以「栈/变量里此刻有哪些 Handle」只能靠扫描得知。
//   * RefCount = 字段引用（SetField 精确维护）+ 根引用（SyncRoots 同步）。
//   * 安全点 = 每个 obj:* 开口入口 + Collect 入口：扫描全部在册 State 的
//     Variables/Stack/Returns，Handle 一律算根，diff 出增减。**先加后删**。
// .NET 差异：没有 String/BinArr 引用计数（引擎管）；「释放」= 摘链 + 判死 +
// 清字段，内存交给引擎——没有 C++ 的 trash/FlushTrash（对象不会地址复用）。

internal sealed class GcAllocator
{
    private readonly GcAnchor _anchor = new() { GcPrev = null, GcNext = null };
    private readonly HashSet<MyObject> _rootSet = new(); // 当前认定的根对象集合
    private long _aliveCount; // 链上真实对象数（触发器用）
    private long _gcTrigger = 64; // 存活数到阈值，分配前先 Collect
    private bool _collecting; // Collect 重入守卫

    /// <summary>gc 节点上限（.NET 侧只计业务对象，描述符由引擎管）；0 = 不限。</summary>
    public long MaxNodes;

    /// <summary>上次 Collect 释放数（诊断用）。</summary>
    public long LastFreed;

    /// <summary>当前根集合大小（诊断用）。</summary>
    public int RootCount => _rootSet.Count;

    /// <summary>安全点根扫描：宿主注册（枚举在册 State + pinned）。</summary>
    public Func<List<MyObject>>? GatherRoots;

    /// <summary>回收前回调：跑 &lt;delete&gt;（析构）。</summary>
    public Action<MyObject>? OnFree;

    public GcAllocator()
    {
        _anchor.GcPrev = _anchor;
        _anchor.GcNext = _anchor;
    }

    /// <summary>新对象挂到链尾。返回 null = 顶到 MaxNodes（开口里 s.Error）。</summary>
    public MyObject? NewObject()
    {
        if (!_collecting && MaxNodes != 0 && _aliveCount >= MaxNodes)
            Collect(); // 顶到上限：先回收再判断——gc 还有机会救
        if (MaxNodes != 0 && _aliveCount >= MaxNodes)
            return null;
        var obj = new MyObject();
        var prev = (IGcNode)_anchor.GcPrev!;
        obj.GcNext = _anchor;
        obj.GcPrev = prev;
        prev.GcNext = obj;
        _anchor.GcPrev = obj;
        ++_aliveCount;
        return obj;
    }

    // ==================== 安全点：根同步 ====================

    // 先加后删的原因：删除可能级联释放——先删会把「恰好刚被本轮扫描发现」
    // 的对象连同活引用一起级联释放。见 cpp/docs/gc.md §4。
    public void SyncRoots()
    {
        if (GatherRoots == null || _collecting)
            return; // 收集期间跳过重扫：根集合保持 Collect 入口时的新鲜度
        var found = GatherRoots();

        // 先加：本轮新发现的根 +1（同一对象在多个槽位出现只记一次根）。
        foreach (var o in found)
        {
            if (o.Dead) continue; // 防御：死对象不可达
            if (_rootSet.Add(o))
                o.RefCount += 1;
        }
        // 后删：上一轮的根这轮没再出现 -> -1，归零立即级联。
        List<MyObject> stale = new();
        foreach (var o in _rootSet)
            if (!found.Contains(o))
                stale.Add(o);
        foreach (var o in stale)
        {
            _rootSet.Remove(o); // 无论死活都摘出根集合
            if (o.Dead) continue; // 同轮级联已收走
            o.RefCount -= 1;
            if (o.RefCount < 1)
                FreeNow(o); // 刚确认：VM 侧再无 Handle，立即级联释放
        }
    }

    // ==================== 引用计数 ====================

    // 只有 Handle 且载荷是 MyObject 才是对象引用；描述符由引擎管。
    private static MyObject? ObjOf(object? v) =>
        v is Handle h && h.Data is MyObject o ? o : null;

    public void AddRef(object? v)
    {
        var o = ObjOf(v);
        if (o != null && !o.Dead) o.RefCount += 1;
    }

    public void DelRef(object? v)
    {
        var o = ObjOf(v);
        if (o == null || o.Dead) return;
        o.RefCount -= 1;
        if (o.RefCount < 1) FreeNow(o); // 归零立即级联释放
    }

    // 字段写入：旧引用先减（可能级联），再挂新引用。.NET 无 String 引用计数。
    public void SetField(MyObject obj, int index, object? v)
    {
        DelRef(obj.Fields[index]);
        obj.Fields[index] = v;
        AddRef(v);
    }

    // ==================== 释放（两条路径；.NET 无需延迟删除） ====================

    // 计数归零路径：字段引用递减，归零的子对象**级联**释放。
    private void FreeNow(MyObject obj)
    {
        if (obj.Dead) return;
        OnFree?.Invoke(obj); // <delete> 先跑：字段还完整可读
        foreach (var v in obj.Fields)
        {
            var child = ObjOf(v);
            if (child != null && !child.Dead)
            {
                child.RefCount -= 1;
                if (child.RefCount < 1) FreeNow(child); // 级联
            }
        }
        obj.Fields.Clear();
        Unlink(obj);
    }

    // sweep 路径：字段引用只减计数**不级联**——真死透的子对象马上就轮到。
    private void FreeSweep(MyObject obj)
    {
        if (obj.Dead) return;
        OnFree?.Invoke(obj);
        foreach (var v in obj.Fields)
        {
            var child = ObjOf(v);
            if (child != null && !child.Dead && child.RefCount > 0) child.RefCount -= 1;
        }
        obj.Fields.Clear();
        Unlink(obj);
    }

    private void Unlink(MyObject obj)
    {
        ((IGcNode)obj.GcPrev!).GcNext = obj.GcNext;
        ((IGcNode)obj.GcNext!).GcPrev = obj.GcPrev;
        obj.Dead = true;
        --_aliveCount;
    }

    // ==================== gc：标记清除 ====================

    // 迭代式标记：沿字段里的 Handle 引用铺开，显式栈防深对象图爆托管栈。
    private void MarkFrom(MyObject root)
    {
        if (root.Dead || root.Mark != 0) return;
        var work = new Stack<MyObject>();
        work.Push(root);
        root.Mark = 1;
        while (work.Count > 0)
        {
            var o = work.Pop();
            foreach (var v in o.Fields)
            {
                var c = ObjOf(v);
                if (c != null && !c.Dead && c.Mark == 0)
                {
                    c.Mark = 1;
                    work.Push(c);
                }
            }
        }
    }

    public void Collect()
    {
        if (_collecting) return; // 析构里新建对象顶到阈值等重入：跳过
        SyncRoots(); // 收集前根集合先刷新到最新（此刻还没置位）

        _collecting = true;
        LastFreed = 0;

        // 标记：从全部根出发。
        foreach (var root in _rootSet) MarkFrom(root);

        // 清除：先收集死对象再逐个回收——OnFree（析构）可能读写字段。
        List<MyObject> doomed = new();
        for (var h = (IGcNode)_anchor.GcNext!; !ReferenceEquals(h, _anchor); h = (IGcNode)h.GcNext!)
            if (h is MyObject mo && mo.Mark == 0)
                doomed.Add(mo);
        foreach (var o in doomed)
        {
            if (!o.Dead)
            {
                // 前面的析构可能已经级联/重入收走了它
                FreeSweep(o);
                LastFreed += 1;
            }
        }

        // 清标记：只走还活着的链。
        for (var h = (IGcNode)_anchor.GcNext!; !ReferenceEquals(h, _anchor); h = (IGcNode)h.GcNext!)
            ((MyObject)h).Mark = 0;

        _collecting = false;
        _gcTrigger = _aliveCount * 2 < 64 ? 64 : _aliveCount * 2;
    }

    // 退出兜底（C++ 的 ~ObjectAllocator）：逐个跑析构、判死——剩余对象
    // （p）的「deleted: James」在这里打印；内存随后由引擎回收。
    public void DisposeAll()
    {
        while (_anchor.GcNext is MyObject mo && !ReferenceEquals(mo, _anchor))
        {
            OnFree?.Invoke(mo);
            Unlink(mo);
        }
    }

    // ==================== 诊断 ====================

    public void ReportAlive()
    {
        long objs = 0;
        for (var h = (IGcNode)_anchor.GcNext!; !ReferenceEquals(h, _anchor); h = (IGcNode)h.GcNext!)
            ++objs;
        Console.WriteLine($"[gc] alive: {objs} object(s), root set {_rootSet.Count}");
        for (var h = (IGcNode)_anchor.GcNext!; !ReferenceEquals(h, _anchor); h = (IGcNode)h.GcNext!)
        {
            var mo = (MyObject)h;
            Console.WriteLine($"  {mo.SelfId}  class {mo.ClassId}  refCount {mo.RefCount}");
        }
    }
}
