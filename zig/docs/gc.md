# 宿主侧垃圾回收（Zig 版）

`demo06` 展示宿主如何自建引用计数 + 标记清除，管理 `obj:*` 域的对象与描述符。语义与
实现动线见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) 与
[`docs/zh-cn/host-memory.md`](../../docs/zh-cn/host-memory.md)。

**Zig 实现目前没有对应的 `06-gc` demo** —— BasicVM 只提供 `Value::Handle`（裸宿主引用），
对象/描述符的内存管理完全由宿主决定，跟 Go/Rust 等实现一样。若要在 Zig 侧实现 OOP 域，
照 cpp 的 `demo/06-gc/` 移植即可；BasicVM 遇到 `Handle` 的 `opCall` / `opAt` / `opAssign` 默认报错，
宿主需自行替换分派表（`State.custom_ops`）来实现对象语义。
