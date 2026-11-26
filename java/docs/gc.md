# Java 实现与 GC

Java 实现只提供基础虚拟机（`stope.BasicVM`），**不实现对象模型或 GC**。对象/方法绑定的语义权威在 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)。

`BasicVM.Value` 的 `Handle` 是宿主引用：VM 只做相等性比较，不解释其内容、不自动回收。宿主需要对象生命周期管理时，自行实现可达性回收或引用计数，并把对象句柄以 `Value.ofHandle(obj)` 放进值流。

BasicVM 遇到 `Handle` 的 `opCall` / `opAt` 默认报错（`State.customOps`）可注册自定义编号的处理函数来实现对象分派。这与 C++ demo6 的 GC 路线一致：VM 保持简单，GC 在宿主侧。
