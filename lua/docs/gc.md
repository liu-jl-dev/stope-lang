# 宿主侧垃圾回收：Lua 侧的对象（demo/06-gc.lua）

> 本文对应 `demo/06-gc.lua`（入口）与 `demo/06-gc/`（模块），是
> [`../cpp/docs/gc.md`](../../cpp/docs/gc.md) 的 Lua 版——语义权威在 C++
> 侧，本文只讲「怎么跑」与「Lua 差异」。

## 跑起来

```bash
lua demo/06-gc.lua   # 任何 cwd 都能跑（入口自定位 package.path）
```

输出与 C++ demo 逐段对应（引用计数级联 / 帧边界破环 / 垃圾 churn），语法
逐字一致；脚本侧没有 gc 函数——裁决时机在宿主帧循环（每 25 帧一次
collect）。执行模型是**显式帧栈**：`run_steps(20)` 每帧只跑栈顶帧的至多 20
条指令，`run_all()` 一口气跑到帧栈清空，两者随时可切（demo 先限步 25 帧再
run_all）。想单步调试就把 20 改成 1。

## Lua 差异

| | C++ | Lua |
| --- | --- | --- |
| 释放 | `delete` + `trash`/`flush_trash` 延迟删除 | 摘链 + 判死 + 清字段——**没有 trash**：table 不会地址复用，悬空指针不存在，内存交给 Lua GC |
| 对象形态 | `GCHeader` 嵌入 C++ 对象 | **平 table**，gc 头字段（gc_prev/gc_next/ref_count/mark/dead）直接长在表里，`tag = "gcnode"` 做鸭子判据 |
| 描述符 | gc 对象，装配期 `Pin` | 平 table——GC 等价替代 Pin |
| 保活「正在执行方法的对象」 | 绑定描述符的字段引用 | `runtime.pinned`（Lua 描述符不参与 gc，等价物） |
| `max_nodes` | 计全部 gc 节点 | 只计业务对象（描述符由 GC 管） |
| 退出兜底 | `~ObjectAllocator` | `dispose_all()`——剩余对象（p）逐个跑 `<delete>`，「deleted: James」在这里打印 |
| 诊断 | 打指针 | 打 `tostring(table)`（地址随会话变化） |

不变的部分（与 C++ 逐条对应）：安全点 = 开口入口 + collect 入口；根同步
**先加后删**；ref_count = 字段引用（`set_field` 精确）+ 根引用（同步）；
`free_now` 级联 / `free_sweep` 不级联；`max_nodes` 顶到上限先 collect 仍
不够则开口报 `too many gc nodes.`；块内 `let` 不是释放点——Lua 编译器行为
与 C++ 相同（变量是函数级平槽位，块退出只归还复用池、零指令），见 C++
文档 §6。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `demo/06-gc.lua` | 入口：STML 文档、装配、运行、收尾诊断（自定位 `package.path`） |
| `demo/06-gc/gc_alloc.lua` | `GcAllocator`：链表、计数、根同步、标记清除、dispose_all |
| `demo/06-gc/object_manager.lua` | `obj:*` 域行为（带 safe_point）+ 析构回调 |
| `demo/06-gc/runtime.lua` | 装配与调用 + 显式帧栈（`frames`）+ `live_states`（析构旁路）/ `pinned` |
| `demo/06-gc/doc_visitor.lua` | STML → 类与函数（export_binds 预算） |

（Lua 没有 api 文件：Api 是在 `runtime.lua` 里 `new` 一个实例、覆写三个
字段实现的。对象与描述符都是平 table，没有独立的"对象模型"文件。）

## 已知差异与注意点

- **根扫描必须用 `pairs` 而不是 `ipairs`**：`State.variables` 是 0 起的平
  表，`let` 的槽位可能是 0——`ipairs` 从 1 起会漏掉 0 号槽位里的根，对象
  在「下一个安全点」被误判回收（本实现踩过的实坑）。
- 析构体里调对象方法 / 新建对象：与 C++ 相同的守卫与纪律（`collecting`
  期间跳过重扫）。
- `use after gc.`：判死对象的 Handle 理论上不可达（可达即不判死），正常
  程序到不了这两个报错点——它们是防御性检查，不是 demo06 的 UB 面。
- 退出顺序：入口帧弹出 → 收尾 collect → `report_live` → `dispose_all`（兜底析构）。
- 析构 `<delete>` 走同步旁路 `invoke_method`：级联/sweep 中间不能让出执行权；
  gc 根扫描范围 = `frames`（全部帧）+ `live_states`（析构旁路）+ `pinned`。
- **Lua 特有的占位坑**：call 开口压帧后返回占位值必须是 `stope.NULL` 而不是
  Lua nil——`op_call` 里 `stack[#stack] = 占位`，赋 nil 是删条目（栈缩短）、
  不是占位（demo5 的 `self:Age()` 用返回值时踩过）。
