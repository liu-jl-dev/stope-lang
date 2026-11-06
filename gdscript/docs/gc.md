# 宿主侧垃圾回收：GDScript 侧的对象（demo_06）

> 本文对应 `demo/demo_06.gd`（入口）与 `demo/06-gc/`（模块），是
> [`cpp/docs/gc.md`](../../cpp/docs/gc.md) 的 GDScript 版——语义权威在 C++
> 侧，本文只讲「怎么跑」与「GDScript 差异」。

## 跑起来

```bash
Godot_console.exe --headless --path gdscript res://demo/demo_06.tscn
```

输出与 C++ demo 逐段对应（引用计数级联 / 循环破环 / 垃圾 churn），语法
逐字一致。执行模型是**显式帧栈 + 两种驱动**：`run_steps(20)` 每帧限步、
宿主每 25 帧调一次 `collect()`（gc 裁决时机在帧边界，脚本侧没有 gc 函数）；
`run_all()` 一口气跑到帧栈清空——没有帧边界，gc 裁决只剩 `max_nodes` 顶满
与收尾那次 collect。demo 先限步 25 帧（第一轮帧边界 Collect 破环）再
`run_all()` 跑完。

## GDScript 差异

| | C++ | GDScript |
| --- | --- | --- |
| 执行模型 | `Runtime::frames` 显式帧栈 + `RunSteps`/`RunAll` | 相同：`frames` 数组 + `run_steps`/`run_all`，调用栈不再走 GDScript 递归栈 |
| gc 节点 | `GCHeader` 嵌在 `Object` 里，对象与描述符都在链上 | gc 字段（链表 + 计数 + 标记）直接长在 `MyObject` 上；**只有业务对象进 gc 链** |
| 描述符 | gc 对象，装配期 `Pin` | 仍是 `RefCounted`——引擎引用计数等价替代 Pin / trash |
| 保活「正在执行方法的对象」 | 绑定描述符的字段引用 | `runtime.pinned`：`push_method_frame` 压入、弹帧收尾弹出（GD 描述符不参与 gc，等价物） |
| 析构（`<delete>`） | 同步旁路 `InvokeMethod` | 相同：`invoke_method`（装配 + run + 收尾），在级联/sweep 中间一口气跑完，不走帧栈 |
| gc 根扫描范围 | `frames` + `liveStates` | 相同：`frames` + `live_states`（只装析构旁路 State）+ `pinned` |
| 延迟删除 | `trash` + `FlushTrash` | 相同（`free()` 立即生效，名单重叠问题同样存在） |
| 释放 | `delete` | `free()`（引擎拒绝重复 free，`dead` 标志同样挡住） |
| `max_nodes` | 计全部 gc 节点 | 只计业务对象（描述符由引擎管） |
| 退出兜底 | `~ObjectAllocator` 逐个析构 | `dispose_all()` 由入口显式调用——GD 没有析构钩子，不调用就 ObjectDB 报泄漏 |
| 装配失败 | `throw` | 沿返回值上传（GD 无异常） |

不变的部分（与 C++ 逐条对应）：安全点 = 开口入口 + Collect 入口；根同步
**先加后删**；refCount = 字段引用（`set_field` 精确）+ 根引用（同步）；
`free_now` 级联 / `free_sweep` 不级联；`max_nodes` 顶到上限先 Collect 仍不够
则开口报 `too many gc nodes.`；块内 `let` 不是释放点（guard 只能活在函数
作用域）——GD 的编译器行为与 C++ 相同，见 C++ 文档 §6。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `demo/demo_06.gd`（配 `demo_06.tscn`） | 入口：STML 文档、装配、帧循环驱动（限步 + 帧边界 collect）、收尾诊断 |
| `demo/06-gc/objects.gd` | `MyObject`（gc 头内嵌）+ `GcAnchor` + 描述符 |
| `demo/06-gc/gc.gd` | 分配器：链表、计数、根同步、标记清除、trash、dispose_all（含锚点自环摘除） |
| `demo/06-gc/object_manager.gd` | `obj:*` 域行为（带 safe_point）+ 析构回调 |
| `demo/06-gc/runtime.gd` | 显式帧栈（`push_entry_frame`/`push_method_frame`/`run_steps`/`run_all`）+ `live_states` / `pinned` |
| `demo/06-gc/doc_visitor.gd` | STML → 类与函数（export_binds 预算） |
| `demo/06-gc/demo_api.gd` | 三开口转发 |

## 已知差异与注意点

- 析构体里调对象方法 / 新建对象：与 C++ 相同的守卫与纪律（`collecting`
  期间跳过重扫）。
- GD 的 VM 运行期错误只中止当前函数——`too many gc nodes.` 报错后 demo
  仍会继续跑完后续语句并走完收尾诊断。
- 退出顺序：`collect()`（入口帧弹出后 p 不可达）→ `report_live()` →
  `dispose_all()`（兜底析构）→ **断开锚点自环与 `on_free`/`gather_roots`
  Callable**（`GcAnchor` 是 RefCounted，自指链表 + 指回 `obj_mgr` 的
  Callable 都是引用计数环，不断开退出时报 ObjectDB leak）→ `runtime.free()`。
