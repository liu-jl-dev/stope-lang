# C# 版快速上手

照这份文档走一遍，你会得到：一份能编译、能跑、能改的宿主程序骨架，以及「哪些 API 可以
依赖、哪些只是内置示例」的分界线。

完整可运行的版本是 [`demo/01-quick-start/Program.cs`](../demo/01-quick-start/Program.cs)，
本文逐段讲它。

## 0. 先分清哪些能依赖

Stope 的标准只覆盖三件事：**语言**、**STML**、**编译器的产物 `Program`**。
所以同一份 demo 里的代码有两种稳定性：

| 段落 | 用到的东西 | 稳定性 |
| --- | --- | --- |
| step 1（编译） | `Lexer` / `Parser` / `Compiler` / `Program` | **编译器接口**，相对稳定。`Program` 的编码契约（指令编号、操作数、跳转目标是指令下标）是标准的，宿主可以依赖、可以复制 |
| step 2–4（运行） | `Api` / `State` / `Arguments` | **内置的基础虚拟机，不是标准**。值的表示、栈布局、宿主函数绑定、错误上报全是实现细节，换一个执行器可以完全不长这样 |

本文把这条分界线标在每一段开头。要自己写执行器，看
[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。

## 1. 先跑起来

不需要先构建 —— `dotnet run` 会自己编译（首次约几秒）：

```bash
dotnet run --project csharp/demo/01-quick-start   # 编译 + 运行：反汇编 + 求和结果
dotnet run --project csharp/demo/02-stml          # 只解析 STML
dotnet run --project csharp/demo/03-custom-opcode # 自定义指令：只编译 + 反汇编
```

三个 demo 的输出与 C++ / GDScript / Node.js 三套实现**逐字节相同**（同一份源码产出同一份
字节码）。`01` 的完整输出：

```
[0]     PushId     0
[2]     PushFloat  0
[4]     Assign     
[5]     PushId     1
[7]     PushInt    0
[9]     Assign     
[10]    PushValue  1
[12]    ArgNum     
[13]    LT         
[14]    If         35
[16]    PushId     0
[18]    PushValue  0
[20]    PushValue  1
[22]    GetArg     
[23]    Add        
[24]    Assign     
[25]    PushId     1
[27]    PushValue  1
[29]    PushInt    1
[31]    Add        
[32]    Assign     
[33]    GoTo       10
[35]    PushValue  2
[37]    PushString 0
[39]    PushValue  0
[41]    Call       2
[43]    Pop        
[44]    PushValue  0
[46]    Return     1
variables:
  "" "" "fmt:println"
int consts:
  0  1
float consts:
  0
string consts:
  "结果为: "
binary array consts:
max return num: 1
required stack size: 3

[Host] 结果为: 15
result: 15
```

前一半是 `Debug.DisasmNoCustom(program)` 的输出（由 step 1 打印），后一半是执行器真跑
出来的。几个读法：

- 方括号里是**指令在 `Program.Opcodes` 里的下标**，不是行号；带操作数的指令下一格就是
  操作数（`PushFloat 0` = 取 `FloatConsts[0]`）。
- `If 35` / `GoTo 10` 的操作数是**跳转目标的下标**（`while` 的回边就是 `GoTo 10`）。
- `variables:` 那行是变量槽，`""` 表示「不是导出变量、没有名字」；`fmt:println` 之所以
  出现在第 3 格，是因为源码里**没声明就用**了它，编译器把它当外部变量登记进了 `Exports`。

## 2. 四步全景

```csharp
// 1. 编译：源码 -> Program
var lexer = new Lexer(src);
var parser = new Parser(lexer);
var tree = new Prog();
parser.ParseProgram(tree);
var compiler = new Compiler();
var program = new Program();
compiler.Compile(tree, program);

// 2-4. 执行：Program -> 结果（内置示例，不是标准）
var state = new State();
state.Reset(new Api(), program, args);      // args 是实现 Arguments 的宿主对象
state.Variables[program.Exports["fmt:println"]] = (Func<object?[], object?>)Println;
state.Run();
Console.WriteLine(state.Returns[0]);
```

## 3. 第一步：编译源码

> 稳定性：编译器接口。

```csharp
const string src = """
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
""";

var lexer = new Lexer(src);
var parser = new Parser(lexer); // 第二参是 CustomOpcodeConfig，可省
var tree = new Prog();
parser.ParseProgram(tree);
foreach (var e in lexer.Errors) Console.Error.WriteLine("[lex] " + e);
foreach (var e in parser.Errors) Console.Error.WriteLine("[parse] " + e);

var compiler = new Compiler(); // 构造参同上，可省
var program = new Program();
var rc = compiler.Compile(tree, program); // AST 与 Program 都传引用
if (rc != Result.Success) return 1;
```

几个要点：

| 约定 | 内容 |
| --- | --- |
| 错误去哪 | `lexer.Errors` / `parser.Errors` / `compiler.Errors` **三处分开**，格式都是 `line N: msg`；不抛异常 |
| 返回值 | `Result.Success == 0`。别写 `if (rc)` 当成功 —— 那是「失败」 |
| 编译失败 | `Compile()` 已经把 `program` 清空（`Opcodes` 为空），别拿它去反汇编或执行 |
| AST 类型 | `new Prog()` 必须是具体类，不是匿名对象 —— `AstVisitor.Visit` 靠 `NodeType` 分发，传错会**静默跳过整棵树** |
| 常量折叠 | `parser.ConstFolding = true`（默认）。测试里关掉它才能看到未折叠的树 |

## 4. 第二步：装配执行器

> 稳定性：内置示例，不是标准。

```csharp
var api = new Api();                                 // 33 条内置指令的分派表
var args = new MyArgs(new object?[] { 1.0, 2.0, 3.0, 4.0, 5.0 });
var state = new State();
state.Reset(api, program, args);                     // 一次做完：清 returns/stack/errors + 开槽位
```

`Reset` 会按 `program.VariableNum` 把 `state.Variables` 开好（C++ 侧那行必写的
`variables.resize(...)` 在这里替你做了 —— 参考实现可以少一个坑，但要知道这是它替你做的）。

实参表是宿主实现的抽象类，`args[i]` / `argc` 都落到它身上：

```csharp
private sealed class MyArgs : Arguments
{
    private readonly object?[] _data;
    public MyArgs(object?[] values) => _data = values;

    // 取不到就**自己报错**：state.Error(...) + 返回 null，执行器立刻停在这里
    public override object? At(State state, object? indexOrKey)
    {
        if (indexOrKey is not long k) { state.Error("index must be an integer. "); return null; }
        if (k < 0 || k >= _data.Length) { state.Error("index out of range. "); return null; }
        return _data[k];
    }

    public override int Num() => _data.Length;
}
```

## 5. 第三步：绑宿主函数

> 稳定性：内置示例，不是标准。

宿主函数在产物里就是**「某个变量槽里的一个值」**（C++ 的 `Value::Type::HostFunction`）。
编译器把未声明的 `fmt:println` 当外部变量登记进 `Exports`，宿主按名字取槽位填上即可：

```csharp
state.Variables[program.Exports["fmt:println"]] = (Func<object?[], object?>)Println;

// 签名统一是 argv => result：参数**整包**进来，自己拆（对应 C++ 的 args span）
private static object? Println(object?[] argv)
{
    Console.WriteLine("[Host] " + string.Concat(argv.Select(Fmt)));
    return null;
}
```

三点：

- **槽位号由编译器分配**，不要写死数字，一律 `program.Exports["名字"]`。
- 返回值会被 `Runtime.Normalize` 折一遍：`bool` → `1L`/`0L`（Stope 没有布尔值类型）。
- 名字里带 `:` 是词法器支持的命名空间写法，用来避开普通变量名。

## 6. 第四步：跑

```csharp
if (state.Run() != Result.Success)
{
    foreach (var e in state.Errors) Console.Error.WriteLine("[vm] " + e);
    return 1;
}
Console.WriteLine("result: " + Fmt(state.Returns[0]));
```

- 错误串格式是 `"<指令下标>: msg"`，下标指向**出错时**停住的那条指令。
- `Run()` 与 `Step()` 是两份独立实现（热循环里不套函数调用）；`while (s.Step() == Result.Success) {}`
  与 `Run()` 等价，连走的条数都一样。想在宿主里分帧执行就用 `Step()`。
- `state.Returns` 是 `return` 带回来的值列表，可能为空（程序没 return）。

值的显示要自己写（`Returns` 里是 `object?`）：

```csharp
private static string Fmt(object? v) => v switch
{
    null => "null",
    long l => l.ToString(CultureInfo.InvariantCulture),
    double d => d.ToString(CultureInfo.InvariantCulture),
    string s => s,
    _ => v.ToString() ?? "null",
};
```

## 7. 最小骨架（可直接复制）

```csharp
using System;
using Stope;

var src = "let a = 1; let b = 2; return a + b;";

var lexer = new Lexer(src);
var parser = new Parser(lexer);
var tree = new Prog();
parser.ParseProgram(tree);

var compiler = new Compiler();
var program = new Stope.Program();   // ⚠ 顶层语句里的裸 `Program` 是入口类，见 §8
if (compiler.Compile(tree, program) != Result.Success)
{
    foreach (var e in compiler.Errors) Console.Error.WriteLine(e);
    return;
}

var state = new State();
state.Reset(new Api(), program);   // 不传实参表就够用
if (state.Run() != Result.Success)
{
    foreach (var e in state.Errors) Console.Error.WriteLine(e);
    return;
}
Console.WriteLine(state.Returns[0]);   // 3
```

三个 demo 没有用顶层语句，而是显式写了 `<c>internal static class Demo01 { static int Main() }</c>`
—— 就是为了避开下面 §8 第一条那个撞名。

## 8. C# 专属坑

| 症状 | 原因 / 做法 |
| --- | --- |
| `float consts: 0` 但源码写的是 `0.0` | 展示口径照 C 的 `%g`（`Format.FmtG`）：`0.0` 打成 `0`。数值没丢 |
| `true + 1` 编译不过 / 运行时报类型错 | Stope 没有布尔值类型：`true` 在产物里就是 `PushTrue` → 压**整数 1**。宿主的 `bool` 要自己折成 `1L`（`Runtime.Normalize`） |
| `long.MinValue / -1` 抛 `OverflowException` | C# 的 `/` 会抛，不是回绕。用 `Runtime.IntDiv` / `Runtime.IntMod`（它们处理了 `-1` 分支） |
| `new Parser(lexer).ParseProgram(tree)` 之后 `tree.Stmts` 是空的 | 传的是 `new Prog()` 吗？传匿名对象（或 `dynamic`）会让 `Visit` 静默跳过 |
| **顶层语句里 `new Program()` 报「无法从 Program 转换为 Stope.Program」** | 顶层语句会把入口类自动命名为 `Program`，与 `Stope.Program` 撞名。写 `new Stope.Program()`，或像 demo 那样显式声明 `static int Main()` |
| 顶层语句里 `return 1;` 报 CS0161 | 用了 `return <值>` 之后入口点变成有返回值，所有路径都得返回。骨架里直接 `return;`（或改用显式 `Main`） |
| `State.Variables[slot]` 赋值后仍然报 `"Call" can only call a function.` | 槽位号写死了 / 取错了：一律 `program.Exports["名字"]`。注意 `Reset` 会重建数组，赋值要在 `Reset` **之后** |
| `Api.OpMap[33]` 抛 `ArgumentOutOfRangeException` | 内置表只有 33 格（0–32）。自定义指令要自己 `OpMap.Add(...)` 补到目标编号 —— 但见 README「标准范围」：内置执行器**不支持**自定义指令 |
| `using Stope;` 与 `using Stope.Stml;` 同时在场时 `Lexer` 指向哪个？ | 指向 `Stope.Lexer`。STML 的写全名 `Stml.Lexer` / `Stml.Parser` / `Stml.Element` |
| `dotnet run` 找不到 `gdscript/test/data` | 测试跑器从可执行文件目录向上找仓库根。从别的目录跑、或打包后运行就会找不到（数据不入包） |

## 9. 下一步

- **解析 STML 文档**：看 [`demo/02-stml/Program.cs`](../demo/02-stml/Program.cs) 与
  [`stml.md`](stml.md)。
- **加自己的指令**：看 [`demo/03-custom-opcode/Program.cs`](../demo/03-custom-opcode/Program.cs) 与
  [`custom-opcode.md`](custom-opcode.md)。
- **每个 API 的签名与返回码**：看 [`usage.md`](usage.md)。
