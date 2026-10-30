# Stope —— Python 实现

Stope 语言的 Python 实现：**词法 / 语法 / 编译器 / STML / 参考执行器**五块齐全，与
`cpp/`（权威实现）、`gdscript/`、`nodejs/`、`csharp/` 四套实现逐项对齐。

- **零第三方依赖**：只用标准库。没有 `requirements.txt`，`pip install` 一步都不需要。
- **只支持 Python 3.9+**（用到 `list[dict]` 这类内建泛型注解；实测 3.14.9）。
- **命名跟 C++ 走，但方法名按 Python 惯例用 snake_case**：`next_token` / `parse_program` /
  `compile` / `disasm` / `run` / `step`，与 `cpp/include/stope/*.hpp` 逐名对应
  （`ParseProgram` ↔ `parse_program`）。类名保持 PascalCase，与头文件一致。

## 快速上手

```bash
# 在仓库根目录下：
python python/tests/run_tests.py            # 跑测试（3215 条断言）
python python/demo/01-quick-start.py        # 编译 + 运行一段 Stope 代码
python python/demo/02-stml.py               # 只解析一份 STML 文档
python python/demo/03-custom-opcode.py      # 只编译 + 反汇编（自定义指令）
```

测试与 demo 都**不需要 C++ 工具链**：期望值读的是入库的 `gdscript/test/data/*.txt`
（C++ 探针 dump 出来的唯一真源），本实现不复制第二份。

## 目录

```
python/
├── stope/                      # 库（一个普通包，没有打包配置）
│   ├── common.py               # Result 返回码 + int64/IEEE 数值助手（最容易踩的都在这里）
│   ├── token.py / lexer.py     # 词法：数字 / 标识符（含 my:add 命名空间）/ 字符串 / 二进制数组
│   ├── opcode.py               # 33 条内置指令 + CustomOpcodeConfig
│   ├── ast.py                  # 28 种节点 + 形状串序列化（shape_prog / shape_stmt / shape_expr）
│   ├── ast_visitor.py          # 表驱动遍历骨架（子类重写 on_visit_xxx）
│   ├── parser.py               # Pratt 语法分析 + 256 层嵌套上限
│   ├── binarr_parser.py        # '...' 里那段字节的内容解析
│   ├── expr_optim.py           # 常量折叠（单节点变换，不递归）
│   ├── program.py              # 指令流 + 常量池 + 变量表
│   ├── compiler.py             # AST -> Program（作用域 / 变量槽回收 / 跳转回填）
│   ├── debug.py                # disasm：人读的反汇编
│   ├── basic_vm.py             # 参考执行器（不是标准，见下）
│   ├── format.py               # esc / %g / 字节十六进制，跨实现逐字节一致
│   ├── stml.py                 # STML 的 Element / Token / 四态
│   ├── stml_lexer.py           # STML 四态词法器
│   └── stml_parser.py          # STML 语法器
├── tests/                      # 八组断言 + golden 读取 + 极简 Report（不用 pytest）
├── demo/                       # 三个可运行示例（教用法，输出不追求跨实现逐字节相同）
└── docs/                       # quick-start / usage / stml / custom-opcode / testing
```

**没做成 pip 包**（没有 `pyproject.toml`）：这套实现的价值是「五份实现对着看」，
不是发布。`tests/run_tests.py` 与三个 demo 都在开头把 `python/` 插进 `sys.path`，
所以仓库里直接跑就行；真要装，`pip install -e python/` 之前得先补打包配置。

## 与另外四套实现的关系

C++ 是**权威实现**，出现分歧时以 C++ 的实测行为为准。本实现的做法是：

- **期望值不手写**：全部由 `gdscript/test/data/` 的 golden 数据驱动
  （`golden_lex.txt` 147 条、`golden.txt` 195 条、`golden_binarr.txt` 86 条、
  `golden_disasm.txt` 12 条、`golden_stml.txt` 121 条）。改行为时先重生成数据：
  `cmake --build cpp/build --target gen-golden`。
- **类型映射**（Python 的 `int` 是无限精度，这份对照最值得记住）：

  | Stope 值 | C++ | Python | 备注 |
  | --- | --- | --- | --- |
  | 整数 | `long long` | `int` | 语义是 int64：写进 `Program` 前一律过 `wrap64()` 回绕 |
  | 浮点 | `double` | `float` | C++ 的 IEEE 行为靠 `common.fdiv/fmod/trunc/fpow` 兜住 |
  | 字符串 | `std::u16string` | `str` | **码点**，不是码元 —— 取下标要自己转 UTF-16（见下） |
  | 二进制数组 | `std::vector<char>` | `bytes` | 常量池按**逐字节**去重 |
  | 布尔 | 无（压整数 1/0） | 无（压 `1`/`0`） | 宿主函数返回 `bool` 时归一成整数 |
  | 宿主函数 | `HostFunction` 值 | 可调用对象 | 参数整包进来（`fn(argv)`），自己拆 |

- **`int` 的四个陷阱**，全在 `common.py`，别绕过它直接用运算符：

  | 想干的事 | 直接写会怎样 | 必须用 |
  | --- | --- | --- |
  | int64 回绕 | `2**64` 得天文数字 | `wrap64(v)` |
  | 向零取整的整除 | `-7 // 2` 得 `-4`（向下取整） | `int_div(-7, 2)` → `-3` |
  | 向零取整的余数 | `-7 % 2` 得 `1`（符号跟除数） | `int_mod(-7, 2)` → `-1` |
  | 快速幂 | `2 ** 64` 是精确大数 | `int_pow(2, 64)` → `0`（回绕） |

- **`float` 的四个陷阱**（C++ 走 IEEE，Python 抛异常或换了语义）：

  | 表达式 | C++ | Python 直接写 | 必须用 |
  | --- | --- | --- | --- |
  | `1.0 / 0` | `inf` | 抛 `ZeroDivisionError` | `fdiv(1.0, 0.0)` |
  | `1.0 % 0` | `nan` | 抛 `ZeroDivisionError` | `fmod(1.0, 0.0)` |
  | `-7.0 % 2.0` | `-1.0`（`std::fmod`） | `1.0`（符号跟除数） | `fmod(-7.0, 2.0)` |
  | `(-8.0) ^ 0.5` | `nan` | `**` 返回**复数** | `fpow(-8.0, 0.5)` |
  | `inf idiv 1` | `inf` | `math.trunc(inf)` 抛 `OverflowError` | `trunc(inf)` |

  常量折叠与执行器共用这组函数 —— 同一个表达式折叠出来和执行出来的答案必须一样。

- **字符串取下标按 UTF-16 码元**：C++ 的 `u16string` 与 C# 的 `char` 都是码元，Python 的
  `str` 是码点。所以 `"😀"[0]` 在 Python 里是 `128512`，而 Stope 要的是高位代理 `55357`。
  `basic_vm` 里先 `encode("utf-16-le", "surrogatepass")` 再取两字节。测试 `V-15g` 锁着这条。

## 测试

```
[1/8] 词法（golden_lex.txt）                        588 条
[2/8] 二进制数组 + 常量折叠（golden_binarr.txt）       87 条
[3/8] 语法（golden.txt）                           1171 条
[4/8] 编译器（golden.txt）                          585 条
[5/8] 嵌套深度上限                                    21 条
[6/8] 反汇编（golden_disasm.txt）                     17 条
[7/8] STML（stml_cases.txt + golden_stml.txt）      604 条
[8/8] 参考执行器                                     142 条
-------------------------------------------------------
全部通过：共 3215 条断言
```

测试跑器是**普通脚本**，不是 pytest：`tests/report.py` 只有「比一下、记一笔」，
`tests/run_tests.py` 依次跑八组。输出格式与 GDScript 的 `run_tests.gd`、C# 的 `Runner`
刻意做成同一副样子，方便几条命令横向对照。

> 条数口径：这 3215 是**断言条数**（与 GD 3153 / C# 3154 同口径）。nodejs 的 780 是
> **用例（`it`）数**，别横向比。

八组怎么来的、golden 数据的转义约定、加一条用例的流程，见
[`docs/testing.md`](docs/testing.md)。

## 标准范围与内置执行器

Stope 只规定三件事：**语言**、**STML**、**编译器的产物 `Program`**。

**不规定虚拟机的标准** —— `basic_vm.py` 只是**内置的基础虚拟机**（会一直维护，接口不会
随意调整，但不属于标准），拿到 `Program` 之后怎么执行、值怎么表示、栈怎么布局、宿主函数
怎么调，全由实现者决定。它**不支持**：

| 内置执行器支持 | 不支持 |
| --- | --- |
| 33 条内置指令、变量槽与栈、`exports`、宿主函数、`argc`/`args[i]`、单步 `step()` | **自定义指令**：`Api.op_map` 默认只有内置 33 项。与另外四份不同，Python 侧提供了 `Api.set_opcode(n, fn)`：它会**把中间补齐**再装上你的处理函数（跳号注册不会留空洞），所以自定义指令能跑 —— 但这是本实现的方便，不是标准 |
| 空、整数、浮点、字符串、二进制数组、宿主函数（布尔 = 整数 1/0） | **自定义数据类型**：不能注册新值类型，没有对象 / 结构体 / 类 |

自己写执行器见 [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md)。

## 文档导览

| 想看 | 去哪 |
| --- | --- |
| 四步上手 + 可复制骨架 + 常见错误 | [`docs/quick-start.md`](docs/quick-start.md) |
| 每个类 / 方法 / 字段 / 返回码 | [`docs/usage.md`](docs/usage.md) |
| STML 怎么用（逐段讲 `demo/02-stml.py`） | [`docs/stml.md`](docs/stml.md) |
| 自定义指令（逐段讲 `demo/03-custom-opcode.py`） | [`docs/custom-opcode.md`](docs/custom-opcode.md) |
| **改实现**：测试怎么跑、数据怎么来、Python 特有的坑 | [`docs/testing.md`](docs/testing.md) |
| STML / 自定义指令的**语义权威** | [`cpp/docs/stml.md`](../cpp/docs/stml.md)、[`cpp/docs/custom-opcode.md`](../cpp/docs/custom-opcode.md) |
| 语言本身 | [`docs/zh-cn/syntax-intro.md`](../docs/zh-cn/syntax-intro.md)、[`syntax-reference.md`](../docs/zh-cn/syntax-reference.md) |
| 产物格式（指令编号 / 操作数 / 跳转） | [`cpp/docs/development.md`](../cpp/docs/development.md) |
| 虚拟机怎么写（指南，不是规范） | [`docs/zh-cn/vm-guide.md`](../docs/zh-cn/vm-guide.md) |

> 文档语言：本目录的中文文档面向「要改这份实现的人」；`docs/zh-cn/` 是五份实现共用的
> 跨实现契约。文件名一律 ASCII kebab-case。
