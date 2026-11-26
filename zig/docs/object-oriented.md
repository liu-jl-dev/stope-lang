# 宿主侧 OOP 对象模型（Zig 版）

`demo05` 展示 `obj:*` 域的手动 OOP 绑定（对象 + 描述符 + 方法调用）。权威实现与完整讲解在
[`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)；跨实现内存管理对照在
[`docs/zh-cn/host-memory.md`](../../docs/zh-cn/host-memory.md)。

**Zig 实现目前没有对应的 `05-object` demo。** 与 Go/Rust 一样，Zig 的 `BasicVM` 只提供
`Value::Handle`（宿主引用），对象生命周期、描述符池、绑定方法都由宿主自己实现 —— 这不是
缺陷，而是 BasicVM「不解释宿主值」的设计边界（见
[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)）。

若要在 Zig 侧实现：
- `Value.handle` 装宿主对象指针，`opCall` / `opAt` / `opAssign` 遇到 Handle 时转交宿主处理；
- BasicVM 的默认行为是报错（`"Call" can only call a function.` 等），需宿主自行替换 `State.custom_ops` 里的分派函数；
- 描述符可作为另一种 Handle 值，池化与引用计数由宿主自行管理。
