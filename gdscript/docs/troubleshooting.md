# GDScript 实现 · 排错速查

> 查「**程序报错了**该改哪里」：拿到一条错误串，先在这里定位阶段和原因。
> 测试跑不起来、golden 对不上 → [`testing.md`](testing.md) §6；每个 API 的签名 →
> [`usage.md`](usage.md)；文案本身属于跨实现契约，以
> [`docs/zh-cn/`](../../docs/zh-cn/) 下四份 `*-test-plan.md` 为准。

## 0. 先认清四件事

| # | 事实 | 后果 |
| --- | --- | --- |
| 1 | **不抛异常**，错误只往 `errors` 里追加 | 不看 `errors` 不会崩，但会拿着错结果继续跑 |
| 2 | **五个阶段各记各的账** | 只看 `compiler.errors` 会漏掉词法 / 语法错 |
| 3 | **两种格式** | 前四个阶段是 `line N: msg`；执行器是 `i OpName: msg`（`i` 是指令下标） |
| 4 | **`StopeResult.Success == 0`** | `if rc:` 判反，成功被当成失败 |

| 阶段 | 账本 | 格式 |
| --- | --- | --- |
| 词法 | `lexer.errors` | `line N: msg` |
| 语法 | `parser.errors`（**不含**词法错误） | `line N: msg` |
| 编译 | `compiler.errors` | `line N: msg` |
| STML | `lx.errors` **+** `p.errors`（两份都要看） | `line N: msg` |
| 执行 | `state.errors` | `i OpName: msg` |

铁律：**某一步 `errors` 非空，就别把结果交给下一步**。语法出错时 AST 里可能有 `null`
子节点（深度超限路径），编译出错时 `program` 已被清空。

## 1. 词法（`lexer.errors`）

| 文案 | 触发 | 怎么办 |
| --- | --- | --- |
| `unknown token. ` | 出现词法不认识的字符（`@`、`$`、中文标点） | 该字符被消费 1 个码元后继续扫；把它改成合法 token |
| `invalid integer. ` | `0x` 后没数字、`0b2`、超出 int64 | 查进制前缀与位数 |
| `invalid float. ` | `1e` 后没数字、指数绝对值 > 308、结果为 inf / nan | 同上 |
| `unclosed string literal. ` | `"` 没闭合（字符串跨行**不**累加行号） | 补引号；`parsed` 截断在报错处 |
| `invalid escape character. ` | `\q` 之类 | 只有 `\\ \" \' \b \f \n \r \t \v` 合法 |
| `unclosed binary array. ` | `'...'` 没闭合 | 补 `'`；`'` 里的内容**不转义** |
| `unclosed identifier. ` | 标识符以 `:` 收尾（`a:`、`a : = 1`） | `:` 后面必须紧跟标识符字符 |

## 2. 语法（`parser.errors`）

| 文案 | 触发 | 怎么办 |
| --- | --- | --- |
| `expected ";" in let statement. ` 等 | 语句末尾漏分号 | 补 `;`（Stope 的 `;` 不可省）。同一族的还有 `in export / return / break / continue statement`、`at end of assign statement` |
| `expected "}" in if statement. ` 等 | 块没闭合，或 `if` / `while` 少了花括号 | 同族：`at end of block statement`、`at end of while statement`、`expected "{" in if statement`、`of elif`、`after else`、`in while statement` |
| `expected ";" or "=". ` | 表达式后面既不是 `;` 也不是 `=` | 典型：两条语句挤在一行，漏了分号 |
| `expected ")". ` / `expected "]". ` | 括号 / 方括号没配对 | 报错点**不推进**，不会吞掉后续 token |
| `no prefix parse function for token type. ` | 该位置不该出现 token（`let a = ;`、`1 + ;`） | 返回裸 `Expr`（形状串为 `Err(行号)`），解析继续 |
| `no infix parse function for token type. ` | 两个表达式直接挨在一起 | 同上 |
| `nesting too deep (max 256). ` | 嵌套超过 `max_depth` | 只报这一条并停止解析；已解析的语句保留在 `prog.stmts`，**`errors` 非空就别编译** |
| `unexpected "}" at top level. ` | 顶层多一个 `}` | 检查块配对 |
| `expected identifier after "let". ` | `let = 1;` | `let` 后面必须是标识符 |
| `expected "(" after custom opcode. ` | `myop 1;` 少了括号 | 自定义指令的括号不可省：`myop(1);` |

## 3. 编译器（`compiler.errors`）

| 文案 | 触发 | 怎么办 |
| --- | --- | --- |
| `duplicate declaration of 'x'. ` | 同一作用域重复 `let` | 改名，或换一层作用域 |
| `duplicate export of "x". ` | 同名字重复 `export` | 同上 |
| `"export" can only be used at top scope. ` | 块内 `export` | 挪到顶层 |
| `cannot use "break" outside of a loop. ` | 循环外 `break` / `continue` | 检查块结构 |
| `undefined custom opcode "x". ` | **Parser 拿到了 config、Compiler 没拿到**，或名字拼错 | 两处都要传同一份 `CustomOpcodeConfig`，见 [usage.md](usage.md) §7 |
| `custom opcode "x" expected N args, but got M. ` | 定长指令实参个数不符 | 报错但**仍然发指令**；改调用处 |
| `compile output too large: index exceeds int16. ` | 变量槽位超过 32767 | 减局部变量、拆块 |
| `compile output too large: jump target exceeds int16. ` | 跳转目标超过 32767 | 拆小循环 / 条件块 |

## 4. STML（`lx.errors` + `p.errors`，两份都要看）

| 文案 | 触发 | 怎么办 |
| --- | --- | --- |
| `expected "<" or "</". ` | 回调把元素判成了 `Xml`，但内容里有裸文本 | **最常撞的一条**：给这个标签返回 `Text` / `Nevext` / `Stope` |
| `expected element content. ` | 回调判成了文本模式，但元素是空的（`<c></c>`） | 空元素别返回文本模式，返回 `Xml` |
| `expected ">" or "/>" or attribute. ` | 标签名含 `.`（会被切成 Word + `.`），或属性值里的引号**不转义**导致字符串提前收尾 | 标签名只允许 `[A-Za-z_:][A-Za-z0-9_:-]*`；属性值里别放引号 |
| `expected tag name. ` | `<` 后面没紧跟合法标签名 | 同上 |
| `tag name mismatch. ` | 起止标签不一致 | 检查嵌套 |
| `expected "<". ` | 顶层不是元素 | 文档必须以元素开头 |
| `expected string. ` | 属性值不是引号串 | 属性要么不带值，要么写 `"..."` / `'...'` |
| `unexpected character. ` | `Xml` 态遇到非法字符 | 消费 1 个字符后继续；改成合法字符 |
| `unexpected lexer state N. ` | 回调返回了非法的状态值 | 只能用 `STMLLexer.State` 的四个值 |
| `unclosed string literal`（**没有句点**） | STML **Xml 属性串**没闭合 | 补引号。它会把剩余输入全部吃掉，后面的报错都是连锁的。这句文案与 C++ 逐字一致，别"顺手"补句点 |
| `unclosed string literal. `（**有句点**） | STML **代码段**（Nevext / Stope）里的引号没闭合 | 补引号；行号取的是**引号开始**那一行，不是输入末尾 |

## 5. 执行器（`state.errors`）

格式是 `i OpName: msg`，**带指令名**。别拿它跟 C++ 的 `i: msg` 逐字节比 —— VM 不是标准。

| 文案 | 触发 | 怎么办 |
| --- | --- | --- |
| `"Call" can only call a function. ` | 被调的值不是 `Callable`（忘了把宿主函数填进变量槽） | `state.variables[program.exports['fmt:println']] = Callable(host, 'println')` |
| `"Div" division by zero. ` / `"IDiv" …` / `"Mod" …` | 整数除零（**两侧都是整数**才拦；任一侧是浮点走 IEEE，得 `inf` / `nan`） | 除法前自己判 0 —— 这类现在会进 `errors`，不再打断脚本 |
| `"Add" can only operate on numbers, strings or bin arrays. ` | 两侧类型对不上（如 `1 + "a"`、`"a" + 1`） | Stope 不做隐式转换，显式转成同一类型 |
| `index out of range. ` / `index must be integer. ` | `a[5]` 越界 / 下标不是整数 | 检查容器长度与下标类型 |
| `no implement for key num != 1. ` / `no implement for container type. ` | 多维下标 / 对非容器取下标 | 参考实现的已知简化，见 [usage.md](usage.md) §9 |
| `0 Assign: no implement. ` | `Assign` 左侧不是变量槽位 | 编译器产物不对，别在 VM 里兜底 |
| `0 Custom33: msg` | 自定义指令处理函数里 `state.error(...)` | 正常报错。指令名印成 `Custom<N>`（枚举里没有这个编号） |

## 6. 不进 `errors` 的报错（只在 Godot 控制台）

这几条是 **GDScript 运行期错误**：`state.errors` 里看不到，`run()` 还会照常返回。

| 控制台报错 | 原因 | 怎么办 |
| --- | --- | --- |
| `Out of bounds get index '33'` on `Array[Callable]` | `Api.op_map` 只有 33 项，没给自定义编号扩表 | `api.op_map.resize(编号 + 1)`，见 [usage.md](usage.md) §7.1 |
| `Attempt to call function 'null::null (Callable)'` | 表扩了但那一格没填处理函数 | 33…N-1 全填成明确报错的 handler |
| `ERROR: Stack underflow! (Engine Bug)` | 把 `max_depth` 调到 400+ 后跑深嵌套 | 保持默认 256 —— GD 每层吃 2 个栈帧，硬墙约 500 |
| `Identifier "StopeLexer" not declared in the current scope` | 全局类缓存过期 | `godot --import`，见 [testing.md](testing.md) §1 |

> 这一类的共同点是：**出错的函数当场中止并返回默认值**（`bool` 是 `false`），调用方继续跑。
> 所以「`run()` 返回 `false` 但 `errors` 是空的」，八成属于这一类。

## 7. 五条「像 bug，其实不是」

1. **`attrs` 顺序不保证** —— `Dictionary` 是插入序，C++ 是 `std::map` 字典序；要稳定就自己排序。
2. **顶层只解析一个元素** —— 根之后的输入被忽略。
3. **元素内文本只有一段** —— `children` 与 `text` 互斥，不拼接。
4. **标识符的 `literal` 带 `:`** —— `a : b` 会被拼成规范形式 `a:b`。
5. **字面量形态看不到类型错** —— `-true` 已被常量折叠成 `Int(-1)`，同样的错只在变量形态
   （`let x = true; -x;`）出现。

## 8. 相关

| 想看 | 去哪 |
| --- | --- |
| 每个 API 的签名与语义 | [usage.md](usage.md) |
| 测试跑不起来 / 数据对不上 | [testing.md](testing.md) §6 |
| GDScript 语言坑与代码约定 | [gdscript-notes.md](gdscript-notes.md) |
| 错误文案的跨实现契约 | [../../docs/zh-cn/](../../docs/zh-cn/) 下四份 `*-test-plan.md` |
| 从 C++ 侧过来，先看哪份 | [README.md](README.md) §7 |
