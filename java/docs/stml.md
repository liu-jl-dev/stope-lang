# Java 实现的 STML

STML 语义权威在 [`cpp/docs/stml.md`](../../cpp/docs/stml.md)，本页只讲 Java 侧动线。

## 解析

```java
String src = "<root a=\"1\"><p>Hello</p></root>";
StmlLexer lx = new StmlLexer(src, Stml.LexerState.Xml);
StmlParser ps = new StmlParser(lx);
Stml.Element root = new Stml.Element();
boolean ok = ps.parse(root, StmlParser.defaultStateFunc()); // true
```

`Stml.Element` 六字段：`line` / `textLine` / `tag` / `attrs` / `selfClosing` / `children` / `text`。

## 状态函数

`StmlParser.StateFunc`（`tag → LexerState`）决定元素内容如何扫描。`defaultStateFunc()` 把 `sto` 映射到 Stope 源码、`nev` 到 Nevext、`p` 到纯文本，其余保持 Xml。可传 `null` 表示一律 Xml，或自定义 lambda（如 `tag -> LexerState.Text`）。

`maxDepth` 默认 256，与 Parser 同语义（只在 `parseElement` 入口检查）。

## 词法四态

`Xml / Text / Nevext / Stope`：遇到 `</` 必须交还 Xml。`Xml` 态跳 `<!-- -->` 注释；内容态跳 `//` 与 `/* */` 注释、识别单双引号字符串。Java 版用 `String` 天然的 UTF-16 码元扫描，与 C++ `u16string` 对齐。
