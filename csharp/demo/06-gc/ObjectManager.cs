using System;
using System.Collections.Generic;

using Stope;

namespace Stope.Demo;

// ==================== ObjectManager：obj:* 域的全部行为 ====================
// （对应 cpp/demo/06-gc/ 的 ObjectManager.*。）
//
// 与 demo 5 的差异：没有 BindCache / live 表 / obj:delete——描述符每次
// Bind 新建（.NET GC 回收不可达者），对象生命期归 gc 分配器。
// 三个开口入口先 SafePoint()：安全点根同步，先于一切 DelRef。

internal sealed class ObjectManager
{
    private readonly Runtime _runtime;
    public readonly GcAllocator Alloc = new(); // gc 分配器（C++ 版同构）

    public ObjectManager(Runtime runtime) => _runtime = runtime;

    // new 业务对象。返回 null = 顶到 MaxNodes（调用方 s.Error）。
    public Handle? NewObject(int clsId)
    {
        var obj = Alloc.NewObject();
        if (obj == null) return null;
        obj.ClassId = clsId;
        obj.Fields.AddRange(new object?[_runtime.Classes[clsId].Properties.Count]);
        return new Handle(obj);
    }

    // 描述符：每次新建，不去重——demo 5 的 BindCache / 驱逐在 demo 6 里
    // 全部消失，不可达的描述符由引擎 GC 回收。
    public Handle NewMemberDesc(int memberId) =>
        new(new MemberDesc { MemberId = memberId });

    public Handle NewCtorDesc(int clsId, int ctorIdx) =>
        new(new CtorDesc { ClsId = clsId, CtorIdx = ctorIdx });

    // 绑定描述符：每次新建。Obj 是普通 Handle——描述符不持有对象（引擎 GC
    // 管不到 gc 对象），「正在执行方法」的对象由 Runtime.Pinned 保活。
    public Handle Bind(int memberId, Handle objHandle) =>
        new(new MemberDesc { MemberId = memberId, Obj = objHandle });

    // 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。
    public void SafePoint() => Alloc.SyncRoots();

    // obj:<名>[p] -> 绑定描述符。
    public object? At(State s, Handle handle, object? key)
    {
        SafePoint();
        if (handle.Data is not MemberDesc md)
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

    // obj:<属性>[p] = v -> 写字段（走 SetField：旧值减引用可级联，新值加引用）。
    public void Assign(State s, Handle handle, object? value)
    {
        SafePoint();
        if (handle.Data is not MemberDesc md || md.Obj is null)
        {
            s.Error("not assignable. ");
            return;
        }
        var obj = (MyObject)md.Obj.Data!;
        if (obj.Dead)
        {
            s.Error("use after gc. "); // 死对象不可达才判死，正常程序到不了这里
            return;
        }
        var cls = _runtime.Classes[obj.ClassId]; // 第一层
        if (!cls.MemberById.TryGetValue(md.MemberId, out var r) || r.Kind != MemberKind.Prop)
        {
            s.Error("not assignable. "); // 该类没有这个属性 / 方法不可赋值
            return;
        }
        Alloc.SetField(obj, r.Index, value); // 第二层
    }

    // obj:<名>[p](...) -> 调方法；<Class>:<New>(...) -> 构造。
    // demo 6 没有 obj:delete(p)：生命期归 gc 管。
    public object? CallMember(State s, Handle handle, object?[] args)
    {
        SafePoint();
        if (handle.Data is CtorDesc cd)
        {
            var cls = _runtime.Classes[cd.ClsId];
            var objHandle = NewObject(cls.Id);
            if (objHandle is null)
            {
                s.Error("too many gc nodes. "); // 顶到 MaxNodes：走正常错误通道
                return null;
            }
            // 构造器压帧：返回值是新对象本身（不走「弹帧回填」通道）。
            _runtime.PushMethodFrame(cls.Methods[cd.CtorIdx], (MyObject)objHandle.Data!, args, false);
            return objHandle;
        }
        if (handle.Data is MemberDesc md)
        {
            if (md.Obj is null)
            {
                s.Error("method not bound. "); // demo 6 只支持 obj:<名>[p]() 形式
                return null;
            }
            var obj = (MyObject)md.Obj.Data!;
            if (obj.Dead)
            {
                s.Error("use after gc. ");
                return null;
            }
            var cls = _runtime.Classes[obj.ClassId]; // 第一层：classId 选类
            if (!cls.MemberById.TryGetValue(md.MemberId, out var r)
                || r.Kind != MemberKind.Method)
            {
                s.Error("no method. "); // 该类没有这个方法（属性不可调）
                return null;
            }
            // 方法调用压帧：返回占位 null——op_call 把它压到调用方栈顶，
            // 方法帧弹栈时（FinishFrame）再回填真正的返回值。
            _runtime.PushMethodFrame(cls.Methods[r.Index], obj, args, true);
            return null;
        }
        s.Error("\"Call\" can only call a function. ");
        return null;
    }

    // gc 回收前回调（Alloc.OnFree）：跑 <delete>。此时字段还完整可读。
    public void RunDestructor(MyObject obj)
    {
        var cls = _runtime.Classes[obj.ClassId];
        if (cls.DeconstructorId >= 0)
            _runtime.InvokeMethod(cls.Methods[cls.DeconstructorId], obj, Array.Empty<object?>());
    }

    public void ReportLive()
    {
        Alloc.ReportAlive();
        Console.WriteLine(
            Alloc.RootCount == 0
                ? "[gc] no roots: everything reachable has been freed"
                : $"[gc] roots keep {Alloc.RootCount} object(s) alive");
    }
}
