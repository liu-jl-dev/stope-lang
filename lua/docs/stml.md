# Lua 版 STML 上手

STML 是 Stope 的标记语言：**树**由 `StmlParser` 管（标签名、属性、嵌套、结束标签是否配对），
**内容怎么切**由宿主管 —— 就是传给 `parse()` 的那个回调。

完整可运行版本是 [`demo/02-stml.lua`](../demo/02-stml.lua)，本文逐段讲它。
STML 的**语义权威**在 [`cpp/docs/stml.md`](../../cpp/docs/stml.md)（12 条语法注意事项都在那），
本文只讲「Lua 侧怎么上手 + 本实现与另外几套的差异」。

## 1. 先跑起来：`demo 02` 的四段

```bash
lua lua/demo/02-stml.lua
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

- `[1]` 属性是 table：`root.attrs["package"]`，没有就得到 `nil`。
- `[3]` `self_closing` 是布尔值 —— `/>` 这种写法不产生子元素，也不会去等结束标签。
- `[4]` 代码段是**原样**的一整段字符串：换行是真换行、缩进保留，只有尾部空白被词法裁掉。
  拿到 `text` 之后交给 `stope.Lexer` 就能编译它 —— 但**这一步不是必须的**，
  STML 不关心你的代码写得对不对（demo 就到此为止）。

## 2. 第一步：写一个回调

回调签名是 `function(tag, attrs) -> LexerState`，在**读完开始标签、还没进内容**的那一刻
被调用一次，它的返回值决定后面怎么扫这个元素的内容：

| 返回 | 含义 |
| --- | --- |
| `stope.StmlState.Xml` | 内容是**子元素列表**（普通标签） |
| `stope.StmlState.Text` | 内容是**一整段普通文本**（`<p>`） |
| `stope.StmlState.Nevext` | 内容是 **Nevext 代码**（`<config>`） |
| `stope.StmlState.Stope` | 内容是 **Stope 代码**（带 `stope` 属性的元素） |

```lua
local function state_func(tag, attrs)
    if tag == "config" then
        return stope.StmlState.Nevext
    elseif attrs["stope"] ~= nil then
        return stope.StmlState.Stope
    end
    return stope.StmlState.Xml
end
```

三点：

- **按标签名 / 属性判断，不要按层级**。回调拿不到「我是谁的儿子」，只有 `tag` 与 `attrs`。
- 传 `nil`（不传第二参）等价于「一律 `Xml`」。要「一律文本」就写
  `function() return stope.StmlState.Text end`。
- 回调**每次进元素都会调一次**，不要在里面积累状态。

现成的默认回调 `stope.stml_parser.default_state_func` 用固定约定：`<sto>` → Stope、
`<nev>` → Nevext、`<p>` → Text，其余 Xml。要按这套约定就显式传它 ——
`parse(root, nil)` 是「一律 Xml」，**不是**「默认约定」。

## 3. 第二步：解析

```lua
local lexer = stope.StmlLexer.new(doc)
local parser = stope.StmlParser.new(lexer)
local root = stope.StmlElement()
if parser:parse(root, state_func) ~= stope.Result.Success then
    for _, e in ipairs(lexer.errors) do print("[lex] " .. e) end
    for _, e in ipairs(parser.errors) do print("[parse] " .. e) end
    error("stml parse failed")
end
```

| 约定 | 内容 |
| --- | --- |
| 错误分两处 | `lexer.errors`（词法）与 `parser.errors`（语法）**不合并**。`parse()` 只看前者是否为空的**间接**结果 —— 返回码只反映语法错误 |
| 返回值 | `stope.Result.Success` / `stope.Result.Error`，同样别写 `if result then` |
| `root` 是容器 | 调用前是空 `stope.StmlElement()`（line = -1），`parse()` 往里填 |
| 只解析一个根 | STML 文档就是一个根元素（demo 里的 `<stml>`），根后面还有内容不会报错，但也不会被解析 |
| 嵌套深度 | 元素嵌套默认最多 **256 层**（根算第 1 层），`parser.max_depth = 0` 表示不限。超限报 1 条 `nesting too deep (max 256). ` 并中止，剩余输入忽略、**不级联** |

## 4. 第三步：读树

元素只有 7 个字段，别指望更多：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `line` | number | 开始标签所在行（从 1 起） |
| `text_line` | number | 内容首行的物理行号（不是标签行）；无内容时 -1 |
| `tag` | string | 标签名 |
| `attrs` | table | 属性；**无值属性的值是空串**。Lua 的 string 键 table **没有稳定顺序**，要稳定输出自己排 |
| `self_closing` | boolean | 是不是 `/>` |
| `children` | 数组（1 起） | 子元素 |
| `text` | string | 元素内文本 / 代码段。与 `children` **互斥** |

`text_line` 是**内容**的第一行：词法器切内容前跳过了前导空白（含换行），所以
`<sto>\nlet a = 1;</sto>` 里 `line` 是 1、`text_line` 是 2。把切出来的代码段交给
`stope.Lexer` 时设 `lexer.line = e.text_line`，报错行号才和原文档对得上。

```lua
local function child(ele, tag)
    for _, c in ipairs(ele.children) do
        if c.tag == tag then return c end
    end
    return nil
end

local func_ele = child(root, "func")
print(func_ele.text)   -- 代码段原样
for k in pairs(func_ele.attrs) do print(k) end -- 属性名（顺序不保证）
```

`text` 与 `children` 互斥，是因为**元素内文本只有一段**：`<p>a<span/>b</p>` 里的 `b` 不会
被拼到 `a` 后面 —— 按 STML 的规则，有文本就不能有子元素，写了就是宿主自己的问题
（词法器会把 `<span/>` 整段当文本吃掉，见 `cpp/docs/stml.md` 的 B-2）。

## 5. 属性

```lua
root.attrs["package"]          -- "MyPkg"
root.attrs["missing"]          -- nil
root.attrs["stope"] ~= nil     -- 有值为空串的属性也要这样判
```

| 规则 | 说明 |
| --- | --- |
| 可以无值 | `<a flag>` 等价于 `flag=""`。判「有没有这个属性」用 `~= nil`，判「值是不是空」用 `== ""` |
| 顺序不保证 | C++ 是 `std::map`（名字序）、Lua 是 string 键 table（pairs 顺序由内部哈希决定）—— 要稳定输出就自己按名字排一遍再打 |
| 同名属性 | 保留**先出现的**那个（对齐 C++ 的 `std::map::emplace`），后一个被静默丢弃 |
| 值不转义 | 属性串里的 `\"` **不会**被当成转义 —— 第一个引号就是结束引号（TD-9） |

## 6. 本实现与另外几套的差异

| 项 | C++ | Lua | 影响 |
| --- | --- | --- | --- |
| `attrs` 容器 | `std::map`（名字序） | string 键 table（**顺序不保证**） | 只影响遍历顺序；golden 里形状串按名字排，所以测试逐字节一致 |
| 属性值就是 Lua 值 | `u16string` | string（**原样字节**，输入通常 UTF-8，不做转码） | 与其余实现一致，Lua 侧不用关心编码转换 |
| 非 BMP 字符（如 emoji） | 按 **UTF-16 码元**，一个字符两个 `?` | 比较经 `golden.esc16` 按 UTF-16 码元折算；存储是原输入的字节串（UTF-8） | 输出与 C++ 一致，但 Lua 侧按字节理解自己的串 |
| `lexeme` 所有权 | `string_view` 借用输入 | string 复制 | 宿主不用管生命周期 |
| `TokenType` 名字 | `EndOfFile` | `Eof` | 与 GD / JS / C# / Python 一致（`stope.stml_type_name` 也印 `Eof`） |

STML 的 12 条语法注意事项（`B-2` / `B-3` / `B-8` / `TD-1` / `TD-8` / `TD-9` …）不再重复，
一律看 [`cpp/docs/stml.md`](../../cpp/docs/stml.md) 与
[`docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md)。

## 7. 最小骨架（已运行）

```lua
local stope = require("stope")

local doc = [[
<root>
<p>hello</p>
<code stope>return 1 + 2;</code>
</root>
]]

local function state_func(tag, attrs)
    if attrs["stope"] ~= nil then return stope.StmlState.Stope end
    if tag == "p" then return stope.StmlState.Text end
    return stope.StmlState.Xml
end

local lexer = stope.StmlLexer.new(doc)
local parser = stope.StmlParser.new(lexer)
local root = stope.StmlElement()
if parser:parse(root, state_func) ~= stope.Result.Success then
    for _, e in ipairs(lexer.errors) do io.stderr:write(e, "\n") end
    for _, e in ipairs(parser.errors) do io.stderr:write(e, "\n") end
    os.exit(1)
end
print(root.tag)                 -- root
for _, c in ipairs(root.children) do
    print(c.tag, c.text)        -- p  hello / code  return 1 + 2;
end
```

（`require("stope")` 之前记得像 demo 那样把 `lua/` 挂进 `package.path`。）

## 8. 排错表

| 症状 | 原因 / 做法 |
| --- | --- |
| `root.children` 是空的 | 回调返回了 `Xml` 却没写子元素？或者文档只有一个空标签（`<a></a>` 也是空） |
| `root.text` 是空串，但我明明写了文本 | 那个元素的回调返回的是 `Xml`（子元素模式），文本被当成了「不合法的子元素」→ `parser.errors` 里有 `expected "<" or "</". ` |
| `attrs` 里少了属性 | 同名属性只保留第一个；属性名里有 `.` 会被当成非法字符（`Word` 不含 `.`，TD-1） |
| 报 `expected string. ` | 属性写在 `=` 后面没给字符串（`<a id=>`） |
| 报 `expected ">" or "/>" or attribute. ` | 属性位置上出现了不是 `Word` 的东西：`<a @>`、`<a.b>`（`Word` 不含 `.`，TD-1） |
| 报 `expected "<" or "</". ` | 两种情形：① 元素没有结束标签（`<a>` 就到头了）；② 内容按 `Xml` 扫，却遇到了裸文本（`<a>text</a>` 且回调返回 `Xml`） |
| 报 `tag name mismatch. ` | 结束标签与开始标签不一致。STML **没有**「自动闭合」 |
| 报 `unclosed string literal`（**没有**句号） | Xml 属性串没闭合，这一条与代码段那条文案不同（TD-8） |
| 报 `unclosed string literal. `（**有**句号） | `Nevext` / `Stope` 代码段里的引号串没闭合 |
| 代码段里含 `</` 却提前结束了 | 只有**引号串与注释内部**的 `</` 不算结束标签（B-3）；裸的 `</` 一定会结束元素 |
| 文本尾部空格丢了 | 故意的：内容段尾部空白不计入 `lexeme`（B-8） |

## 9. 下一步

- **加自己的指令**：看 [`demo/03-custom-opcode.lua`](../demo/03-custom-opcode.lua) 与
  [`custom-opcode.md`](custom-opcode.md)。
- **把切出来的代码编译了**：看 [`quick-start.md`](quick-start.md)。
- **STML 的语义权威**：[`cpp/docs/stml.md`](../../cpp/docs/stml.md)。
