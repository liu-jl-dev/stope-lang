# C# 版自定义指令

项目只规定 **33 条内置指令**（`Opcode`：`Assign = 0` … `Return = 32`）与 `Program` 的编码
契约；再往上加指令是**宿主自己的事**。三步：

1. 用 `CustomOpcodeConfig` 登记「名字 → (编号, 参数个数)」；
2. **同一份 config** 同时交给 `Parser` 和 `Compiler`（以及 `Disasm`）；
3. 产物里就只是一串整数 —— 编号什么含义、谁来执行，全由你决定。

> **语义权威是 [`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。** 本文讲 C# 侧
> 怎么写、怎么跑，以及与另外三套的差异；与语言无关的规则不重复。

## 1. 先跑起来：`demo/03` 的五段

```bash
dotnet run --project csharp/demo/03-custom-opcode
```

`demo/03` **只编译 + 反汇编，不执行**。五段各讲什么：

| 段 | 在干什么 | 本文哪节 |
| --- | --- | --- |
| `[1]` | 登记三条指令（定长 / 变长 / 零参） | §2 |
| `[2]` | 编译并反汇编，看自定义编号长什么样 | §3 §4 |
| `[3]` | 同样的调用**不传 config** → 退化成普通函数调用 | §5.1 |
| `[4]` | 定长指令参数个数不符 → 编译期报错 | §5.2 |
| `[5]` | 编号撞内置 → 名字丢失，反汇编按内置解码 + warning | §5.3 |

**demo 没有第六段**：执行是 §6 补的（内置执行器不认识自定义编号）。

## 2. 登记：`CustomOpcodeConfig` —— demo 的 `[1]` 段

```csharp
var config = new CustomOpcodeConfig();
config.AddCustomOpcode("my:add", OpcodeLimits.FirstCustomOpcode + 0, 2);   // 定长 2 参
config.AddCustomOpcode("my:log", OpcodeLimits.FirstCustomOpcode + 1, -1);  // 变长
config.AddCustomOpcode("my:halt", OpcodeLimits.FirstCustomOpcode + 2, 0);  // 定长 0 参
```

四个要注意的地方：

| 点 | 说明 |
| --- | --- |
| `ArgNum >= 0` | 定长：参数个数在**编译期**校验，产物里不再重复写 |
| `ArgNum < 0`（默认 `-1`） | 变长：产物里**多一个整数**表示本次实参个数 |
| 返回值 | `Result.DuplicateWithBuiltinOpcode` 表示同名重复注册，且**不覆盖**已有项 |
| 编号 | 必须 ≥ `OpcodeLimits.FirstCustomOpcode`（33）。不校验范围，撞内置就丢名字（§5.3） |

`Opcodes` 是 `Dictionary<string, CustomOpcode>`（插入序），C++ 侧是 `std::map`（名字序）——
要输出可比的字符串就自己排序，demo 里按**编号**排。

`CustomOpcode` 的三个字段：`int Opcode`、`int ArgNum`、`bool IsVarArg`（= `ArgNum < 0`）。
**变长判断一律写 `IsVarArg`**，别自己写 `ArgNum < 0` 之外的约定。

## 3. 编译：同一份 config 交给 Parser 和 Compiler —— demo 的 `[2]` 段

```csharp
private static bool CompileAndReport(string src, CustomOpcodeConfig? config, Program outProg)
{
    var lexer = new Lexer(src);
    var parser = new Parser(lexer, config);   // 第二参：可空的 config
    var tree = new Prog();
    parser.ParseProgram(tree);
    foreach (var e in lexer.Errors) Console.WriteLine("  lexer: " + e);
    foreach (var e in parser.Errors) Console.WriteLine("  parser: " + e);

    var compiler = new Compiler(config);      // 配置只在构造时注入一次
    var rc = compiler.Compile(tree, outProg);
    foreach (var e in compiler.Errors) Console.WriteLine("  compiler: " + e);
    return rc == Result.Success && lexer.Errors.Count == 0 && parser.Errors.Count == 0;
}
```

**必须是同一份 config 对象**（不是「内容相同的两份」）。两边不一致时会看到
`undefined custom opcode "x". `，或者干脆得到一个普通 `Call`（§5.1）。

demo 的源码与产物：

```csharp
const string src = """
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  """;
```

```
[0]     PushId     0
[2]     PushInt    0
[4]     Assign     
[5]     PushValue  0
[7]     PushInt    1
[9]     my:add     
[10]    Pop        
[11]    PushString 0
[13]    PushValue  0
[15]    my:log     2
[17]    Pop        
[18]    my:log     0
[20]    Pop        
[21]    my:halt    
[22]    Pop        
[23]    PushValue  0
[25]    Return     1
```

看两处：`my:add` 后面**没有**操作数（定长 2 参是登记时定死的），`my:log` 后面跟着
`2` / `0`（本次实参个数）。

## 4. 反汇编：`Debug.Disasm(program, config)` —— demo 的 `[2]` 段末尾

```
custom opcodes:
  my:add     -> 33 (2 args)
  my:log     -> 34 (vararg)
  my:halt    -> 35 (0 args)
```

- 名字列宽 = `max(10, 最长名字的 UTF-8 字节数)`，所以中文名会把整列撑宽（与 C++ 同口径）。
- 这一段**按编号排序**打印（C++ 的 `customByOpcode` 是 `map<short,…>`）。
- 不带 config 就只能印 `Custom33` 这种占位，**而且变长指令后面那个「实参个数」会被当成
  下一条指令** —— 两者只差一个整数，读起来全错位。所以只要产物里可能有自定义指令，
  就必须把 config 交给 `Disasm`。

## 5. 三个误解

### 5.1 「名字没登记，编译器也会报错」

不会 —— 它只会变成**普通标识符**，编译成 `Call`（即「调用一个名叫 `my:add` 的宿主函数」）：

```csharp
var plain = new Program();
CompileAndReport("my:add(1, 2);", null, plain);   // 第二参传 null
Console.WriteLine(Debug.DisasmNoCustom(plain));
```

```
[0]     PushValue  0
[2]     PushInt    0
[4]     PushInt    1
[6]     Call       2
[8]     Pop
variables:
  "my:add"
```

变量表里出现了 `"my:add"` —— 因为「未声明就使用」会被编译器登记进 `Exports`（等宿主填
宿主函数）。所以**忘了传 config 不会报错，只会静默变成函数调用**，这是最常见的坑。

### 5.2 「参数个数不对是运行期的事」

定长指令在**编译期**就校验：

```
[4] 定长 2 参却只给 1 个：
  compiler: line 1: custom opcode "my:add" expected 2 args, but got 1.
  -> 编译失败，Program 已清空（opcodes 剩 0 个 number）
```

注意 `Program` 被**清空**了 —— `Compile` 失败时不会留半成品（留着只会让人误以为能跑）。

### 5.3 「编号随便取，反正只是个数字」

不是。`Opcodes` 是**指令与操作数混排的整数序列**，撞号以后与内置指令无法区分：

```csharp
var collide = new CustomOpcodeConfig();
collide.AddCustomOpcode("my:steal", (int)Opcode.Add, 2);   // 用内置 Add 的编号
```

产物里 `my:steal` 就是 `20`，反汇编只能按内置指令解码：

```
[4]     Add
…
warning: custom opcode "my:steal" uses #20, which collides with Add; builtin decoding wins.
```

**名字已经丢了**。所以编号从 `OpcodeLimits.FirstCustomOpcode`（33）起，别撞内置。

## 6. 怎么真的执行（demo 之外）

内置执行器**不支持**自定义指令（`Api.OpMap` 只有 33 格），但它是**基础虚拟机**、
`OpMap` 是公开的 `List<Action<State>>` —— 自己补上就能跑：

```csharp
var api = new Api();
api.OpMap.Add(MyAdd);      // 33 号。注意中间不能有空位：下标就是编号
// 从 33 到目标编号之间每一格都必须是有效委托；越界/空委托会抛
// ArgumentOutOfRangeException / NullReferenceException。

private static void MyAdd(State s)
{
    var b = s.AtTop(1);
    var a = s.AtTop(2);
    if (a is not long x || b is not long y) { s.Error("my:add 只接受整数. "); return; }
    s.StoreBinary(unchecked(x + y));   // 弹右操作数，结果写回左操作数的位置
}
```

跑完整例子（编译 → 反汇编 → 执行 → 取返回值）：

```csharp
var config = new CustomOpcodeConfig();
config.AddCustomOpcode("my:add", OpcodeLimits.FirstCustomOpcode, 2);

var tree = new Prog();
new Parser(new Lexer("let x = my:add(1, 2); return x;"), config).ParseProgram(tree);
var program = new Program();
if (new Compiler(config).Compile(tree, program) != Result.Success) return;

var api = new Api();
api.OpMap.Add(MyAdd);

var state = new State();
state.Reset(api, program);            // 不传实参表就够用
if (state.Run() != Result.Success) return;
Console.WriteLine(state.Returns[0]);  // 3
```

这就是 demo 缺的「第六段」。`C++` 侧同一步见 `cpp/docs/custom-opcode.md` §6，GDScript /
Node.js 侧见各自的 `custom-opcode.md`。

## 7. 排错表

| 症状 | 原因 |
| --- | --- |
| `line N: undefined custom opcode "my:add". ` | Compiler 拿到的 config 里没有这个名字（最常见：`new Compiler()` 忘了传） |
| 产物里是 `Call` 而不是自定义编号 | Parser 拿到的 config 里没有（词法器不认这个名字）—— 不报错，静默退化 |
| `line N: custom opcode "x" expected 2 args, but got 1. ` | 定长指令的实参个数不符；编译失败、产物被清空 |
| `AddCustomOpcode` 返回 `DuplicateWithBuiltinOpcode` | 同名重复注册。**不会覆盖**，之前那条仍然生效 |
| 反汇编里出现 `Custom34` | `Disasm` 没拿到 config（或者 config 里没这条） |
| 反汇编 warning `uses #20, which collides with Add` | 编号撞内置：名字丢了，请从 33 起 |
| `ArgumentOutOfRangeException`（`Api.OpMap[...]`） | 产物里的编号超出 `OpMap` 长度；`OpMap` 必须稠密到最大编号 |
| 自定义指令里 `s.AtTop(1)` 拿到 `Identifier` | 那是 `PushId` 压的槽位引用 —— 只可能出现在 `Assign` 左端，其它位置收到它说明产物错了 |
| 变长指令执行后栈不平衡 | 忘了先读「实参个数」那个操作数，或把它也算成了一个实参 |

## 8. 下一步

- 完整 demo：[`demo/03-custom-opcode/Program.cs`](../demo/03-custom-opcode/Program.cs)。
- 产物格式（指令编号 / 操作数 / 跳转目标）：[`cpp/docs/development.md`](../../cpp/docs/development.md)。
- 自己写执行器：[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。
- 想给内置执行器加**数据类型**：做不到 —— 它只认 6 种值（空 / 整数 / 浮点 / 字符串 /
  二进制数组 / 宿主函数），见根 README「标准范围」。
