# 面向对象：Go 侧的对象（cmd/demo05）

> 本文对应 `cmd/demo05/`（package main 多文件，入口 `main.go`），是
> [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 Go 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 Go 里
> 怎么接**，以及最要紧的一件事——**Go 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`basicvm/vm.go`，随 module 分发，不需要改语义）：

- `basicvm.Handle`——第 7 种可观测值，包装一个宿主引用（`Data`）；
  `Equals` 加同一性分支：两个 Handle 相等当且仅当同一个包装实例；
- **`Api` 从具体类型改为接口**：指令分派表 + Handle 的三个开口
  （`HandleAt` / `HandleAssign` / `HandleCall`）。内置实现 `BaseApi` 的三个
  方法默认一律报错；`NewApi()` 返回 `*BaseApi`；
- `State.Api` 字段类型改为 `Api` 接口，`opAssign` / `opCall` / `opAt` 各有
  Handle 分支：识别 Handle → 经 **`s.Api`** 转发接口调用 → 检查 `HasError()`
  → 维持栈纪律。Go 没有 class 继承，虚分发的等价物就是接口——宿主**内嵌
  `BaseApi` 并覆写三个方法**（与 GD/C# 的「继承 Api 覆写」同构）：

```go
type DemoApi struct {
    *basicvm.BaseApi          // 继承 OpTable 与默认 Handle 方法
    objMgr *ObjectManager
}

func (a *DemoApi) HandleAt(s *basicvm.State, h *basicvm.Handle, key any) any {
    return a.objMgr.At(s, h, key)
}
// HandleAssign / HandleCall 同理
```

⚠ `OpMap` 从接口拿不到了：热循环里的 `s.Api.OpMap[...]` 改为
`s.Api.OpTable()[...]`——一个可内联的小方法，语义不变。

## 2. Go 的内存管理：并发三色标记清除

**Go 运行时自带并发三色标记清除 GC**（写屏障 + 分代是我们自己想的，
官方只有并发标记/清扫；GC 触发由 GOGC/GOMEMLIMIT 等启发式决定）。与 C++
的根本差异：

| | C++（demo 5 的立场） | Go |
| --- | --- | --- |
| 释放时机 | `delete` 显式、立即 | 不可达后由并发 GC 决定（STW 只在标记两端，极短） |
| 悬空指针 | `delete` 后再用是 UB | **不存在**——引用仍在，对象不会中途蒸发 |
| 手动释放 | `delete p` | **做不到**——没有释放对象的 API |
| 确定性清理 | 析构函数 | `defer` / `Close()`（**约定**，不是语言机制） |
| 非确定性清理 | —— | `runtime.SetFinalizer`：**不保证运行**（官方文档明确警告不能依赖它做资源管理） |

所以 Go 版的「手动管理」是一条**模拟纪律**，语义与 C++ 对齐、机制不同：

- **删除标记**：`obj:delete` 跑完 `<delete>` 后给对象打 `Deleted = true`；
- **使用检测**：之后对它的属性/方法访问一律报 `use after free.`——C++ 里
  这是未定义行为，Go 里变成确定性的即时报错；
- **内存回收**：`delete` 之后对象不可达，由并发 GC 在下个周期回收。

**析构函数的有效性不受影响**：`<delete>` 的 Program 只在显式 `obj:delete`
时运行，`[Person] deleted!` 出现在删除那一行——时机确定，与 C++ 逐字对应。
语义上 `<delete>` 对应的是 `io.Closer.Close()` / `defer` 的确定性清理角色；
**不要**与 `runtime.SetFinalizer` 混为一谈——官方文档明确说明它不保证执行，
不适合做资源管理，demo 有意避开。

## 3. 描述符的账：GC 替掉复用池

C++ 版为描述符做了「去重缓存 + 驱逐 + `freeDescs` 复用池」三层记账。
Go 版保留去重缓存与驱逐（防曾见增长），但**不需要复用池**——被驱逐的
描述符若不可达，GC 会回收它。缓存用两级 map（对象 → `map[成员 id]描述符`），
键是 `*Object`（按同一性哈希），驱逐是 `delete(map, obj)` 整组摘除，O(1)。

## 4. 与 C++ 版的其它差异

- **值表示**：Integer 是 `int64`、Float 是 `float64`、String 是 `string`、
  BinArr 是 `[]byte`、宿主函数是 `HostFunction`（`fn(argv []any) any` 整包
  传参）、Null 是 Go 的 `nil`；
- **没有哨兵 classID**：C++ 用负数 classID 区分成员/构造器描述符；Go 直接
  按 `Data` 的具体类型分派（`*CtorDesc` / `*MemberDesc`）；
- **没有 Allocator / ProgramConstants**：Go 字符串本身是引用值，常量随
  `Program` 走；
- **装配期失败**：Go 用 `panic` + main 里 `recover` 接住（对齐 C++ 的
  `throw`/catch；这是 Go 社区公认的 panic 用法——只在不可继续的装配错误上）；
- **Exports 是切片**：`Program.Exports` 是 `[]ExportEntry`，查名走
  `ExportOf(name)`（返回 `(slot, ok)`），链接遍直接扫切片；
- **self 槽位**：与 C++ 相同——属性不进 preExports，`self:<属性>` 走隐式
  导出、链接遍配对 `(槽位, 字段下标)`；`self:<方法名>` 链接成 self 的绑定
  描述符。`<func>` 里的 `self:` 有意不校验（见 C++ 文档 §10）；
- **运行期输出**：`reportLive` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`。

## 5. 运行

```
go run ./cmd/demo05
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
Go 里性质有变（见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10）：

- **悬空 Handle → 使用检测**：C++ 的 UB 在 Go 里变成确定性的
  `use after free.` 报错（§2）；
- **属性没有 rvalue 读**：`obj:name[p]` 读取语境得到绑定描述符的 Handle，
  不是字段值——读属性请经方法；
- **构造失败返回半成品对象**：`<new>` 执行中出错时对象已进存活表，
  Handle 照常返回，需手动 delete；
- **缺参调用静默**：缺的形参槽位是 `nil`，构造照常完成；
- **方法递归无深度限制**：每层调用一个临时 State（Go 递归栈），无限自调
  最终 `fatal error: stack overflow`（进程直接终止）；
- **`<func>` 中的 `self:` 无校验**：能编译（隐式导出），运行时槽位 nil
  才报错——函数没有 self 语义，文档里不应出现 `self:`。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `cmd/demo05/main.go` | 入口：STML 文档、装配、运行、清理诊断 |
| `cmd/demo05/object.go` | `Object` + `MemberRef` / `MemberDesc` / `CtorDesc` |
| `cmd/demo05/class.go` | `MethodInfo` / `FunctionInfo` / `ClassInfo` + 槽位装配 |
| `cmd/demo05/object_manager.go` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `cmd/demo05/api.go` | Handle 三个开口的薄转发（内嵌 `BaseApi`） |
| `cmd/demo05/runtime.go` | `Runtime`：静态结构 + 显式帧栈（`pushEntryFrame` / `pushMethodFrame` / `runSteps` / `runAll`）+ 同步 `invokeMethod`（析构专用） |
| `cmd/demo05/doc_visitor.go` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |

同一 package main 下的多文件拆分，跨文件引用零样板（小写标识符包内可见）。

## 8. 存活对象上限

与 C++ 一致，ObjectManager 有 `maxMaxObjects`（默认 0 = 不限，对齐 Parser / STML
`maxDepth` 的约定）：顶到上限的构造器报 `too many objects.` 走 Stope 正常错误
通道，而不是 throw。demo 入口设 4096 作配置演示。注意手动管理的语义：上限内
也**不会自动回收**，必须 `obj:delete`。
