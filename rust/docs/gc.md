# 宿主侧垃圾回收：Rust 侧的对象（src/bin/demo06）

> 本文对应 `src/bin/demo06/main.rs`（入口）与 `src/bin/demo06/`（模块），是
> [`../../cpp/docs/gc.md`](../../cpp/docs/gc.md) 的 Rust 版——语义权威在 C++ 侧，
> 本文只讲「怎么跑」与「Rust 差异」。

## 跑起来

```bash
cargo run --bin demo06
```

输出与 C++ demo 逐段对应（引用计数级联 / 帧边界破环 / 垃圾 churn），语法
逐字一致；脚本侧没有 gc 函数——裁决时机在宿主帧循环（每 25 帧一次
collect）。执行模型是**显式帧栈**：`run_steps(20)` 每帧只跑栈顶帧的至多 20
条指令，`run_all()` 一口气跑到帧栈清空，两者随时可切（demo 先限步 25 帧再
run_all）。想单步调试就把 20 改成 1。

## Rust 差异

| | C++ | Rust |
| --- | --- | --- |
| 释放 | `delete` + `trash`/`FlushTrash` 延迟删除 | 摘链 + 判死 + 清字段——**没有 trash**：对象不会地址复用，悬空指针不存在，剩余 `Rc` 引用消失后内存由 Rc 回收 |
| gc 头 | `GCHeader` 嵌入 | `Object` 结构体的普通字段（`gc_prev`/`gc_next`/`ref_count`/`mark`/`dead`）——Rust 无继承 |
| 共享所有权 | 裸指针 + 手工生命期 | `ObjRef = Rc<RefCell<Object>>`；root_set 是 `HashMap<*const RefCell<Object>, ObjRef>`——键裸指针、值 ObjRef（根本来就是活的，登记表多一份强引用不改变语义） |
| 描述符 | gc 对象，装配期 `Pin` | 普通 `Rc`——Rc 引用计数等价替代 Pin |
| 保活「正在执行方法的对象」 | 绑定描述符的字段引用 | `runtime.pinned`（Rust 描述符不参与 gc，等价物） |
| `MaxNodes` | 计全部 gc 节点 | 只计业务对象（描述符由 Rc 管） |
| 退出兜底 | `~ObjectAllocator` | `dispose_all()`——剩余对象（p）逐个跑 `<delete>`，「deleted: James」在这里打印 |
| 诊断 | 打指针 | 打自增 `SelfID`（`next_obj_id()` 原子自增） |

### 与 C++ 最大的工程差异：`&mut State` 独占借用

C++ 版的根扫描可以遍历「全部帧」（`frames` + liveStates）。Rust 的 VM 接口
是 `&mut State`——`run()`/`step()` 执行期间该 State 被**独占借用**，回调里既
扫不到 `frames` 也借不动它。等价方案是**调用时快照**：call 开口的回调拿得到
`&mut State`（= 挂起中的调用方），当场拍一份它的根快照压入
`Runtime.snapshots`；被调执行期的安全点直扫**当前** `State`
（`safe_point(s: &State)`，开口参数直拿），方法帧弹栈时弹出快照。语义等价：
任意时刻可达的根 = 当前 State + 快照栈上各层挂起帧 + pinned。帧边界（没有
正在执行的 State）的 collect 用 `boundary_roots()`：栈顶帧直扫 + 快照 + pinned。

**待挂帧队列**：call 开口要压新帧，但 `frames` 的 `RefCell` 正被 run_steps
持有——回调把新帧放进 `pending` 暂存队列，run_steps 在每条指令之后搬运到帧
栈顶。析构 `<delete>` 走同步旁路 `invoke_method_with_roots`（`in_sync_run`
置位），此间的方法调用回调改走同步路径而不是压帧。

### RefCell 借用纪律

Rust 侧没有 C++ 的「随便改成员」，所有可变状态走 `RefCell`，且**借用严格
不跨嵌套调用**：安全点同步、字段级联、析构回调都在借用结束后才触发下一层。
一个实际的坑：`dispose_all` 不能写 `while let Some(mo) = self.anchor.borrow()…`
——2021 edition 下该不可变借用会活到整个循环体结束，循环体里 `unlink` 对
anchor 的 `borrow_mut` 会 panic。先取出判据、借用随语句结束即可（源码有注释）。

### 装配顺序

Runtime 装配完成后**冻结为 `Rc`**（之后只读）；ObjectManager 的
`runtime: RefCell<Option<Rc<Runtime>>>` 延迟注入——描述符/绑定在装配期就要
创建（此刻 Runtime 还没冻结），析构与诊断在冻结后才需要它。

不变的部分（与 C++ 逐条对应）：安全点 = 开口入口 + Collect 入口；根同步
**先加后删**；ref_count = 字段引用（`set_field` 精确）+ 根引用（同步）；
`free_now` 级联 / `free_sweep` 不级联；`max_nodes` 顶到上限先 collect 仍不够
则开口报 `too many gc nodes.`；块内 `let` 不是释放点——Rust 侧编译器行为与
C++ 相同（变量是函数级平槽位，块退出只归还复用池、零指令），见 C++ 文档
§6。溢出语义由库侧 `wrapping_*` 保证（同 C++ 回绕），demo 侧无感。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `src/bin/demo06/main.rs` | 入口：STML 文档、装配（冻结 + 延迟注入）、运行、收尾诊断 |
| `src/bin/demo06/object.rs` | `Object`（gc 字段 + `SelfID`）+ `ObjRef`/`Desc` + `obj_of`/`handle_of` |
| `src/bin/demo06/gc.rs` | `GcAllocator`：链表、计数、根同步、标记清除、`dispose_all` |
| `src/bin/demo06/object_manager.rs` | `obj:*` 域行为（带 safe_point）+ 析构回调 |
| `src/bin/demo06/runtime.rs` | 装配与调用 + 显式帧栈（`frames` / `pending`）+ `snapshots` / `pinned` |
| `src/bin/demo06/doc_visitor.rs` | STML → 类与函数（`export_binds` 预算） |
| `src/bin/demo06/api.rs` | 三开口转发（内嵌 `BaseApi`） |

`Cargo.toml` 里 `[[bin]] name = "demo06" path = "src/bin/demo06/main.rs"`。

## 已知差异与注意点

- 析构体里调对象方法 / 新建对象：`in_sync_run` 守卫下改走同步路径（压帧
  没人跑——驱动循环正停在 Step 中间）；`collecting` 期间跳过重扫。
- 退出顺序：入口帧弹出 → 收尾 collect（`boundary_roots` 此时为空，p 的根
  引用随之清掉）→ `report_live` → `dispose_all`（兜底析构）。
- `use after gc.`：判死对象的 Handle 理论上不可达（可达即不判死），正常
  程序到不了这两个报错点——它们是防御性检查，不是 demo06 的 UB 面。
- 退出顺序：`rt.scan_state(&state)`（出口前最后一次收集的根）→
  `alloc.collect(&roots)` → `report_live()` → `dispose_all()`（兜底析构）。
