# Stope —— Lua 实现

Stope 语言的 Lua 5.4 实现：**词法 / 语法 / 编译器 / STML / 参考执行器**五块齐全，与
`cpp/`（权威实现）、`gdscript/`、`nodejs/`、`csharp/`、`python/` 八套实现逐项对齐。

- **零第三方依赖**：只用 Lua 5.4 标准库（连官方 `utf8` 库都没用上 —— UTF-8 ↔ UTF-16
  编解码自写在 `stope/utf.lua`，对非法序列与 lone surrogate 的处理更可控）。没有
  LuaRocks 包，`require` 一步到位。
- **只支持 Lua 5.4+**（依赖整数子类型：int64 原生回绕、`math.type` 区分整数与浮点）。
- **命名跟 C++ 走，方法名用 snake_case**：`next_token` / `parse_program` / `compile` /
  `disasm` / `run` / `step`，与 `cpp/include/stope/*.hpp` 逐名对应（`ParseProgram` ↔
  `parse_program`）。模块名与 `python/stope/*.py` 一一对应。

## 快速上手

```bash
# 在仓库任意目录下（脚本自定位，任何 cwd 都能跑）：
lua lua/tests/run_tests.lua               # 跑测试（golden 驱动 + 自写断言）
lua lua/demo/01-quick-start.lua           # 编译 + 运行一段 Stope 代码
lua lua/demo/02-stml.lua                  # 只解析一份 STML 文档
lua lua/demo/03-custom-opcode.lua         # 只编译 + 反汇编（自定义指令）
lua lua/demo/04-pre-export.lua            # 预导出：宿主先塞形参，再编译函数体
lua lua/demo/05-object.lua                # 宿主侧面向对象：Handle 缝 + 手动生命周期
lua lua/demo/06-gc.lua                    # 宿主侧垃圾回收：引用计数级联 + 标记清除
```

测试与 demo 都**不需要 C++ 工具链**：期望值读的是入库的 `gdscript/test/data/*.txt`
（C++ 探针 dump 出来的唯一真源），本实现不复制第二份。

五个 demo 的输出与 `python/demo/` **逐字节一致**（除行尾）。

## 目录

```
lua/
├── stope/                      # 库（一个普通目录，没有打包配置）
│   ├── common.lua              # Result 返回码 + int64/IEEE 数值助手 + esc/%g/fmt_bytes
│   ├── utf.lua                 # UTF-8 <-> UTF-16(LE) 编解码（自写，零依赖）
│   ├── token.lua / lexer.lua   # 词法：数字 / 标识符（含 my:add 命名空间）/ 字符串 / 二进制数组
│   ├── opcode.lua              # 33 条内置指令 + CustomOpcodeConfig
│   ├── ast.lua                 # 28 种节点 + 形状串序列化（shape_prog / shape_stmt / shape_expr）
│   ├── expr_optim.lua          # 常量折叠（单节点变换，不递归）
│   ├── parser.lua              # Pratt 语法分析 + 256 层嵌套上限
│   ├── binarr_parser.lua       # '...' 里那段字节的内容解析
│   ├── program.lua             # 指令流 + 常量池 + 变量表
│   ├── scope_context.lua       # 作用域 / 变量槽回收（最小堆）/ 栈深记账
│   ├── compiler.lua            # AST -> Program（跳转回填 / preExports）
│   ├── disasm.lua              # disasm：人读的反汇编
│   ├── basic_vm.lua            # 参考执行器（不是标准，见下）
│   ├── stml.lua                # STML 的 Element / Token / 四态
│   ├── stml_lexer.lua          # STML 四态词法器
│   ├── stml_parser.lua         # STML 语法器
│   └── init.lua                # 聚合导出
├── tests/                      # 八组断言 + golden 读取 + 极简 Report（不用测试框架）
├── demo/                       # 五个可运行示例（与 python/demo/ 输出逐字节一致）
└── docs/                       # quick-start、object-oriented（宿主侧面向对象）
```

## 类型映射（Lua 特有的坑，这份对照最值得记住）

| Stope 值 | C++ | Lua | 备注 |
| --- | --- | --- | --- |
| 整数 | `long long` | integer | Lua 5.4 整数**天生 int64 补码回绕**，加 / 减 / 乘 / 位运算直接写就行 |
| 浮点 | `double` | float | `^` 与 `math.fmod` 走 C 库（与 std::pow / std::fmod 一致）；边界见 `common.lua` |
| 字符串 | `std::u16string` | 包装 table + UTF-16LE 字节串 | 长度 / 下标 / 相等按**码元**；用 `str_value` / `str_bytes` 装拆 |
| 二进制数组 | `std::vector<char>` | 裸 Lua string | 常量池按**逐字节**去重 |
| 布尔 | 无（压整数 1/0） | 无（压 `1`/`0`） | 宿主函数返回 `true`/`false` 时归一成整数 |
| 宿主函数 | `HostFunction` 值 | Lua function | 参数整包进来（`fn(argv)`，argv 1 起），自己拆 |
| Null | `Value::Null` | `stope.NULL` 哨兵 | Lua 的 `nil` 不能上栈，用一个唯一 table 表示 |

- **整数除法必须走 `common.int_div` / `int_mod`**：Lua 的 `//` 与 `%` 是 **floor 语义**，
  Stope 要**向零取整**（`-7 idiv 2` 是 `-3` 不是 `-4`）。`MIN // -1` 与 `MIN % -1`
  在里面单独兜住。
- **整数幂必须走 `common.int_pow`**：Lua 的 `^` 永远返回 float；`2 ^ 64` 要整数回绕得 0。
- **浮点除零 / 取模 / 幂**：`1.0 / 0` 得 inf、`1.5 % 0` 得 nan、`(-8.0) ^ 0.5` 得 nan
  —— Lua 的原生行为与 C++ 一致，但 `math.fmod(x, 整数 0)` 会报错、
  `math.floor(2^63.0)` 会报「没有整数表示」，都由 `common.fdiv` / `fmod` / `trunc` 兜住。
  常量折叠与执行器共用这组函数 —— 同一个表达式折叠出来和执行出来的答案必须一样。
- **字符串按 UTF-16 码元**：`"😀"[0]` 要给高位代理 `55357`（C++ / C# 口径）。
  词法器在 UTF-8 字节上扫（结构字符都是 ASCII），字符串字面量内容反转义后转成
  UTF-16LE 内部表示；输出时再转回 UTF-8。

## 在 stope 中使用 nevext 的字符串

[nevext](../../nevext)（`E:\lib\nevext`）是与 stope 同作者的解析库，两者的转义表自
stope **0.5.0** 起完全一致（classic 九项 + `\uXXXX`），但**字符串的表示形态不同**，
跨界使用时要过一次转换：

| | nevext（Lua 版） | stope（本实现） |
| --- | --- | --- |
| 表示 | UTF-8 **裸字节串**（透传，无表示层） | UTF-16LE 字节串，**必须**经 `basic_vm.str_value` 包装 |
| 转义展开 | 语法层，可替换（`escape_func`） | 词法层，内置不可替换 |
| 编码假设 | 不校验，字节即字节 | `utf8_to_utf16` 假定 UTF-8，非法字节按 latin-1 兜底 |

### 两个方向的转换

```lua
local stope = require("stope")
local vm, utf = stope.basic_vm, stope.utf

-- nevext 字符串（UTF-8 字节串） -> Stope String 值：
local stope_str = vm.str_value(utf.utf8_to_utf16(nevext_str))

-- Stope String 值（VM 返回值 / exports / 常量）-> UTF-8 字节串：
local bytes = utf.utf16_to_utf8(vm.str_bytes(stope_str))
-- 先判断是不是 String 值：vm.is_str_value(v)；BinArr 是裸 Lua string，不走这里。
```

### 完整例子（nevext 解析 → 作为 Stope 值使用 → 取回）

```lua
local nevext = require("nevext")           -- E:\lib\nevext\lua\nevext\nevext.lua
local stope  = require("stope")

-- 1) nevext 侧：解析出 UTF-8 字节串
local lx = nevext.Lexer.new('greet "hello"')
local res = nevext.Parser.new(lx):parse_program()
local text = res.val[1].strings[2]         -- "hello"（UTF-8 字节串）

-- 2) 转成 Stope String 值：塞给宿主函数参数 / exports 都行
local s = stope.basic_vm.str_value(stope.utf.utf8_to_utf16(text))

-- 3) VM 里跑完后取回，转回 UTF-8 交还给 nevext 或宿主
local back = stope.utf.utf16_to_utf8(stope.basic_vm.str_bytes(s))
```

### 注意点

- **不要直接把 nevext 的字符串当 Stope 值用**：裸字节串在本实现的 VM 里是
  BinArr 的表示（At 按字节、与 String 跨类型相等恒为假），少了 `str_value`
  包装会把语义悄悄变成二进制数组。
- **编码必须真是 UTF-8**：nevext 不校验字节，`utf8_to_utf16` 对非法序列按
  latin-1 逐字节兜底（一个坏字节变成一个码元），不会报错但内容已变形。
- **代理区码点**（`\uD800`–`\uDFFF`）：stope 原样落成 lone surrogate 码元；
  跨库往返走 `utf8_to_utf16` / `utf16_to_utf8`（CESU-8 / WTF-8 形态）是保值的，
  但 nevext 各语言版对代理区码点的接受口径不一，跨实现搬运前先看对方文档。
- **开销**：转换是 O(n) 一次性分配，VM 内部全程不再转换；只有同一份串反复
  跨界才值得缓存转换结果，一次性使用可忽略。

## 测试

```
[1/8] 词法（golden_lex.txt）                        588 条（147 条用例）
[2/8] 二进制数组 + 常量折叠（golden_binarr.txt）       87 条（86 条用例）
[3/8] 语法（golden.txt）                           1345 条（224 条用例）
[4/8] 编译器（golden.txt）                          672 条（224 条用例）
[5/8] 嵌套深度上限                                    21 条
[6/8] 反汇编（golden_disasm.txt）                     17 条（12 条用例）
[7/8] STML（stml_cases.txt + golden_stml.txt）      634 条（126 条用例）
[8/8] 参考执行器                                     142 条
-------------------------------------------------------
全部通过：共 3299 条断言
```

测试跑器是**普通脚本**，不是测试框架：`tests/report.lua` 只有「比一下、记一文」，
`tests/run_tests.lua` 依次跑八组。输出格式与 Python / GDScript / C# 的跑器刻意做成
同一副样子，方便几条命令横向对照。golden 数据的转义约定照抄 `python/tests/golden.py`：
`golden.txt` / `golden_disasm.txt` 的字段解一层、`SRC` 解两层；`golden_lex.txt` 的
`SRC` 用 `unescape_lex`（多认 `\v` `\f`）、其余不解；`golden_stml.txt` 一律不解。

## 标准范围与内置执行器

Stope 只规定三件事：**语言**、**STML**、**编译器的产物 `Program`**。

**不规定虚拟机的标准** —— `basic_vm.lua` 只是**内置的基础虚拟机**（会一直维护，接口
不会随意调整，但不属于标准），拿到 `Program` 之后怎么执行、值怎么表示、栈怎么布局、
宿主函数怎么调，全由实现者决定。`run` 与 `step` 是**两份独立实现**（热循环里不套一层
函数调用），由 `test_vm.lua` 的 V-21 锁两条路径一致。

| 内置执行器支持 | 不支持 |
| --- | --- |
| 33 条内置指令、变量槽与栈、`exports`、宿主函数、`argc`/`args[i]`、单步 `step()` | **自定义指令默认无实现**：`Api.op_map` 默认只有内置 33 项；用 `Api:set_opcode(n, fn)` 装上处理函数（会把中间补齐，跳号注册不留空洞）就能跑 —— 这是本实现的方便，不是标准 |
| 空、整数、浮点、字符串、二进制数组、宿主函数（布尔 = 整数 1/0） | **自定义数据类型**：不能注册新值类型，没有对象 / 结构体 / 类 |

自己写执行器见 [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md)。

## 与另外八套实现的关系

C++ 是**权威实现**，出现分歧时以 C++ 的实测行为为准。本实现的做法与 `python/` 一致：

- **期望值不手写**：全部由 `gdscript/test/data/` 的 golden 数据驱动。改行为时先重生成
  数据：`cmake --build cpp/build --target gen-golden`。
- 拿不准的语义直接看 `cpp/src/` 对应文件（expr_optim 折叠规则、stml_lexer 四态、
  basic_vm 指令语义）。

## 文档导览

| 想看 | 去哪 |
| --- | --- |
| 四步上手 + 可复制骨架 + 常见错误 | [`docs/quick-start.md`](docs/quick-start.md) |
| 解析 STML 文档（demo 02 上手） | [`docs/stml.md`](docs/stml.md) |
| 加自定义指令（demo 03 上手，含怎么真的执行） | [`docs/custom-opcode.md`](docs/custom-opcode.md) |
| 预导出：编译前先占好槽位（`demo/04-pre-export.lua`） | [`../docs/zh-cn/pre-export.md`](../docs/zh-cn/pre-export.md) |
| **宿主侧面向对象**（demo 05）：Handle 缝 + Lua GC 与手动生命周期 | [`docs/object-oriented.md`](docs/object-oriented.md) |
| **宿主侧垃圾回收**（demo 06）：引用计数级联 + 标记清除破环，安全点根扫描 | [`docs/gc.md`](docs/gc.md)（语义权威：[`cpp/docs/gc.md`](../cpp/docs/gc.md)） |
| 每个类 / 方法 / 字段 / 返回码（Python 口径，命名一致） | [`../python/docs/usage.md`](../python/docs/usage.md) |
| STML / 自定义指令的**语义权威** | [`cpp/docs/stml.md`](../cpp/docs/stml.md)、[`cpp/docs/custom-opcode.md`](../cpp/docs/custom-opcode.md) |
| 语言本身 | [`docs/zh-cn/syntax-intro.md`](../docs/zh-cn/syntax-intro.md)、[`syntax-reference.md`](../docs/zh-cn/syntax-reference.md) |
| 虚拟机怎么写（指南，不是规范） | [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md) |
