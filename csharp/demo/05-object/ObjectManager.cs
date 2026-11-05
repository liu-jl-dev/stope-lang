using System;
using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== ObjectManager：obj:* 域的全部行为 ====================

internal sealed class ObjectManager
{
    private readonly Runtime _runtime;
    private readonly HashSet<MyObject> _live = new(); // delete 后移除
    // 去重缓存：对象 -> (成员 id -> 绑定描述符)。绑定描述符只存这两样且创建后
    // 不可变，同一绑定永远等价；delete 时整组驱逐，不可达的描述符交给 GC。
    private readonly Dictionary<MyObject, Dictionary<int, MemberDesc>> _bindCache = new();

    public ObjectManager(Runtime runtime) => _runtime = runtime;

    public Handle NewObject(int clsId)
    {
        var obj = new MyObject { ClassId = clsId };
        obj.Fields.AddRange(new object?[_runtime.Classes[clsId].Properties.Count]);
        _live.Add(obj);
        return new Handle(obj);
    }

    public Handle NewMemberDesc(int memberId) =>
        new(new MemberDesc { MemberId = memberId });

    public Handle NewCtorDesc(int clsId, int ctorIdx) =>
        new(new CtorDesc { ClsId = clsId, CtorIdx = ctorIdx });

    // 绑定（创建即去重）。C++ 版还有 freeDescs 复用池；这里不需要 —— 驱逐后
    // 不可达的描述符由 GC 回收，池的存在意义被语言机制替掉了。
    public Handle Bind(int memberId, Handle objHandle)
    {
        var obj = (MyObject)objHandle.Data!;
        if (!_bindCache.TryGetValue(obj, out var byMember))
        {
            byMember = new Dictionary<int, MemberDesc>();
            _bindCache[obj] = byMember;
        }
        if (byMember.TryGetValue(memberId, out var hit))
            return new Handle(hit); // 命中：复用
        var d = new MemberDesc { MemberId = memberId, Obj = objHandle };
        byMember[memberId] = d;
        return new Handle(d);
    }

    // obj:<名>[p] -> 绑定描述符（属性引用与绑定方法都从这里出发）。
    public object? At(State s, Handle handle, object? key)
    {
        var d = handle.Data;
        if (d is not MemberDesc md)
        {
            s.Error("no implement for container type. ");
            return null;
        }
        if (key is not Handle objHandle)
        {
            s.Error("not an object. ");
            return null;
        }
        return Bind(md.MemberId, objHandle);
    }

    // obj:<属性>[p] = v -> 写字段。两层整数查询：对象自己的 ClassId 选类，
    // MemberById 查 MemberRef——同名成员在各类里落在不同位置也各归各。
    public void Assign(State s, Handle handle, object? value)
    {
        var d = handle.Data;
        if (d is not MemberDesc md || md.Obj is null)
        {
            s.Error("not assignable. ");
            return;
        }
        var obj = (MyObject)md.Obj.Data!;
        if (obj.Deleted)
        {
            s.Error("use after free. "); // GC 无悬空指针：删除标记替代 UB
            return;
        }
        var cls = _runtime.Classes[obj.ClassId]; // 第一层
        if (!cls.MemberById.TryGetValue(md.MemberId, out var r) || r.Kind != MemberKind.Prop)
        {
            s.Error("not assignable. "); // 该类没有这个成员 / 方法不可赋值
            return;
        }
        obj.Fields[r.Index] = value; // 第二层：MemberRef.Index 即字段下标
    }

    // obj:<名>[p](...) -> 调方法；obj:<名>(...) 直接调（delete 走这里，对象在
    // 实参里）；<Class>:<New>(...) -> 构造。
    public object? CallMember(State s, Handle handle, object?[] args)
    {
        var d = handle.Data;
        if (d is CtorDesc cd)
        {
            var cls = _runtime.Classes[cd.ClsId];
            var objHandle = NewObject(cls.Id);
            _runtime.InvokeMethod(cls.Methods[cd.CtorIdx], (MyObject)objHandle.Data!, args);
            return objHandle;
        }
        if (d is MemberDesc md)
        {
            // kind 由 MemberById 查表揭晓；类来自绑定对象或实参对象。
            var objHandle = md.Obj;
            if (objHandle is null)
            {
                if (args.Length > 0 && args[0] is Handle ah)
                    objHandle = ah; // obj:delete(p) 实参形式
                else
                {
                    s.Error(args.Length > 0 ? "not an object. " : "method not bound. ");
                    return null;
                }
            }
            var obj = (MyObject)objHandle.Data!;
            if (obj.Deleted)
            {
                s.Error("use after free. ");
                return null;
            }
            var cls = _runtime.Classes[obj.ClassId]; // 第一层
            if (!cls.MemberById.TryGetValue(md.MemberId, out var r))
            {
                s.Error("no method. "); // 该类没有这个成员
                return null;
            }
            if (r.Kind == MemberKind.Delete)
            {
                Delete(s, obj); // 绑定形式与实参形式在此收敛
                return null;
            }
            if (r.Kind != MemberKind.Method)
            {
                s.Error("\"Call\" can only call a function. "); // 属性不可调
                return null;
            }
            return _runtime.InvokeMethod(cls.Methods[r.Index], obj, args);
        }
        s.Error("\"Call\" can only call a function. ");
        return null;
    }

    // 跑 <delete>（可读写字段）-> 驱逐绑定描述符 -> 删除标记。双重 delete 拦下。
    public void Delete(State s, MyObject obj)
    {
        if (!_live.Remove(obj))
        {
            s.Error("double delete. ");
            return;
        }
        var cls = _runtime.Classes[obj.ClassId];
        if (cls.DeconstructorId >= 0)
            _runtime.InvokeMethod(cls.Methods[cls.DeconstructorId], obj, Array.Empty<object?>());
        _bindCache.Remove(obj); // 整组驱逐；不可达的描述符由 GC 回收
        obj.Deleted = true; // 内存回收时机交给 GC；之后使用即 use after free
    }

    public void ReportLive()
    {
        if (_live.Count == 0)
            Console.WriteLine("[objects] all freed");
        else
            Console.WriteLine($"[objects] {_live.Count} alive");
        int cached = 0;
        foreach (var byMember in _bindCache.Values) cached += byMember.Count;
        // 差异：C++ 打 allocated/pooled 两个数（复用池）；这里只有缓存里仍被
        // 引用的绑定描述符，池被 GC 替代了。
        Console.WriteLine($"[bind-cache] {cached} entries");
    }
}
