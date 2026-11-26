# Java 实现与面向对象 demo

Java 实现不含 `05-object` / `06-gc` 这类 OOP demo——它只提供基础虚拟机。对象模型 / 描述符 / 手动与 GC 对比的完整讲解见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)。

若要在 Java 宿主里做 OOP：对象与描述符都可放在宿主自己的池里，用 `Value.ofHandle(...)` 传给 VM；`Handle` 的内容 VM 不解释。方法绑定若要随对象可达性自动回收，由宿主的 GC 负责——Java 自身的 GC 可以管理宿主对象图，但 VM 栈里的 `Handle` 值只是引用，需要宿主在安全点自行判定存活。

相关设计取舍记在 [`docs/zh-cn/open-questions.md`](../../docs/zh-cn/open-questions.md) 的 OQ-10。
