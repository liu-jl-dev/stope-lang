# 编译前先导出宿主变量（preExports）

> **这是一份用法文档，不是规范。**
>
> `preExports` 是编译器的一个**调用参数**，不是语言特性，也没有新语法：源码里看不见它，
> 同一段源码配不同的名单会产出不同的 `Program`（槽位编号不一样）。
>
> 它兑现的场景只有一个：**参数表已经写在外面了** —— STML 标签的 `params="a b"`、
> 配置文件、数据库里的函数签名 —— 宿主希望在编译函数体**之前**就把这些名字变成可写的
> 变量，而不是让编译器从函数体的使用情况里「猜」出参数是谁。
>
> 八份实现都有这个参数（签名见 [§7](#7-八份实现的-api-对照)）。**必须一致的行为、错误文案、
> 用例编号**在 [compiler-test-plan.md](compiler-test-plan.md) 的 B-12 与 §4.9（`CM-73…CM-78`），
> 本文不复述那张表，只讲怎么用、什么时候别用、坑在哪。

## 目录

- [1. 先看场景](#1-先看场景)
- [2. 跑起来](#2-跑起来)
- [3. 三步](#3-三步)
- [4. 编译产物里长什么样](#4-编译产物里长什么样)
- [5. 和「未声明标识符自动导出」的取舍](#5-和未声明标识符自动导出的取舍)
- [6. 五个坑](#6-五个坑)
- [7. 八份实现的 API 对照](#7-八份实现的-api-对照)
- [8. 排错表](#8-排错表)
- [9. 相关文件](#9-相关文件)

---

## 1. 先看场景

一份 STML 文档里定义函数，参数表写在标签属性上，函数体是 Stope 源码：

```xml
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
```

宿主拿到这份文档后要回答一个问题：**调用 `add(3, 4)` 时，3 和 4 分别写到哪个槽位？**

`Program.exports` 里有答案，但答案取决于编译器怎么分配变量：

- 什么都不做 —— 函数体里 `a`、`b` 是「未声明就使用」，按 B-9 自动登记成外部变量，
  顺序是**出现顺序**，而且只有**用到的**名字才会出现；
- 把 `params` 当 `preExports` 传进去 —— `a`、`b` 先按**参数表的顺序**占好槽位（0、1），
  没用到也占着。

后者才是「参数表是唯一真源」的做法：宿主可以照参数表直接写槽位，也不需要先反汇编
或猜顺序。

## 2. 跑起来

八份实现各有一个 `04` demo，做的是同一件事：

```bash
# C++（在 cpp/ 下，先 cmake --build build）
./build/demo04.exe

# GDScript（仓库根目录）
godot --headless --path gdscript res://demo/demo_04.tscn

# Node.js（在 nodejs/ 下）
node demo/04-pre-export.js

# C#（仓库根目录）
dotnet run --project csharp/demo/04-pre-export

# Python（仓库根目录）
python python/demo/04-pre-export.py
```

八份输出逐字节一致（下面是 C++ 侧，中间几段空的 `int consts` / `float consts` / `string consts` /
`binary array consts` 已省略）：

```text
[1] 从 <func> 取出：add(a, b)

[2] 编译函数体（preExports = 形参表）：
[0]     PushValue  0
[2]     PushValue  1
[4]     Add
[5]     Return     1
...
  exports: a=0 b=1

[3] add(3, 4) = 7

[4] 函数体里又写 export a;：
  compiler: line 1: duplicate export of "a".
```

`[4]` 段演示的是 §6.2 那个坑：名字已经进了文件作用域，函数体里再 `export a;` 就是
重复导出。demo 到 `[4]` 就结束了 —— 出错但不中断是故意的，让读者看到错误长什么样。

## 3. 三步

### 3.1 拿出形参表

`params="a b"` 是空白分隔的一串名字，拆成列表即可。**多个连续空格不算一个空名字** ——
空名字会被编译器当成错误（§6.3），所以别写 `split(" ")` 了事：

```cpp
// "a b" -> {"a", "b"}；多个空格 / 制表 / 换行都当一个分隔符
static std::vector<std::u16string> splitParams(std::u16string_view s) {
  std::vector<std::u16string> out;
  std::u16string cur;
  for (char16_t c : s) {
    if (c == u' ' || c == u'\t' || c == u'\n' || c == u'\r') {
      if (!cur.empty()) { out.push_back(cur); cur.clear(); }
    } else {
      cur += c;
    }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}
```

如果参数表本来就来自配置 / 数据库（不是从字符串拆），跳过这一步，直接用那份列表 ——
这也是 `preExports` 比「自动导出」更值钱的地方：名字的**来源**由你决定。

### 3.2 编译时交给 `Compile` 的第三参

```cpp
Compiler compiler;
Program program;
Result r = compiler.Compile(tree, program, params);   // params 就是上面拆出来的
if (r != Result::Success) {
  for (const auto& e : compiler.errors) std::cout << e << "\n";
}
```

名单在 `Compile` 内部**第一件事**就登记完，早于遍历 AST 的任何节点 —— 所以函数体里
第一句就用 `a` 也没问题，它不是「未声明」。

**顺手把行号对齐**：从 STML 里切出来的代码段不是从文档第 1 行开始的，而 `Lexer` 默认
按 1 起算 —— 不处理的话，报错会指向「代码段的第 5 行」，不是「文档的第 5 行」。
`Element` 的 `textLine` 就是内容首行的物理行号，赋给 `Lexer::line` 即可：

```cpp
Lexer lexer(fn->text);
lexer.line = fn->textLine;   // <func> 在 3 行、代码 4–6 行 → 报错直接指第 5 行
```

`textLine` 是**内容**首行而不是标签行：词法器切内容时跳过了前导空白（含换行），
所以 `<sto>\nlet a = 1;</sto>` 的 `line` 是 1、`textLine` 是 2。八份实现的写法见 §7.1。

### 3.3 运行前按 `exports` 写槽位

```cpp
BasicVM::State state;
// ... SetAPI / SetAllocator / SetProgramConstants / SetProgram
state.variables.resize(program.variableNum);        // 槽位得先存在

auto setInt = [&](const std::u16string& ident, int64_t v) {
  auto& slot = state.variables[program.exports.at(ident)];
  slot.type = BasicVM::Value::Type::Integer;
  slot.data.integer = v;
};
setInt(u"a", 3);
setInt(u"b", 4);
state.Run();
```

「调用」就是写变量 + 跑一遍 —— 没有额外的参数传递机制，也不需要构造 `Arguments`。
预导出变量的槽位在 `Run` 之前是 `null`：**没写的形参被函数体读到就是 `null`**，
不会报错（§6.4）。

## 4. 编译产物里长什么样

以上面的 `add` 为例：

| 位置 | 值 | 说明 |
| --- | --- | --- |
| `exports` | `a=0`、`b=1` | 名字 → 槽位；槽位按 `preExports` 的顺序分配（遍历顺序另说，见 §6.5） |
| `variableNum` | `2` | 两个形参各占一个槽位，函数体里没有别的变量 |
| 指令 | `PushValue(0) PushValue(1) Add Return(1)` | `a`、`b` 解析到文件作用域，直接按下标取值 |

对比一下**不给** `preExports` 的同一段源码：`exports` 也是 `a=0`、`b=1`，产物**一模一样**。
差别不在这个例子里，而在下面这些情况下：

- 函数体只用了 `a`（`params="a b"`）→ 自动导出只有 `a`，`b` 不存在，宿主没法写它，
  也没法知道「实参个数应该是 2」；
- 函数体先用 `b` 再用 `a` → 自动导出是 `b=0`、`a=1`，顺序跟着代码走，参数表说的顺序
  反而没兑现；
- 函数体里 `let c = 1;` 在形参之前 → 自动导出时 `c` 抢到 0 号槽位，形参整体后移。

第三条正是 §6.1 那个坑的来源。

## 5. 和「未声明标识符自动导出」的取舍

B-9 那条规则（未声明就使用的标识符当作外部变量，并进 `exports`）已经能让代码跑起来，
所以要不要用 `preExports` 是个真实的取舍：

| 维度 | 自动导出（B-9） | `preExports` |
| --- | --- | --- |
| 名字从哪来 | 函数体里**用到**的名字 | 宿主给的名单 |
| 顺序 | 出现顺序 | 名单顺序 |
| 函数体没用到的形参 | 不存在 | 仍占槽位 |
| 编译前宿主能否知道布局 | 不能（要先反汇编或读 `exports`） | 能（就是自己给的名单） |
| 真源有几份 | 一份（函数体） | 两份（名单 + 函数体），**得自己保证一致** |
| 拼错名字会怎样 | 不涉及 | **静默出错**，见 §6.4 |

结论：

- **参数表本来就存在**（STML 属性、配置、签名元数据）→ 用 `preExports`，它让参数表成为
  布局的唯一来源；
- **脚本是用户手写的一次性片段**、没有单独的参数表 → 别硬造一份，让自动导出干活，
  产物反而更短（没用到的变量不占槽位）。

## 6. 五个坑

### 6.1 源码里所有变量的编号整体后移

预导出的名字先占槽位，且**永不回收** —— 所以 `preExports = {"a"}` + `let b = 1;` 里
`b` 是 **1 号**槽位，不是 0（CM-77）。两个后果：

- **别跨配置比对 `Program`**：同一份源码配不同名单产出不同字节码，golden 比对会全线失败；
- **别在宿主里硬编码槽位号**（`variables[0]`），一律走 `exports.at(name)`。

### 6.2 名字进了文件作用域，不能再声明

源码里再 `export 同名`（CM-76）或**顶层** `let 同名`（CM-78）都报 duplicate：

```text
line 1: duplicate export of "a".
line 1: duplicate declaration of 'a'.
```

预导出的变量**只能赋值**（`a = 1;`）。块内 `let 同名` 不算冲突 —— 它是遮蔽，出了块就
看不见了，需要「局部覆盖形参」时可以用。

### 6.3 空名字 / 重名是编译错误，行号是 0

```text
line 0: empty name in pre-exports.
line 0: duplicate export of "a".
```

行号记 0 是**故意的**：这些名字不来自源码，报不了源码行。看到 `line 0` 就说明问题在
宿主传进来的名单里，不在脚本里 —— 最常见的原因是 `split` 留下了空串。

### 6.4 它只占槽位，不校验「名单和函数体对得上」

这是最难查的一个：`params="aa"`、函数体写 `return a;`，编译器**不报错**，运行也**不报错**，
但结果是 `null`（C++ 实测）：

```text
compile=Success errors=0
exports: a=1 aa=0 vars=2
returns: 0 (0=Null 1=Integer)
```

读法：`aa` 占 0 号槽（预导出），`a` 走了自动导出抢到 1 号槽 —— 于是宿主老老实实往 `aa`
写的 3，函数体根本没读；`a` 那个槽没人写过，返回 `null`。编译期的两份名字是各自独立的
真源，编译器只见过其中一份，没有理由认为它们应该匹配。

宿主侧要么在写槽位前检查「名单里的每个名字都在 `exports` 里」，要么在装配后校验
`exports` 的键集合是否等于参数表。

### 6.5 别靠遍历 `exports` 还原参数表顺序

`exports` 的容器类型各实现不同，遍历顺序**不保证一致**（`preExports = {"b", "a"}` 实测）：

| 实现 | 容器 | 遍历结果 |
| --- | --- | --- |
| C++ | `std::map` | `a=1 b=0`（按名字排序） |
| Node.js / Python | `Map` / `dict`（插入序） | `b=0 a=1` |
| GDScript | `Dictionary`（插入序） | `b=0 a=1` |
| C# | `Dictionary` | 顺序不作保证 |

要还原顺序，就用**你自己那份参数表列表**；`exports` 只用来按名字查槽位。

## 7. 八份实现的 API 对照

| 实现 | 调用 | 名单类型 | `exports` 类型 |
| --- | --- | --- | --- |
| C++ | `compiler.Compile(tree, out, {u"a", u"b"})` | `const std::vector<std::u16string>&`（默认 `{}`） | `std::map<std::u16string, int>` |
| GDScript | `compiler.compile(tree, out, ["a", "b"])` | `Array`（默认 `[]`） | `Dictionary[String, int]` |
| Node.js | `compiler.Compile(tree, out, ['a', 'b'])` | `string[]`（默认 `[]`） | `Map<string, number>` |
| C# | `compiler.Compile(tree, out, new[] { "a", "b" })` | `IReadOnlyList<string>?`（默认 `null`） | `Dictionary<string, int>` |
| Python | `compiler.compile(tree, out, ("a", "b"))` | 序列（默认 `()`） | `dict[str, int]` |
| Lua | `compiler:compile(tree, out, {"a", "b"})` | 表（默认 `{}`） | `table`（名字 → 槽位） |
| Go | `compiler.Compile(ast, out, []string{"a", "b"})` | `[]string`（默认 `nil`） | `[]ExportEntry`（登记序） |
| Rust | `compiler.compile(&tree, &mut out, &["a", "b"])` | `&[&str]`（默认 `&[]`） | `BTreeMap<String, i32>`（名字序） |

三点注意：

- 名单是**第三参**，前两参永远是 AST 与输出 `Program`；空名单（不传）等于「不预导出」。
- 名单只在**本次调用内**被读，不存指针也不拷贝成成员 —— 传临时对象（`{u"a", u"b"}`）也安全。
- C++ 的 `Program` 不能拷贝（`ProgramConstants` 持有常量的引用，拷贝会二次释放）；
  其余七份没有这条限制。

### 7.1 设 `Lexer` 的起始行号

代码段是从文档里切出来的，行号得从 `Element.textLine` 接上（§3.2 讲了为什么）：

| 实现 | 写法 |
| --- | --- |
| C++ | `lexer.line = fn->textLine;` |
| GDScript | `lexer.line = fn.text_line` |
| Node.js | `lexer.line = fn.textLine` |
| C# | `lexer.Line = fn.TextLine;` |
| Python | `lexer.line = fn.text_line` |
| Lua | `lexer.line = fn.text_line` |
| Go | `lexer.Line = fn.TextLine` |
| Rust | `lexer.set_line(fn.text_line)` |

C++ / GDScript / Node.js / Python / Lua 的 `line` 本来就是可写字段，构造后直接赋；C# 的
`Lexer.Line` 有 setter；Rust 用 `set_line()` 方法。注意赋值要放在构造（或 `Reset`）**之后**
—— `Reset` 会把它重置为 1。

## 8. 排错表

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `line 0: empty name in pre-exports.` | 名单里有空串 | 拆参数表时别留空元素（§3.1） |
| `line 0: duplicate export of "a".` | 名单里自己重名 | 去重；重名通常意味着参数表拼错了 |
| `line N: duplicate export of "a".` | 源码里 `export a;` 与名单撞名 | 删掉源码里的 `export` —— 它已经在作用域里了 |
| `line N: duplicate declaration of 'a'.` | 源码**顶层** `let a` 与名单撞名 | 改用赋值 `a = ...;`，或把 `let` 挪进块里（遮蔽） |
| 编译、运行都不报错，但结果是 `null` | 名单与函数体用到的名字对不上（§6.4） | 校验 `exports` 的键集合 == 参数表 |
| 搬了名单顺序后 golden / 产物比对全挂 | 变量编号整体后移（§6.1） | 同一份源码只跟同配置的产物比 |
| 遍历 `exports` 得到的顺序和参数表不一致 | 容器不保序 / 保的是名字序（§6.5） | 用自己那份参数表 |

## 9. 相关文件

- 八份 demo：`cpp/demo/04-pre-export.cpp`、`gdscript/demo/demo_04.gd`、
  `nodejs/demo/04-pre-export.js`、`csharp/demo/04-pre-export/Program.cs`、
  `python/demo/04-pre-export.py`、`lua/demo/04-pre-export.lua`、
  `go/cmd/demo04/`、`rust/src/bin/demo04.rs`
- 契约：同目录 [compiler-test-plan.md](compiler-test-plan.md) 的 B-6（槽位不回收、`variableNum`
  只记「曾经最大值」）、B-9（未声明就使用 → 自动进 `exports`）、B-12（预导出三条必须一致的
  行为）、§4.9（`CM-73…CM-78` 用例）
- 为什么参数放在 `Compile` 上而不是构造函数：`../../cpp/docs/development.md` §7.2
- 虚拟机怎么填槽位、`Run` 前的装配顺序：同目录 [vm-guide.md](vm-guide.md) §4、各实现 `docs/quick-start.md`
