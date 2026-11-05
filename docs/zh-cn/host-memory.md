# demo 5/6 的宿主内存管理：八份实现的对照

> demo 5（[`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)）把类、
> 属性、方法、构造、析构**全部长在宿主侧**：对象是 `Value::Handle`（宿主引用），
> 生命周期由宿主管——`obj:delete` 显式删除，`<delete>` 析构函数**只在显式删除时
> 运行**。demo 6 再把生命周期交给 GC。
>
> 各宿主语言的内存机制不同，同一份设计落到每份实现上的形状也不同。本文是
> **跨实现契约的对照表**：每种语言是谁在管内存、`obj:delete` 的确定性析构靠
> 什么保住、哪些语义发生了偏移。各实现的细节展开见各自 `docs/object-oriented.md`
> （cpp 版是教程正典）。

## 1. 一句话总纲

**`<delete>` 析构函数的有效性在所有实现里都成立**：它只在显式 `obj:delete`
时运行，时机由文档程序员的代码决定，从不依赖任何回收机制。语言内存机制
决定的只是**删除之后内存何时归还**，以及「忘记删除」如何现形。

## 2. 内存机制对照表

| 实现 | 宿主内存机制 | 官方口径 | 手动 delete 的语义 | 内存归还时机 |
| --- | --- | --- | --- | --- |
| **C++**（正典） | 无 GC；`new`/`delete` 手动管理 | ——（语言本身） | `delete &obj`，真释放 | **立即** |
| **GDScript** | **引用计数 + 手动管理，无 GC** | 官方教程：*"Godot implements reference counting … **instead of a garbage collector**"*；`RefCounted` 归零立即释放；非 RefCounted 的 `Object` 手动 `free()`；**循环引用会泄漏**（官方提供 `weakref()` 打破）；C# 绑定下 RefCounted 由 .NET GC 延迟回收（唯一例外） | 对象继承 **`Object`**（手动）：`free()` 真释放 | **立即** |
| **Node.js** | **追踪式 GC**（V8：分代 + 标记清除/整理） | 规范只要求「不可达即最终回收」 | 删除标记 + `use after free.` 检测（无悬空指针可用） | 不可达后由 GC 决定 |
| **C#** | **分代、压缩式追踪 GC**；终结器非确定；`IDisposable` 是确定性清理的**约定** | .NET 运行时 | 删除标记 + 使用检测；`<delete>` 语义对应 `Dispose` 的确定性角色（**避开**终结器） | 不可达后由 GC 决定 |
| **Python** | **CPython 引用计数即时回收 + `gc` 模块分代兜环**；`del` 只断引用；`__del__` 依赖归零时机且环内不保证触发 | CPython 实现口径 | 删除标记 + 使用检测 | 引用计数归零**立即**；环由 `gc` 兜底 |
| **Lua** | **自动内存管理**：5.4 增量（默认）或分代**标记清除**；`__gc` 元方法时机由收集器决定、不保证及时 | Lua 5.4 参考手册 | 删除标记 + 使用检测 | 不可达后由收集器决定 |
| **Go** | **并发三色标记清除 GC**（STW 仅两端，极短） | Go 运行时；`SetFinalizer` 官方明确警告不可依赖 | 删除标记 + 使用检测；`<delete>` 对应 `defer`/`Close()` 的确定性角色 | 不可达后由并发 GC 决定 |
| **Rust** | **无 GC：所有权 + RAII + `Drop`**；共享所有权 `Rc`（计数归零确定性 `Drop`）；环引用泄漏需 `Weak` | 语言规范 | 删除标记 + 使用检测（借用检查禁悬空）；`Drop` 确定性 | 计数归零**立即** |

**两个阵营**：

- **「真释放」阵营**（C++ / GDScript）：`obj:delete` 之后内存立刻归还，
  悬空 Handle 再用是**未定义行为**——与 C++ 正典完全一致；
- **「模拟纪律」阵营**（其余六份）：宿主语言**不存在手动释放**（对象不可
  强杀），`obj:delete` = 跑 `<delete>` + **删除标记**；之后访问一律报
  `use after free.`——C++ 的 UB 在这些实现里变成**确定性的即时报错**，
  这是宿主语言送的安全垫，不是语义偏移。内存由计数/回收机制在对象不可达
  后归还（CPython/Rust 的 `Rc` 归零即时，其余由 GC 决定）。

## 3. 描述符的账：谁替掉 freeDescs 池

C++ 版为绑定描述符做了三层记账：**去重缓存**（同一绑定永远等价）→
**驱逐**（`obj:delete` 时整组摘除，防曾见增长）→ **`freeDescs` 复用池**
（`descs` 只随峰值并发绑定增长）。宿主语言的回收机制直接替掉第三层：

| 实现 | 缓存结构 | 驱逐复杂度 | 复用池 |
| --- | --- | --- | --- |
| C++ | `map<地址, map<id, desc>>` | O(log A) 定位 + O(k) 入池 | **需要**（freeDescs） |
| GDScript | 两级 `Dictionary`（实例哈希键） | **O(1)** 整组摘除 | 不需要——RefCounted 归零即释放 |
| Node.js | 两级 `Map` | O(1) | 不需要——GC 回收 |
| C# | 两级 `Dictionary` | O(1) | 不需要——GC 回收 |
| Python | 两级 `dict` | O(1) | 不需要——计数归零即释放 |
| Lua | 两级 `table` | O(1) | 不需要——GC 回收 |
| Go | 两级 `map` | O(1) | 不需要——GC 回收 |
| Rust | 两级 `HashMap`（裸指针键） | O(1) | 不需要——`Drop` 即回收 |

前两层（去重 + 驱逐）在**所有实现**里原样保留：驱逐防「曾见绑定」单调
增长，是 demo 5 手动管理叙事的组成部分。

## 4. Api 缝的形态：各语言的「虚函数」等价物

BasicVM 的 Handle 缝 = `Value::Type::Handle` + Api 上的三个开口 +
At/Assign/Call 三条执行路径。**「宿主继承 Api 覆写三个虚函数」在各语言的
等价物**：

| 实现 | 覆写机制 | 注意点 |
| --- | --- | --- |
| C++ | `class DemoApi : public BasicVM::API` 虚函数覆写 | 指令的 Handle 分支经 `s.Api` 转发（引用虚分发） |
| GDScript | `class DemoApi extends StopeBasicVM.Api` 方法覆写 | 方法天然动态派发；经 `s.api` 转发 |
| Node.js | `class DemoApi extends BasicVM.Api`（ES class） | `opMap` 是模块级函数，**必须经 `s.api` 转发** |
| C# | `class DemoApi : Api`（Api 去 sealed）虚方法覆写 | `OpMap` 是 `Ops` 静态方法委托，经 `s.Api` 转发 |
| Python | `class DemoApi(Api)` 方法覆写 | 同上；`Api` 有 `__slots__`，子类不写 slots 即可 |
| Lua | **实例级覆写**（Lua 无继承语法）：`function api:handle_at(...) end` | 经 `s.api:` 冒号调用转发 |
| Go | **接口 + 内嵌**：`type DemoApi struct { *basicvm.BaseApi; ... }` 遮蔽同名方法 | `State.Api` 字段是接口 `Api`；热循环经 `OpTable()` 取表 |
| Rust | **trait object**：`Rc<dyn Api>`，宿主实现 trait | 先 `clone()` Api 的 Rc 再调用（与 State 的 `&mut` 借用冲突）；Handle 载荷包一层才能从 `dyn Any` 下转回 |

## 5. demo 5 → demo 6 的接口不变量

demo 6（GC）替换的只是**生命周期策略**，各实现里以下接口形状不动：

1. `Value` 的 Handle 表示与 equals 同一性分支；
2. Api 的三个开口（覆写点）与 At/Assign/Call 的三条执行路径；
3. `bindEntry` 的装配期绑定（宿主函数 / 构造器描述符 / `obj:*` 成员描述符）
   与装配期预计算的整数索引（运行中零按名查找）；
4. `self:` 槽位契约（属性走槽位、方法走隐式导出 + 链接遍）与两层整数查询。

demo 6 退场的：`obj:delete` / `live` 表 / `bindCache` / `freeDescs`（C++）——
绑定描述符变成 GC 管理的普通对象，随可达性自动回收。

## 6. 已知局限（跨实现共享）

C++ 版 §10 列出的未定义行为与已知局限（悬空 Handle、属性无 rvalue 读、
构造失败返回半成品、缺参静默、方法递归无深度限制、`<func>` 里 `self:`
无校验）**全部适用于各移植**；在「模拟纪律」阵营里，悬空 Handle 从 UB
变成确定性的 `use after free.` 报错，其余条目逐字对应。各实现的特有差异
（如 Rust 的 `RefCell` 借用不跨嵌套调用、Lua 的 variables 0 起槽位）见
各自 `docs/object-oriented.md`。
