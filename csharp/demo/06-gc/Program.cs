using System;
using System.Collections.Generic;

using Stope;
using Stope.Stml;

namespace Stope.Demo;

// Demo 06: 宿主侧的垃圾回收 —— 对应 cpp/demo/06-gc/。
//
// 多文件拆分与 C++ 参考实现同构（demo/06-gc/ 目录）：
//   Object.cs（gc 节点 + 描述符）、Gc.cs（分配器：链表/计数/同步/标记清除）、
//   ObjectManager.cs（obj:* 域行为 + 安全点）、Runtime.cs（装配与调用 +
//   LiveStates）、DocVisitor.cs（STML -> 类与函数）、Api.cs（三开口转发）；
//   本文件只留文档、装配与入口。
//   设计推导见 cpp/docs/gc.md，.NET 侧差异见 docs/gc.md。
//
// 语法（与 cpp demo 逐字一致）：
//   Person:New("Tom", 18)     构造（对象生命期归 gc，无 obj:delete）
//   obj:friend[p] = null      字段覆盖：计数归零 -> 立即级联
//   gc:Collect()              宿主函数：强制标记清除
//
// ★ .NET 侧的内存管理（与 C++ demo 的差异，详见 docs/gc.md）：
//   · gc 决定「何时判死」：<delete> 在判死时运行、时机确定；节点摘链后
//     不可达，内存由引擎 GC 回收——没有 C++ 的 delete/trash（对象不会
//     地址复用，悬空指针不存在）；
//   · 描述符交给引擎 GC：Bind 每次新建，不可达即回收，不需要 Pin；
//   · 「正在执行方法」的对象由 Runtime.Pinned 强引用保活（.NET 描述符不
//     参与 gc，C++ 靠绑定描述符的字段引用，这里是等价物）；
//   · MaxNodes 只计业务对象（描述符由引擎管）。

internal static class Demo06
{
    private static readonly string Doc = """
<stml>

<class name="Person">
  <property name="name" />
  <property name="age" />
  <property name="friend" />
  <property name="partner" />
  <method name="Greet">
    println("i am ", self:name, ", ", self:age, " years old.");
  </method>
  <method name="Age">
    return self:age;
  </method>
  <method name="Introduce">
    println("-- introducing --");
    self:Greet();
    println("age via self:Age() = ", self:Age());
  </method>
  <method name="Pair">
    // 循环引用：a、b 互指，且只存在于本方法的变量里。方法一返回，两个
    // 变量槽位随栈帧销毁，引用计数停在 1 互相锁定——计数收不走，只能
    // 等标记清除裁决。
    let a = Person:New("cycle.a", 1);
    let b = Person:New("cycle.b", 2);
    obj:partner[a] = b;
    obj:partner[b] = a;
  </method>
  <new name="New" params="name age">
    self:name = name;
    self:age = age;
  </new>
  <delete>
    // 析构函数：gc 回收对象前自动跑，可以打遗言、清理宿主的非托管资源。
    println("[Person] deleted: ", self:name);
  </delete>
</class>

<func name="main">
  let p = Person:New("James", 18);
  obj:Introduce[p]();

  // 1) 引用计数级联：朋友只挂在字段上，覆盖成 null 旧值计数归零，
  //    立即析构（安全点刚同步过根，VM 侧再无 Handle，即时释放是可靠的）。
  obj:friend[p] = Person:New("Jimmy", 1);
  println("-- expect [Person] deleted: Jimmy right above --");
  obj:friend[p] = null;

  // 2) 循环引用：引用计数收不走，脚本侧也没有 gc 函数可调——裁决时机在
  //    宿主手里：驱动循环的帧边界 Collect（见 Main），游戏里就是
  //    「每 N 帧收集一次」。
  obj:Pair[p]();
  println("-- expect nothing above: the pair is locked in a cycle --");
  println("-- expect two [Person] deleted above at a frame-boundary collect --");

  // 3) 垃圾 churn：丢弃结果的对象走引用计数路径，在下个安全点被逐个收走；
  //    一路积累的一次性描述符（self 绑定等）由帧边界的标记清除成批收走。
  let i = 0;
  while i < 100 {
    Person:New("garbage", i);
    i = i + 1;
  }
  println("-- expect batches of deleted above: safe-point refcount + frame-boundary sweep --");
</func>

</stml>
""";

    private static int Main()
    {
        var runtime = new Runtime();
        runtime.ObjMgr.Alloc.MaxNodes = 4096; // gc 节点上限（.NET 只计业务对象）；
        // 顶到上限先 Collect 仍不够则开口报 too many gc nodes.；0 = 不限
        runtime.AddHostFunction("println", HostPrintln);
        // 注意没有 gc:Collect：宿主本来就能直接调 Collect()，注册成 VM 宿主
        // 函数只是让脚本能「主动要求 gc」——去掉之后静态桥接（_runtime）也
        // 跟着删，gc 时机完全归帧循环（下方的 slices % 25 == 0）。

        // ---------- 1. STML 解析：代码段标签按 Stope 代码扫 ----------
        var root = new Stml.Element();
        var lexer = new Stml.Lexer(Doc);
        var stmlParser = new Stml.Parser(lexer);
        if (stmlParser.Parse(root, StateFunc) != Result.Success)
        {
            foreach (var e in stmlParser.Errors) Console.WriteLine(e);
            return 1;
        }

        // ---------- 2. 访问文档：构建类、编译函数 ----------
        try
        {
            new DocVisitor().VisitDoc(root, runtime);
        }
        catch (Exception e)
        {
            Console.WriteLine(e.Message);
            return 1;
        }
        var mainFunc = runtime.FindFunction("main");
        if (mainFunc == null)
        {
            Console.WriteLine("no main function");
            return 1;
        }

        // ---------- 3. 装配入口帧：绑定归 Runtime.PushEntryFrame ----------
        runtime.PushEntryFrame(mainFunc);

        // ---------- 4. 运行：两种驱动，随时可切 + 帧边界 collect ----------
        // 限步：RunSteps(20) 每帧最多 20 条指令，帧间就是宿主的逻辑帧；每
        //   25 帧做一次标记清除——gc 时机完全由这个循环决定，脚本侧无感。
        //   单步调试就把 20 改成 1。
        // 直接：RunAll() 一口气跑到帧栈清空——没有帧边界，gc 的裁决点只剩
        //   maxNodes 顶满与收尾那次 Collect。demo 先限步 25 帧（第一轮帧边
        //   界 Collect 在这里触发，循环引用被破环），再直接执行跑完剩下的。
        var slices = 0;
        while (slices < 25 && runtime.RunSteps(20))
        {
            ++slices;
            if (slices % 25 == 0)
            {
                runtime.ObjMgr.Alloc.Collect();
                Console.WriteLine($"[gc] frame slice {slices}: collect freed {runtime.ObjMgr.Alloc.LastFreed}");
            }
        }
        runtime.RunAll();
        Console.WriteLine($"-- {slices} stepped slice(s), 20 steps each, then RunAll --");
        runtime.ObjMgr.Alloc.Collect(); // 入口帧弹出后 p 不可达：最后一次收集
        runtime.ObjMgr.ReportLive(); // 帧栈已空，根集合随最后一步同步清零
        runtime.ObjMgr.Alloc.DisposeAll(); // 退出兜底：剩余对象逐个跑 <delete>
        return runtime.HadErrors ? 1 : 0;
    }

    // 宿主函数：与 C++ demo 一致——只格式化 Integer / Float / String，其余忽略。
    private static object? HostPrintln(object?[] args)
    {
        var outStr = "";
        foreach (var a in args)
        {
            if (a is long i) outStr += i;
            else if (a is double d) outStr += FormatDouble(d);
            else if (a is string str) outStr += str;
        }
        Console.WriteLine(outStr);
        return null;
    }

    // gc:Collect 已删：宿主本来就能直接调 Collect()，注册成 VM 宿主函数只是
    // 让脚本能「主动要求 gc」——裁决时机现在完全归 Main() 的帧循环。

    // 浮点按 C++ iostream 默认精度（6 位有效数字）的样子打，读起来对得上。
    private static string FormatDouble(double v)
    {
        if (v == Math.Floor(v) && Math.Abs(v) < 1e15) return ((long)v).ToString();
        return v.ToString("G6");
    }

    // 带 stope 属性的元素，内容按 Stope 代码扫；其余按子元素列表（Xml）解析。
    private static Stml.Lexer.State StateFunc(string tag, Dictionary<string, string> attrs) =>
        tag is "method" or "new" or "delete" or "func"
            ? Stml.Lexer.State.Stope
            : Stml.Lexer.State.Xml;
}
