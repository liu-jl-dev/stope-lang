# C# 版 STML 上手

STML 是「Stope 标记语言」：一份文档里既有树形结构（标签、属性、嵌套），又能把
**Nevext**、**Stope** 的代码段原样嵌进去。

> **语义权威是 [`cpp/docs/stml.md`](../../cpp/docs/stml.md)。** 本文只讲 C# 侧怎么用，
> 以及本实现与另外三套真的不一样的地方；与语言无关的 12 条语法细节不重复。

## 1. 先跑起来：`demo/02` 的六段

```bash
dotnet run --project csharp/demo/02-stml
```

`demo/02` **只解析**，不编译也不执行（要把 Stope 代码跑起来看 [`quick-start.md`](quick-start.md)）。
完整输出：

```
[1] 根元素 <stml>，属性 package="MyPkg"
[2] 它的直接子元素：
  config
  func
  class
[3] <class> 的子元素：
  property(自闭合)
  property(自闭合)
  method(自闭合)
[4] <func> 里的 Stope 代码段：
let a = 1;
  return a + argc;
[5] 同一段代码，交给 Stope 词法器扫一遍 token 数：
  10 个 token
[6] Parse() 的返回值：Success
```

输入是 `demo/02-stml/Program.cs` 里的 `Doc` 常量（原始字符串字面量，**开头没有换行**，
所以行号从 1 起）。六段各讲什么：

| 段 | 在干什么 | 本文哪节 |
| --- | --- | --- |
| `[1]` | 根元素的标签名与属性 | §5 属性 |
| `[2]` `[3]` | 按 `Children` 遍历树，`SelfClosing` 区分自闭合 | §4 读树 |
| `[4]` | 把 `<func stope>` 的内容**原样**切出来 | §4 读树 |
| `[5]` | 同一段文本交给 Stope 词法器（证明「切得出来」） | §9 下一步 |
| `[6]` | `Parse` 的返回码 | §3 解析 |

## 2. 第一步：写一个回调

STML 唯一需要宿主发挥的地方 —— 一个委托：

```csharp
// tag: 标签名；attrs: 属性副本（Dictionary）
// 返回 Stml.Lexer.State 的一项，决定这个元素的**内容**按哪种状态扫
private static Stml.Lexer.State StateFunc(string tag, Dictionary<string, string> attrs)
{
    if (tag == "config") return Stml.Lexer.State.Nevext;
    if (attrs.ContainsKey("stope")) return Stml.Lexer.State.Stope;
    return Stml.Lexer.State.Xml;
}
```

四种状态就是 STML 的全部「内容切法」：

| 状态 | 内容怎么扫 | 得到 |
| --- | --- | --- |
| `Xml` | 按子元素解析 | `Children` 非空 |
| `Text` | 到 `</` 为止的纯文本 | `Text` |
| `Nevext` | 同上，但引号串与注释整段跳过 | `Text` |
| `Stope` | 同上，单引号是 BinArr（不转义） | `Text` |

⚠ **`using Stope;` 与 `using Stope.Stml;` 同时在场时，裸名 `Lexer` 指向 `Stope.Lexer`**
（Stope 的词法器），STML 的要写 `Stml.Lexer`。本文所有 STML 类型都带 `Stml.` 前缀就是这个
原因 —— 两套词法器同名，这是 C# 侧最容易踩的一脚。

## 3. 第二步：解析

```csharp
var lexer = new Stml.Lexer(Doc);
var parser = new Stml.Parser(lexer);
var root = new Stml.Element();
var result = parser.Parse(root, StateFunc);   // 第二参是那个回调，可为 null
foreach (var e in lexer.Errors) Console.Error.WriteLine("[lex] " + e);
foreach (var e in parser.Errors) Console.Error.WriteLine("[parse] " + e);
```

| 约定 | 内容 |
| --- | --- |
| 入口 | `Parse(root, stateFunc)` **自己会先取一个 token**，你不要替它调 `NextToken()` |
| 返回值 | `Result.Success`（**`== 0`**）当且仅当 `parser.Errors` 为空 |
| 错误去哪 | 累加进 `parser.Errors`，格式 `line N: msg`；**不抛异常、不中断** |
| 顶层 | 只解析**一个**元素，根之后的输入静默忽略 |
| 出错后 | `root` 是「部分成功」的状态，别当完整的树用 |

词法错误在 `lexer.Errors`，语法错误在 `parser.Errors`，**两边不合并** —— 排查时两个都要看。

## 4. 第三步：读树

`Element` 只有 6 个字段（与 C++ 的 `STML::Element` 一一对应，别加字段）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `Line` | `int` | 标签的 `<` 所在行 |
| `Tag` | `string` | 标签名 |
| `Attrs` | `Dictionary<string,string>` | 属性；无值属性的值是空串 |
| `SelfClosing` | `bool` | `<a/>` |
| `Children` | `List<Element>` | 子元素 |
| `Text` | `string` | 元素内文本，与 `Children` **互斥**、只有一段 |

`demo/02` 里那两段遍历：

```csharp
Console.WriteLine("[2] 它的直接子元素：");
foreach (var c in root.Children) Console.WriteLine("  " + c.Tag);

foreach (var c in classEle.Children)
    Console.WriteLine("  " + c.Tag + (c.SelfClosing ? "(自闭合)" : ""));
```

三件容易搞混的事：

1. **`Text` 与 `Children` 互斥**。`<a><b/></a>` 走 Xml → 有 `Children`、`Text` 是空串；
   `<p>hello</p>` 走 Text → `Text` 是 `hello`、`Children` 为空。
2. **文本只有一段、不拼接**。`<p>a<!-- c -->b</p>` 里注释会被跳过，但文本仍然是一段；
   `<p>x<b/></p>` 在 Text 状态下 `<b/>` 会被整段当文本吃掉（这是 STML 的既定行为）。
3. **`Line` 是标签行的行号**，不是元素结束处。

## 5. 属性

| 点 | C# 侧 |
| --- | --- |
| 类型 | `Dictionary<string,string>`（**插入序**；C++ 是 `std::map` 的字典序） |
| 无值属性 | `<a flag>` → `Attrs["flag"] == ""` |
| 取不存在的键 | `Attrs["x"]` 抛 `KeyNotFoundException`；用 `TryGetValue` / `GetValueOrDefault` |
| 重复属性 | 后者覆盖前者 |
| 属性值 | Xml 状态下**不转义**（`"a\"b"` 里的引号就是结束引号） |

⚠ **属性顺序不保证**（`stml-test-plan.md` §2.3）。要输出可比的字符串就自己排序 ——
测试里的形状串按 `Attrs.Keys` 排序后输出，就是为了不为了一个不保证的顺序互相打架。
这与 GDScript / Node.js 侧的处理一致。

## 6. 本实现与另外三套的差异

只列真的不一样的：

| 点 | 本实现 | 说明 |
| --- | --- | --- |
| `Element` 的字符串 | `string`（引用、不可变） | 没有 C++ 那种「输入必须活得比树更久」的悬垂坑；`doc` 是局部变量也没关系 |
| 文本与标签的宽度 | **UTF-16 码元** | 与 C++ / Node.js 一致（GDScript 按 UTF-32 码点，这是登记在案的 GD-S-18） |
| 属性顺序 | 插入序 | 与 GDScript / Node.js 一致；C++ 是字典序（GD-S-17） |
| 回调参数 | `Dictionary<string,string>` **副本** | 宿主改它不会改到解析器的 `Attrs`（C++ 的 `std::map` 按值传，同理） |

## 7. 最小骨架（已运行）

```csharp
using System;
using System.Collections.Generic;

using Stope;               // Result
using Stml = Stope.Stml;   // 两套 Lexer / Parser 同名，用别名最省事

const string Src = "<stml><config>windowSize 1280, 720</config><func stope>let a = 1; return a;</func></stml>";

static Stml.Lexer.State StateFunc(string tag, Dictionary<string, string> attrs)
{
    if (tag == "config") return Stml.Lexer.State.Nevext;
    if (attrs.ContainsKey("stope")) return Stml.Lexer.State.Stope;
    return Stml.Lexer.State.Xml;
}

static void Walk(Stml.Element e, int depth)
{
    string pad = new(' ', depth * 2);
    var attrs = "";
    foreach (var (k, v) in e.Attrs) attrs += $" {k}=\"{v}\"";
    Console.WriteLine($"{pad}<{e.Tag}{attrs}{(e.SelfClosing ? "/>" : ">")} @L{e.Line}");
    if (e.SelfClosing) return;
    if (e.Text.Length > 0) Console.WriteLine($"{pad}  [{e.Text}]");
    foreach (var c in e.Children) Walk(c, depth + 1);
    Console.WriteLine($"{pad}</{e.Tag}>");
}

var lexer = new Stml.Lexer(Src);
var parser = new Stml.Parser(lexer);
var root = new Stml.Element();
var result = parser.Parse(root, StateFunc);
if (result != Result.Success)
{
    foreach (var e in parser.Errors) Console.Error.WriteLine(e);
    return;
}
Walk(root, 0);
```

输出：

```
<stml> @L1
  <config> @L1
    [windowSize 1280, 720]
  </config>
  <func stope=""> @L1
    [let a = 1; return a;]
  </func>
</stml>
```

注意 `stope=""` —— 无值属性的值就是空串（`Attrs["stope"] == ""`），`ContainsKey` 照样为真。

## 8. 排错表

| 症状 | 原因 |
| --- | --- |
| `line 1: unexpected character. ` | Xml 状态下遇到了既不构成标签、也不能当词法单元首字符的东西（最常见的是 `&`、`;`、`?`） |
| `line N: expected tag name. ` | `<` 后面不是合法标签名（`Word`：字母 / `_` / `:` 起头，可含数字与 `-`） |
| `line N: expected ">" or "/>" or attribute. ` | 属性位置出现了别的东西 |
| `line N: tag name mismatch. ` | 结束标签名与开头不一致 |
| `line N: unclosed string literal`（**没有句号**） | Xml 属性值没闭合。代码段那条**有**句号 —— 两者都是原文，别「顺手补全」 |
| 文本里莫名少了一段 | 走的是 Xml 状态，`<` 被当成子元素起了；把内容状态设成 `Text` |
| `Stml.Lexer` 报「找不到类型」 | 只 `using Stope;` 没 `using Stope.Stml;` |
| `Lexer` 用到的是 Stope 的词法器 | 两套同名，STML 的写全名 `Stml.Lexer` |

## 9. 下一步

- 把 `Text` 交给 Stope 的词法器 / 编译器：看 [`quick-start.md`](quick-start.md) 与
  [`demo/01-quick-start`](../demo/01-quick-start/Program.cs)。
- STML 的完整语法（四态、12 条细节、`<!-- -->`、属性不转义……）：
  [`cpp/docs/stml.md`](../../cpp/docs/stml.md)。
- 跨实现的 121 条用例清单与残留差异：`docs/zh-cn/stml-test-plan.md`。
