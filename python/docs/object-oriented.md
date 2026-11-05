# 面向对象：Python 侧的对象（demo/05-object/）

> 本文对应 `demo/05-object/`（入口 `demo/05-object.py`），是
> [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 Python 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 Python
> 里怎么接**，以及最要紧的一件事——**Python 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`stope/basic_vm.py`，随包分发，不需要改）：

- `stope.Handle`——第 7 种可观测值，包装一个宿主引用（`data`）；
  `equals` 加同一性分支：两个 Handle 相等当且仅当同一个包装实例；
- `Api` 内置三个**虚方法** `handle_at` / `handle_assign` / `handle_call`，
  默认实现一律报错；
- `_op_assign` / `_op_call` / `_op_at` 各有 Handle 分支：识别 Handle → 经
  **`s.api`**（State 挂着的 Api 实例）转发虚调用 → 检查 `errors` → 维持栈
  纪律。注意 `op_map` 里装的是模块级函数，转发必须走 `s.api`——宿主只需
  继承并覆写（Python 方法天然动态派发）：

```python
class DemoApi(Api):
    def handle_at(self, s, handle, key): return obj_mgr.at(s, handle, key)
    def handle_assign(self, s, handle, value): obj_mgr.assign(s, handle, value)
    def handle_call(self, s, handle, args): return obj_mgr.call_member(s, handle, args)
```

## 2. Python 的内存管理：引用计数 + 兜环 GC

CPython 的机制是**两层**，与 C++ 的根本差异：

| | C++（demo 5 的立场） | CPython |
| --- | --- | --- |
| 主回收机制 | `delete` 显式、立即 | **引用计数**：最后一个引用一断，对象**立即**销毁 |
| 兜底机制 | —— | `gc` 模块：分代回收，专收**循环引用** |
| 悬空指针 | `delete` 后再用是 UB | **不存在**——引用仍在，对象不会中途蒸发 |
| 手动释放 | `delete p` | **做不到**——`del p` 只断引用，杀不掉仍被引用的对象 |
| 确定性清理 | 析构函数 | `__del__` 在计数归零时触发；**兜环 GC 回收的环内对象不保证触发** |

所以 Python 版的「手动管理」是一条**模拟纪律**，语义与 C++ 对齐、机制不同：

- **删除标记**：`obj:delete` 跑完 `<delete>` 后给对象打 `deleted = True`；
- **使用检测**：之后对它的属性/方法访问一律报 `use after free.`——C++ 里
  这是未定义行为，Python 里变成确定性的即时报错；
- **内存回收**：`delete` 之后对象不可达，引用计数立即归还内存（这是 CPython
  比 JS/C# 确定性更强的一点）；若将来出现引用环，由 `gc` 模块分代兜底。

**析构函数的有效性不受影响**：`<delete>` 的 Program 只在显式 `obj:delete`
时运行，`[Person] deleted!` 出现在删除那一行——时机确定，与 C++ 逐字对应。
注意不要把 `<delete>` 与 Python 的 `__del__` 混为一谈：`__del__` 依赖计数
归零的时机，且**兜环 GC 回收的环内对象不保证触发 `__del__`**——demo 有意
避开这条非确定性路径。

## 3. 描述符的账：回收机制替掉复用池

C++ 版为描述符做了「去重缓存 + 驱逐 + `freeDescs` 复用池」三层记账。
Python 版保留去重缓存与驱逐（防曾见增长），但**不需要复用池**——被驱逐的
描述符若不可达，引用计数立即回收它。缓存用两级 `dict`（对象 → (成员 id →
描述符)），键是对象（按同一性哈希），驱逐是 `dict.pop` 整组摘除，O(1)。

## 4. 与 C++ 版的其它差异

- **值表示**：Integer 是 `int`（VM 侧 64 位回绕；demo 的量级远碰不到）、
  Float 是 `float`、String 是 `str`、BinArr 是 `bytes`、宿主函数是普通函数
  （`fn(argv)` 整包传参）；
- **没有哨兵 classId**：C++ 用负数 classId 区分成员/构造器描述符；Python
  直接 `isinstance(d, MemberDesc)` / `isinstance(d, CtorDesc)` 按类型分派；
- **没有 Allocator / ProgramConstants**：Python 字符串本身是引用对象，常量
  随 `Program` 走；
- **装配期异常**：Python 有异常，装配期失败沿用 C++ 的做法（`raise`、
  main 里接住）；
- **self 槽位**：与 C++ 相同——属性不进 preExports，`self:<属性>` 走隐式
  导出、链接遍配对 `(槽位, 字段下标)`；`self:<方法名>` 链接成 self 的绑定
  描述符。`<func>` 里的 `self:` 有意不校验（见 C++ 文档 §10）；
- **运行期输出**：`report_live` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`。

## 5. 运行

```
python python/demo/05-object.py
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
Python 里性质有变（见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10）：

- **悬空 Handle → 使用检测**：C++ 的 UB 在 Python 里变成确定性的
  `use after free.` 报错（§2）；
- **属性没有 rvalue 读**：`obj:name[p]` 读取语境得到绑定描述符的 Handle，
  不是字段值——读属性请经方法；
- **构造失败返回半成品对象**：`<new>` 执行中出错时对象已进存活表，
  Handle 照常返回，需手动 delete；
- **缺参调用静默**：缺的形参槽位是 `None`，构造照常完成；
- **方法递归无深度限制**：每层调用一个临时 State（Python 递归栈），无限
  自调最终抛 `RecursionError`（比 C++ 的栈溢出体面一些，但同样是崩溃）；
- **`<func>` 中的 `self:` 无校验**：能编译（隐式导出），运行时槽位 None
  才报错——函数没有 self 语义，文档里不应出现 `self:`。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `demo/05-object.py` | 入口：STML 文档、装配、运行、清理诊断（把 `demo/05-object/` 挂进 `sys.path`） |
| `demo/05-object/object_model.py` | `Object` + `MemberRef` / `MemberDesc` / `CtorDesc` |
| `demo/05-object/classes.py` | `MethodInfo` / `FunctionInfo` / `ClassInfo` + 槽位装配 |
| `demo/05-object/object_manager.py` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `demo/05-object/api.py` | BasicVM 三个虚方法的薄转发 |
| `demo/05-object/runtime.py` | `Runtime`：静态结构 + `bind_entry` + `invoke_method` |
| `demo/05-object/doc_visitor.py` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |
