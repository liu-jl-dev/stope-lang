# STML 上手（C++）

> 目标读者：想在自己的 C++ 程序里解析 STML 文档的人。
> 本文逐段讲 `cpp/demo/02-stml.cpp`（可以直接编译运行），最后给出一份可复制的最小骨架。
>
> STML **是** Stope 标准三件套之一（Stope 语言 / STML / `Program` 的产物格式），
> 所以本文的接口比虚拟机那些示例 API 稳定得多，可以照着写。

| 想看 | 去哪（相对本文件） |
| --- | --- |
| 本目录总览（面向所有人） | `README.md`（本目录） |
| STML 的行为契约（跨实现，以它为准） | `../../docs/zh-cn/stml-test-plan.md` |
| C++ 侧的实现笔记与缺陷流水 | `stml_test_plan.md`（本目录） |
| Nevext 语言本身 | <https://github.com/liu-jl-dev/nevext> |
| 标准范围（哪些是标准、哪些只是示例） | `../../README.md` |
| Stope 程序的编译与运行 | `quick-start.md`（本目录） |
| 给编译器加自定义指令 | `custom-opcode.md`（本目录） |
| 构建 / 格式化 / 行尾 / 文档约定 | `development.md`（本目录） |

依赖只有 C++20 编译器 + CMake，无第三方库。

---

## 0. STML 是"两半"：树的形状 + 内容怎么切

理解 STML 只需要分清楚一件事：**哪些是解析器管的，哪些是宿主管的。**

| 部分 | 谁管 | 内容 |
| --- | --- | --- |
| **树的形状** | `STML::Parser` | 标签名、有没有属性、自闭合还是一对、嵌套关系、结束标签是否匹配 |
| **内容怎么切** | **宿主的回调** `LexerStateFunc` | 这个元素的内容是子元素、纯文本、Nevext 代码，还是 Stope 代码 |
| **内容是什么** | 宿主自己找的处理器 | Parser 对 `<func>` 里的代码一个字符都不检查，只是整段交出来 |

代码位置：

```
cpp/include/stope/stml_lexer.hpp    12 种 TokenType、4 种 LexerState
cpp/include/stope/stml_parser.hpp   Element + LexerStateFunc + Parser
```

所以 STML 里**不存在**"`sto` 必须是 Stope 代码"这种规定。`config` / `func` /
`class` 这几个名字也不过是本仓库示例惯用的 —— 换成 `sto` / `nev` / `p`（测试里
那套）或让 `<shader>` 装 GLSL、`<sql>` 装 SQL 都没问题。解析器只是一个被回调
驱动的切分器。

---

## 1. 先跑起来

```bash
cd cpp
cmake -B build -G "MinGW Makefiles"     # 必须显式指定 generator
cmake --build build                      # 产出 build/libstope.a 与各 demo
./build/demo02.exe
```

`demo02` **只解析**，不编译也不执行 —— 接过内容之后干什么完全是宿主的事
（要把 Stope 代码跑起来看 `quick-start.md`）。它的完整输出就这么几行：

```
config
func
class
property
property
method
let a = 1;
  return a + argc;
```

demo 的输入就是 `02-stml.cpp` 里那份 raw string，下面逐字照搬（**包括空行**）：

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

这份输入与仓库根 [`README.md`](../../README.md) 里那份 STML 示例是同一份文档 ——
唯一差别是 raw string 开头多那个换行，所以行号整体 +1（`<stml>` 在 README 里是
第 1 行，这里是第 2 行）。一棵树把三种内容模式都齐了：

| 元素 | 回调给了什么模式 | 内容落在 `Element` 的哪 |
| --- | --- | --- |
| `stml` | `Xml` | `children`（3 个） |
| `config` | `Nevext` | `text`，一整段 Nevext |
| `func`（带 `stope` 属性） | `Stope` | `text`，一整段 Stope |
| `class` | `Xml` | `children`（3 个） |
| `property` / `method` | `Xml`，但它们是自闭合 | 只有 `attrs` |

demo 的打印只有三处，对着输出看：

| demo 里的那行代码 | 打印出来 | 说明 |
| --- | --- | --- |
| 遍历 `root.children` 的 `tagName` | `config` `func` `class` | 顶层三个子元素，**按源码顺序** |
| 遍历 `root.children[2].children` | `property` `property` `method` | `[2]` 是 `<class>`，它按 Xml 模式递归出了三个子节点 |
| 打印 `root.children[1].text` | `let a = 1;` 换行 `  return a + argc;` | `[1]` 是 `<func>`；**`text` 里的换行原样保留**，直接 `cout` 就会真的换行 |

> `root.children[2]` / `[1]` 这种硬编码下标是 demo 图省事写的。
> **真实代码别这么干** —— 文档稍作调整，下标就错位了，而且 `<property>` 和
> `<method>` 的顺序一变你会发现得更晚。按名字找，或者干脆写个遍历（§4、§7）。

想知道某个元素当时被判成了哪种模式，最简单的办法是把整棵树打印出来 ——
`demo02` 没做这一步，但把 §7 那份 `walk()` 套上去就能看到全貌；同一份输入的
真实输出如下（注意多行 `text` 会真的换行，因为它原样保留缩进）：

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

对着这张图读：`[]` 括起来的是 `text`（`config` / `func`），其余两层是
`children`（`stml` / `class` 各自三个子节点，`@L` 是起始行）。
`<func name="myFunc" stope="">` 里那个 `stope=""` 是 §5 说的"属性没有值就是空串"。

---

## 2. 第一步：写一个回调

STML **唯一**需要宿主发挥的地方，一个函数而已 —— demo 里写成 lambda：

```cpp
auto lexerStateFunc =
    [](std::u16string_view tag,
       std::map<std::u16string_view, std::u16string_view> attrs)
    -> STML::LexerState {
  if (tag == u"config") {
    return STML::LexerState::Nevext;
  }
  if (attrs.find(u"stope") != attrs.end()) {
    return STML::LexerState::Stope;
  }
  return STML::LexerState::Xml;
};
```

四个返回值，选的是**内容该怎么被扫描**：

| `LexerState` | 内容会被切成 | `Element` 里落在哪 |
| --- | --- | --- |
| `Xml` | 若干个子元素（递归），中间可以插注释 | `children` |
| `Text` | 一整段原文，一路吃到 `</` | `text` |
| `Nevext` | 一整段 Nevext 代码，按 Nevext 的引号/注释规则躲开串内的 `</` | `text` |
| `Stope` | 一整段 Stope 代码，按 Stope 的引号/注释规则躲开串内的 `</` | `text` |

关于这个回调，四条要记住：

1. **必须无捕获。** `LexerStateFunc` 是**裸函数指针**
   `LexerState (*)(u16string_view, map<...>)`，不是 `std::function`。
   写成 `[&]` 或 `[=]` 会直接编译失败：

   ```
   error: cannot convert 'main()::<lambda(...)  >' to
          'Stope::STML::LexerStateFunc' {aka 'Stope::STML::LexerState (*)(...)'}
   ```

   回调里能用的只有两个入参。想带外部状态就把回调写成普通静态函数，
   或者把状态塞进 `attrs` / 标签名里（这本来也是 STML 的路子）。

2. **判断顺序是有意义的。** 上面先把 `config` 排在前，所以万一有个
   `<config stope>` 会被判成 `Nevext` 而不是 `Stope`。写的时候就当它是
   一串 `if`，从上往下第一条命中的生效。

3. **`attrs` 是完整给你的。** demo 就用 `attrs.find(u"stope") != attrs.end()`
   决定了 `<func>` 的内容怎么切 —— 这就是 STML 那句"标签语义由宿主决定"的实际写法：
   **先看标签和属性，再决定内容怎么切**。

4. **`children` 和 `text` 互斥。** 选了 `Xml` 就只有子节点，选了另外三种就只有
   `text`，不可能两个都有（§6.6）。

还有一条是老实话：**回调要覆盖你能遇到的全部标签**。
没覆盖到的会落到最后的 `Xml` 分支上（§6.1 讲这种错位的表现）。

---

## 3. 第二步：解析

```cpp
STML::Element root;
STML::Lexer lexer(doc);                    // 借用 doc（§6.10）
STML::Parser parser(lexer);                // 借用 lexer
parser.Parse(root, lexerStateFunc);        // 第二个参数是那个回调

for (auto& err : parser.errors) {          // demo 只打印了错误
  cout << err << endl;
}
```

demo 为了短，**打印了 `errors` 却没看返回值**。真实代码别这样：

```cpp
Result r = parser.Parse(root, lexerStateFunc);
if (r != Result::Success) {
  for (auto& e : parser.errors) cout << "parser: " << e << "\n";
  return 1;   // root 此时是"部分成功"的状态，别当完整的树用
}
```

| 约定 | 内容 |
| --- | --- |
| 入口 | `Parse(root, stateFunc)` **自己会先取一个 token**，你不要替它调 `NextToken` |
| 返回值 | `Result::Success` **当且仅当** `parser.errors` 为空 |
| 错误去哪 | 累加进 `parser.errors`，格式 `line N: msg`；**不抛异常、不 exit** |
| 顶层 | 只解析**一个**元素，根之后的输入静默忽略（§6.7） |
| 出错后 | `root` 是"部分成功"的状态，别假设它是完整的一棵树 |

词法错误在 `lexer.errors`，语法错误在 `parser.errors`，**两边不合并** ——
排查时两个都要看。

> demo 用的是聚合头 `<stope/core.hpp>`（一次拿到全部公共头）。
> 只做 STML 的话，include `stml_lexer.hpp` + `stml_parser.hpp` 两个就够。

---

## 4. 第三步：读树

`Element` 一共六个字段，全是值语义（`children` 直接存 `Element`，不用 `unique_ptr`）：

```cpp
struct Element {
  int line = -1;                                              // 起始行
  std::u16string_view tagName;                                // 标签名
  std::map<std::u16string_view, std::u16string_view> attrs;   // 属性
  bool selfClosing = false;                                   // <a/> 为真
  std::vector<Element> children;                              // 子元素（Xml 模式）
  std::u16string_view text;                                   // 内容（其余三种模式）
};
```

读这棵树时最容易搞混的三件事：

**（1）`children` 是 `std::vector`，按源码顺序。** 和 `attrs` 不一样 ——
属性是 `std::map`（顺序不保证，见 §5），子元素是按出现顺序排的，
所以 demo 里 `root.children` 出来就是 `config` / `func` / `class`。

**（2）`text` 里的换行、缩进原样保留。** 只有**尾部**空白会被去掉（§6.9）。
demo 最后两行直接把 `<func>` 的 `text` 打印出来，换行就真的换行了 ——
如果想在一行里显示，得自己把 `\n` 换成 `\n` 两个字符。

**（3）按名字找，别用下标。** demo 为了短写了 `root.children[2]` / `[1]`。
一个够用的版本：

```cpp
const STML::Element* find(const STML::Element& parent,
                          u16string_view tagName) {
  for (const auto& c : parent.children) {
    if (c.tagName == tagName) return &c;
  }
  return nullptr;   // 别忘了：没找到很正常，不是错误
}
```

**字符串全是 `u16string_view`**（§6.10），打印前记得转 UTF-8：

```cpp
cout << UTF::Utf16ToUtf8(e.tagName);   // <stope/utf.hpp>
```

---

## 5. 属性

demo 没有打印属性，但回调里就用到了 `attrs`。关于这张 `std::map`，三件事：

**（1）可以没有值。** `<func name="myFunc" stope>` 里的 `stope` 存成
`attrs["stope"] = ""` —— 空串，不是布尔、也不是别的哨兵值。
所以回调里用 `attrs.find(u"stope") != attrs.end()` 判断"有没有这个属性"，
**不能**用 `attrs[u"stope"]` 去判断（它是 `map::operator[]`，名字不存在会插入一项）。

**（2）`<a x>` 和 `<a x="">` 拿到的东西一模一样** —— 都是空串，`Element` 上没有任何
别的信息能让你把两者区分开。如果"写了这个属性"和"属性值是空串"对你来说是两件事，
STML 帮不了你，得换一种编码方式（比如写 `<a x="1"/>`）。

**（3）迭代顺序是键的字典序，不是源码顺序。** 实测 `<p id="1" name="x" flag/>`：

```
flag=[""]
id=["1"]
name=["x"]
```

源码里写的是 `id` → `name` → `flag`，迭代出来是字典序。这是契约 TD-2：
**两侧实现都不保证源码顺序**。需要源码顺序就自己按字节在原文里定位。

取值范围的细节见 §6.8。

---

## 6. 语法注意事项

这一节是写 STML 文档时最容易踩的地方，每条都是实测过的。
（demo 里没有演示这些，因为它们会把 demo 变成一堆报错样例。）

下面的例子统一用最简的写法：`<p>` 代表"一个被判成 `Text` 模式的元素"，
`<sto>` 代表"一个被判成 `Stope` 模式的元素"，`<class>` 代表"一个被判成
`Xml` 模式、装子元素的元素"。名字本身不重要，见 §0。

### 6.1 内容模式选错 → `expected "<" or "</". `

`Xml` 模式的元素只能装子元素，**任何裸文本都是错误**。写了 `<tree>hello</tree>`
而回调返回 `Xml`，会得到：

```
line 1: expected "<" or "</".
```

反过来，本该有子元素的标签如果被判成 `Text`，子元素会连 `<` 一起被当成文本内容
（`children` 是空的），而且**不报错** —— 这种静默的错位比上面的报错更难查。

### 6.2 没有字符实体

STML 不认识 `&amp;` `&lt;` 这些东西，它们就是字面文本。
需要 `<` 就**直接写** `<` —— 因为它只有紧跟 `/`（构成 `</`）时才算标签终点，
孤立的 `<` 什么都不是（见下一条）。

### 6.3 `<` 不是标签起点，`</` 才是

`Text` / `Nevext` / `Stope` 三种状态都是一路吃到 `</` 为止。所以：

```xml
<p>a < b</p>          ← text 是 `a < b`
```

`<func>` 里写 `while i < argc {` 也一样安全。**别把 STML 当 XML 读**，
这里不需要（也不能用）转义。

### 6.4 `<!-- -->` 只在 `Xml` 状态是注释

这是 §6.3 的直接推论，`p` / `sto` / `nev` 的内容里 `<!--` 就只是普通字符。
实测：

| 输入 | 结果 |
| --- | --- |
| `<a><!-- hi --><b/></a>` | 注释被跳过，`a` 有一个子元素 `b` |
| `<a x="1" <!-- hi --> y="2"/>` | **连属性之间都能插注释**，两个属性都正常 |
| `<p>a <!-- b --></p>` | text 是 `a <!-- b -->`，**注释原样留在文本里** |
| `<a><!-- hi </a>` | 注释没闭合 → 吃掉剩余全部输入 → `expected "<" or "</". ` |

最后一条值得单独说：未闭合的注释不会报"注释没关"，它会一路吃到输入末尾，
然后表现为"文档缺了东西"。排查时顺手确认一下 `-->` 有没有写。

### 6.5 标签名不含 `.`

标签名的字符集跟 XML 不一样：首字符 `[a-zA-Z_:]`，后续 `[a-zA-Z0-9_:-]`。
注意**没有 `.`**，所以 `<my.mod/>` 是不合法的，会报
`expected ">" or "/>" or attribute. `。`<my-tag:x_1/>` 是合法的。

### 6.6 `children` 和 `text` 互斥

回调返回什么就只有什么：`Xml` → 只有 `children`，其余三种 → 只有 `text`。
两者不会同时出现，所以遍历时可以放心地写 `if (!e.text.empty()) … else for (…children)`。

### 6.7 顶层只解析一个元素

`Parse()` 只解析一个根。`<a/><b/>` 的结果是 `root` 为 `<a/>`，
`<b/>` **被静默忽略，不报错**。整份文档必须有一个单一的根元素。

### 6.8 属性值的取值规则（比想象中简单，也因此更严格）

Xml 属性串**不做任何转义**：`scanString` 一路找到下一个同种引号为止。实测：

| 输入 | 结果 |
| --- | --- |
| `<a x="a>b"/>` | `x` = `a>b`（`>` 无影响） |
| `<a x="a<b"/>` | `x` = `a<b`（`<` 也无影响） |
| `<a x='sq'/>` | 单引号一样用，值不含引号 |
| `<a x="a\"b"/>` | ❌ `x` = `a\`，后面的 `b` 被当成另一个无值属性，然后报错 |
| `<a x="1" />` | 合法，`/>` 前的空格不影响自闭合 |
| `<property name="name" />` | demo 里就是这么写的，正常解析成自闭合元素 |

倒数第二行是关键：**属性值里没法写引号**，因为 `\` 不是转义符。
要放引号就换另一种引号（`"He said 'hi'"`）。

### 6.9 三种代码段的引号规则各不相同

同样是元素里的一整段文本，交给不同的扫描器，`</` 的躲避规则不一样：

| 状态 | 双引号 | 单引号 | 注释 | 实例（实测通过） |
| --- | --- | --- | --- | --- |
| `Text` | 无特殊含义 | 无特殊含义 | 无 | `<p>a < b</p>` |
| `Nevext` | 字符串，**支持转义** | 字符串，**支持转义** | `//`、`/* */` | `<nev>x "a</b";</nev>` → 整段拿到 |
| `Stope` | 字符串，支持转义 | **BinArr 字面量，不转义** | `//`、`/* */` | `<sto>let a = 1; // hi` 换行 `return a;</sto>` → 整段拿到 |

三者都能让例子里的 `</` **不被当成结束标签**（要么因为它在字符串里，要么因为它
压根不存在）。所以代码里放心写小于号、放心写 `"a</b"`。

**尾部空白：** `text` 结尾的空白会被去掉（`trimTrailingWs`），开头的不算
（那是要处理的空格会被词法器的 `skipWs` 吃掉）。中间的换行和缩进**一律保留**。

### 6.10 `Element` 一份字符串都不拥有

`tagName` / `attrs` 的键值 / `text` 全是 `u16string_view`，指向**输入缓冲**。
这决定了两条硬约束：

1. **输入必须活得比这棵树久。** 典型事故是把源串写在某个函数的局部变量里、
   返回 `Element` —— 函数一回来整棵树全是悬垂引用。demo 里 `doc` 和 `root`
   都在 `main` 里，同生命周期，所以没事。
2. **别把输入当临时串用。** 需要长期持有这棵树，就把源串也长期持有
   （`std::shared_ptr<const u16string>` 之类），或者先把需要的文本拷成
   `std::u16string` 再存 —— 只拷 `Element` 是没用的。

### 6.11 行号：`\n` 才计数，`\r` 不计数

`Element::line` 是 `<` 所在的物理行（**起始行**，不是结束行）。
CRLF 和 LF 两种文件得到相同的行号。跨行的标签也没问题：

```xml
<a
  x="1"
>
<b/>
</a>
```

`<a>` 是 `L1`，`<b/>` 是 `L4`。

### 6.12 错误不抛、不停、只累加

`Parse()` 出错后**继续往下走**（除了少数提前 `return` 的分支），
所以 `parser.errors` 里可能有一串错误，`root` 是半棵树。错误处理要自己写：

```cpp
Result r = parser.Parse(root, stateFunc);
if (r != Result::Success) { /* 处理 parser.errors 与 lexer.errors */ }
```

别指望用异常捕获 —— STML 一个都不抛，能判断成败的只有返回值和 `errors`。

---

## 7. 最小骨架

把本文的内容压成一份可以复制走的文件（demo 的精简版 + 错误检查 + 递归打印）：

```cpp
// g++ -std=c++20 -Icpp/include demo.cpp cpp/build/libstope.a
#include <iostream>
#include <map>
#include <string>
#include <string_view>

#include <stope/stml_lexer.hpp>
#include <stope/stml_parser.hpp>
#include <stope/utf.hpp>

using namespace std;
using namespace Stope;

// 回调必须无捕获：LexerStateFunc 是裸函数指针。
static STML::LexerState stateFunc(u16string_view tag,
                                  map<u16string_view, u16string_view> attrs) {
  if (tag == u"config") return STML::LexerState::Nevext;
  if (attrs.find(u"stope") != attrs.end()) return STML::LexerState::Stope;
  return STML::LexerState::Xml;
}

static void walk(const STML::Element& e, int depth) {
  const string pad(size_t(2) * depth, ' ');
  cout << pad << "<" << UTF::Utf16ToUtf8(e.tagName);
  for (const auto& [k, v] : e.attrs) {
    cout << " " << UTF::Utf16ToUtf8(k) << "=\"" << UTF::Utf16ToUtf8(v) << "\"";
  }
  cout << (e.selfClosing ? "/>" : ">") << " @L" << e.line << "\n";
  if (e.selfClosing) return;
  if (!e.text.empty()) cout << pad << "  [" << UTF::Utf16ToUtf8(e.text) << "]\n";
  for (const auto& c : e.children) walk(c, depth + 1);
  cout << pad << "</" << UTF::Utf16ToUtf8(e.tagName) << ">\n";
}

int main() {
  u16string src =
      u"<stml><config>windowSize 1280, 720</config>"
      u"<func stope>let a = 1; return a;</func></stml>";
  STML::Element root;
  STML::Lexer lexer(src);
  STML::Parser parser(lexer);
  Result r = parser.Parse(root, stateFunc);
  for (const auto& e : parser.errors) cout << "parser: " << e << "\n";
  for (const auto& e : lexer.errors) cout << "lexer:  " << e << "\n";
  if (r != Result::Success) return 1;
  walk(root, 0);
  return 0;
}
```

真实输出：

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

`src` 写在 `main` 里、和 `root` 同生命周期 —— 这是 §6.10 的要求，
把它挪到某个返回 `Element` 的函数里就会踩坑。

---

## 8. 排错表

| 现象 | 原因 | 去哪 |
| --- | --- | --- |
| 报错说 `cannot convert '<lambda...>' to LexerStateFunc` | 回调 lambda 带了捕获 | §2 |
| `expected "<" or "</". ` | 内容模式选成了 `Xml`，但里面有裸文本 | §6.1 |
| `expected ">" or "/>" or attribute. ` | 属性值里有引号，或标签名含 `.` | §6.5、§6.8 |
| `expected tag name. ` | `<` 后面没紧跟合法标签名 | §6.5 |
| `tag name mismatch. ` | 起始标签与结束标签不一致 | — |
| 预期有子元素，结果 `children` 是空的 | 回调把它判成了某种文本模式 | §6.1 |
| 纯文本元素的文本里出现了 `<!-- -->` | 注释只在 `Xml` 状态生效 | §6.4 |
| 属性顺序跟源码对不上 | `attrs` 是 `std::map`，按键字典序迭代 | §5 |
| 用下标取到的元素不是想要的那个 | `children` 变了；按名字找 | §4 |
| 打印出来的内容有乱码 / 崩溃 | 输入先于树析构，view 悬垂了 | §6.10 |
| 文档后半段凭空消失 | 只解析一个顶层元素，或注释没闭合 | §6.7、§6.4 |
| 想执行 `<func>` 里的 Stope 代码 | Parser 不管这些，把 `text` 交给 `Stope::Lexer` | `quick-start.md`、`demo01` |

---

## 9. 相关文件

| 文件 | 讲什么 |
| --- | --- |
| `include/stope/stml_lexer.hpp` | 12 种 TokenType、4 种 `LexerState`、状态交还约定 |
| `include/stope/stml_parser.hpp` | `Element` 六个字段、`LexerStateFunc`、`Parser` |
| `include/stope/core.hpp` | 聚合头，demo 用它一次拿到全部公共头 |
| `src/stml_lexer.cpp` | 四种状态的扫描实现，`<!--` 只在 Xml 生效的那一行就在这 |
| `src/stml_parser.cpp` | 属性循环为什么"每个分支自己推进"（文件头注释写清楚了） |
| `demo/02-stml.cpp` | 本文讲的 demo，目标 `demo02`；**只解析，不编译不执行** |
| `test/test_stml_parser.cpp`（59 用例） | 语法侧断言，用例编号 PA / PB / PC / PE / PF / PH / PL |
| `test/test_stml_lexer.cpp`（62 用例） | 词法侧断言，用例编号 SE / SL / SN / SP / SR / SS / ST / SW / SX |
| `stml_test_plan.md`（本目录） | C++ 侧的实现笔记与缺陷编号 TD-xx |
| `../../docs/zh-cn/stml-test-plan.md` | 跨实现的行为契约：什么是对的（C++ 与 GDScript 两侧都按它验证） |
