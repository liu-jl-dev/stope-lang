# 宿主侧垃圾回收：Go 侧的对象（cmd/demo06）

> 本文对应 `cmd/demo06/main.go`（入口）与 `cmd/demo06/`（模块），是
> [`../cpp/docs/gc.md`](../../cpp/docs/gc.md) 的 Go 版——语义权威在 C++ 侧，
> 本文只讲「怎么跑」与「Go 差异」。

## 跑起来

```bash
go run ./cmd/demo06
```

输出与 C++ demo 逐段对应（引用计数级联 / 帧边界破环 / 垃圾 churn），语法
逐字一致；脚本侧没有 gc 函数——裁决时机在宿主帧循环（每 25 帧一次 Collect）。
执行模型是**显式帧栈**：`runSteps(20)` 每帧只跑栈顶帧的至多 20 条指令，
`runAll()` 一口气跑到帧栈清空，两者随时可切（demo 先限步 25 帧再 RunAll）。
想单步调试就把 20 改成 1。

## Go 差异

| | C++ | Go |
| --- | --- | --- |
| 释放 | `delete` + `trash`/`FlushTrash` 延迟删除 | 摘链 + 判死 + 清字段——**没有 trash**：对象不会地址复用，悬空指针不存在，内存交给 Go GC |
| gc 头 | `GCHeader` 嵌入 | `gcHeader` 内嵌进 `Object`/`gcAnchor`——Go 不能同名字段+方法，内嵌结构体方法提升即 `GcNode` 接口契约 |
| 描述符 | gc 对象，装配期 `Pin` | 普通对象——Go GC 等价替代 Pin |
| 保活「正在执行方法的对象」 | 绑定描述符的字段引用 | `runtime.pinned`（Go 描述符不参与 gc，等价物） |
| `MaxNodes` | 计全部 gc 节点 | 只计业务对象（描述符由 GC 管） |
| 退出兜底 | `~ObjectAllocator` | `DisposeAll()`——剩余对象（p）逐个跑 `<delete>`，「deleted: James」在这里打印 |
| 诊断 | 打指针 | 打自增 `SelfID`（Go 拿不到稳定地址） |

不变的部分（与 C++ 逐条对应）：安全点 = 开口入口 + Collect 入口；根同步
**先加后删**；RefCount = 字段引用（`SetField` 精确）+ 根引用（同步）；
`freeNow` 级联 / `freeSweep` 不级联；`MaxNodes` 顶到上限先 Collect 仍不够
则开口报 `too many gc nodes.`；块内 `let` 不是释放点——Go 侧编译器行为与
C++ 相同（变量是函数级平槽位，块退出只归还复用池、零指令），见 C++ 文档
§6。Go 的 int 就是 64 位，溢出回绕语义与 C++ 一致，demo 侧无感。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `cmd/demo06/main.go` | 入口：STML 文档、装配、运行、收尾诊断 |
| `cmd/demo06/object.go` | `Object`（`gcHeader` 内嵌 + `SelfID`）+ `GcNode`/`gcAnchor` + 描述符 |
| `cmd/demo06/gc.go` | `gcAllocator`：链表、计数、根同步、标记清除、DisposeAll |
| `cmd/demo06/object_manager.go` | `obj:*` 域行为（带 SafePoint）+ 析构回调 |
| `cmd/demo06/runtime.go` | 装配与调用 + 显式帧栈（`frames`）+ `liveStates` / `pinned` |
| `cmd/demo06/doc_visitor.go` | STML → 类与函数（ExportBinds 预算） |
| `cmd/demo06/api.go` | 三开口转发（内嵌 `BaseApi`） |

## 已知差异与注意点

- 析构体里调对象方法 / 新建对象：与 C++ 相同的守卫与纪律（`collecting`
  期间跳过重扫）。
- `use after gc.`：判死对象的 Handle 理论上不可达（可达即不判死），正常
  程序到不了这两个报错点——它们是防御性检查，不是 demo06 的 UB 面。
- 退出顺序：入口帧弹出 → 收尾 `Collect` → `reportLive` → `DisposeAll`（兜底析构）。
- 析构 `<delete>` 走同步旁路 `invokeMethod`：级联/sweep 中间不能让出执行权，
  压帧没人跑；gc 根扫描范围 = `frames` + `liveStates`（只装析构旁路 State）+ `pinned`。
