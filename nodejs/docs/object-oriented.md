# 面向对象：nodejs 侧的对象（demo/05-object/）

> 本文对应 `demo/05-object/`（入口 `demo/05-object.js`），是
> [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 nodejs 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 JS 里
> 怎么接**，以及最要紧的一件事——**JS 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`src/basic_vm.js`，随包分发，不需要改）：

- `BasicVM.Handle`——第 7 种可观测值，包装一个宿主引用（`data`）；
  `equals` 加同一性分支：两个 Handle 相等当且仅当同一个包装实例；
- `Api` 内置三个**虚方法** `handleAt` / `handleAssign` / `handleCall`，
  默认实现一律报错；
- `opAt` / `opAssign` / `opCall` 各有 Handle 分支：识别 Handle → 经 **`s.api`**
  （State 挂着的 Api 实例）转发虚调用 → 检查 `HasError()` → 维持栈纪律。
  注意 `opMap` 里的指令是模块级函数，转发走 `s.api` 而不是 `this`——所以
  继承 Api 覆写三个方法即可生效（ES class 原生继承）：

```js
class DemoApi extends BasicVM.Api {
  handleAt(s, handle, key) { return objMgr.at(s, handle, key) }
  handleAssign(s, handle, value) { objMgr.assign(s, handle, value) }
  handleCall(s, handle, args) { return objMgr.callMember(s, handle, args) }
}
```

## 2. JS 的内存管理：没有手动释放

**JS 引擎是追踪式垃圾回收**（V8：分代 + 标记清除/整理；实现细节随引擎而异，
规范只要求「不可达即最终回收」）。与 C++ 的根本差异：

| | C++（demo 5 的立场） | JS |
| --- | --- | --- |
| 释放时机 | `delete` 显式、立即 | 不可达后由 GC 决定 |
| 悬空指针 | `delete` 后再用是 UB | **不存在**——引用仍在，对象不会中途蒸发 |
| 手动释放 | `delete p` | **做不到**——没有任何 API 能释放一个仍被引用的对象 |

所以 JS 版的「手动管理」是一条**模拟纪律**，语义与 C++ 对齐、机制不同：

- **删除标记**：`obj:delete` 跑完 `<delete>` 后给对象打 `deleted = true`；
- **使用检测**：之后对它的属性/方法访问一律报 `use after free.`——C++ 里
  这是未定义行为，JS 里变成确定性的即时报错（没有悬空指针可复用，错误
  检测反而更友好）；
- **内存回收**：`delete` 之后对象是否立刻归还内存**不由 demo 决定**——
  VM 变量、缓存等引用断掉之后，对象不可达，由 GC 在某个时刻回收。

**析构函数的有效性不受影响**：`<delete>` 的 Program 只在显式
`obj:delete` 时运行，`[Person] deleted!` 出现在删除那一行——时机确定，
与 C++ 逐字对应。GC 兜走的只是「析构之后的内存」。

## 3. 描述符的账：GC 替掉复用池

C++ 版为描述符做了「去重缓存 + 驱逐 + `freeDescs` 复用池」三层记账。
JS 版保留去重缓存与驱逐（防曾见增长），但**不需要复用池**——被驱逐的
描述符若不可达，GC 会回收它。缓存用两级 `Map`（对象 → (成员 id → 描述符)），
键是对象引用（同一性），驱逐是 `Map.delete` 整组摘除，O(1)。

## 4. 与 C++ 版的其它差异

- **值表示**：Integer 是 `BigInt`、Float 是 `Number`、String 是 `string`、
  BinArr 是 `Uint8Array`、宿主函数就是普通函数（`fn(argv)` 整包传参）；
- **没有哨兵 classId**：C++ 用负数 classId 区分成员/构造器描述符；JS 直接
  `instanceof MemberDesc` / `instanceof CtorDesc` 按类型分派；
- **没有 Allocator / ProgramConstants**：JS 字符串本身就是引用值，常量随
  `Program` 走；
- **装配期异常**：JS 有 `throw/catch`，装配期失败沿用 C++ 的做法（抛出、
  main 里接住）；
- **self 槽位**：与 C++ 相同——属性不进 preExports，`self:<属性>` 走隐式
  导出、链接遍配对 `(槽位, 字段下标)`；`self:<方法名>` 链接成 self 的绑定
  描述符。`<func>` 里的 `self:` 有意不校验（见 C++ 文档 §10）；
- **运行期输出**：`reportLive` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`。

## 5. 运行

```
node demo/05-object.js
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
JS 里性质有变（见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10）：

- **悬空 Handle → 使用检测**：C++ 的 UB 在 JS 里变成确定性的
  `use after free.` 报错（§2）；
- **属性没有 rvalue 读**：`obj:name[p]` 读取语境得到绑定描述符的 Handle，
  不是字段值——读属性请经方法；
- **构造失败返回半成品对象**：`<new>` 执行中出错时对象已进存活表，
  Handle 照常返回，需手动 delete；
- **缺参调用静默**：缺的形参槽位是 `null`，构造照常完成；
- **方法递归无深度限制**：每层调用一个临时 State（JS 递归栈），无限自调
  最终耗尽栈容量抛 `RangeError: Maximum call stack size exceeded`——
  比 C++ 的栈溢出体面一些，但同样是崩溃；
- **`<func>` 中的 `self:` 无校验**：能编译（隐式导出），运行时槽位 null
  才报错——函数没有 self 语义，文档里不应出现 `self:`。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `demo/05-object.js` | 入口：STML 文档、装配、运行、清理诊断 |
| `demo/05-object/object.js` | `MyObject` + `MemberRef` / `MemberDesc` / `CtorDesc` |
| `demo/05-object/classes.js` | `MethodInfo` / `FunctionInfo` / `ClassInfo` + 槽位装配 |
| `demo/05-object/object_manager.js` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `demo/05-object/api.js` | BasicVM 三个虚方法的薄转发 |
| `demo/05-object/runtime.js` | 显式帧栈（`pushEntryFrame`/`pushMethodFrame`/`runSteps`/`runAll`）+ `bindEntry` + `invokeMethod`（析构同步路径） |
| `demo/05-object/doc_visitor.js` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |

## 8. 存活对象上限

与 C++ 一致，ObjectManager 有 `maxmaxObjects`（默认 0 = 不限，对齐 Parser / STML
`maxDepth` 的约定）：顶到上限的构造器报 `too many objects.` 走 Stope 正常错误
通道，而不是 throw。demo 入口设 4096 作配置演示。注意手动管理的语义：上限内
也**不会自动回收**，必须 `obj:delete`。
