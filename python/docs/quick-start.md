# Python 版快速上手

照这份文档走一遍，你会得到：一份能编译、能跑、能改的宿主程序骨架，以及「哪些 API 可以
依赖、哪些只是内置示例」的分界线。

完整可运行的版本是 [`demo/01-quick-start.py`](../demo/01-quick-start.py)，本文逐段讲它。

## 0. 先分清哪些能依赖

Stope 的标准只覆盖三件事：**语言**、**STML**、**编译器的产物 `Program`**。
所以同一份 demo 里的代码有两种稳定性：

| 段落 | 用到的东西 | 稳定性 |
| --- | --- | --- |
| step 1（编译） | `Lexer` / `Parser` / `Compiler` / `Program` | **编译器接口**，相对稳定。`Program` 的编码契约（指令编号、操作数、跳转目标是指令下标）是标准的，宿主可以依赖、可以复制 |
| step 2–4（运行） | `Api` / `State` / `Arguments` | **内置的基础虚拟机，不是标准**。值的表示、栈布局、宿主函数绑定、错误上报全是实现细节，换一个执行器可以完全不长这样 |

本文把这条分界线标在每一段开头。要自己写执行器，看
[`docs/zh-cn/vm-guide.md`](../../docs/zh-cn/vm-guide.md)。

## 1. 先跑起来

```bash
python python/demo/01-quick-start.py     # 编译 + 运行：反汇编 + 求和结果
python python/demo/02-stml.py            # 只解析 STML
python python/demo/03-custom-opcode.py   # 自定义指令：只编译 + 反汇编
```

三个 demo 的输出与 C++ / GDScript / Node.js / C# **逐字节相同**（同一份源码产出同一份
字节码）。`01` 的完整输出：

```
[0]     PushId     0
[2]     PushFloat  0
[4]     Assign     
[5]     PushId     1
[7]     PushInt    0
[9]     Assign     
[10]    PushValue  1
[12]    ArgNum     
[13]    LT         
[14]    If         35
[16]    PushId     0
[18]    PushValue  0
[20]    PushValue  1
[22]    GetArg     
[23]    Add        
[24]    Assign     
[25]    PushId     1
[27]    PushValue  1
[29]    PushInt    1
[31]    Add        
[32]    Assign     
[33]    GoTo       10
[35]    PushValue  2
[37]    PushString 0
[39]    PushValue  0
[41]    Call       2
[43]    Pop        
[44]    PushValue  0
[46]    Return     1
variables:
  "" "" "fmt:println"
int consts:
  0  1
float consts:
  0
string consts:
  "结果为: "
binary array consts:
max return num: 1
required stack size: 3

[Host] 结果为: 15
result: 15
```

前一半是 `disasm_no_custom(program)` 的输出（由 step 1 打印），后一半是执行器真跑出来的。
几个读法：

- 方括号里是**指令在 `program.opcodes` 里的下标**，不是行号；带操作数的指令下一格就是
  操作数（`PushFloat 0` = 取 `float_consts[0]`）。
- `If 35` / `GoTo 10` 的操作数是**跳转目标的下标**（`while` 的回边就是 `GoTo 10`）。
- `variables:` 那行是变量槽，`""` 表示「不是导出变量、没有名字」；`fmt:println` 之所以
  出现在第 3 格，是因为源码里**没声明就用**了它，编译器把它当外部变量登记进了 `exports`。

## 2. 四步全景

```python
from stope import AST, Api, Compiler, Lexer, Parser, Program, Result, State

# 1. 编译：源码 -> Program
lexer = Lexer(src)
parser = Parser(lexer)
tree = AST.Prog()
parser.parse_program(tree)
compiler = Compiler()
program = Program()
compiler.compile(tree, program)

# 2-4. 执行：Program -> 结果（内置示例，不是标准）
state = State()
state.reset(Api(), program, args)          # args 是实现了 Arguments 的宿主对象
state.variables[program.exports["fmt:println"]] = println
state.run()
print(state.returns[0])
```

> AST 那一层的类名统一挂在 `stope.AST` 下面（`AST.Prog()`、`AST.NodeType.IntExpr`…），
> 与 C++ 的 `Stope::AST` 命名空间同构；`__init__.py` 没有把 28 个节点类逐个提到顶层。

## 3. 第一步：编译源码

> 稳定性：编译器接口。

```python
from stope import AST, Compiler, Lexer, Parser, Program, Result

src = """
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
"""

lexer = Lexer(src)
parser = Parser(lexer)          # 第二参是 CustomOpcodeConfig，可省
tree = AST.Prog()               # ⚠ 必须是具体实例，见下
parser.parse_program(tree)
for e in lexer.errors:
    print("[lex] " + e)
for e in parser.errors:
    print("[parse] " + e)

compiler = Compiler()           # 构造参同上，可省
program = Program()
rc = compiler.compile(tree, program)   # AST 与 Program 都传引用
if rc != Result.Success:
    ...
```

几个要点：

| 约定 | 内容 |
| --- | --- |
| 错误去哪 | `lexer.errors` / `parser.errors` / `compiler.errors` **三处分开**，格式都是 `line N: msg`；不抛异常 |
| 返回值 | `Result.Success == 0`。别写 `if rc:` 当成功 —— 那是「失败」 |
| 编译失败 | `compile()` 已经把 `program` 清空（`opcodes` 为空），别拿它去反汇编或执行 |
| AST 类型 | `AST.Prog()` 必须是具体实例。`ASTVisitor` 靠节点的 `node_type` 分发，传 `None`、`dict` 或自己拼的鸭子对象会让分发**静默跳过整棵树**（不报错、`stmts` 直接是空的） |
| 常量折叠 | `parser.const_folding = True`（默认）。测试里关掉它才能看到未折叠的树 |
| 顶层入口 | 现成的 `parse_program(prog)` 不用自己走 `parse_prog(prog, True, 1)` |

## 4. 第二步：装配执行器

> 稳定性：内置示例，不是标准。

```python
from stope import Api, State

api = Api()                                        # 33 条内置指令的分派表
args = MyArgs([1.0, 2.0, 3.0, 4.0, 5.0])
state = State()
state.reset(api, program, args)                    # 一次做完：清 returns/stack/errors + 开槽位
```

`reset` 会按 `program.variable_num` 把 `state.variables` 开好（C++ 侧那行必写的
`variables.resize(...)` 在这里替你做了 —— 参考实现可以少一个坑，但要知道这是它替你做的）。

实参表是宿主实现的抽象类，`args[i]` / `argc` 都落到它身上：

```python
from stope import Arguments


class MyArgs(Arguments):
    __slots__ = ("data",)

    def __init__(self, values):
        self.data = list(values)

    # 取不到就**自己报错**：state.error(...) + 返回 None，执行器立刻停在这里
    def at(self, state, index_or_key):
        if not isinstance(index_or_key, int) or isinstance(index_or_key, bool):
            state.error("index must be an integer. ")
            return None
        if index_or_key < 0 or index_or_key >= len(self.data):
            state.error("index out of range. ")
            return None
        return self.data[index_or_key]

    def num(self) -> int:
        return len(self.data)
```

⚠ `isinstance(x, int)` 对 `True` 也成立（`bool` 是 `int` 的子类），所以要像上面那样排掉
`bool`。`basic_vm.is_int` 里也是这么写的。

## 5. 第三步：绑宿主函数

> 稳定性：内置示例，不是标准。

宿主函数在产物里就是**「某个变量槽里的一个值」**（C++ 的 `Value::Type::HostFunction`）。
编译器把未声明的 `fmt:println` 当外部变量登记进 `exports`，宿主按名字取槽位填上即可：

```python
from stope import fmt_g


def fmt(v):
    if v is None:
        return "null"
    if isinstance(v, float):
        return fmt_g(v)      # 与 C 的 %g 一致：15.0 打成 "15"
    return str(v)


def println(argv):
    # 签名统一是 fn(argv) -> 值：参数**整包**进来，自己拆（对应 C++ 的 args span）
    print("[Host] " + "".join(fmt(a) for a in argv))
    return None


state.variables[program.exports["fmt:println"]] = println
```

四点：

- **槽位号由编译器分配**，不要写死数字，一律 `program.exports["名字"]`。
- 赋值要在 `reset()` **之后** —— `reset` 会重建 `variables` 列表。
- 返回 `True` / `False` 会被归一成整数 1 / 0（Stope 没有布尔值类型），见 `V-14b`。
- 名字里带 `:` 是词法器支持的命名空间写法，用来避开普通变量名。

## 6. 第四步：跑

```python
if state.run() != Result.Success:
    for e in state.errors:
        print("[vm] " + e)
    raise SystemExit(1)
print("result: " + fmt(state.returns[0]))
```

- 错误串格式是 `"<指令下标>: msg"`，下标指向**出错时**停住的那条指令。
  与 GD 的 `"<下标> <指令名>: msg"` 不同 —— 跨实现只比 `: ` 之后那一段。
- `run()` 与 `step()` 是两份独立实现（热循环里不套函数调用）；
  `while s.step() == Result.Success: ...` 与 `run()` 等价，连走的条数都一样。
  想在宿主里分帧执行就用 `step()`（`test_vm.py` 的 `V-21` 锁着两条路径一致）。
- `state.returns` 是 `return` 带回来的值列表，可能为空（程序没 return）。

值的显示要自己写（`returns` 里是 Python 对象）：

```python
def fmt(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "1" if v else "0"    # 值层面不该出现 bool，出现就是没归一
    if isinstance(v, float):
        return fmt_g(v)
    if isinstance(v, (bytes, bytearray)):
        return "[" + ",".join(str(x) for x in v) + "]"
    return str(v)
```

## 7. 最小骨架（可直接复制）

```python
import sys

from stope import Api, AST, Compiler, Lexer, Parser, Program, Result, State

src = "let a = 1; let b = 2; return a + b;"

lexer = Lexer(src)
parser = Parser(lexer)
tree = AST.Prog()
parser.parse_program(tree)

compiler = Compiler()
program = Program()
if compiler.compile(tree, program) != Result.Success:
    for e in compiler.errors:
        print(e, file=sys.stderr)
    raise SystemExit(1)

state = State()
state.reset(Api(), program)          # 不传实参表就够用
if state.run() != Result.Success:
    for e in state.errors:
        print(e, file=sys.stderr)
    raise SystemExit(1)
print(state.returns[0])              # 3
```

把 `stope` 放进 `sys.path` 的方式（仓库里直接跑时）：

```python
# 脚本位于 python/ 下设的子目录（如 python/demo/、python/tests/）：
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 脚本放在仓库根（或任何别处）：按仓库根拼
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "python"))
```

三个 demo 与 `tests/run_tests.py` 开头都是第一种写法。

## 8. Python 专属坑

| 症状 | 原因 / 做法 |
| --- | --- |
| `1.0 / 0` 抛 `ZeroDivisionError` | Python 的浮点除零**抛异常**，C++ 是 `inf`。执行器内部走 `common.fdiv`；自己写执行器时别直接写 `/` |
| `-7 // 2` 得 `-4`，`-7 % 2` 得 `1` | Python 是**向下取整**、余数符号跟除数；C++ 是向零取整、符号跟被除数。用 `common.int_div` / `int_mod` |
| `2 ** 64` 是个天文数字 | Python 的 `int` 无限精度。Stope 要 int64 回绕，用 `common.wrap64` / `int_pow` |
| `(-8.0) ** 0.5` 得到复数 | Python 的 `**` 对负底数 + 分数指数返回 `complex`。用 `common.fpow`（给 `nan`，与 C++ 一致）。**复数一路混进 `float_consts` 就再也没人发现** |
| `math.trunc(inf)` 抛 `OverflowError` | 用 `common.trunc`（对 `±inf` / `nan` 原样返回） |
| `b"ab" * -1` 得 `b""` | Python 静默给空串，C++ 报错。执行器先判负数（`V-08d` / `V-08g` 锁着） |
| `'d 1 2' * -1` 同理 | 同上 |
| `isinstance(True, int)` 是 `True` | `bool` 是 `int` 子类。判「整数」一律 `stope.basic_vm.is_int`（它排掉了 `bool`） |
| Stope 里 `true + 0` 得 `1`，Python 里 `True + 0` 得 `True` | 宿主函数返回 `bool` 会被归一成 `1`/`0`；自己拼值的时候也要注意 |
| `"😀"[0]` 得 `128512` | Python 的下标是**码点**，C++ 的 `u16string` 是**码元**（要 `55357`）。`basic_vm` 先转 UTF-16 再取 |
| 打印中文乱码 / 输出的换行与另外几份不同 | Windows 控制台默认按本地代码页编码，文本模式还会把 `\n` 变 `\r\n`。demo 开头统一 `sys.stdout.reconfigure(encoding="utf-8", newline="\n")` |
| `RecursionError: maximum recursion depth exceeded` | 深度用例要构造 600/12000 层嵌套，每层 3 个栈帧。`tests/run_tests.py` 开头 `sys.setrecursionlimit(30000)` |
| `parse_program` 之后 `tree.stmts` 是空的 | 传的是 `AST.Prog()` 吗？`ASTVisitor` 靠 `node_type` 分发，传错会静默跳过 |
| `state.variables[slot] = fn` 之后仍报 `"Call" can only call a function. ` | 槽位号写死了 / 在 `reset()` 之前赋的值（`reset` 会重建列表） |
| `api.op_map[33]` 抛 `IndexError` | 内置表只有 33 格（0–32）。自定义指令用 `api.set_opcode(33, fn)`，它会把中间补齐 |
| `b"...": bytes` 与 `'...'` 混淆 | Stope 里 `"…"` 是 **String**、`'…'` 是 **BinArr**。Python 侧分别是 `str` 与 `bytes` |
| `run_tests.py` 找不到 `gdscript/test/data` | `tests/golden.py` 从自身位置向上找仓库根。把 `python/` 单独拷出去就跑不了（数据不入包） |

## 9. 下一步

- **解析 STML 文档**：看 [`demo/02-stml.py`](../demo/02-stml.py) 与 [`stml.md`](stml.md)。
- **加自己的指令**：看 [`demo/03-custom-opcode.py`](../demo/03-custom-opcode.py) 与
  [`custom-opcode.md`](custom-opcode.md)。
- **每个 API 的签名与返回码**：看 [`usage.md`](usage.md)。
- **改实现 / 加用例**：看 [`testing.md`](testing.md)。
