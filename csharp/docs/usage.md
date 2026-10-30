# C# 实现 API 手册

按「调用顺序」排：词法 → 语法 → 编译器 → 产物 → 反汇编 → 执行器 → STML。
所有类型都在 `namespace Stope` 下（STML 在 `Stope.Stml`）。

> **稳定性**：§1–§6 是**编译器接口**（相对稳定，`Program` 的编码契约属标准）；
> §7 起是**内置的基础虚拟机** —— 会一直维护、接口不随意调整，但不是标准，换执行器可以
> 完全不长这样。分界线见 [`quick-start.md`](quick-start.md) §0 与根 README「标准范围」。

## 1. 返回码 `Result`

```csharp
public enum Result { Success = 0, Error = 1, UnknownError = 2, DuplicateWithBuiltinOpcode = 3 }
```

`Success == 0`。**不要**写 `if (rc)` 当成功 —— 那是失败。与 C++ / GDScript / Node.js 同序同值。

## 2. 词法

### 2.1 `Lexer`

| 成员 | 说明 |
| --- | --- |
| `Lexer(string input)` / `Reset(string input)` | 构造即 Reset：换输入、行号归 1、清空 `Errors` |
| `Token NextToken(CustomOpcodeConfig? custom = null)` | 取下一个 token。传了 `custom` 时登记表里的名字才会被识别成 `TokenType.Custom` |
| `List<string> Errors` | 词法错误，格式 `line N: msg` |
| `int Line` | 当前行号（从 1 起） |

**不做**的事：不合并空白（`SkipWs` 里连注释一起吃）、不校验语义（`0b` 这种空前缀只报
`invalid integer. `，不抛异常）。

### 2.2 `Token`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `Line` | `int` | 行号 |
| `Type` | `TokenType` | 47 项，值与 C++ 的 `TokenType` 一致 |
| `Lexeme` | `string` | 原文。标识符保留 `:` 两侧的空白与注释 |
| `Parsed` | `string` | 「建节点用」的形式：数字去掉 `_`、字符串去掉转义、标识符拼成不含空白的 `a:b` |
| `Value` | `object?` | 仅 `Integer`（`long`）与 `Float`（`double`）有值 |
| `IntValue` / `FloatValue` | `long` / `double` | 上面两个的强类型读法 |

**三个文本字段都可能不同**，别合并：`0x_1F` 的 `Lexeme` 是 `0x_1F`、`Parsed` 是 `0x1F`、
`Value` 是 `31L`。

### 2.3 数字与字符串的边界

| 写法 | 结果 |
| --- | --- |
| `0b1010` / `0o17` / `0x1F` / `1_000` | 整数。前缀与下划线只在 `Lexeme` 里 |
| `1.5` / `.5` / `1e3` | 浮点 |
| `1e` / `.` / `0b` / `0x` / `9223372036854775808` | `Lexeme` 保留原文，`Type` 置 `Invalid` 并报 `invalid integer. ` / `invalid float. ` |
| `"a\nb"` | 字符串，转义在 `Parsed` 里；非法转义报 `invalid escape character. ` |
| `'d 65'` | 二进制数组，**不转义**、可跨行；未闭合报 `unclosed binary array. ` |
| `my:add` | 标识符（命名空间形式）；`my:` 后面不是标识符则报 `unclosed identifier. ` |

## 3. 指令集与自定义指令登记

```csharp
public enum Opcode { Assign = 0, …, Return = 32 }
public static class OpcodeLimits
{
    public const int FirstCustomOpcode = 33;  // = Return + 1
    public const int BuiltinCount = 33;
}
```

| 类型 | 成员 |
| --- | --- |
| `CustomOpcode` | `int Opcode`、`int ArgNum`、`bool IsVarArg`（= `ArgNum < 0`） |
| `CustomOpcodeConfig` | `Dictionary<string, CustomOpcode> Opcodes`、`Result AddCustomOpcode(name, opcode, argNum = -1)`、`bool Has(name)` |

- `AddCustomOpcode` 同名重复注册 → `Result.DuplicateWithBuiltinOpcode`，**不覆盖**已有项。
- 不校验编号范围（与 C++ 一致）——编号请从 `FirstCustomOpcode` 起，撞内置会丢名字（见
  [`custom-opcode.md`](custom-opcode.md) §5）。
- **同一份 config 要同时交给 `Parser` 和 `Compiler`**（以及 `Disasm`），各建一份会出现
  「编译期找不到指令」或「反汇编印不出名字」。

## 4. AST

`namespace Stope`，`Node` 有两个公共字段：`int Line`、`AstNodeType NodeType`，以及
`string ToStr(int level = 0)`（调试用）。

| 节点 | 关键字段 |
| --- | --- |
| `Prog` | `List<Stmt> Stmts` |
| `ExprStmt` | `Expr? Expr` |
| `LetStmt` | `bool HasAssign`、`List<string> Idents`、`Expr? Expr`、`int IdentNum()` |
| `ReturnStmt` | `List<Expr> Exprs`、`int ExprNum()` |
| `ExportStmt` | `List<string> Idents` |
| `BlockStmt` | `Prog Prog`（永远非 null） |
| `IfStmt` | `Expr? Cond`、`Prog FirstProg`、`List<IfStmtElif> Elifs`、`Prog? ElseProg`、`bool HasElse()` |
| `WhileStmt` | `Expr? Cond`（**null 表示无条件循环** `while { }`）、`Prog Prog` |
| `AssignStmt` | `Expr? LeftExpr`、`Expr? RightExpr` |
| `BreakStmt` / `ContinueStmt` | — |
| `NullExpr` / `ArgcExpr` | — |
| `BoolExpr` | `bool Value` |
| `IntExpr` | `long Value` |
| `FloatExpr` | `double Value` |
| `BinArrExpr` | `byte[] Value` |
| `StringExpr` | `string Value` |
| `IdentExpr` | `string Ident` |
| `ArgsExpr` | `Expr? KeyExpr`（`args[]` 缺下标时为 null） |
| `UnaryOpExpr` | `TokenType Op`（只可能是 `Sub` / `Not`）、`Expr? Expr` |
| `BinaryOpExpr` | `Expr? LeftExpr`、`TokenType Op`、`Expr? RightExpr` |
| `CallExpr` | `Expr? Callee`、`List<Expr> Args` |
| `AtExpr` | `Expr? Container`、`List<Expr> KeyExprs` |
| `CustomOpcodeExpr` | `string OpcodeName`、`List<Expr> Args` |
| `ErrorExpr` | 失败路径的占位（形状串 `Err(L行号)`）；C# 的 `Expr` 是抽象类，实例化不了，所以单开这个类型 |

**形状串序列化**（测试用，格式与 `cpp/test/test_common.hpp` 逐字一致）：

```csharp
Shape.Prog(tree);   // "Let[a]=Int(1) ; Return(Ident(a))"
Shape.Stmt(stmt);
Shape.Expr(expr);
```

### 4.1 `AstVisitor`

```csharp
public class AstVisitor
{
    public int CurLine;             // 由 Visit 维护，子类报诊断用
    public void Visit(Node? n);     // 按 NodeType 分发；null 直接返回
    public virtual void OnVisitProg(Prog p);
    public virtual void OnVisitExprStmt(ExprStmt s);
    // …26 个钩子，与 C++ 的 ASTVisitor 同名
}
```

默认实现一律「按源码顺序递归子节点」。重写后要继续下钻就调 `base.OnVisitXxx(...)`。

⚠ **漏一个分支不会报错，只会静默跳过整类节点**（`Node` / `Stmt` / `Expr` 三个裸基类本来就
没有分支，它们只在错误恢复路径上出现）。

## 5. 语法分析

```csharp
var parser = new Parser(lexer, custom: null);
parser.ConstFolding = true;   // 关掉它才能看到未折叠的 AST
parser.MaxDepth = 256;        // 0 = 不限制
var tree = new Prog();
parser.ParseProgram(tree);
```

| 成员 | 说明 |
| --- | --- |
| `Parser(Lexer lexer, CustomOpcodeConfig? custom = null)` | 构造即 `Reset`：连读两个 token（`CurToken` / `PeekToken` 才有值） |
| `void Reset(Lexer lexer, CustomOpcodeConfig? custom = null)` | 清错误、重挂词法器、重读两个 token |
| `void ParseProgram(Prog prog)` | 解析整个输入 |
| `List<string> Errors` | 语法错误 `line N: msg` |
| `bool ConstFolding` | 默认 true，挂在 `ParseUnaryOpExpr` / `ParseBinaryOpExpr` 末尾 |
| `int MaxDepth` | 嵌套深度上限，默认 256 |
| `Token CurToken` / `PeekToken` | 当前 / 下一个 token（调试用） |
| `bool HasError()` | `Errors.Count > 0` |

**错误恢复的三条约定**（跨实现契约，别改）：

1. 分隔符缺失时**只报错、不推进**，把后续 token 留给下一条语句重新解析。
   例外：`ParseLetStmt` / `ParseReturnStmt` 的兜底分支仍会推进（有意保留旧语义）。
2. `ParseExpr()` 之后必有一次 `NextToken()`。
3. 顶层孤立 `}` 要报错**并跳过**继续解析；块内的 `}` 由外层消费，不报错。

**嵌套深度**：`depth` 走函数参数（每个 `ParseXxx` 一个形参），只在真正的递归处 +1。
超限报一条 `line N: nesting too deep (max 256). ` 并置 `aborted`，此后不再解析、也不再记错
（否则 12000 层嵌套会刷上万条噪音）。

## 6. 常量折叠 / 二进制数组 / 编译器 / 产物 / 反汇编

### 6.1 `ExprOptim`

| 成员 | 说明 |
| --- | --- |
| `static Expr? Optimize(Expr? e)` | 成功折叠返回**新**节点，否则返回入参本身。只做单节点变换，不递归 |
| `static ConstKind KindOf(Expr? e)` | `NotConst / Null / Bool / Int / Float / String / BinArr` |

拿不准就**不折叠**：除零、含浮点的 `idiv`、跨类型 `==`、null 参与比较、Bool 参与比较。
三条项目自定的规则：`BinArr + BinArr` 是字节连接；`String/BinArr * 非负整数` 是串重复；
`+ - * / idiv % ^` 里 Bool 视作 0/1，但比较运算符仍按类型区分。

### 6.2 `BinArrParser`

```csharp
var bytes = new List<byte>();
var rc = new BinArrParser().Parse("x 41 42", bytes);   // 输入**不含单引号**
```

无前缀按 16 进制；`b/o/d/x` 切进制；超出一个字节静默截断到低 8 位；空段 / 非法字符 →
`Result.Error`（此时 `bytes` 可能已写入前半段，调用方负责丢弃）。

### 6.3 `Program`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `Opcodes` | `List<int>` | 指令与操作数**混排**；元素都在 int16 范围内 |
| `VariableNum` | `int` | 变量槽数 |
| `Exports` | `Dictionary<string,int>` | 导出变量名 → 槽位 |
| `IntConsts` / `FloatConsts` / `StringConsts` / `BinArrConsts` | `List<long>` / `double` / `string` / `byte[]` | 常量池，**相同的值只存一份**（`byte[]` 按逐字节比） |
| `MaxReturnNum` | `int` | `return` 最大返回值个数 |
| `RequiredStackSize` | `int` | 执行这段产物需要的最小栈容量 |
| `Clear()` | — | 清空成「刚构造」的状态（`Compile` 开头会调） |

带操作数的指令：`PushInt/PushFloat/PushString/PushBinArr/PushValue/PushId`（常量池或变量表
索引）、`Call/At`（参数个数）、`If/GoTo`（**指令下标**）、`Return`（返回值个数）、自定义指令
（变长时多一个参数个数）。

### 6.4 `Compiler`

```csharp
var compiler = new Compiler(custom: null);   // 配置只在构造时注入一次
var rc = compiler.Compile(tree, program);    // 结果写进 program
```

| 成员 | 说明 |
| --- | --- |
| `Compiler(CustomOpcodeConfig? custom = null)` | |
| `void Reset(CustomOpcodeConfig? custom = null)` | 清错误、换自定义指令表 |
| `Result Compile(Prog ast, Program outProg)` | 有错误时返回 `Error` 并把 `outProg` **清空** |
| `List<string> Errors` | `line N: msg` |

编译期的几条规则：`export` 只能在顶层；`break` / `continue` 只能在循环里；同名重复声明 /
重复导出报错；`let` 的变量在离开块时**槽位被回收复用**（最小堆，总是复用最小空位）。

### 6.5 `Debug`

| 成员 | 说明 |
| --- | --- |
| `static string Disasm(Program prog, CustomOpcodeConfig? config = null)` | 人读的反汇编 |
| `static string DisasmNoCustom(Program prog)` | 产物里确定没有自定义指令时的简写 |
| `static bool OpcodeHasArg(int op)` | 内置指令是否带一个操作数 |
| `static bool CustomOpcodeHasArg(int raw, CustomOpcodeConfig? config)` | 自定义指令是否带（变长才带） |
| `static string[] BuiltinNames` | 下标即编号的名字表 |

输出与另外三套实现逐字节一致：编号列宽 8、名字列宽 `max(10, 最长名字按 UTF-8 字节)`、
int/float 常量同列连排、字符串一行一个、二进制数组只印字节数、末尾 warning 段。

## 7. 参考执行器（不是标准）

### 7.1 `Api` / `State`

| 成员 | 说明 |
| --- | --- |
| `Api.OpMap` | `List<Action<State>>`，默认 33 格；下标 = 指令编号 |
| `State.Reset(Api api, Program program, Arguments? args = null)` | 清 `Returns`/`Stack`/`Errors`，并按 `VariableNum` 开好槽位 |
| `Result Step()` | 走**一条**指令。`Errors` 非空 = 出错停住；`Errors` 空 = 指令流走完 |
| `Result Run()` | 走到底；出错立即停。与 `Step` 是两份独立实现 |
| `List<object?> Returns` | `return` 带回来的值 |
| `object?[] Variables` | 变量槽（宿主往里填宿主函数） |
| `List<object?> Stack` | 求值栈 |
| `List<string> Errors` | `"<指令下标>: msg"` |
| `void Error(string msg)` | 宿主报错入口（进同一个 `Errors`，执行器立刻停） |
| `object? AtTop(int k)` / `Pop()` / `PopN(int n)` / `PushInt(long)` / `StoreBinary(object?)` | 栈操作小工具 |

**值用 `object?` 表示**：`null` / `long` / `double` / `string` / `byte[]` /
`Func<object?[], object?>` / `Identifier`。**没有 bool 值类型**（`PushTrue` 压 `1L`）。

⚠ **栈上除了 `Assign` 的左值之外一定是值**：`PushId` 只由编译器产生在赋值左端。所以执行器
**没有**解引用 helper —— 收到 `Identifier` 就是产物错了，该让它当场暴露。

### 7.2 `Arguments`

```csharp
public abstract class Arguments
{
    public abstract object? At(State state, object? indexOrKey);  // 取不到就 state.Error(...) + 返回 null
    public abstract int Num();                                    // argc
}
```

### 7.3 `Runtime` 工具类

| 成员 | 说明 |
| --- | --- |
| `IsInt / IsFloat / IsNumber / IsString / IsBinArr / IsFunc / IsSequence / IsNull` | 值判定 |
| `AsDouble(object?)` | 整数 / 浮点统一成 `double` |
| `Normalize(object?)` | `bool` → `1L`/`0L`（宿主返回值要过一次） |
| `Truely(object?)` | 真值：null 假、数非零真、序列非空真 |
| `AreEqual(object?, object?)` | 相等。类型不同一律不等（整数与浮点互通） |
| `IntDiv / IntMod / IntPow` | 64 位回绕版；处理了 `long.MinValue / -1` 会抛异常的那个坑 |

### 7.4 写一条自己的指令

```csharp
public static void MyAdd(State s)
{
    var b = s.AtTop(1);          // 右操作数
    var a = s.AtTop(2);          // 左操作数
    if (a is not long x || b is not long y) { s.Error("my:add 只接受整数. "); return; }
    s.StoreBinary(unchecked(x + y));   // 弹右操作数，结果写回左操作数的位置
}
```

处理函数的约定：**操作数已经在栈上**，自己 `AtTop` 取、自己 `StoreBinary` 收尾；报错用
`s.Error(...)` 且**立刻 return**（执行器看到 `Errors` 非空就停）。变长指令要自己 `++s.I`
读那个「实参个数」（见 `Ops` 里的 `Call`）。

## 8. STML

`namespace Stope.Stml`。契约见 [`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md)，
权威实现是 C++；上手看 [`stml.md`](stml.md)。

| 类型 | 成员 |
| --- | --- |
| `Lexer(string source)` | `Token NextToken()`、`State CurrentState`（`Xml/Text/Nevext/Stope`）、`List<string> Errors`、`int Line` |
| `Parser(Lexer lex)` | `Result Parse(Element root, LexerStateFunc? stateFunc = null)`、`List<string> Errors`、`delegate Lexer.State LexerStateFunc(string tag, Dictionary<string,string> attrs)` |
| `Element` | `int Line`、`string Tag`、`Dictionary<string,string> Attrs`、`bool SelfClosing`、`List<Element> Children`、`string Text`、`string ToStr(int level = 0)` |
| `TokenType` | 12 项：`Invalid/Eof/LAngle/RAngle/CLAngle/CRAngle/EQ/Word/String/Text/NevextSrc/StopeSrc` |

⚠ `using Stope;` 与 `using Stope.Stml;` 同时在场时，裸名 `Lexer` / `Parser` / `Element` /
`Token` / `TokenType` 都指向 **`Stope` 的**；STML 的要写全名或起别名。

## 9. 错误信息总表

| 阶段 | 位置 | 格式 | 真实文案示例 |
| --- | --- | --- | --- |
| 词法 | `lexer.Errors` | `line N: msg` | `line 1: invalid integer. ` |
| 语法 | `parser.Errors` | `line N: msg` | `line 1: expected ";" in let statement. ` |
| 嵌套超限 | `parser.Errors` | `line N: msg` | `line 1: nesting too deep (max 256). ` |
| 编译 | `compiler.Errors` | `line N: msg` | `line 1: undefined custom opcode "myop". ` |
| 运行期 | `state.Errors` | `"<下标>: msg"` | `4: "Div" division by zero. ` |
| STML 词法 | `stmlLexer.Errors` | `line N: msg` | `line 1: unexpected character. ` |
| STML 语法 | `stmlParser.Errors` | `line N: msg` | `line 1: expected tag name. ` |

全部**不抛异常**（唯一的例外是 `Api.OpMap` 越界 —— 那是产物里有内置执行器不认识的编号）。
