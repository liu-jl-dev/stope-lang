# 宿主侧垃圾回收：Python 侧的对象（demo/06-gc.py）

> 本文对应 `demo/06-gc.py`（入口）与 `demo/06-gc/`（模块），是
> [`../cpp/docs/gc.md`](../../cpp/docs/gc.md) 的 Python 版——语义权威在 C++
> 侧，本文只讲「怎么跑」与「Python 差异」。

## 跑起来

```bash
python demo/06-gc.py   # 仓库根目录
```

输出与 C++ demo 逐段对应（引用计数级联 / 循环破环 / 垃圾 churn），语法
逐字一致。执行模型是**显式帧栈 + 两种驱动**：`run_steps(20)` 每帧限步、宿主
每 25 帧调一次 `collect()`（gc 裁决时机在帧边界，脚本侧没有 gc 函数）；
`run_all()` 一口气跑到帧栈清空——没有帧边界，gc 裁决只剩 `max_nodes` 顶满
与收尾那次 collect。demo 先限步 25 帧（第一轮帧边界 collect 破环）再
`run_all()` 跑完。与 C++ 相同的部分：`frames` 显式帧栈 + `live_states`
（只装析构同步旁路 State）+ `pinned`（push_method_frame 压入、弹帧弹出）；
`<delete>` 析构走同步旁路 `invoke_method`（级联/sweep 中间一口气跑完）。

## Python 差异

| | C++ | Python |
| --- | --- | --- |
| 释放 | `delete` + `trash`/`flush_trash` 延迟删除 | 摘链 + 判死 + 清字段——**没有 trash**：对象不会地址复用，悬空指针不存在，内存交给引用计数/兜环 GC |
| 描述符 | gc 对象，装配期 `Pin` | 普通对象——引用计数等价替代 Pin |
| 保活「正在执行方法的对象」 | 绑定描述符的字段引用 | `runtime.pinned`（Python 描述符不参与 gc，等价物） |
| `max_nodes` | 计全部 gc 节点 | 只计业务对象（描述符由引擎管） |
| 退出兜底 | `~ObjectAllocator` | `dispose_all()`——剩余对象（p）逐个跑 `<delete>`，「deleted: James」在这里打印 |
| 诊断 | 打指针 | 打自增 `self_id`（Python 拿不到稳定地址） |
| 分配器文件名 | `Object.cpp` 里的 `ObjectAllocator` | **`gc_alloc.py`**——`gc.py` 会撞标准库的 `gc` 模块 |

不变的部分（与 C++ 逐条对应）：安全点 = 开口入口 + collect 入口；根同步
**先加后删**；ref_count = 字段引用（`set_field` 精确）+ 根引用（同步）；
`free_now` 级联 / `free_sweep` 不级联；`max_nodes` 顶到上限先 collect 仍
不够则开口报 `too many gc nodes.`；块内 `let` 不是释放点——Python 编译器
行为与 C++ 相同（变量是函数级平槽位，块退出只归还复用池、零指令），见
C++ 文档 §6。注意 Python 的 `int` 无限精度，VM 侧的 64 位语义由 stope 包
统一处理，demo 侧无感。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `demo/06-gc.py` | 入口：STML 文档、装配、运行、收尾诊断（把 `06-gc/` 挂进 `sys.path`） |
| `demo/06-gc/object_model.py` | `Object`（gc 头内嵌 + `self_id`）+ `GcAnchor` + 描述符 |
| `demo/06-gc/gc_alloc.py` | `GcAllocator`：链表、计数、根同步、标记清除、dispose_all |
| `demo/06-gc/object_manager.py` | `obj:*` 域行为（带 safe_point）+ 析构回调 |
| `demo/06-gc/runtime.py` | 显式帧栈（`push_entry_frame`/`push_method_frame`/`run_steps`/`run_all`）+ `live_states` / `pinned` / `class_map` |
| `demo/06-gc/doc_visitor.py` | STML → 类与函数（export_binds 预算） |
| `demo/06-gc/api.py` | 三开口转发 |

## 已知差异与注意点

- 析构体里调对象方法 / 新建对象：与 C++ 相同的守卫与纪律（`collecting`
  期间跳过重扫）。
- `use after gc.`：判死对象的 Handle 理论上不可达（可达即不判死），正常
  程序到不了这两个报错点——它们是防御性检查，不是 demo06 的 UB 面。
- 退出顺序：`untrack_state`（拆根）→ `dispose_all`（兜底析构）。
