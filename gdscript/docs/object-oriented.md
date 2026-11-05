# 面向对象：GDScript 侧的对象（demo_05）

> 本文对应 `demo/demo_05.gd`（入口）与 `demo/05-object/`（多文件拆分），是
> [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 GDScript 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 GDScript
> 里怎么接**，以及最要紧的一件事——**GDScript 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`addons/stope/basic_vm.gd`，随插件分发，不需要改）：

- `StopeBasicVM.Handle`——第 7 种可观测值，包装一个宿主引用（`data`）；
  `equals` 加同一性分支：两个 Handle 相等当且仅当同一个包装实例；
- `Api` 内置三个**虚方法** `handle_at` / `handle_assign` / `handle_call`，
  默认实现一律报错；
- `_at` / `_assign` / `_call` 各有 Handle 分支：识别 Handle → 转发虚调用 →
  检查 errors → 维持栈纪律（弹参、压返回值归指令管）。

宿主侧要做的只是**继承 `StopeBasicVM.Api` 并覆写三个方法**（GDScript 方法
天然动态派发，不需要 C++ 那样的 virtual 语法）：

```gdscript
class DemoApi extends StopeBasicVM.Api:
	func handle_at(s, handle, key) -> Variant: return obj_mgr.at(s, handle, key)
	func handle_assign(s, handle, value) -> void: obj_mgr.assign(s, handle, value)
	func handle_call(s, handle, args) -> Variant: return obj_mgr.call_member(s, handle, args)
```

## 2. GDScript 的内存管理：官方口径

**Godot 没有 GC，只有引用计数 + 手动管理。** GDScript 基础教程
"Memory management" 一节（docs.godotengine.org）原文：

> Godot implements reference counting to free certain instances that are no
> longer used, **instead of a garbage collector**, or requiring purely manual
> management.

两条线并存：

| 机制 | 适用 | 释放时机 | 循环引用 |
| --- | --- | --- | --- |
| 引用计数 | `RefCounted` 及其子类 | 计数归零**立即**释放 | **会泄漏**，官方提供 `weakref()` 打破 |
| 手动管理 | 其余 `Object`（含 `Node`） | 开发者 `free()` / `queue_free()` | 不适用（手动配对） |

（唯一例外：C# 绑定下的 RefCounted 由 .NET GC 延迟回收，见 RefCounted 类文档
的 Note。）

## 3. demo 的映射：谁手动、谁计数

demo 5 的语义是「没有 GC、手动清理」，在 GDScript 里这样落：

| 成分 | 继承 | 管理方式 | 对应 C++ |
| --- | --- | --- | --- |
| `MyObject`（业务对象） | **`Object`** | 手动：`obj:delete` → 跑 `<delete>` → `free()` | `new Object` / `delete &obj` |
| `MemberDesc` / `CtorDesc`（描述符） | `RefCounted` | 引用计数：无人引用立即释放 | `descs` deque + `freeDescs` 池 |
| `Handle`（VM 值） | `RefCounted` | 引用计数，瞬态 | 栈上的 Value（位拷贝） |

**析构函数的有效性由此保住**：`MyObject` 继承 `Object` 而不是
`RefCounted`——`RefCounted` 会被引擎拒绝手动 `free()`，析构时机就不再由
文档程序员决定；继承 `Object` 后 `obj:delete(p)` 就是「先跑 `<delete>` 的
Program、再 `free()`」，时机确定，与 C++ 逐字对应。代价与 C++ 相同：
**悬空 Handle 是程序错误**（`free()` 后 `p` 仍持有旧引用，再用是未定义
行为；引擎会在访问已释放对象时报错，但那是事后诊断不是保护）。

**引用计数替 demo 管掉的一笔账**：C++ 版为描述符做了「去重缓存 + 驱逐 +
`freeDescs` 复用池」三层记账；GDScript 版保留去重缓存与驱逐（防曾见增长），
但**不需要复用池**——被驱逐的描述符若无人引用，引用计数当场释放它。
缓存用 `Dictionary`（按实例哈希）实现两级结构「对象 → (成员 id → 描述符)」，
驱逐是 O(1) 整组摘除（C++ 的 `std::map` 是 O(log A) 定位 + O(k) 摘除）。

**一处环引用的处理**：`Runtime ⇄ ObjectManager` 互指，若都继承 RefCounted
就构成计数环——整个运行时图退出时报 ObjectDB leak。`Runtime` 因此继承
`Object`，由 demo 末尾显式 `free()`；ObjectManager 持有的 runtime 引用
不参与计数，环就断了。这本身就是 Godot「循环引用会泄漏」口径的一个活例子。

## 4. 与 C++ 版的其它差异

- **没有异常**：C++ 装配期失败用 `throw` 上传；GDScript 无异常，`DocVisitor`
  的失败沿返回值上传（`visit_doc -> bool`），编译失败经 `_compile` 返回 null。
- **没有哨兵 classId**：C++ 用负数 classId 区分成员描述符（-2）与构造器
  描述符（-3）；GDScript 直接用 `is MemberDesc` / `is CtorDesc` 按类型分派。
- **没有 Allocator / ProgramConstants**：Godot 的 String 是引用计数的
  Variant，常量随 `Program` 走，无需深拷贝进共享池。
- **`Method.self_props`**：与 C++ 相同，属性不进 preExports，方法体里的
  `self:<属性>` 走隐式导出、链接遍配对 `(槽位, 字段下标)`；
  `self:<方法名>` 链接成 self 的绑定描述符。`<func>` 里的 `self:` 有意
  不校验（见 C++ 文档 §10 已知局限）。
- **运行期输出**：`ReportLive` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`——池被引用计数替代，只剩缓存里仍被
  引用的绑定。

## 5. 运行

```
godot --headless --path gdscript res://demo/demo_05.tscn
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

C++ 版 §10 列出的未定义行为与已知局限**全部适用于本移植**（悬空 Handle、
属性无 rvalue 读、构造失败返回半成品、缺参静默、方法递归无深度限制、
`<func>` 里 `self:` 无校验），见
[`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10。
GDScript 特有的两条：

- `free()` 之后引用已释放对象，Godot 报引擎级脚本错误（比 C++ 的纯 UB
  稍好——事后诊断），但**不阻止你犯错**；
- RefCounted 描述符若在 `bind_cache` 驱逐前被 VM 变量长期持有，会活到
  持有者销毁——正常用法下这就是期望行为，不算泄漏。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `demo/demo_05.gd` | 入口：STML 文档、装配、运行、清理诊断（配 `demo_05.tscn`） |
| `demo/05-object/objects.gd` | `MyObject` + `MemberRef` / `MemberDesc` / `CtorDesc`（内类容器） |
| `demo/05-object/classes.gd` | `MethodInfo` / `FunctionInfo` / `ClassInfo`（内类容器） |
| `demo/05-object/object_manager.gd` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `demo/05-object/demo_api.gd` | BasicVM 三个虚方法的薄转发 |
| `demo/05-object/runtime.gd` | `Runtime`：静态结构 + `bind_entry` + `invoke_method` |
| `demo/05-object/doc_visitor.gd` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |

跨文件引用走 `preload` 常量（如 `Objects.MyObject.new()`）；引用方向无环
（runtime → object_manager / demo_api，doc_visitor → classes / objects），
`ObjectManager` 里的 `runtime` 故意不写静态类型，避免 preload 成环。
