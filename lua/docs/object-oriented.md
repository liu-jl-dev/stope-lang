# 面向对象：Lua 侧的对象（demo/05-object/）

> 本文对应 `demo/05-object/`（入口 `demo/05-object.lua`），是
> [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 Lua 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 Lua 里
> 怎么接**，以及最要紧的一件事——**Lua 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`stope/basic_vm.lua`，随包分发，不需要改）：

- `stope.Handle.new(data)`——第 7 种可观测值，包装一个宿主引用（`data`）；
  `equals` 加同一性分支：两个 Handle 相等当且仅当同一个包装实例（Lua 的
  `==` 对不带 `__eq` 的 table 天然按同一性比较，零成本）；
- `Api` 内置三个**方法** `handle_at` / `handle_assign` / `handle_call`，
  默认实现一律报错；
- `op_assign` / `op_call` / `op_at` 各有 Handle 分支：识别 Handle → 经
  **`s.api`**（State 挂着的 Api 实例）转发 → 检查 `has_error()` → 维持栈
  纪律。注意 `op_map` 里装的是模块级函数，转发必须走 `s.api`。Lua 没有
  class 继承语法，惯用法是**在实例上覆写**这三个字段：

```lua
local api = stope.Api.new()
function api:handle_at(_s, handle, key) return obj_mgr:at(_s, handle, key) end
function api:handle_assign(_s, handle, value) obj_mgr:assign(_s, handle, value) end
function api:handle_call(_s, handle, args) return obj_mgr:call_member(_s, handle, args) end
```

（用元表链做子类也可以，实例覆写最简单。）

## 2. Lua 的内存管理：自动标记清除

**Lua 5.4 是自动内存管理**：增量（默认）与分代两种模式的**标记清除 GC**
（`collectgarbage("incremental")` / `"generational"`）。与 C++ 的根本差异：

| | C++（demo 5 的立场） | Lua |
| --- | --- | --- |
| 释放时机 | `delete` 显式、立即 | 不可达后由 GC 决定（增量步进或分代周期） |
| 悬空指针 | `delete` 后再用是 UB | **不存在**——引用仍在，对象不会中途蒸发 |
| 手动释放 | `delete p` | **做不到**——没有释放对象的 API |
| 确定性清理 | 析构函数 | `__gc` 元方法：收集器决定时机，**不保证及时**（官方文档明确警告） |
| 弱引用 | —— | 弱表（`__mode = "k"/"v"`） |

所以 Lua 版的「手动管理」是一条**模拟纪律**，语义与 C++ 对齐、机制不同：

- **删除标记**：`obj:delete` 跑完 `<delete>` 后给对象打 `deleted = true`；
- **使用检测**：之后对它的属性/方法访问一律报 `use after free.`——C++ 里
  这是未定义行为，Lua 里变成确定性的即时报错；
- **内存回收**：`delete` 之后对象不可达，由收集器在某个周期回收。

**析构函数的有效性不受影响**：`<delete>` 的 Program 只在显式 `obj:delete`
时运行，`[Person] deleted!` 出现在删除那一行——时机确定，与 C++ 逐字对应。
**不要**把 `<delete>` 与 `__gc` 元方法混为一谈：`__gc` 由收集器决定时机，
官方文档明确警告「垃圾收集器不会立即执行它们」——demo 有意避开这条
非确定性路径。

## 3. 描述符的账：GC 替掉复用池

C++ 版为描述符做了「去重缓存 + 驱逐 + `freeDescs` 复用池」三层记账。
Lua 版保留去重缓存与驱逐（防曾见增长），但**不需要复用池**——被驱逐的
描述符若不可达，GC 会回收它。缓存用两级 table（对象 → `{[成员 id] = 描述符}`），
键是对象 table（按同一性哈希），驱逐是整组置 nil，O(1)。

## 4. 与 C++ 版的其它差异

- **值表示**：Integer/Float 是 Lua number（integer 天生 int64 回绕）、String
  是**包装表**（携带 UTF-16LE 字节串，与 BinArr 的裸 `string` 区分）、
  BinArr 是 Lua string、宿主函数就是普通函数（`fn(argv)` 整包传参）、
  Null 是唯一哨兵 table `stope.NULL`（Lua 的 nil 不能上栈）；
- **索引约定**：Lua 数组 1 起——`Program.opcodes` 按 `s.i + 1` 取、
  `exports` 槽位号却**直接**作 `state.variables` 的 0 起下标（见
  `basic_vm.lua` 的 `set_program`，`for k = 0, variable_num - 1`）；
  demo 侧自己的数组（`fields` / `methods`）按各自约定对齐，装配期用
  `+1` 折算，这是本移植最容易错的一处；
- **没有哨兵 classId**：C++ 用负数 classId 区分成员/构造器描述符；Lua 直接
  按描述符表的字段形状（`cls_id` 有无）分派；
- **没有 Allocator / ProgramConstants**：String 包装表本身是引用，常量随
  `Program` 走；
- **装配期异常**：Lua 有 `error/pcall`，装配期失败沿用 C++ 的做法
  （`error`、main 里 `pcall` 接住）；
- **self 槽位**：与 C++ 相同——属性不进 preExports，`self:<属性>` 走隐式
  导出、链接遍配对 `(槽位, 字段下标)`；`self:<方法名>` 链接成 self 的绑定
  描述符。`<func>` 里的 `self:` 有意不校验（见 C++ 文档 §10）；
- **运行期输出**：`report_live` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`。

## 5. 运行

```
lua lua/demo/05-object.lua
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
Lua 里性质有变（见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10）：

- **悬空 Handle → 使用检测**：C++ 的 UB 在 Lua 里变成确定性的
  `use after free.` 报错（§2）；
- **属性没有 rvalue 读**：`obj:name[p]` 读取语境得到绑定描述符的 Handle，
  不是字段值——读属性请经方法；
- **构造失败返回半成品对象**：`<new>` 执行中出错时对象已进存活表，
  Handle 照常返回，需手动 delete；
- **缺参调用静默**：缺的形参槽位是 `NULL` 哨兵，构造照常完成；
- **方法递归无深度限制**：每层调用一个临时 State（Lua 递归栈），无限自调
  最终耗尽 C 栈——Lua 会先抛栈错误（`stack overflow`），但同样是崩溃；
- **`<func>` 中的 `self:` 无校验**：能编译（隐式导出），运行时槽位 NULL
  才报错——函数没有 self 语义，文档里不应出现 `self:`。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `demo/05-object.lua` | 入口：STML 文档、装配、运行、清理诊断（把 `demo/05-object/` 挂进 `package.path`） |
| `demo/05-object/object_manager.lua` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `demo/05-object/runtime.lua` | `Runtime`：静态结构 + `bind_entry` + `invoke_method`（含 Api 三个开口的实例覆写） |
| `demo/05-object/doc_visitor.lua` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |

（Lua 的业务对象与描述符都是平 table，没有独立的"对象模型"文件；类/方法/
函数结构也长在 `runtime.lua` 的 `new_class` 里。）
