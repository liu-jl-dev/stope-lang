# 面向对象：Rust 侧的对象（src/bin/demo05/）

> 本文对应 `src/bin/demo05/`（入口 `main.rs`），是
> [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md)
> 的 Rust 移植。C++ 版是**参考实现教程**，逐个文件讲「怎么把类、属性、方法、
> 构造、析构全部长在宿主侧」；本文不重复那些设计推导，只讲**这条缝在 Rust 里
> 怎么接**，以及最要紧的一件事——**Rust 的内存管理机制与 C++ 不同在哪，
> 析构函数的有效性靠什么保住**。

## 1. 库侧：BasicVM 的 Handle 缝

与 C++ 相同，缝内建在库里（`src/basic_vm.rs`，随 crate 分发，不需要改语义）：

- `Value::Handle(Rc<dyn Any>)`——第 7 种可观测值；`equals` 加同一性分支
  （`Rc::ptr_eq`：两个 Handle 相等当且仅当同一个包装实例）；
- **`Api` 从具体结构改为 trait**：指令表（`op_map()`）+ Handle 的三个开口
  （`handle_at` / `handle_assign` / `handle_call`），默认实现一律报错；
  内置实现 `BaseApi`（`op_map` 保持 pub 字段，`set_opcode` 扩表不变）；
- `State.api` 持 `Rc<dyn Api>`，`op_assign` / `op_call` / `op_at` 各有 Handle
  分支：识别 Handle → 经 **`s.api`**（先 `clone()` Rc——否则与 State 的
  `&mut` 借用冲突）转发 trait 调用 → 检查 `errors` → 维持栈纪律。Rust 的虚
  分发等价物是 **trait object**——宿主实现 trait 即可覆写：

```rust
struct DemoApi {
    base: BaseApi,
    obj_mgr: Rc<ObjectManager>,
}

impl Api for DemoApi {
    fn op_map(&self) -> &[stope::basic_vm::OpFunc] { &self.base.op_map }
    fn handle_at(&self, s: &mut State, h: &Value, k: &Value) -> Value {
        self.obj_mgr.borrow().at(s, h, k)
    }
    // handle_assign / handle_call 同理
}
```

## 2. Rust 的内存管理：所有权，没有 GC

**Rust 没有 GC**——所有权系统 + RAII + `Drop` 在编译期静态确定释放点；
共享所有权用 `Rc`/`Arc`（引用计数，最后引用消失时**确定性地** `Drop`）；
`RefCell` 提供内部可变性（运行时借用检查）。与 C++ 的根本差异：

| | C++（demo 5 的立场） | Rust |
| --- | --- | --- |
| 释放时机 | `delete` 显式、立即 | 所有权结束处由编译器静态插入（`Rc` 计数归零） |
| 悬空指针 | `delete` 后再用是 UB | **不存在**——借用检查从语言层面禁止 |
| 手动释放 | `delete p` | **做不到**——不能销毁仍被引用的值 |
| 循环引用 | 程序员自己避免 | `Rc` 环会泄漏，打破要用 `Weak`（与 GDScript 同口径） |
| 确定性清理 | 析构函数 | `Drop`（语言机制，确定性）✓ |

所以 Rust 版的「手动管理」是一条**模拟纪律**，语义与 C++ 对齐、机制不同：

- **删除标记**：`obj:delete` 跑完 `<delete>` 后给对象打 `deleted = true`；
- **使用检测**：之后对它的属性/方法访问一律报 `use after free.`——C++ 里
  这是未定义行为，Rust 里变成确定性的即时报错（借用检查保证对象活着，
  `deleted` 标记保证语义正确）；
- **内存回收**：`delete` 之后对象不可达——但 VM 变量仍持 Handle 引用，
  计数未归零；引用全部消失时 `Drop` 确定性运行。

**析构函数的有效性不受影响**：`<delete>` 的 Program 只在显式 `obj:delete`
时运行，`[Person] deleted!` 出现在删除那一行——时机确定，与 C++ 逐字对应。
`Drop` trait 的确定性正是 Rust 对「析构」问题的回答，与本 demo 的显式
`obj:delete` 各管一层：`<delete>` 是 Stope 语义的析构，`Drop` 是宿主对象
内存的析构。

## 3. 描述符的账：Rc 替掉复用池

C++ 版为描述符做了「去重缓存 + 驱逐 + `freeDescs` 复用池」三层记账。
Rust 版保留去重缓存与驱逐（防曾见增长），但**不需要复用池**——被驱逐的
描述符若计数归零，`Drop` 当场回收。缓存用两级 `HashMap`
（`*const RefCell<Object>` → `HashMap<i32, Value>`），键是裸指针
（同一性），驱逐是 `remove` 整组摘除，O(1)。

## 4. 与 C++ 版的其它差异（也是 Rust 移植的工程要点）

- **值表示**：Integer 是 `i64`、Float 是 `f64`、String 是 `Rc<Vec<u16>>`
  （UTF-16 码元）、BinArr 是 `Rc<Vec<u8>>`、宿主函数是 `Rc<dyn Fn>`；
- **Handle 的 Any 载荷要包一层**：`Rc<RefCell<T>>` 直接 coerce 进
  `Rc<dyn Any>` 后，下转拿到的是 `RefCell<T>` 而 **Rc 已丢失**——demo 用
  `struct ObjHandle(ObjRef)` 包装后再装入，`downcast_ref::<ObjHandle>()`
  拿回 `ObjRef`；描述符同理（`Desc` 直接作为载荷，`#[derive(Clone)]`）；
- **所有权结构**：Runtime 在装配期结束后**冻结为 `Rc`**（类表/函数表只读，
  方法递归 = 不可变借用栈）；ObjectManager 的可变状态（live 表、bindCache）
  用 `RefCell`，且**借用严格不跨嵌套调用**——`RefCell` 在方法递归路径上
  二次 `borrow_mut` 会当场 panic，这是与 C++「随便改成员」最大的工程差异；
- **没有哨兵 classID**：C++ 用负数 classId 区分成员/构造器描述符；Rust 用
  `Desc` 枚举按变体分派；
- **没有 Allocator / ProgramConstants**：String 本身是 `Rc` 引用，常量随
  `Program` 走；
- **装配期失败**：`panic!` + main 里 `catch_unwind` 接住（对齐 C++ 的
  `throw`/catch；`AssertUnwindSafe` 标注）；
- **exports 是 `BTreeMap<String, i32>`**：直接按名查槽位；
- **self 槽位**：与 C++ 相同——属性不进 preExports，`self:<属性>` 走隐式
  导出、链接遍配对 `(槽位, 字段下标)`；`self:<方法名>` 链接成 self 的绑定
  描述符。`<func>` 里的 `self:` 有意不校验（见 C++ 文档 §10）；
- **运行期输出**：`report_live` 打 `[bind-cache] N entries` 而非 C++ 的
  `[descs] N allocated, M pooled`。

## 5. 运行

```
cargo run --bin demo05
```

输出（与 C++ demo 一致）：

```
-- introducing --
i am James, 18 years old.
age via self:Age() = 18
[Person] deleted!
[objects] all freed
[bind-cache] 0 entries
```

`[Person] deleted!` 出现在 `obj:delete(p)` 那一行——析构时机由文档程序员
决定，这正是 demo 5 的核心演示点。

## 6. 已知局限

C++ 版 §10 列出的未定义行为与已知局限**基本适用于本移植**，个别条目在
Rust 里性质有变（见 [`cpp/docs/object-oriented.md`](../../cpp/docs/object-oriented.md) §10）：

- **悬空 Handle → 使用检测**：C++ 的 UB 在 Rust 里变成确定性的
  `use after free.` 报错（§2）；
- **属性没有 rvalue 读**：`obj:name[p]` 读取语境得到绑定描述符的 Handle，
  不是字段值——读属性请经方法；
- **构造失败返回半成品对象**：`<new>` 执行中出错时对象已进存活表，
  Handle 照常返回，需手动 delete；
- **缺参调用静默**：缺的形参槽位是 `Null`，构造照常完成；
- **方法递归无深度限制**：每层调用一个临时 State（Rust 递归栈），无限自调
  最终栈溢出崩溃；
- **`<func>` 中的 `self:` 无校验**：能编译（隐式导出），运行时槽位 Null
  才报错——函数没有 self 语义，文档里不应出现 `self:`。
- **Rust 特有**：`RefCell` 借用冲突在运行时 panic（本 demo 的借用纪律已
  保证不发生，但扩展者自行加嵌套调用时会撞上）。

## 7. 文件结构（多文件拆分，与 C++ 参考实现同构）

| 文件 | 职责 |
| --- | --- |
| `src/bin/demo05/main.rs` | 入口：STML 文档、装配、运行、清理诊断 |
| `src/bin/demo05/object.rs` | `Object` + `ObjHandle` / `Desc` 载荷 + handle helper |
| `src/bin/demo05/classes.rs` | `MethodInfo` / `FunctionInfo` / `ClassInfo` + 槽位装配 |
| `src/bin/demo05/object_manager.rs` | `obj:*` 域全部行为：描述符创建、三个开口、`live` 表 |
| `src/bin/demo05/api.rs` | Handle 三个开口的薄转发（`impl Api for DemoApi`） |
| `src/bin/demo05/runtime.rs` | `Runtime`：静态结构 + `bind_entry` + `invoke_method` |
| `src/bin/demo05/doc_visitor.rs` | STML 文档 → 类与函数（含编译、索引预算、self 链接） |

Cargo 的 `src/bin/demo05/main.rs` 布局（`Cargo.toml` 里 `path` 指向它），
模块树就长在目录里。
