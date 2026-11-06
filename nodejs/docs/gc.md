# 宿主侧垃圾回收：nodejs 侧的对象（demo/06-gc.js）

> 本文对应 `demo/06-gc.js`（入口）与 `demo/06-gc/`（模块），是
> [`cpp/docs/gc.md`](../../cpp/docs/gc.md) 的 nodejs 版——语义权威在 C++
> 侧，本文只讲「怎么跑」与「JS 差异」。

## 跑起来

```bash
node demo/06-gc.js
```

输出与 C++ demo 逐段对应（引用计数级联 / 循环破环 / 垃圾 churn），语法
逐字一致。执行模型是**显式帧栈 + 两种驱动**：`runSteps(20)` 每帧限步、宿主
每 25 帧调一次 `collect()`（gc 裁决时机在帧边界，脚本侧没有 gc 函数）；
`runAll()` 一口气跑到帧栈清空——没有帧边界，gc 裁决只剩 `maxNodes` 顶满与
收尾那次 collect。demo 先限步 25 帧（第一轮帧边界 Collect 破环）再
`runAll()` 跑完。

## JS 差异

| | C++ | nodejs |
| --- | --- | --- |
| 执行模型 | `Runtime::frames` 显式帧栈 + `RunSteps`/`RunAll` | 相同：`frames` 数组 + `runSteps`/`runAll`，调用栈不再走 JS 调用栈 |
| 释放 | `delete` + `trash`/`FlushTrash` 延迟删除 | 摘链 + 判死 + 清字段——**没有 trash**：JS 对象不会地址复用，悬空指针不存在，内存交给引擎 |
| 描述符 | gc 对象，装配期 `Pin` | 普通对象——引擎 GC 等价替代 Pin |
| 保活「正在执行方法的对象」 | 绑定描述符的字段引用 | `runtime.pinned`：`pushMethodFrame` 压入、弹帧收尾弹出（JS 描述符不参与 gc，等价物） |
| 析构（`<delete>`） | 同步旁路 `InvokeMethod` | 相同：`invokeMethod`（装配 + Run + 收尾），在级联/sweep 中间一口气跑完，不走帧栈 |
| gc 根扫描范围 | `frames` + `liveStates` | 相同：`frames` + `liveStates`（只装析构旁路 State）+ `pinned` |
| `maxNodes` | 计全部 gc 节点 | 只计业务对象（描述符由引擎管） |
| 退出兜底 | `~ObjectAllocator` | `disposeAll()`——剩余对象逐个跑 `<delete>`，「deleted: James」在这里打印 |
| 诊断 | 打指针 | 打自增 `selfId`（JS 拿不到稳定地址） |

不变的部分（与 C++ 逐条对应）：安全点 = 开口入口 + Collect 入口；根同步
**先加后删**；refCount = 字段引用（`setField` 精确）+ 根引用（同步）；
`freeNow` 级联 / `freeSweep` 不级联；上限顶到先 Collect 仍不够则开口报
`too many gc nodes.`；块内 `let` 不是释放点——JS 的编译器行为与 C++ 相同
（变量是函数级平槽位，块退出只归还复用池、零指令），见 C++ 文档 §6。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `demo/06-gc.js` | 入口：STML 文档、装配、帧循环驱动（限步 + 帧边界 collect）、收尾诊断 |
| `demo/06-gc/object.js` | `MyObject`（gc 头内嵌 + `selfId`）+ `GcAnchor` + 描述符 |
| `demo/06-gc/gc.js` | 分配器：链表、计数、根同步、标记清除、disposeAll |
| `demo/06-gc/object_manager.js` | `obj:*` 域行为（带 safePoint）+ 析构回调 |
| `demo/06-gc/runtime.js` | 显式帧栈（`pushEntryFrame`/`pushMethodFrame`/`runSteps`/`runAll`）+ `liveStates` / `pinned` / `classMap` |
| `demo/06-gc/doc_visitor.js` | STML → 类与函数（exportBinds 预算） |
| `demo/06-gc/api.js` | 三开口转发 |

## 已知差异与注意点

- 析构体里调对象方法 / 新建对象：与 C++ 相同的守卫与纪律（`collecting`
  期间跳过重扫）。
- `use after gc.`：判死对象的 Handle 理论上不可达（可达即不判死），正常
  程序到不了这两个报错点——它们是防御性检查，不是 demo06 的 UB 面。
- 退出顺序：`collect()`（入口帧弹出后 p 不可达）→ `reportLive()` →
  `disposeAll()`（兜底析构）。
