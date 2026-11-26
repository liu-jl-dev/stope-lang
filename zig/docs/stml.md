# STML（Zig 版）

STML 是把标记文档里的代码段原样切出来的语言，语义权威在
[`cpp/docs/stml.md`](../../cpp/docs/stml.md) 与
[`docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md)。本文只讲 Zig 侧的动线。

## 四态词法

`stope.stml_lexer.Lexer` 有四态：`Xml` / `Text` / `Nevext` / `Stope`。扫完一段内容后
**必须交还 Xml**（库内部自动做）。`</` 在内容态里是结束标签，但引号串与注释里的 `</` 不算
（库内部会整段跳过）。

## 解析

```zig
var lx = stope.stml_lexer.Lexer.init(alloc, src, .Xml);
var ps = stope.stml_parser.Parser.init(alloc, &lx);
var root = stope.stml.Element.init(alloc);
const ok = try ps.parse(&root, stope.stml_parser.defaultStateFunc);
```

`defaultStateFunc` 把 `<sto>` 判为 Stope 代码、`<nev>` 为 Nevext、`<p>` 为 Text，其余递归子元素。
传 `null` 表示一律 Xml；传自定义 `*const fn(tag) LexerState` 可覆盖。

`Element` 六个字段：`line`、`text_line`、`tag`、`attrs`、`self_closing`、`children` / `text`
（后两者互斥）。`text_line` 是内容首行（跳过前导空白后），不是标签行。

## 深度上限

`ps.max_depth` 默认 256（0 = 不限），与 Stope Parser 同语义同文案；超限只报一条
`line N: nesting too deep (max 256). ` 并中止，不级联。

## 接代码段到 Stope lexer

从 `Element.text_line` 接上行号：

```zig
lx.line = e.text_line;   // 在构造/Reset 之后赋值
```

代码见 `zig/demo/02-stml.zig`。
