# STML 上手（GDScript）

> 目标读者：想在 Godot 项目里解析 STML 文档的人。
> 本文逐段讲 `gdscript/demo/demo_02.gd`（可直接运行），最后给出一份可复制的最小骨架。
>
> **语义权威是 C++ 那篇**（[`../../cpp/docs/stml.md`](../../cpp/docs/stml.md)）：STML 是 Stope
> 标准三件套之一，两侧跑的是**同一份行为契约**。本文只写「用 GDScript 怎么写」，以及
> GDScript 侧**真的不一样**的地方 —— 语法注意事项那 12 条不重复，直接看 C++ §6。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 本目录总览（插件怎么装、文档导览） | [`README.md`](README.md) |
| STML 的 API 表（字段 / 返回值 / 错误格式） | [`usage.md`](usage.md) §10 |
| **STML 上手全文（语义权威）** | [`../../cpp/docs/stml.md`](../../cpp/docs/stml.md) |
| 写文档时的 12 条语法坑 | C++ 那篇的 §6 |
| STML 的行为契约（跨实现，以它为准） | [`../../docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md) |
| GDScript 侧的实现笔记与缺陷流水 | [`testing.md`](testing.md) + 上述契约 §7 的 GD-S-xx |
| 给编译器加自定义指令（另一种宿主扩展） | [`custom-opcode.md`](custom-opcode.md) |
| 标准范围（哪些是标准、哪些只是示例） | [`../../README.md`](../../README.md) |

依赖只有 **Godot 4.7.2**（开发与实测版本），零第三方插件。

---

## 0. STML 是「两半」：树的形状 + 内容怎么切

| 部分 | 谁管 | 内容 |
| --- | --- | --- |
| **树的形状** | `STMLParser.Parser` | 标签名、有没有属性、自闭合还是一对、嵌套关系、结束标签是否匹配 |
| **内容怎么切** | **宿主的回调** | 这个元素的内容是子元素、纯文本、Nevext 代码，还是 Stope 代码 |
| **内容是什么** | 宿主自己找的处理器 | Parser 对 `<func>` 里的代码一个字符都不检查，只是整段交出来 |

代码位置：

```
gdscript/addons/stope/stml.gd          Element（6 个字段）+ Token + TokenType（12 项）
gdscript/addons/stope/stml_lexer.gd    Lexer + State（Xml / Text / Nevext / Stope）
gdscript/addons/stope/stml_parser.gd   Parser + 回调约定
```

所以 STML 里**不存在**「`sto` 必须是 Stope 代码」这种规定。`config` / `func` / `class`
只是本仓库 demo 惯用的名字 —— 换成 `<shader>` 装 GLSL、`<sql>` 装 SQL 都行。
解析器只是一个被回调驱动的切分器。

---

## 1. 先跑起来：demo_02 的六段

```bash
godot --headless --path gdscript res://demo/demo_02.tscn
```

`demo_02` **只解析**，不编译也不执行（要把 Stope 代码跑起来看 [`quick-start.md`](quick-start.md)）。
它的完整输出：

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

六个编号就是 `demo_02.gd` 里 `demo()` 的六段，本文后面每一节都对得上号：

| demo 段 | 那段代码在干什么 | 本文 |
| --- | --- | --- |
| `[1]` | `print('[1] 根元素 <', root.tag, '>，属性 package="', root.attrs['package'], '"')` | §5（属性） |
| `[2]` | `for c in root.children: print('  ', c.tag)` | §4（读树） |
| `[3]` | 用 `_child_by_tag(root, 'class')` 取 `<class>`，再遍历它的子元素、标出自闭合 | §4 |
| `[4]` | `print(func_ele.text)` —— 把 `<func>` 的代码段原样打出来 | §4 |
| `[5]` | 把 `func_ele.text` 交给 `StopeLexer` 数一遍 token | §3 末尾 |
| `[6]` | `print('[6] parse() 的返回值：', 'Success' if result == StopeResult.Success else 'Error')` | §3 |

输入就是 `demo_02.gd` 里那份 `DOC`（**开头有一个换行**，所以行号整体 +1）：

```xml
<stml package="MyPkg">

<config>
  windowTitle "demo";
  windowSize 1280, 720
</config>
<func name="myFunc" stope>
  let a = 1;
  return a + argc;
</func>
<class name="Person">
  <property name="name" />
  <property name="age" />
  <method name="greet" />
</class>

</stml>
```

一棵树把三种内容模式都齐了：

| 元素 | 回调给了什么模式 | 内容落在 `Element` 的哪 |
| --- | --- | --- |
| `stml` | `Xml` | `children`（3 个） |
| `config` | `Nevext` | `text`，一整段 Nevext |
| `func`（带 `stope` 属性） | `Stope` | `text`，一整段 Stope |
| `class` | `Xml` | `children`（3 个） |
| `property` / `method` | `Xml`，但自闭合 | 只有 `attrs` |

把 §7 的 `_walk()` 套到这份文档上，能直接看到解析出来的整棵树（`[]` 里是 `text`）：

```
<stml package="MyPkg"> @L2
  <config> @L4
    [windowTitle "demo";
  windowSize 1280, 720]
  </config>
  <func name="myFunc" stope=""> @L8
    [let a = 1;
  return a + argc;]
  </func>
  <class name="Person"> @L12
    <property name="name"/> @L13
    <property name="age"/> @L14
    <method name="greet"/> @L15
  </class>
</stml>
```

`<func name="myFunc" stope="">` 里那个 `stope=""` 就是「属性没有值 = 空串」。

---

## 2. 第一步：写回调 —— `demo_02.gd` 末尾的 `_state_func`

STML 唯一需要宿主发挥的地方，一个函数而已。demo 里就是这么写的（**原文照抄**）：

```gdscript
# 宿主回调：与 C++ demo 的 lexerStateFunc 一一对应。
#   <config>            -> Nevext 代码
#   带 stope 属性的元素  -> Stope 代码
#   其余                -> Xml（按子元素列表解析）
static func _state_func(tag:String, attrs:Dictionary) -> int:
	if tag == 'config': return STMLLexer.State.Nevext
	if 'stope' in attrs: return STMLLexer.State.Stope
	return STMLLexer.State.Xml
```

三行 `if` 正好把 §1 那份文档切成三种内容：`<config>` → Nevext、`<func stope>` → Stope、
`<stml>` / `<class>` → Xml（于是它们按子元素列表递归）。

| 返回值 | 内容会被切成 | `Element` 里落在哪 |
| --- | --- | --- |
| `STMLLexer.State.Xml` | 若干个子元素（递归），中间可以插注释 | `children` |
| `STMLLexer.State.Text` | 一整段原文，一路吃到 `</` | `text` |
| `STMLLexer.State.Nevext` | 一整段 Nevext 代码，按 Nevext 的引号/注释规则躲开串内的 `</` | `text` |
| `STMLLexer.State.Stope` | 一整段 Stope 代码，按 Stope 的引号/注释规则躲开串内的 `</` | `text` |

四条要记住（前三条与 C++ 相同，第四条是 GDScript 特有的）：

1. **判断顺序有意义。** 上面把 `config` 排在最前，所以万一有个 `<config stope>`，它会被判成
   `Nevext` 而不是 `Stope`。当成一串 `if`，从上往下第一条命中的生效。
2. **`attrs` 是完整给你的**，用它决定内容怎么切 —— 这就是「标签语义由宿主决定」的实际写法。
3. **`children` 和 `text` 互斥。** 选了 `Xml` 就只有子节点，其余三种就只有 `text`。
4. **用 `static func` 或 `Callable` 都行**（C++ 那边必须是无捕获的裸函数指针，GDScript 没有
   这个限制）。用 `static func` 最省事；要带外部状态就传 `Callable(host, 'method')`，
   宿主对象自己持有字段。`parse(root, null)` 等价于「一律 `Xml`」。

回调要**覆盖你能遇到的全部标签**。没覆盖到的会落到最后的 `Xml` 分支上，症状见 §6。

---

## 3. 第二步：解析 —— demo 的 `[6]` 段

`demo()` 开头这几行就是全部（`[6]` 打印的是它的返回值）：

```gdscript
var lexer := STMLLexer.Lexer.new(DOC)
var parser := STMLParser.Parser.new(lexer)
var root := STML.Element.new()
var result:int = parser.parse(root, _state_func)
for e in lexer.errors: print('[lex] ', e)
for e in parser.errors: print('[parse] ', e)
...
print('[6] parse() 的返回值：',
	'Success' if result == StopeResult.Success else 'Error')
```

| 约定 | 内容 |
| --- | --- |
| 入口 | `parse(root, _state_func)` **自己会先取一个 token**，你不要替它调 `next_token()` |
| 返回值 | `StopeResult.Success`（**`== 0`**）当且仅当 `parser.errors` 为空 |
| 错误去哪 | 累加进 `parser.errors`，格式 `line N: msg`；**不抛异常、不中断** |
| 顶层 | 只解析**一个**元素，根之后的输入静默忽略 |
| 出错后 | `root` 是「部分成功」的状态 |

词法错误在 `lexer.errors`，语法错误在 `parser.errors`，**两边不合并** —— 排查时两个都要看。
demo 里 `for e in lexer.errors` / `parser.errors` 那两行就是干这个的（正常文档什么都不打）。

> `parse()` 用的是 `StopeResult`（与编译器共用的那一份），不是独立的枚举。
> 所以别写 `if r:` 当成功 —— `Success == 0`，`if r:` 判断的是「失败」。
> demo 里写成三元表达式 `'Success' if result == StopeResult.Success else 'Error'`，就是这个原因。

**`[5]` 段接着证明「内容是什么，Parser 完全不管」**：它把 `[4]` 打出来的那段文本原样交给
Stope 词法器，数出 10 个 token —— 同一份文本在这一步之前只是 `Element.text` 里的一个字符串。

```gdscript
var stope_lexer := StopeLexer.Lexer.new(func_ele.text)
var n := 0
while true:
	var t := stope_lexer.next_token()
	if t.type == StopeLexer.Token.Type.Eof: break
	n += 1
print('  ', n, ' 个 token')
```

---

## 4. 第三步：读树 —— demo 的 `[1]`–`[4]` 段

`Element` 一共六个字段（`stml.gd`），全是普通值：

```gdscript
class Element:
	var line: int = -1            # 起始行（< 所在的物理行）
	var tag: String = ''          # 标签名
	var attrs: Dictionary = {}    # 属性；无值属性的值是空串
	var self_closing: bool = false
	var children: Array = []      # 子元素（Xml 模式）
	var text: String = ''         # 内容（其余三种模式）
```

注意字段名与 C++ 的差别：C++ 是 `tagName` / `selfClosing`，GDScript 是 `tag` /
`self_closing` —— 这是 GDScript 的 snake_case 约定，别照着 C++ 抄。

demo 的 `[1]`–`[4]` 段把这六个字段基本都用了一遍（**原文照抄**）：

```gdscript
print('[1] 根元素 <', root.tag, '>，属性 package="', root.attrs['package'], '"')
print('[2] 它的直接子元素：')
for c in root.children: print('  ', c.tag)

# 按名字找，别像 C++ demo 那样写死下标 —— 下标会随空行/注释变。
var func_ele := _child_by_tag(root, 'func')
var class_ele := _child_by_tag(root, 'class')
print('[3] <class> 的子元素：')
for c in class_ele.children:
	print('  ', c.tag, '(自闭合)' if c.self_closing else '')

# 代码段原样切出来：换行是真的换行，缩进也保留（尾部空白已被词法裁掉）。
print('[4] <func> 里的 Stope 代码段：')
print(func_ele.text)
```

逐段对：`[1]` 用 `tag` + `attrs`；`[2]` 用 `children`（顺序就是源码顺序）；`[3]` 额外用
`self_closing` 区分 `<property name="name" />` 这类；`[4]` 用 `text`。

读这棵树时最容易搞混的三件事：

**（1）`children` 是 `Array`，按源码顺序。** 和 `attrs` 不一样（属性顺序见 §5）。
demo 里 `root.children` 出来就是 `config` / `func` / `class`。

**（2）`text` 里的换行、缩进原样保留。** 只有**尾部**空白会被去掉（`trimTrailingWs`）。
demo 第 4 段直接 `print(func_ele.text)`，换行就真的换行了。

**（3）按名字找，别用下标。** demo 写了个小工具：

```gdscript
static func _child_by_tag(ele:STML.Element, tag:String) -> STML.Element:
	for c in ele.children:
		if c.tag == tag: return c
	return null
```

（返回 `null` 表示没找到 —— 这很正常，不是错误。）

`demo_02` 特意没用 C++ demo 那种 `root.children[2]` 的写法 —— 文档里多一个空行，下标就错位。

想整体打印可以调 `Element.to_str()`（调试用，属性值会重排、自闭合写法不保留），
或者用 §7 的 `_walk()`（带行号，便于对照源码）。

---

## 5. 属性 —— demo 的 `[1]` 段

`[1]` 用的是最直接的写法：`root.attrs['package']`（对应文档里的 `<stml package="MyPkg">`）。
`attrs` 是 `Dictionary`，几条约定：

| 点 | GDScript 侧 |
| --- | --- |
| 无值属性 | `<func stope>` 存成 `attrs['stope'] == ''`，空串，不是布尔 |
| 判断有无 | `'stope' in attrs`（`in` 判键）；**不要**用 `attrs['stope'] != ''`，那会把 `x=""` 也判成「没有」 |
| 迭代顺序 | **插入序**（源码顺序）—— 与 C++ 的 `std::map` 字典序**不同**（差异 GD-S-17） |
| 回调拿到的是副本 | `stml_parser.gd` 里 `attrs.duplicate()`，删/改键不影响解析结果 |

实测 `<p id="1" name="x" flag/>`：

```
attrs={ "id": "1", "name": "x", "flag": "" }  keys=["id", "name", "flag"]
```

源码顺序就是 `id` → `name` → `flag`，GDScript 保持住了。C++ 那边同一份输入迭代出来是
`flag` / `id` / `name`（字典序），所以**跨实现比对时不要比属性顺序**，这也是 GD-S-17 登记
的内容。需要固定顺序就自己排序，别依赖任何一侧的迭代序。

`<a x>` 与 `<a x="">` 拿到的东西一模一样（都是空串），`Element` 上没有别的信息能区分两者。
如果这对你来说是两件事，得换编码方式（比如写 `<a x="1"/>`）。

---

## 6. 语法注意事项

C++ 那篇的 **§6 一共 12 条**（内容模式选错、没有字符实体、`<` 不是标签起点、
`<!-- -->` 只在 Xml 态、标签名不含 `.`、children/text 互斥、顶层只解析一个、
属性取值规则、三种代码段的引号规则、`Element` 不拥有字符串、行号规则、错误只累加），
**对 GDScript 侧逐条成立，这里不重复** —— 直接看
[`../../cpp/docs/stml.md`](../../cpp/docs/stml.md) §6。

下面只写 GDScript 侧**真的不一样**的三条：

**（1）属性顺序是插入序。** C++ 是字典序（上面 §5）。

**（2）非 BMP 字符（emoji 等）按码点算。** GDScript 的 `String` 是 UTF-32 码点序列，
C++ 是 UTF-16 码元序列，两侧的「第 N 个字符」在非 BMP 上不同。这是 GD-S-18；
STML 解析本身（找 `</`、切 text）不受影响，只有你自己按索引处理字符串时才会撞上。

**（3）`Element` 拥有自己的字符串。** C++ 的 `Element` 全是 `u16string_view`，指向输入缓冲，
所以 C++ 文档里有一条「输入必须活得比树久」的硬约束（C++ §6.10）。**GDScript 没有这个坑**：
`String` 是引用计数的不可变值，`tag` / `text` / `attrs` 里的串各自持有引用，`doc` 是局部
变量也不会悬垂。代价是大文档会多占内存。

---

## 7. 最小骨架（可直接复制）

把 `demo_02.gd` 压成一份能贴进自己工程的脚本：`DOC` 缩成一行、去掉六段打印、
`_state_func` 原样保留、`_child_by_tag` 换成通用的递归 `_walk()`。
（这份骨架是独立跑的，输出与 `demo_02` 的 `[1]`–`[4]` 是同一棵树。）

```gdscript
extends Node

const SRC := "<stml><config>windowSize 1280, 720</config>" \
	+ "<func stope>let a = 1; return a;</func></stml>"

# 回调：返回 STMLLexer.State 的一项
static func _state_func(tag: String, attrs: Dictionary) -> int:
	if tag == 'config': return STMLLexer.State.Nevext
	if 'stope' in attrs: return STMLLexer.State.Stope
	return STMLLexer.State.Xml

static func _walk(e: STML.Element, depth: int) -> void:
	var pad := '  '.repeat(depth)
	var attrs := ''
	for k in e.attrs: attrs += ' %s="%s"' % [k, e.attrs[k]]
	print(pad, '<', e.tag, attrs, '>' if not e.self_closing else '/>', ' @L', e.line)
	if e.self_closing: return
	if e.text != '': print(pad, '  [', e.text, ']')
	for c in e.children: _walk(c, depth + 1)
	print(pad, '</', e.tag, '>')

func _ready() -> void:
	var lexer := STMLLexer.Lexer.new(SRC)
	var parser := STMLParser.Parser.new(lexer)
	var root := STML.Element.new()
	var r := parser.parse(root, _state_func)
	for e in parser.errors: print('parser: ', e)
	for e in lexer.errors: print('lexer:  ', e)
	if r != StopeResult.Success:
		get_tree().quit(1)
		return
	_walk(root, 0)
	get_tree().quit()
```

输出（`--headless` 实跑）：

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

想把它挂到自己的工程里：把 `addons/stope/` 拷进目标工程并启用插件（见 [`README.md`](README.md) §4），
然后把上面这段贴进任意脚本。

---

## 8. 排错表

| 现象 | 原因 | 去哪 |
| --- | --- | --- |
| `line 1: expected "<" or "</". ` | 内容模式选成了 `Xml`，但里面有裸文本 | §6（C++ §6.1） |
| `line 1: expected ">" or "/>" or attribute. ` | 属性值里有引号，或标签名含 `.` | C++ §6.5、§6.8 |
| `line 1: expected tag name. ` | `<` 后面没紧跟合法标签名 | C++ §6.5 |
| `line 1: tag name mismatch. ` | 起始标签与结束标签不一致 | — |
| 预期有子元素，结果 `children` 是空的 | 回调把它判成了某种文本模式（且**不报错**） | C++ §6.1 |
| 纯文本元素的文本里出现了 `<!-- -->` | 注释只在 `Xml` 状态生效 | C++ §6.4 |
| 属性顺序跟源码对不上 | 不该发生：GDScript 是插入序；跟 C++ 比对时才「对不上」 | §5、GD-S-17 |
| 用下标取的元素不是想要的那个 | `children` 变了；按名字找 | §4 |
| `SCRIPT ERROR: Invalid access to property or key` + 拿到 `null` | `attrs['不存在的键']` 在 GDScript 里会报错并给 `null`（不像 C++ 的 `map::operator[]` 会插入） | §5 |
| 文档后半段凭空消失 | 只解析一个顶层元素，或注释没闭合 | C++ §6.7、§6.4 |
| 想执行 `<func>` 里的 Stope 代码 | Parser 不管这些，把 `text` 交给 `StopeLexer.Lexer` | [`quick-start.md`](quick-start.md)、`demo_02` 第 5 段 |

---

## 9. 相关文件

| 文件 | 讲什么 |
| --- | --- |
| `addons/stope/stml.gd` | `Element` 六个字段、`Token`、12 项 `TokenType` |
| `addons/stope/stml_lexer.gd` | 四态扫描；`<!--` 只在 `Xml` 生效的实现就在这 |
| `addons/stope/stml_parser.gd` | 属性循环、回调调用点、错误分支 |
| `demo/demo_02.gd` | 本文讲的 demo，场景 `demo_02.tscn`；**只解析，不编译不执行** |
| `test/test_stml.gd` | 121 条共用清单（`test/data/stml_cases.txt`）的词法 + 语法断言 |
| [`usage.md`](usage.md) §10 | API 表与四条宿主侧注意事项 |
| [`../../cpp/docs/stml.md`](../../cpp/docs/stml.md) | 语义权威 + 12 条语法坑 |
| [`../../docs/zh-cn/stml-test-plan.md`](../../docs/zh-cn/stml-test-plan.md) | 跨实现行为契约（GD-S-17/18 两条差异登记在 §7） |
