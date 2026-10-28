# BasicVM —— 栈式虚拟机

> `cpp/include/stope/basic_vm.hpp`：执行 `Program` 的栈式虚拟机。
> **header-only**，是 `include/stope/` 里少数带函数体的头文件（另见 `debug.hpp`）。

| 想看 | 去哪 |
| --- | --- |
| 本目录总览（面向所有人） | `README.md`（本目录） |
| 怎么把它跑起来（四步） | `quick-start.md`（本目录） |
| 指令表与 `Program` 字段 | `compiler_test_plan.md` §2 |
| 不想先编译、想直接跑 AST（继承 `ASTVisitor`） | `../../docs/zh-cn/syntax-impl.md` §7.2 |
| 工程侧的构建 / 测试约定 | `development.md`（本目录） |
| 自己写一个执行器（**虚拟机不属于标准**） | `../../docs/zh-cn/vm-guide.md` |

---

## 1. 组成

```cpp
Allocator          字符串 / BinArr 的 refcount 句柄池
ProgramConstants   把 Program 的常量提前装进 Allocator
API                33 条内置指令的实现表（opFuncs）
Arguments          宿主向脚本提供 argc / args[i] 的接口
Value              栈上的值（句柄式）
State              一次执行的全部状态
```

`State` 是**依赖注入**式的：五个 `SetXxx` 全部是「不拥有」的裸指针，装配顺序没有约束，
但 `Run()` 之前必须都设好。`variables` 要自己 `resize(program.variableNum)`。

```cpp
Result State::Step() {          // 执行 i 指向的一条指令（含它的操作数）
  if (HasError()) return Result::Error;                      // 错误态不再执行
  if (i >= (int)program->opcodes.size()) return Result::Success;  // 越界：什么也不做
  api->opFuncs[program->opcodes[i]](*api, *this);
  if (HasError()) return Result::Error;
  ++i;
  return Result::Success;
}

Result State::Run() {           // 复用 Step：header-only + 隐式 inline，编译期就展开
  while (i < program->opcodes.size()) {
    if (Step() != Result::Success) return Result::Error;
  }
  return Result::Success;
}
```

出错时 `Error(msg)` 把 `"指令下标: msg"` 追加进 `errors`，`Run()` 立即返回 `Result::Error`。

`Step()` 有两条容易踩的：

- **终止条件要用 `i` 判，不能写成 `while (s.Step() == Result::Success)`** —— 指令流走完
  之后 `Step()` 返回 Success 但什么也不做，那个循环永远不结束。正确写法：
  `while (s.i < (int)s.program->opcodes.size() && s.Step() == Result::Success) { ... }`
- **错误态再调 `Step()` 不执行任何指令**（预检直接返回 `Error`），所以调试器里连点两次
  不会把同一条错指令跑两遍、把错误刷出两条。`Run()` 没有这个预检 —— 它一出错就返回，
  调用方本就不该续跑，这是两者唯一的语义差别。

单步遍历的代价是每条指令一次函数调用，但 `Step()` 是 inline 的，`Run()` 复用它不会变慢。
`test/test_vm.cpp` 的 V-31…V-34 把两条驱动路径钉在一起：同一份源码，`Run()` 一次跑完
vs `Step()` 逐条走到停机，停机位置、错误、返回值必须一致。

---

## 2. `Value`：句柄 + 引用计数

```cpp
struct Value {
  enum class Type { Null, Integer, Float, BinArr, String, Identifier, HostFunction };
  union Data { int64_t data; int64_t integer; double floating;
               unsigned index; unsigned handle; HostFunction hostFuncPtr; };
  Type type = Type::Null;
  Data data = {};
};
```

这是**第二代设计**（2026-10-21 重写）。第一代用 `std::variant`，已废弃；
`ValueType` 枚举也随那一版一起删掉了——别按旧记忆改。

- `Integer` / `Float` / `Identifier`(变量槽位) / `HostFunction` 直接放在 union 里。
- `String` / `BinArr` 只放一个 `unsigned handle`，真实数据在 `Allocator` 里，
  靠 `StringRefInc/Dec` `BinArrRefInc/Dec` 计数，用 `GetString(handle)` /
  `GetBinArr(handle)` 取出来。**`String` 是 `u16string`**，输出前要 `UTF::Utf16ToUtf8()`。
- **拷贝构造与拷贝赋值都被 `delete`**，只有移动。这是刻意的：
  拷贝必须同时 `RefInc`，隐式拷贝会漏。

### 2.1 三个静态 helper 的区别

| 函数 | 句柄计数 | 源的状态 | 用途 |
| --- | --- | --- | --- |
| `Copy(alloc, src, dst)` | **+1** | 不变 | 值的常规复制，两个 `Value` 各持一份引用 |
| `Move(alloc, src, dst)` | **不变** | 变 `Null` | 所有权转移 |
| `ShallowCopy(alloc, src, dst)` | **不变** | 不变 | 位拷贝，调用方自己保证计数正确 |

**`Move` 绝不能对源 `RefDec`。** 引用计数的含义是「有几个 `Value` 持有这个句柄」，
所有权转移后持有者数量不变。这里曾经错写成 `src.Clear(alloc)`，多减了一次：
`let s = "abc";` 让常量与变量共用句柄但计数只有 1，变量一改值就把常量用的字符串提前释放。

### 2.2 移动是位拷贝 + 源置空

```cpp
Value(Value&& other) noexcept : type(other.type), data(other.data) {
  other.type = Type::Null;
  other.data = {};
}
```

移动赋值**不去 `RefDec` 目标原有的句柄**。理由是现有 `PopN` 在 `stack.erase` 之前
已经逐个 `Clear2` 过，被覆盖的旧值必定是 `Null`。这条是前提，不是巧合：
**谁要是把 `PopN` 改成「直接 erase 不 Clear2」，就会漏减计数。**

`noexcept` 是必需的——否则 `std::vector<Value>` 扩容会退化成拷贝，而拷贝已 `delete`。

---

## 3. 栈与变量

- **栈顶下标一律「从栈顶数、1 起算」**：`AtTop(1)` 就是 `stack.back()`。
- **栈上不放 `Identifier`。** 编译器保证 `PushValue` 压的是解引用后的值，
  `PushId` 只在紧邻 `Assign` 的左侧出现（`let` 的目标、赋值语句的裸标识符左值）。
  所以执行指令时直接读栈顶即可，不需要任何「解引用兜底」。
  > 早期版本有 `ReplaceTopValues(n)` / `GetValueTop(i)` 两个辅助函数，在每个指令里
  > 把 `Identifier` 就地换成真实值。2026-10-22 拆出 `PushValue` 之后这类栈内容不再
  > 产生，两个函数已删除。**不要再加回来** —— 它们只是掩盖编译器的产物错误。
- `Pop()` / `PopN(n)` 在移除前**必须先 `Clear2`**，否则句柄泄漏。

> 循环变量**绝不能写成 `i`** —— `i` 是 `State` 的指令指针。曾因把 `for (int k…)` 写成
> `for (i…)`，循环把指令指针归零，`Run()` 直接死循环。

---

## 4. 指令实现的五条硬约定

1. **`opIf` 先求值再 `Pop()` 掉条件。** 不弹会让栈整体垫高一层，之后每条语句
   都取到错位的值（表现为 `Assign` 忽然报
   `'Assign' can only assign to a variable.`）。
2. **`opGoTo` 读 `opcodes[i + 1]`。** 读 `opcodes[i]` 是读到 `GoTo` 自己的编码 28，
   跳到一个完全不相干的位置。
3. **二元 / 一元运算的收尾必须是 `Pop()` + 写回栈顶**，不能只算出一个局部 `result` 就返回。
   `opAdd` 曾经缺这段收尾：`+` 什么都不算，两个操作数还留在栈上，
   而且不支持的类型组合也不报错、直接静默穿过。现在统一走 `storeBinary()`：
   `Pop()` → `Clear2()` 旧值 → `ShallowCopy()` 新值。
4. **算术先过「类型」和「除零」两道闸门，再落回具体类型分支。**
   `checkArith()` 拦 `null` 与非数字，`checkIntZero()` 拦整数除数为 `0`
   （`/` `%` `idiv` 三处都要调 —— 直接让 C 的 `a / b` 去执行会触发硬件异常、
   整个进程消失）。**闸门看的是「运算走哪条路径」：只有两侧都是整数才拦**，
   任一侧是浮点就走 IEEE、不拦 —— 否则 `1.0 / 0` 会报错而同值的 `1 / 0.0`
   得 `inf`，同一个运算出两种结果。整数结果一律用无符号运算回绕，**不检查溢出**；
   除法 / 取模额外用 `intDiv` / `intMod`，只为躲开 `INT64_MIN / -1` 的陷阱。
   语义细节见 `../../docs/zh-cn/vm-guide.md` §8.1.1。
5. **序列重复要取「序列那一侧」的句柄**：`Value& seq = isSequence(left) ? left : right;`。
   `2 * "ab"` 里 `left` 是整数，`left.data.handle` 是垃圾下标 —— 早期版本拿它去索引
   `binArrs`，`2 * "ab"` 与 `2 * 'x 41'` 都会崩，而 `"ab" * 2` 正常。

---

## 5. 宿主接口

### 5.1 宿主函数

```cpp
using HostFunction = void (*)(State& state, std::span<const Value> args, Value& output);
```

**类型里没有 udata 通道**，所以只有**不捕获**的 lambda 能转成这个函数指针。
需要上下文就放全局变量 / 单例，不要指望闭包。

注册方式是「往变量槽位里填」：

```cpp
auto& v = state.variables[program.exports[u"fmt:println"]];
v.type = BasicVM::Value::Type::HostFunction;
v.data.hostFuncPtr = hostPrintln;
```

**`program.exports` 是 `std::map`，`operator[]` 在名字不存在时会插入并返回 0** ——
源码里没出现过的名字会把宿主函数静默绑到变量 0。宿主侧要用 `find()` 先确认。

名字由 Compiler 登记：**被调用但未声明的名字（如 `fmt:println`）会隐式进 `exports`**，
槽位随声明顺序变化，所以槽位号不能写死。

### 5.2 `Arguments`

脚本里的 `argc` / `args[i]` 由宿主提供，实现两个纯虚函数：

```cpp
struct Arguments {
  virtual Result at(State& state, const Value& indexOrKey, Value& out) = 0;
  virtual std::int64_t num() = 0;
};
```

`at()` 出错时 `s.Error(msg)` + 返回 `Result::Error`，VM 立刻停下。
用不到 `argc` / `args` 时**整步可以跳过**（不调 `SetArguments`）。

---

## 6. 返回值与错误

- **读返回值用 `state.returns`（`span<Value>`），不是 `stack[0]`。**
- **`Result::Success == 0`、`Error == 1`** —— 不要写 `if (state.Run())` 当成功。
- 源码没有 `return` 语句时，`Run()` **仍返回 Success**，但 `returns` 是空的。
  取 `returns[0]` 之前先判 `!returns.empty()`。
- `errors` 的格式是 `"指令下标: 消息"`，只累加不清空。

---

## 7. 生命周期

`Allocator` 必须比 `ProgramConstants` 和 `State` 都活得长。都在同一作用域时，
按 `alloc` → `constants` → `state` 的顺序声明（析构是逆序）即可。

`ProgramConstants(alloc, program)` 在**构造时**就把常量装进 `alloc`，
所以必须先有 `alloc`；一个 `Allocator` 可以被多个 `State` 共享。
