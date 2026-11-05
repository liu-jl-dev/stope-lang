# Go 版 STML 上手

STML 是 Stope 的标记语言：**树**由 `stml.Parser` 管（标签名、属性、嵌套、结束标签是否配对），
**内容怎么切**由宿主管 —— 就是传给 `Parse()` 的那个回调。

完整可运行版本是 [`cmd/demo02/main.go`](../cmd/demo02/main.go)，本文逐段讲它。
STML 的**语义权威**在 [`cpp/docs/stml.md`](../../cpp/docs/stml.md)（12 条语法注意事项都在那），
本文只讲「Go 侧怎么上手 + 本实现与另外几套的差异」。

## 1. 先跑起来：`demo02` 的四段

```bash
go run ./cmd/demo02
```

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
```

- `[1]` 属性走 `root.Attr("package")`；没有就返回空串（与无值属性同形，
  要区分「不存在」用 `HasAttr`，见 §4）。
- `[3]` `SelfClosing` 是布尔值 —— `/>` 这种写法不产生子元素，也不会去等结束标签。
- `[4]` 代码段是**原样**的一整段 `string`：换行是真换行、缩进保留，只有尾部空白被词法裁掉。
  拿到 `Text` 之后交给 `stope.NewLexer` 就能编译它 —— 但**这一步不是必须的**，
  STML 不关心你的代码写得对不对（demo 就到此为止）。

## 2. 第一步：写一个回调

回调类型是 `stml.StateFunc`，即 `func(tag string, attrs map[string]string) stml.LexerState`，
在**读完开始标签、还没进内容**的那一刻被调用一次，它的返回值决定后面怎么扫这个元素的内容：

| 返回 | 含义 |
| --- | --- |
| `stml.XmlState` | 内容是**子元素列表**（普通标签） |
| `stml.TextState` | 内容是**一整段普通文本**（`<p>`） |
| `stml.NevextState` | 内容是 **Nevext 代码**（`<config>`） |
| `stml.StopeState` | 内容是 **Stope 代码**（带 `stope` 属性的元素） |

```go
func contentKind(tag string, attrs map[string]string) stml.LexerState {
	if tag == "config" {
		return stml.NevextState
	}
	if _, ok := attrs["stope"]; ok {
		return stml.StopeState
	}
	return stml.XmlState
}
```

三点：

- **按标签名 / 属性判断，不要按层级**。回调拿不到「我是谁的儿子」，只有 `tag` 与 `attrs`。
- 传 `nil` 等价于「一律 `Xml`」。要「一律文本」就传一个固定返回 `stml.TextState`
  的回调（`tests/stml_test.go` 里就是这么造的）。
- 回调**每次进元素都会调一次**，不要在里面积累状态。

现成的默认回调 `stml.DefaultStateFunc` 用固定约定：`<sto>` → Stope、
`<nev>` → Nevext、`<p>` → Text，其余 Xml。想用它的语义就显式传 `stml.DefaultStateFunc`
（`Parse` 的第二参**没有**默认值，`nil` 是「一律 Xml」而不是「默认约定」）。

## 3. 第二步：解析

```go
lexer := stml.NewLexer(doc, stml.XmlState) // 初态：文档最外层按 Xml 扫
parser := stml.NewParser(lexer)
root := stml.NewElement()
if parser.Parse(root, contentKind) != stml.Success {
	var all []string
	all = append(all, lexer.Errors...)
	all = append(all, parser.Errors...)
	fmt.Fprintln(os.Stderr, strings.Join(all, "\n"))
	os.Exit(1)
}
```

| 约定 | 内容 |
| --- | --- |
| 错误分两处 | `lexer.Errors`（词法）与 `parser.Errors`（语法）**不合并**。`Parse()` 只看前者是否为空的**间接**结果 —— 返回码只反映语法错误 |
| 返回值 | `stml.Success` / `stml.Error`（`Result` 类型） |
| `root` 是容器 | 调用前是 `stml.NewElement()`（line = -1），`Parse()` 往里填 |
| 只解析一个根 | STML 文档就是一个根元素（demo 里的 `<stml>`），根后面还有内容不会报错，但也不会被解析 |
| 嵌套深度 | 元素嵌套默认最多 **256 层**（根算第 1 层），`parser.MaxDepth = 0` 表示不限。超限报 1 条 `nesting too deep (max 256). ` 并中止，剩余输入忽略、**不级联** |

## 4. 第三步：读树

`stml.Element` 只有 7 个字段，别指望更多：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `Line` | `int` | 开始标签所在行（从 1 起） |
| `TextLine` | `int` | 内容首行的物理行号（不是标签行）；无内容时 -1 |
| `Tag` | `string` | 标签名 |
| `Attrs` | `[]stml.AttrEntry` | 属性切片，**保序**；每条 `Name` / `Value`。**无值属性的值是空串** |
| `SelfClosing` | `bool` | 是不是 `/>` |
| `Children` | `[]*stml.Element` | 子元素 |
| `Text` | `string` | 元素内文本 / 代码段。与 `Children` **互斥** |

`TextLine` 是**内容**的第一行：词法器切内容前跳过了前导空白（含换行），所以
`<sto>\nlet a = 1;</sto>` 里 `Line` 是 1、`TextLine` 是 2。把切出来的代码段交给
`stope.NewLexer(src)` 后设 `lexer.Line = e.TextLine`，报错行号才和原文档对得上。

按名字取属性有两个 helper，比直接扫 `Attrs` 舒服：

```go
func childByName(ele *stml.Element, tag string) *stml.Element {
	for _, c := range ele.Children {
		if c.Tag == tag {
			return c
		}
	}
	return nil
}

funcEle := childByName(root, "func")
fmt.Println(funcEle.Text)             // 代码段原样
fmt.Println(funcEle.Attr("stope"))    // ""（有值但为空的属性与不存在的属性同形）
fmt.Println(funcEle.HasAttr("stope")) // true —— 判「有没有」用它
```

`Text` 与 `Children` 互斥，是因为**元素内文本只有一段**：`<p>a<span/>b</p>` 里的 `b` 不会
被拼到 `a` 后面 —— 按 STML 的规则，有文本就不能有子元素，写了就是宿主自己的问题
（词法器会把 `<span/>` 整段当文本吃掉，见 `cpp/docs/stml.md` 的 B-2）。

## 5. 属性

```go
root.Attr("package")     // "MyPkg"
root.Attr("missing")     // ""（不存在与无值同形）
root.HasAttr("stope")    // 有值为空串的属性也要用 HasAttr 判
```

| 规则 | 说明 |
| --- | --- |
| 可以无值 | `<a flag>` 等价于 `flag=""`。判「有没有这个属性」用 `HasAttr`，判「值是不是空」用 `Attr("flag") == ""` |
| 顺序保序 | `Attrs` 是 `[]AttrEntry`，按文档顺序排 —— 这是 Go 版与 C++ `std::map`（名字序）的显示差异；golden 里形状串按名字排，所以测试逐字节一致 |
| 同名属性 | 保留**先出现的**那个（对齐 C++ 的 `std::map::emplace`），后一个被静默丢弃 |
| 值不转义 | 属性串里的 `\"` **不会**被当成转义 —— 第一个引号就是结束引号（TD-9） |

## 6. 本实现与另外几套的差异

| 项 | C++ | Go | 影响 |
| --- | --- | --- | --- |
| `attrs` 容器 | `std::map`（名字序） | `[]AttrEntry` 切片（**保序**） | 遍历顺序不同；查名字用 `Attr` / `HasAttr`，别按 `map` 心智直接下标 |
| 回调缺省 | —— | `nil` = 一律 Xml；`DefaultStateFunc` 要**显式传** | 与 Python（缺省走默认回调）不同 |
| 非 BMP 字符（如 emoji） | 按 **UTF-16 码元**，一个字符两个 `?` | 词法按字节扫、lexeme 是源码子串原样保留（UTF-8 字节），golden 经 `escUtf8` 对齐 | 输出与 C++ 一致，但 Go 侧按字节理解自己的串 |
| `lexeme` 所有权 | `string_view` 借用输入 | `string` 复制 | 宿主不用管生命周期 |
| `TokenType` 名字 | `EndOfFile` | `Eof`（`stml.TypeName` 也印 `Eof`） | 与 GD / JS / C# / Python 一致 |

STML 的 12 条语法注意事项（`B-2` / `B-3` / `B-8` / `TD-1` / `TD-8` / `TD-9` …）不再重复，
一律看 [`cpp/docs/stml.md`](../../cpp/docs/stml.md) 与
[`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md)。

## 7. 最小骨架（已运行）

```go
package main

import (
	"fmt"
	"os"

	"stope/stml"
)

func stateFunc(tag string, attrs map[string]string) stml.LexerState {
	if _, ok := attrs["stope"]; ok {
		return stml.StopeState
	}
	if tag == "p" {
		return stml.TextState
	}
	return stml.XmlState
}

func main() {
	doc := `
<root>
<p>hello</p>
<code stope>return 1 + 2;</code>
</root>
`
	lexer := stml.NewLexer(doc, stml.XmlState)
	parser := stml.NewParser(lexer)
	root := stml.NewElement()
	if parser.Parse(root, stateFunc) != stml.Success {
		for _, e := range lexer.Errors {
			fmt.Fprintln(os.Stderr, e)
		}
		for _, e := range parser.Errors {
			fmt.Fprintln(os.Stderr, e)
		}
		os.Exit(1)
	}
	fmt.Println(root.Tag) // root
	for _, c := range root.Children {
		fmt.Println(c.Tag, c.Text) // p hello / code return 1 + 2;
	}
}
```

## 8. 排错表

| 症状 | 原因 / 做法 |
| --- | --- |
| `root.Children` 是空的 | 回调返回了 `XmlState` 却没写子元素？或者文档只有一个空标签（`<a></a>` 也是空） |
| `root.Text` 是空串，但我明明写了文本 | 那个元素的回调返回的是 `XmlState`（子元素模式），文本被当成了「不合法的子元素」→ `parser.Errors` 里有 `expected "<" or "</". ` |
| `Attrs` 里少了属性 | 同名属性只保留第一个；属性名里有 `.` 会被当成非法字符（`Word` 不含 `.`，TD-1） |
| `Attr("x")` 返回 `""`，分不清「不存在」还是「无值」 | 用 `HasAttr("x")` —— 两者同形是刻意设计，区分开是宿主的责任 |
| 报 `expected string. ` | 属性写在 `=` 后面没给字符串（`<a id=>`） |
| 报 `expected ">" or "/>" or attribute. ` | 属性位置上出现了不是 `Word` 的东西：`<a @>`、`<a.b>`（`Word` 不含 `.`，TD-1） |
| 报 `expected "<" or "</". ` | 两种情形：① 元素没有结束标签（`<a>` 就到头了）；② 内容按 `Xml` 扫，却遇到了裸文本（`<a>text</a>` 且回调返回 `Xml`） |
| 报 `tag name mismatch. ` | 结束标签与开始标签不一致。STML **没有**「自动闭合」 |
| 报 `unclosed string literal`（**没有**句号） | Xml 属性串没闭合，这一条与代码段那条文案不同（TD-8） |
| 报 `unclosed string literal. `（**有**句号） | `Nevext` / `Stope` 代码段里的引号串没闭合 |
| 代码段里含 `</` 却提前结束了 | 只有**引号串与注释内部**的 `</` 不算结束标签（B-3）；裸的 `</` 一定会结束元素 |
| 文本尾部空格丢了 | 故意的：内容段尾部空白不计入 `lexeme`（B-8） |

## 9. 下一步

- **加自己的指令**：看 [`cmd/demo03/main.go`](../cmd/demo03/main.go) 与
  [`custom-opcode.md`](custom-opcode.md)。
- **把切出来的代码编译了**：看 [`quick-start.md`](quick-start.md)。
- **STML 的语义权威**：[`cpp/docs/stml.md`](../../cpp/docs/stml.md)。
