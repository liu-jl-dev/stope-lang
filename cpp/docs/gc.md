# 宿主侧垃圾回收：C++ 参考实现（demo06）

> 本文对应 `demo/06-gc.cpp`（入口）与 `demo/06-gc/`（模块），承接
> [`object-oriented.md`](object-oriented.md)（demo05，手动生命周期）。**这是
> 参考实现 + 教程**：逐步讲清宿主侧 GC 的完整做法。与 demo05 一样，demo 5 / 6
> 会修 bug、优化结构与可读性，但不修文档第 11 节列出的未定义行为与待裁定问题。

## 1. demo 6 改了什么

demo05 里对象的生命期由 Stope 程序手动管理：`obj:delete(p)` 跑 `<delete>`
并释放对象，忘了 delete 就泄漏（`ReportLive` 现形）。demo06 把生命期收归 GC：

| | demo05（手动） | demo06（GC） |
| --- | --- | --- |
| 释放入口 | `obj:delete(p)` | 无手动入口——引用计数归零 / 标记清除 |
| `<delete>` 语义 | `obj:delete` 时跑 | gc 回收前自动跑（析构函数） |
| 存活登记 | `live` 表 + `ReportLive` 现形 | gc 链表 + 退出诊断 |
| 绑定描述符 | 两级 bindCache 去重 + 驱逐 + 复用池 | **全部消失**——描述符也是 gc 对象，用完即垃圾 |
| 兜底 | 无（忘了 delete 就是泄漏） | 标记清除收走循环引用 |

demo06 与 demo05 的代码差异**几乎全部集中在内存管理这一处**：Handle 仍直存
对象指针，描述符结构、两层整数查询、self 绑定、三个开口的语义全部原样。

## 2. 跑起来

```bash
cmake -B build -G "MinGW Makefiles"
cmake --build build --target demo06
./build/demo06
```

输出（节选）：

```
-- introducing --
i am James, 18 years old.
age via self:Age() = 18
-- expect [Person] deleted: Jimmy right above --
[Person] deleted: Jimmy                        ← 1) 字段覆盖，计数归零，立即级联
-- expect nothing above: the pair is locked in a cycle --
-- expect two [Person] deleted above at a frame-boundary collect --
[Person] deleted: cycle.a                      ← 2) 宿主帧边界的 Collect 破环
[Person] deleted: cycle.b
[gc] frame slice 25: collect freed 26          ← 限步 25 帧处的帧边界 Collect
-- expect batches of deleted above: safe-point refcount + frame-boundary sweep --
-- 25 stepped slice(s), 20 steps each, then RunAll --
[Person] deleted: James                        ← 入口帧弹出后 p 不可达，收尾 Collect 收走
[gc] alive: 0 object(s), 3 descriptor(s), root set 0
[gc] no roots: everything reachable has been freed
```

demo 程序对应三段剧情：**字段覆盖触发即时级联**（Jimmy 只挂在 `self:friend`
上，覆盖成 `null` 即死）；**循环引用**（`Pair` 方法里 a、b 互指且只存在于
方法变量里，返回后计数互相锁定——脚本侧没有 gc 函数可调，裁决时机在宿主
手里：驱动循环的帧边界 Collect）；**垃圾 churn**（while 循环丢弃 `Person:New`
的结果——对象本体走安全点引用计数逐个收走，一路积累的一次性描述符由帧边界
的标记清除成批收走）。

执行模型是**帧栈 + 两种驱动**（显式 State 帧栈，见 §9；与 demo05 同一套）：
**限步** `runtime.RunSteps(20)` 每帧只跑栈顶帧的至多 20 条指令，宿主每 25 帧
调一次 `Collect()`——gc 的时机完全由这个循环决定，游戏里就是「每帧给 N 条
指令预算、每 M 帧收集一次」，脚本侧无感；**直接** `runtime.RunAll()` 一口气
跑到帧栈清空——没有帧边界，gc 的裁决点只剩 maxNodes 顶满与收尾那次 Collect。
demo 先限步 25 帧（第一轮帧边界 Collect 在这里触发）再 RunAll 跑完。想单步
调试就把 20 改成 1：嵌套方法体的每一条指令都会停下来。

## 3. 设计总览：两种机制，各管一半

```cpp
struct GCHeader {
  GCHeader* prev;  GCHeader* next;   // 裸侵入式循环双向链表
  int64_t refCount;                  // 字段引用（精确）+ 根引用（安全点同步）
  int mark;                          // 标记清除
  bool dead;                         // 已摘链待删（防双重释放）
};
```

* **引用计数**：对象图的「最后一份引用消失」大多发生在字段覆盖的那一刻，
  计数归零立即级联释放（析构及时，堪比手动 delete）。
* **标记清除**：计数收不走循环引用；回收时机由宿主的驱动循环决定（demo
  每 25 帧调一次 `Collect()`）——从根集合出发标记、未标记的扫除。分配器
  自身只有一个自动触发点：`maxNodes` 顶到上限时分配前先试一次 Collect。
* **节点上限**：`maxNodes`（默认 0 = 不限，对齐 Parser / STML `maxDepth` 的
  约定）限制链上全部 gc 节点——业务对象与描述符都算。顶到上限先尝试
  Collect（gc 还有机会救），仍放不下则分配失败，各开口报
  `too many gc nodes.` 走 Stope 程序的正常错误通道（`s.Error` →
  `state.errors`），而不是 throw；方法体内的 self 绑定失败则记入该方法
  State 的错误，`Run` 的预检让方法体直接不执行。demo 把上限设为 4096
  作配置演示。

两条释放路径：

* `FreeNow`（计数归零路径）：字段引用递减**且级联**——一串刚失去最后一丝
  引用的对象在同一瞬间全部析构。
* `FreeSweep`（sweep 路径）：字段引用只减计数**不级联**——真死透的子对象
  这次没被标记、马上就轮到它；还活着的（从根可达）计数不会归零。

被回收的对象先摘链进 `trash`，安全点末尾统一 `delete`（`FlushTrash`）——
级联与 sweep 的回收名单里可能重叠着同一个对象，`dead` 标志挡住重复处理，
延迟删除保证名单里的指针始终有效。

## 4. 根从哪来：安全点与「先加后删」

**VM 对 Handle 的复制不通知宿主**（Clear2/Copy 对 Handle 是无操作——缝的
设计，见 basic_vm.hpp）。所以「栈/变量里此刻有哪些 Handle」无法靠钩子维护，
只能在**安全点**扫描得知：

* 安全点 = 每个 `obj:*` 开口入口（`ObjectManager::SafePoint`）+ Collect 入口。
* 扫描范围 = 全部**在册 State**：Runtime 的**显式帧栈**（入口帧 + 压住的
  方法帧，见 §9）加 `liveStates`（只装 `<delete>` 析构的同步旁路 State）。
  调用栈不在 C++ 递归里、就在 `frames` 成员里——gc 扫描直接遍历它。
* 扫描内容 = variables + stack + returns，Handle 一律算根（只有 Handle 是
  对象引用，检查 Value 的类型）。

同步的顺序**必须先加后删**（`SyncRoots`）：删除可能级联释放——若先删后加，
被摘除的过期根可能「恰好刚被本轮扫描发现在另一个 State 里」，先删会把它连
同活引用一起级联释放。先加则保证删除级联发生时，本轮新发现的根已经各就各位。

这条顺序同时是**「归零即释放」可靠性的来源**：任何 DelRef（字段覆盖）只
发生在开口内部，而开口入口刚扫过全部 State——此时计数归零必然意味着 VM 侧
再无 Handle。若没有安全点纪律（比如外部手动维护 rootSet、增删时机不明），
「归零即释放」随时可能把栈上还活着的 Handle 悬空——这是 demo06 最关键的
一处设计。

一个逐步对照的例子（与 §6 的作用域陷阱无关，这里 `t` 是函数级变量；下文
说的「新对象」都指这句 `Person:New` 造出来的那个 Person 实例）：

```stml
let t = Person:New("Alice", 1);   // 新对象的 Handle 先在栈上，let 后躺进变量槽 t
obj:friend[p] = t;                // 新对象：字段引用 +1
obj:friend[p] = null;             // 旧值 DelRef → 新对象计数归零 → 释放？
```

**没有安全点的世界**：根引用从未被记账（宿主不知道 `t` 槽位里躺着它），
新对象的计数只有字段那 1。第三句 DelRef → 0 → 新对象被立即释放——而 `t`
还指着它，下一句 `obj:name[t]` 读的是已释放内存（若节点地址被新对象复用，
则是「操作错误的绑定」），典型 UB。

**有安全点的世界**：第三句是 `Assign` 开口，入口先扫根——发现 `t` 槽位里
有它，RootAdd，计数 2；然后才执行字段覆盖 → 1，不归零，新对象活着。等
`t` 被覆写（VM 静默，计数保持 1——偏高但安全）且字段也空了，**下一个
开口**的扫描发现它不再出现在任何 State 里 → 后删阶段 −1 → 0 → 释放。
这个释放之所以可靠，正因为扫描刚确认过「它无处可寻」。

SafePoint 因此有两个职责：① 给引用计数兜底——让所有 DelRef 都发生在「根
集合刚刷新」的瞬间；② 给标记清除供根——Collect 从 `rootSet` 出发标记，
没有安全点扫描，标记清除连「从哪里开始标」都不知道。demo05 不需要它，因为
生死由用户手动 `obj:delete` 决定、错了是用户的 UB；demo06 里释放决定权在
gc，就必须自己把「谁还活着」查清楚。

## 5. 引用计数的口径

```
refCount = 字段引用（SetField 精确维护）+ 根引用（SyncRoots 同步，每个对象至多 +1）
         + 宿主长期持有的 Pin（装配期描述符，永久 +1）
```

* 字段写入走 `SetField`：旧值 DelRef（可级联）→ Clear2 → Copy → 新值 AddRef。
* 根引用按「对象是否出现在扫描结果里」记账，不按 Handle 份数——同一对象在
  五个槽位里也只 +1（保守：少记不漏记，漏记即悬空，多记只是晚回收）。
* 方法返回时的 `selfProps` 回写也走 `SetField`——demo05 这里是裸 Copy。

**计数减少只有三个时机**，其余场合一律不动计数：

1. **字段旧值被覆盖**（`SetField` 的 DelRef）：`obj:friend[p] = null` 这类
   开口内的写入，以及方法返回时 `selfProps` 的回写。发生在开口内部——
   安全点刚扫过，归零即级联。
2. **安全点同步的后删阶段**（`SyncRoots`）：上一轮被记为根的对象这一轮扫描
   没再出现 → −1。同样发生在刚扫完的瞬间，归零即级联。
3. **持有者对象被回收、清点字段时**（`FreeNow` / `FreeSweep` 遍历字段）：
   字段里的 Handle 引用逐个 −1——归零路径级联，sweep 路径不级联（见 §3）。

反面同样重要：**VM 弹栈、变量被覆盖、描述符 Handle 被丢弃，都不会立即减
计数**——这些「Handle 从 VM 侧消失」的变化宿主看不见，只能等下一个安全点
的根同步统一结算（ −1 或维持）。所以计数反映的是「上次扫描时的根 + 当前
字段引用」，宁可偏大不可偏小；垃圾最迟在下次 Collect 被标记清除收走。

## 6. 作用域陷阱：块内 `let` 不是释放点，guard 对象只能活在函数作用域

Stope 的变量是**函数级平槽位**，`let` 在块 / if / while 体内声明也一样。
编译器的实际行为（`src/compiler.cpp`）：

* `let` 声明 → `varAlloc.newVar()` 分配新槽位，赋值写入；
* **块退出**（`onVisitBlockStmt` 与 if / while 体的 `visitBodyAsBlock`）→
  只把槽位 `freeVar` 归还编译器的复用池（`newVar` 按最小序取用），**不产生
  任何指令**：不清值、不通知宿主。槽位里那个 Handle 还在 `variables` 里，
  gc 根扫描每次都扫得到它；
* 被归还的槽位何时被覆写取决于**后续代码**：复用它的 `let` 带赋值才覆写，
  `let x;`（无赋值）连覆写都没有。

于是下面这个「块作用域 guard」没有任何及时的释放路径：

```
{
  let file = open("input.txt");   // guard 对象：析构里关文件
}
// 块在这里结束——但什么都不会发生：不跑 <delete>、不减计数
```

看一个最小的编译结果就能确认。Stope 源码：

```
let a = 1;
{
  let f = 2;
}
let b = 3;
```

编译产物（`Disasm` 输出，节选指令区）：

```
[0]     PushId     0          ← a：槽位 0
[2]     PushInt    0          （常量 1）
[4]     Assign
[5]     PushId     1          ← f：槽位 1（块内 let）
[7]     PushInt    1          （常量 2）
[9]     Assign
[10]    PushId     1          ← b：复用槽位 1（f 已 freeVar）
[12]    PushInt    2          （常量 3）
[14]    Assign
```

两个铁证：**[9] 与 [10] 之间空无一物**——`}` 的编译产物是零指令，块退出
既不清值也不通知宿主；**b 的 PushId 是 1**——f 的槽位早已被编译器回收，
复用给 b。也就是说块退出后对象仍被槽位 1 引用，gc 根扫描每次都扫到它，
永远不收；直到 b 的 Assign 覆写槽位（此刻宿主依然不知情），下个安全点的
根同步才把 f 结算掉。若块之后没有任何 `let` 复用，就只剩函数返回一条路。

它唯一的释放路径是**函数返回**：State 弹栈销毁、variables 消失，下一个安全点
（下个 `obj:*` 开口或宿主帧边界的 Collect）的根同步发现它不再出现 → −1 → 归零 →
级联。也因此**释放顺序不保证**——多个 guard 的结算顺序由根集合遍历与级联
链决定，不是声明逆序；while 体内声明的对象则按「下一轮覆写 → 下个安全点
结算」批次化延迟。

**结论：析构承担副作用的 guard 类型（关文件、解锁、回滚）只能声明在函数
作用域**，且要接受「函数返回后的下个安全点」这个时机与不保证的顺序。块内
声明 guard 是程序错误——编译器不报错、运行期不炸，句柄就是漏了。需要
「离开块就释放」的语义，得靠显式关闭入口（demo05 的 `obj:delete` 正是为此
存在的）。

## 7. 描述符也是 gc 对象

demo05 为绑定描述符建了整套基建：两级 bindCache 去重、对象级驱逐、复用池。
demo06 里**全部消失**：描述符就是挂在 gc 链表上的普通节点（classId 为负
哨兵），`Bind` 每次新建，方法返回后无人引用即成垃圾，下次 gc 收走——
「缓存正确性」问题被「垃圾可回收」消解了。

唯一的例外是**装配期**创建、长住宿主侧（`Method::exportBinds`）的描述符：
它们不在任何 State 里，根扫描看不见。分配器提供 `Pin`：永久 +1 且 Collect
恒从 pinned 出发标记。`SafePoint` 跳过收集期间的重扫（`collecting` 守卫），
析构函数体里调对象方法是安全的，但不要大量新建对象——会重入 gc（有守卫
不会崩，时机不可预期）。

## 8. 为什么是裸双向链表

对象全 collection 需要一条能走遍的注册链；demo06 直接用**裸侵入式循环双向
链表**（哨兵锚点 + 每对象 prev/next 指针），而不是「数组 + 整数 id」的
间接方案，理由有三：

1. **Handle 语义连贯**：Handle 直存对象指针是 demo05 全部访问路径的基础
   （描述符、两层查询、self 绑定）；换 id 就得每条路径加一层 `Get(id)`。
2. **没有槽位复用别名问题**：id 方案必然带 recycled 槽位复用，悬空 id 会
   别名到新对象——demo05 用 freeDescs 池苦苦解决的就是这一类问题；链表
   方案下节点 delete 掉就没了，问题不存在。
3. **GC 不搬移对象**：堆节点地址天然稳定，直接存指针即可，摘链 O(1)，
   sweep 就是走一遍链表。

代价两条，都只在规模上显形（对 demo 规模无所谓）：

* **每对象一次堆分配**：链表方案里每个对象都是独立的 `new Object{}`，创建
  一万个对象就是一万个独立的堆分配/释放调用，每个节点还带 prev/next/
  refCount/mark 头开销，且散布在堆的各处。数组方案一次要一大块连续内存，
  分配是"推进一个下标"级别的操作，槽位复用进一步摊薄成本。
* **遍历是指针追逐**：sweep / 清标记 / 诊断走遍全部对象时，只能沿 `next`
  指针一个一个跳——每个节点的地址都不可预测，大概率不在缓存里，每次跳转
  都可能是一次缓存未命中。数组方案按下标连续存放，线性扫内存，硬件预取器
  非常擅长这种访问模式。

换来的是硬性的东西：Handle 直存指针、没有悬空 id 的别名问题。真要做嵌入
级别的分配器，典型的改进方向是折中——**对象仍放连续内存块（page / slab），
块内用空闲链串起来**：既保住数组式遍历的缓存友好，又保住"节点地址稳定、
free 即摘链"的链表语义。

## 9. 装配、驱动与文件结构

装配顺序与 demo05 相同（STML 解析 → DocVisitor → `PushEntryFrame`），驱动
换成**显式帧栈 + 每帧限步**（与 demo05 的 §6 同一套模型，此处只说 gc 相关
的部分）：

* **帧栈就是 gc 的扫描范围**：`Runtime::frames`（入口帧 + 压住的方法帧）
  加 `liveStates`（只装析构同步旁路的临时 State）。旧版「main 里
  `TrackState(state)` 注册 driver、`InvokeMethod` 执行期间临时 Track」的
  做法没有了——State 活在帧栈里，根扫描直接遍历，不再有「散落在宿主各处的
  State 要登记」的问题。
* **没有 `gc:Collect` 宿主函数**：脚本侧没有 gc 函数可调。宿主本来就能直接
  调 `Collect()`——注册成 VM 函数只是让脚本能「主动要求 gc」，代价是每个
  移植版都要为 `HostFunction` 没有 user-data 参数搞一条桥接通道（C++ 的
  文件级  静态指针等）。demo 把裁决时机放进驱动循环：限步段每 25 帧一次 Collect，
  顺带演示「gc 时机由宿主决定」这个嵌入立场（切到 `RunAll` 后没有帧边界，
  gc 裁决只剩 maxNodes 顶满与收尾那次 Collect）。
* **析构保持同步旁路**：`<delete>` 在级联释放 / sweep 的中间被调用，之后还
  要清字段、还字符串引用——`InvokeMethod`（同步版：装配 + `Run` + 收尾）
  专供这条路，析构里再调方法也走它（压帧会没人跑，见 demo05 §6）。

**`Method::exportBinds` 是 demo06 新增的装配产物**：方法有独立的 program，
方法体里的 `Person:New` / `obj:<名>` 是它自己的隐式导出——demo05 只往 main
绑描述符，方法体内建对象会拿到 Null 槽位。链接遍（`linkSelfCalls`）把
`(槽位下标, 描述符 Handle)` 逐方法预算好，`SetupMethodState` 逐个拷进 State。
（过程中还修了一个 demo05 潜伏的 bug：`Runtime::NewClass` 在 `cls.name` 赋值
**之前**登记 classMap，键永远是空串——demo05 从不查 classMap 所以没暴露。）

| 文件 | 职责 |
| --- | --- |
| `../06-gc.cpp` | 入口：STML 文档、装配、帧循环驱动（每帧限步 + 帧边界 Collect）、收尾诊断 |
| `Object.hpp/.cpp` | `GCHeader` / `Object` / `ObjectAllocator`：链表、计数、同步、标记清除 |
| `ObjectManager.hpp/.cpp` | `obj:*` 域全部行为：描述符、三个开口（带 SafePoint）、析构回调 |
| `Runtime.hpp/.cpp` | `Runtime`：显式帧栈 + `liveStates` + `BindEntry` + `InvokeMethod`（析构同步路径） |
| `Class.hpp/.cpp` / `Function.hpp/.cpp` | 同 demo05（`Method` 多一个 `exportBinds`） |
| `API.hpp/.cpp` / `DocVisitor.hpp/.cpp` | 同 demo05（DocVisitor 多了 exportBinds 链接） |

## 10. 移植提示

* **先问宿主语言三件事**：对象地址稳不稳（决定 Handle 存指针还是存 id）、
  能不能枚举 VM 栈/变量（决定根扫描怎么写）、有没有析构钩子（决定 `<delete>`
  何时跑）。C++ 三问全绿灯；GDScript 引用计数即析构、JS/Go 等有 Finalizer
  但时机不保证——各语言的口径见
  [`../../docs/zh-cn/host-memory.md`](../../docs/zh-cn/host-memory.md)。
* **「立即级联」的可靠性来自安全点顺序**，不来自引用计数本身。宿主环境若
  无法在对象操作入口重扫根，就得接受「外部手动维护 rootSet」的纪律，并把
  纪律写进文档。
* 延迟删除（trash）在带 GC 的宿主语言里不需要——那是 C++ 侧防止「回收名单
  重叠」的手段；宿主语言自己的 gc 会兜底。

## 11. 已知局限与未定义行为（有意不修，供参考时注意）

与 demo05 相同的纪律边界**继续成立**：宿主在 gc 结构之外私存的 Handle 副本
（C++ 局部变量）不参与根扫描——在两个安全点之间持有即有悬空风险，嵌入者
应在开口返回后立即消费返回值。此外 demo06 特有的：

* **析构函数里的重入**：`<delete>` 体里新建对象会重入 gc（守卫使本次
  Collect 跳过），大量新建会把回收推迟到下个安全点；析构里不要依赖
  「此时还有哪些对象活着」。
* **标记是递归语言无关的迭代实现**（显式栈），但同步扫描是全量重扫——
  每 obj 开口 O(总槽位)。demo 规模无感，真要嵌入请改增量记账。
* **无分代、无整理**：不搬移对象（Handle 存指针的前提），碎片交给分配器；
  长命对象反复穿越 Collect。
* **回收时机完全由宿主决定**：分配器自身只在 `maxNodes` 顶到上限时才自动
  Collect。宿主驱动循环若从不调 `Collect()`，循环引用就永远挂着——嵌入者
  必须把「何时收集」写进自己的帧循环（demo 是每 25 帧）。
* **`FreeNow` 的级联是 C++ 递归**：一条一万长的对象链同时失去引用，就是
  一万层递归——爆宿主栈。标记路径已迭代化（显式栈），级联没有；真要嵌入
  请改成两阶段（先沿引用收集待释放名单，再循环逐个释放）。
* **SyncRoots 的再入窗口**：`Collect` 入口的那次同步发生在 `collecting`
  置位之前——若这次同步的级联触发了析构、析构体又调了对象方法（开口 →
  再入一次全量扫描），两层同步会交错运行。当前靠「外层用预计算的 stale
  名单、内层增删 rootSet、dead 标志挡重」保证不出错，但这属于「脆弱的
  正确」：改动任何一处的顺序前，先想清楚这两层在交错什么。
* **`<delete>` 跑在回收线程的调用栈上**（本 demo 无多线程）：若宿主环境
  异步回收，析构里的 println 之类要自己保证时序。
