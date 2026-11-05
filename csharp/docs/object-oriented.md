# 面向对象：C# 侧的对象（demo/05-object）

> 本文对应 `demo/05-object/`，是 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 C# 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 C# 里
> 怎么接**，以及最要紧的一件事——**.NET 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`Stope/BasicVm.cs`，随库分发，不需要改语义）：

- `Stope.Handle`——第 7 种可观测值，包装一个宿主引用（`Data`）；
  `Runtime.AreEqual` 加同一性分支：两个 Handle 相等当且仅当同一个包装实例；
- `Api` 由 `sealed` 改为可继承，内置三个**虚方法** `HandleAt` / `HandleAssign` /
  `HandleCall`，默认实现一律报错；
- `Ops.Assign` / `Ops.Call` / `Ops.At` 各有 Handle 分支：识别 Handle → 经
  **`s.Api`**（State 挂着的 Api 实例）转发虚调用 → 检查 `HasError()` → 维持
  栈纪律。注意 `OpMap` 里装的是 `Ops` 的**静态方法**委托，转发必须走 `s.Api`
  ——所以宿主只需继承并覆写：

```csharp
private sealed class DemoApi : Api
{
    public override object? HandleAt(State s, Handle h, object? key) => objMgr.At(s, h, key);
    public override void HandleAssign(State s, Handle h, object? v) => objMgr.Assign(s, h, v);
    public override object? HandleCall(State s, Handle h, object?[] args) =>
        objMgr.CallMember(s, h, args);
}
```

## 2. .NET 的内存管理：分代追踪 GC

**.NET 是分代、压缩式的追踪垃圾回收**（Gen0/1/2 + LOH），与 C++ 的根本差异：

| | C++（demo 5 的立场） | .NET |
| --- | --- | --- |
| 释放时机 | `delete` 显式、立即 | 不可达后由 GC 决定（分代回收时机不确定） |
| 悬空指针 | `delete` 后再用是 UB | **不存在**——引用仍在，对象不会中途蒸发 |
| 手动释放 | `delete p` | **做不到**——没有释放托管对象的 API |
| 确定性清理 | 析构函数 | `IDisposable.Dispose`（**约定**，不是语言机制） |
| 非确定性清理 | —— | 终结器（`~Finalize`）：由 GC 决定何时跑，**不保证运行** |

所以 C# 版的「手动管理」是一条**模拟纪律**，语义与 C++ 对齐、机制不同：

- **删除标记**：`obj:delete` 跑完 `<delete>` 后给对象打 `Deleted = true`；
- **使用检测**：之后对它的属性/方法访问一律报 `use after free.`——C++ 里
  这是未定义行为，C# 里变成确定性的即时报错；
- **内存回收**：`delete` 之后对象不可达，由 GC 在某个分代回收时归还内存。

**析构函数的有效性不受影响**：`<delete>` 的 Program 只在显式 `obj:delete`
时运行，`[Person] deleted!` 出现在删除那一行——时机确定，与 C++ 逐字对应。
语义上 `<delete>` 对应的就是 `IDisposable.Dispose` 的角色（确定性资源清理），
而**不是**终结器（终结器由 GC 决定时机、不保证运行，恰恰是 demo 要避开
的非确定性路径）。

## 3. 描述符的账：GC 替掉复用池

C++ 版为描述符做了「去重缓存 + 驱逐 + `freeDescs` 复用池」三层记账。
C# 版保留去重缓存与驱逐（防曾见增长），但**不需要复用池**——被驱逐的
描述符若不可达，GC 会回收它。缓存用两级 `Dictionary`（对象 → (成员 id →
描述符)），键是对象引用（`ReferenceEquals` 语义），驱逐是 `Remove` 整组
摘除，O(1)。

## 4. 与 C++ 版的其它差异

- **值表示**：Integer 是 `long`（unchecked 回绕）、Float 是 `double`、String
  是 `string`、BinArr 是 `byte[]`、宿主函数是 `Func<object?[], object?>`；
- **没有哨兵 classId**：C++ 用负数 classId 区分成员/构造器描述符；C# 直接
  `is MemberDesc` / `is CtorDesc` 按类型分派；
- **没有 Allocator / ProgramConstants**：C# 字符串本身是引用类型，常量随
  `Program` 走；
- **装配期异常**：C# 有异常，装配期失败沿用 C++ 的做法（抛出、Main 接住）；
- **self 槽位**：与 C++ 相同——属性不进 preExports，`self:<属性>` 走隐式
  导出、链接遍配对 `(槽位, 字段下标)`；`self:<方法名>` 链接成 self 的绑定
  描述符。`<func>` 里的 `self:` 有意不校验（见 C++ 文档 §10）；
- **运行期输出**：`ReportLive` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`。

## 5. 运行

```
dotnet run --project csharp/demo/05-object
```

输出（与 C++ demo 一致）：

```
-- introducing --
i am James, 18 years old.
age via self:Age() = 18
[Person] deleted!
[objects] all freed
[bind-cache] 0 entries
```

`[Person] deleted!` 出现在 `obj:delete(p)` 那一行——析构时机由文档程序员
决定，这正是 demo 5 的核心演示点。

## 6. 已知局限

C++ 版 §10 列出的未定义行为与已知局限**基本适用于本移植**，个别条目在
C# 里性质有变（见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10）：

- **悬空 Handle → 使用检测**：C++ 的 UB 在 C# 里变成确定性的
  `use after free.` 报错（§2）；
- **属性没有 rvalue 读**：`obj:name[p]` 读取语境得到绑定描述符的 Handle，
  不是字段值——读属性请经方法；
- **构造失败返回半成品对象**：`<new>` 执行中出错时对象已进存活表，
  Handle 照常返回，需手动 delete；
- **缺参调用静默**：缺的形参槽位是 `null`，构造照常完成；
- **方法递归无深度限制**：每层调用一个临时 State（C# 递归栈），无限自调
  最终抛 `StackOverflowException`（进程直接终止，无法捕获）；
- **`<func>` 中的 `self:` 无校验**：能编译（隐式导出），运行时槽位 null
  才报错——函数没有 self 语义，文档里不应出现 `self:`。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `demo/05-object/Program.cs` | 入口：STML 文档、装配、运行、清理诊断 |
| `demo/05-object/Object.cs` | `MyObject` + `MemberRef` / `MemberDesc` / `CtorDesc`（业务对象叫 `MyObject`：避开 `System.Object`） |
| `demo/05-object/Class.cs` | `MethodInfo` / `FunctionInfo` / `ClassInfo` + 槽位装配 |
| `demo/05-object/ObjectManager.cs` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `demo/05-object/Api.cs` | BasicVM 三个虚方法的薄转发 |
| `demo/05-object/Runtime.cs` | `Runtime`：静态结构 + `BindEntry` + `InvokeMethod` |
| `demo/05-object/DocVisitor.cs` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |

SDK 风格工程自动编入同目录全部 `.cs`，同一 `namespace Stope.Demo` 下类型直接可见。
