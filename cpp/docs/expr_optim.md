# `expr_optim.hpp` 常量折叠 —— 行为说明

> 本文描述 `cpp/include/stope/expr_optim.hpp` 中 `ExpressionOptimizer::optimizeUnaryOpExpr` 与
> `optimizeBinaryOpExpr` 的**全部行为**，包括「什么情况下不折叠」。
> 文中每条规则均于 **2026-10-16** 用探针实测核对过（见 §8）；
> **2026-10-21** 改了两条规则并复核：① `null` 不再参与算术（`+ - * / idiv % ^`
> 一律不折叠，交给后端报错）；② 整数溢出**不再检查**，一律按 64 位补码回绕
> （与参考实现 `basic_vm.hpp` 对齐，见 §6）。
>
> 面向：要修改折叠规则、或要把折叠接进 `parser.hpp` 的人。
> 语言本身的语法见 `docs/zh-cn/syntax-reference.md`；AST 结构见 `ast.hpp`。

## 目录

- [1. 定位与设计原则](#1-定位与设计原则)
- [2. 调用方式与契约](#2-调用方式与契约)
- [3. 常量分类与真值规则](#3-常量分类与真值规则)
- [4. 完整行为矩阵（总表 · 可调）](#4-完整行为矩阵总表)
  - 4.1 类型代号 · 4.2 求值顺序 · 4.3 一元矩阵 · 4.4 含 null 矩阵 · 4.5 主矩阵
  - 4.6 条件例外 · 4.7 格子→代码对照 · 4.8 常见调整
  - **4.9 本项目自定的三条算术规则**（BinArr 连接 / 串重复 / Bool 当 0 或 1）
- [5. 一律不折叠的清单](#5-一律不折叠的清单)
- [6. 溢出与除零](#6-溢出与除零)
- [7. 与 GDScript 参考实现的关系](#7-与-gdscript-参考实现的关系)
- [8. 已验证用例](#8-已验证用例)
- [9. 已接入 parser（挂点 / 开关 / 影响）](#9-已接入-parser2026-10-16)
- [10. 待定与可扩展项](#10-待定与可扩展项)

---

## 1. 定位与设计原则

在**构造 AST 节点时**就地求值：把「操作数全是字面量」的子树替换成一个字面量节点。
不是独立的优化 pass——没有额外遍历，也没有 IR。

三条原则：

1. **只做单节点变换**，不递归处理子节点。折叠在子节点返回时就已完成（见 §2.2）。
2. **拿不准就一律不折叠**。不折叠永远只是「少一次优化」，不会改变程序语义；
   而错误地折叠会静默改变结果或吞掉运行期错误。
3. **折叠后的节点沿用运算符节点的 `line`**（`UnaryOpExpr::line` / `BinaryOpExpr::line`，
   后者取左操作数的行），因此折叠不会丢失报错位置。
4. **不检查整数溢出**（2026-10-21 定夺）：`+ - * / idiv % ^` 与一元 `-` 的整数结果
   按 64 位补码回绕，与参考实现 `basic_vm.hpp` 一致（§6）。「回绕」是确定的语义，
   不是 UB —— 全程用无符号运算实现。

## 2. 调用方式与契约

### 2.1 两个入口

```cpp
AST::Expr*    Optimize(AST::Expr* expr);         // 返回新指针，入参在成功折叠时被 delete
void          OptimizeInPlace(AST::Expr*& expr); // 原地替换，推荐
```

**契约**：`Optimize` 成功折叠时 `delete` 入参并返回**另一个**指针；未折叠时原样返回入参。
所以调用方**必须重新赋值**：

```cpp
e = opt.Optimize(e);        // 漏写 → e 悬垂
opt.OptimizeInPlace(e);     // 引用入参，不可能漏掉
```

`Optimize` 只分发 `UnaryOpExpr` / `BinaryOpExpr`；其它节点原样返回。`nullptr` 原样返回。

### 2.2 必须自底向上调用

因为只做单节点变换，调用点必须保证**子节点已经折叠过**。有两个可选挂点：

| 挂点 | 写法 | 特点 |
| --- | --- | --- |
| **`parseUnaryOpExpr` / `parseBinaryOpExpr` 构造末尾** | 各加 1 行 | **推荐**。语义最贴切「一个运算节点刚造好」，且不受 `parseExpr` 提前返回的影响 |
| `parseExpr` 的正常出口（`return leftExpr;` 前） | 加 1 行 | 一处覆盖全部上下文（参数表、下标、`if`/`while` 条件、赋值右式）；但 `parseExpr` 另有两处提前 `return`，容易漏 |
| ~~把 `parseExpr` 包一层（新函数调旧函数）~~ | 改结构 | **不可行**。每层递归多一个常驻栈帧，栈用量约 +50%，实测把 10000 层括号（B-02）打崩（paren 崩溃阈值 11000 ok / 12000 crash） |

推荐第一种，形如（`parser.hpp`）：

```cpp
static AST::Expr* parseBinaryOpExpr(Parser& p, AST::Expr* leftExpr) {
  ...
  expr->rightExpr.reset(p.parseExpr(prec));
  AST::Expr* out = expr;      // 两侧都已折好，折叠自底向上自然成立
  p.optimizeInPlace(out);     // ← constFolding 为真时才折，且走引用版
  return out;
}
```

自底向上的效果（已实测）：

```
1 + 2 * 3;   →  Int(7)      // 内层 2*3 先折成 Int(6)
(1 + 2) * 3; →  Int(9)
- (2 * 3);   →  Int(-6)
2 ^ 3 ^ 2;   →  Int(512)    // ^ 右结合：2^(3^2)
```

> 若要对一棵**已存在**的树做一次性折叠，需在外部做后序遍历再调用 `OptimizeInPlace`
> （本文件不提供）。

## 3. 常量分类与真值规则

### 3.1 哪些算「字面量常量」

| 类型 | 是否常量 | 备注 |
| --- | --- | --- |
| `NullExpr` `BoolExpr` `IntExpr` `FloatExpr` | ✅ | 折叠的原料 |
| `StringExpr` `BinArrExpr` | ✅ | 只参与拼接与相等比较 |
| `IdentExpr` `CallExpr` `AtExpr` `ArgsExpr` `ArgcExpr` `CustomOpcodeExpr` | ❌ | 值要运行期才知道；`Call`/`Custom` 还可能有副作用 |
| 裸 `Expr`（PD-8 的失败节点） | ❌ | — |

### 3.2 真值规则（`and` / `or` 用）

| 类型 | 为真当且仅当 |
| --- | --- |
| `NullExpr` | 永不为真 |
| `BoolExpr` | `value == true` |
| `IntExpr` | `value != 0` |
| `FloatExpr` | `value != 0.0` |
| `StringExpr` | 非空串 |
| `BinArrExpr` | 非空数组 |

与参考实现 VM 的 `if not value` 判定一致。

## 4. 完整行为矩阵（总表）

> **这一节是可调整的总表**：一张表里能找到每一格（运算符 × 操作数类型组合）的当前行为、
> 对应的代码位置、以及可直接替换的备选语义。
> 改一格 = 改代码里的一个分支；改完把 §8 的用例重跑一遍即可。
>
> 表中所有格子均为 **2026-10-16 探针实测值**（15 个运算符 × 36 个类型对 × 2 组代表值）。

### 4.1 类型代号与代表值

| 代号 | 类型 | 代表值 | 备用组（用于验证符号/边界） |
| --- | --- | --- | --- |
| `N` | `NullExpr` | `null` | — |
| `B` | `BoolExpr` | `true` | `false` |
| `I` | `IntExpr` | `7` | `-7` |
| `F` | `FloatExpr` | `2.5` | `-2.5` |
| `S` | `StringExpr` | `"ab"` | `""` |
| `A` | `BinArrExpr` | `'x 41'`（1 字节） | `''`（0 字节） |
| `X` | 任意一个**非 null** 的常量 | — | — |
| `跨类型` | 两侧类型不同且都不是 null（如 `I⊕B`、`I⊕S`、`S⊕A`） | — | — |
| `Num` | 算术上下文里的数字：`I`、`F`，以及按 §4.9 规则 ③ 折算的 `B` | — | — |

`t(e)` = 真值（§3.2）；`KEEP` = **不折叠**（原节点与 `line` 均不变）。

### 4.2 求值顺序（决定"哪张表优先"）

```
L0 任一侧不是字面量常量   → KEEP          —— 硬闸门，也是副作用保护
L1 op 是 and / or        → Bool(t(L) ⊕ t(R))      —— 与类型无关
L2 任一侧含 null         → §4.4 null 矩阵
L3 op 是 == != < <= > >= → §4.5 的对应行
L4 op 是 + - * / idiv % ^→ §4.5 的对应行（先看左值是数值还是序列）
   其中 §4.6 的"条件例外"在每一层里都优先命中（除零 / 非有限 / 收窄）
```

第 L0 条是硬闸门，也是**副作用保护**：`null * myop()`、`false and myop()` 都停在这里。
L1 提前于 L2 只是顺序选择：`t(null) == false`，所以含 null 的 `and`/`or` 结论与 L2 一致
（§4.4 里 `and` 行仍按 null 矩阵写出，方便对照）。

### 4.3 一元矩阵（`optimizeUnaryOpExpr`）

| 操作数 | `!` / `not` | `-` | 代码位置 | 可替换的备选 |
| --- | --- | --- | --- | --- |
| `N` null | `Bool(true)` | `KEEP` | `Not` 分支（`truthy`）+ `negateConst` 不认 null | `-null` → `Null` / `Int(0)` |
| `B` bool | `Bool(!v)` | `Int(-1)`（`true`）<br>`Int(0)`（`false`） | 同上 + `negateConst` 的 Bool 分支 | `KEEP`（对齐参考实现 `_minus` 报错，见 §7） |
| `I` int | `Bool(v == 0)` | `Int(-v)`，按补码回绕（`-INT64_MIN` → `INT64_MIN`） | 同上 + `negateConst` 走 `intNeg` | `KEEP`（若后端改为溢出即报错） |
| `F` float | `Bool(v == 0.0)` | `Float(-v)` | 同上 | — |
| `S` string | `KEEP` | `KEEP` | `Not` 分支排除了 `isSeq`（序列的 `!` 未定义） | `Bool(value.empty())` |
| `A` binarr | `KEEP` | `KEEP` | 同上 | `Bool(value.empty())` |

一元只有两个算子：`!` 一律走 `truthy`、`-` 一律走 `negateConst`，
两者的例外（序列的 `!`、`null` 的 `-`）分别用类型判断和 `negateConst` 的返回值兜住。

### 4.4 二元矩阵 —— 含 null 的一侧（L2）

`X` 表示另一侧那个非 null 的常量。

| 运算符 | `N ⊕ N` | `N ⊕ X`（null 在左） | `X ⊕ N`（null 在右） | 代码位置 | 可替换的备选 |
| --- | --- | --- | --- | --- | --- |
| `+` `-` `*` `/` `idiv` `%` `^` | `KEEP` | `KEEP` | `KEEP` | `L2` 只认 `==` / `!=` | 恢复「null 是加法单位元 / 乘法吸收元」（2026-10-21 前的行为，见 §4.8） |
| `==` | `Bool(true)` | `Bool(false)` | `Bool(false)` | `L2 EQ`（`bothNull`） | — |
| `!=` | `Bool(false)` | `Bool(true)` | `Bool(true)` | `L2 NE` | — |
| `and` | `Bool(false)` | `Bool(false)` | `Bool(false)` | `L1 And`（null 的真值为假） | — |
| `or` | `Bool(false)` | `Bool(t(X))` | `Bool(t(X))` | `L1 Or` | 返回 `X` 而不是 `Bool`（会破坏"逻辑运算恒返回 Bool"） |
| `<` `<=` `>` `>=` | `KEEP` | `KEEP` | `KEEP` | `L3 LT…GE` 的 `isNumeric` 判断 | `Bool(false)`（若后端决定 null 参与比较恒假） |

**2026-10-21 定夺：null 不参与算术。** 之前 null 是加法的单位元（`null + 5` → `Int(5)`）
与 `* / idiv % ^` 的吸收元，而参考实现只有 `Add` 实现了这套规则、其余一律报错 ——
同一个表达式写成字面量（折叠）和写成变量（运行期）结果不同，是最难查的一类分歧。
现在折叠对 `+ - * / idiv % ^` 一律让路，由后端报错（统一报
`"Xxx" cannot operate on null.`）。`==` `!=` 与 `and` `or` 的结论不受影响。

### 4.5 二元主矩阵 —— 两侧都非 null（L3 与 L4）

列的含义（**注意第 1 列含 bool**，见 §4.9 规则 ③）：

| 列 | 覆盖的类型对 |
| --- | --- |
| 整数算术 | `I⊕I`、`B⊕B`、`B⊕I`、`I⊕B`（bool 视作 0/1） |
| 含 `F` | 任一侧是 `Float` 的算术（含 `B⊕F`、`F⊕B`） |
| `S ⊕ S` | 两个字符串 |
| `A ⊕ A` | 两个二进制数组 |
| `S/A ⊕ 整数` | `S*I`、`A*I`、`I*S`、`I*A`（以及 bool 次数，见 §4.9 规则 ②） |
| 其余跨类型 | 上面没覆盖到的组合 |

| 运算符 | 整数算术 | 含 `F` | `S ⊕ S` | `A ⊕ A` | `S/A ⊕ 整数` | 其余跨类型 | 代码位置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `+` | `Int(a+b)`（回绕） | `Float(a+b)` | `String(a+b)` 拼接 | `BinArr` 字节连接 | `KEEP` | `KEEP` | `L4a 数值 Add` / `L4b 序列 Add` |
| `-` | `Int(a-b)`（回绕） | `Float(a-b)` | `KEEP` | `KEEP` | `KEEP` | `KEEP` | `L4a 数值 Sub` |
| `*` | `Int(a*b)`（回绕） | `Float(a*b)` | `KEEP` | `KEEP` | **串重复**（见 §4.9 规则 ②） | `KEEP` | `L4a 数值 Mul` / `L4b 序列 Mul` |
| `/` | 整除 → `Int(a/b)`；否则 `Float` | `Float(a/b)` | `KEEP` | `KEEP` | `KEEP` | `KEEP` | `L4a 数值 Div` |
| `idiv` | `Int(a/b)` 向零取整 | **`KEEP`**（避免 float→int 收窄） | `KEEP` | `KEEP` | `KEEP` | `KEEP` | `L4a 数值 IDiv` |
| `%` | `Int(a%b)`，符号随 `a` | `Float(fmod(a,b))` | `KEEP` | `KEEP` | `KEEP` | `KEEP` | `L4a 数值 Mod` |
| `^` | 指数 ≥ 0 → `Int(快速幂)`（回绕）<br>指数 < 0 → 转 `Float` 分支（`2^-1` → `Float(0.5)`） | `Float(pow(a,b))`，非有限→`KEEP` | `KEEP` | `KEEP` | `KEEP` | `KEEP` | `L4a 数值 Pow` |
| `<` `<=` `>` `>=` | `Bool(整数比较)`（bool 不参与，含 `B` → `KEEP`） | `Bool(double 比较)` | `KEEP` | `KEEP` | `KEEP` | `KEEP` | `L3 LT…GE`（`cmpOf`） |
| `==` | `Bool(a == b)`（`B⊕B` 比较布尔值） | `Bool(double 相等)` | `Bool(串相等)` | `Bool(字节相等)` | `KEEP` | `KEEP`（`B⊕Num` 也不折） | `L3 EQ` |
| `!=` | `Bool(a != b)` | `Bool(double 不等)` | `Bool(串不等)` | `Bool(字节不等)` | `KEEP` | `KEEP` | 同 `==` 行 |
| `and` `&&` | `Bool(t(L) && t(R))` | 同左 | 同左 | 同左 | 同左 | 同左 | `L1 And` |
| `or` `\|\|` | `Bool(t(L) \|\| t(R))` | 同左 | 同左 | 同左 | 同左 | 同左 | `L1 Or` |

实测样例（默认组 / 备用组）：`7+7`→`Int(14)`、`-7+-7`→`Int(-14)`；`7+2.5`→`Float(9.5)`；
`"ab"+"ab"`→`String(abab)`、`""+""`→`String()`；`7/7`→`Int(1)`、`7/2.5`→`Float(2.8)`；
`7%2.5`→`Float(2)`、`-7%-2.5`→`Float(-2)`；`7^7`→`Int(823543)`、`-7^-7`→`Float(-1e-6)`；
`'x 41'+'x 4243'`→`BinArr(3B)`；`"ab"*3`→`String(ababab)`、`3*"ab"`→`String(ababab)`；
`true+1`→`Int(2)`、`true+true`→`Int(2)`、`false-true`→`Int(-1)`、`true*2.5`→`Float(2.5)`。

**`and` / `or` 是唯一对全部类型对都折叠的运算符**（含跨类型），
且结果恒为 `Bool`（不返回操作数）。这两条保证了不会吞掉副作用、也不会改变类型。

> 本表各格的可替换语义见 §4.8（与数值相关的几条同样列在那里）。

### 4.6 条件例外（优先于 §4.4 / §4.5 的格子）

| 条件 | 命中的格子 | 行为 | 代码 |
| --- | --- | --- | --- |
| 任一侧不是字面量常量 | 全部 | `KEEP` | `L0` 闸门 |
| **任一侧含 `null` 且运算符是 `+ - * / idiv % ^`** | 含 null 的算术 | `KEEP` | `L2` 只处理 `==` `!=` |
| `/` `idiv` `%` 的除数为 `0` 或 `0.0` | 数值除法 | `KEEP` | `L4a 数值 Div / IDiv / Mod` 的 `b == 0` 判断 |
| `^` 整数指数为负 | 整数算术列 | 改走 `Float` 分支 | `L4a 数值 Pow` 的 `b >= 0` 判断 |
| `^` 结果为 `NaN` / `±Inf` | 含 `F` | `KEEP` | `std::isfinite` |
| `idiv` 任一侧为浮点 | 含 `F` | `KEEP` | `L4a 数值 IDiv` 的 `bothNumInt` 判断 |
| bool 参与 `<` `<=` `>` `>=` | 含 `B` 的比较 | `KEEP` | `L3 LT…GE` 的 `isNumeric(lk) && isNumeric(rk)` |
| bool 与数字做 `==` / `!=` | `B ⊕ Num` | `KEEP` | `L3 EQ/NE` 的类型判断 |
| 串重复次数 `< 0` | `S/A ⊕ 整数` | `KEEP` | `L4a 数值 Mul` / `L4b 序列 Mul` 只看 `Int\|Bool`；负次由 `repeatSeq` 拒掉 |
| 串重复次数非整数（`F`） | `S/A ⊕ F` | `KEEP` | `L4a 数值 Mul` 的 `lk != Float` 判断 |
| 串重复结果元素数超过 `kMaxRepeatElem`（1 M） | `S/A ⊕ 整数` | `KEEP` | `repeatSeq` 的 `times > kMaxRepeatElem / unit` |
| 重复的是空串 / 空数组（`unit == 0`） | `S/A ⊕ 整数` | 折成**空的**同类型常数 | `repeatSeq` 的 `unit == 0` 分支 —— 结果恒为空，不需要真去循环 |

> `unit == 0` 那一格在 2026-10-16 之前是**漏判**：`if (unit != 0 && times > ...)`
> 让空串直接跳过了上限检查，`"" * INT64_MAX` 会进入近乎无限次的循环（挂住）。
> 现在改成直接返回空常数。**这是历史上唯一一处会让折叠卡住的输入。**

### 4.7 格子 → 代码位置对照（改表用）

`optimizeBinaryOpExpr` 还是**一个函数**（`expr_optim.hpp` 341–517）。判断顺序自上而下，
每层都在文件里有对应的 `----------` 分隔注释：

| 层 | 处理什么 | 为什么提到最前面 | 位置 |
| --- | --- | --- | --- |
| L0 | 两侧是否都是常量 | 不是则不折（副作用保护） | 350–352 |
| L1 | `and` / `or` | 结果与左值类型无关，恒走 `truthy` | 356–359 |
| L2 | 任一侧是 `null` | 一次处理完，后面的分支都不再判 `null` | 361–380 |
| L3 | `==` `!=` `<` `<=` `>` `>=` | 只取决于两侧是否同为数字 / 同为序列 | 383–407 |
| L4 | `+ - * / idiv % ^` | 只剩两类左值：数值（`Bool` 折算 0/1）与序列（连接 / 重复） | 409–516 |

**定位任一格的建议顺序**：先看它属于哪一层（多数格子在 L4），
若在 L4 再看左值是数值还是序列，最后按运算符缩小到那一段。

**保持这个结构（一个函数 + 分层判断），不要拆成 `foldXxx` 系列** ——
§4.7 这张「格子 → 代码位置」对照表就是按它写的，拆开后对照关系会失效。

| 想改哪一片格子 | 位置（`expr_optim.hpp`，2026-10-16 简化后） |
| --- | --- |
| 常量分类（哪些算常量） | `kindOf` 51–66、`isConst` 68 |
| 类型谓词 | `isNumeric` 70–72、`bothInt` 73–76、`isSeq` 77–80、`isNumLike` 83–86、`bothNumInt` 87–91 |
| 取值（`bool` 折算在哪） | `boolVal/asInt/doubleVal` 93–101、**`numAsInt` 102–106**、`asDouble` 107–114（含 `Bool` 分支） |
| 序列读写（String / BinArr 共用） | `seqSize` 118、`seqEqual` 123、`makeSeq` 130、`seqReserve` 140、`seqAppend` 147 |
| 真值规则 `t()` | `truthy` 160–172 |
| 整数运算（回绕，不检查溢出） | `intAdd/intSub/intMul/intNeg/intDiv/intMod/intPow`（`.cpp`） |
| 造节点 / 取负 | `makeXxx`、`negateConst`（`.cpp`） |
| **串重复（含上限常量）** | `repeatSeq` 280–291、`kMaxRepeatElem` 279 |
| `<` `<=` `>` `>=` 的四分支 | 模板 `cmpOf` 295–304（整数与浮点共用） |
| 一元全部格子 | `optimizeUnaryOpExpr` 307–330 |
| 二元·入口与「两侧都是常量」闸门（`L0`） | `optimizeBinaryOpExpr` 341–352 |
| 二元·`L1` `and` / `or` | 355–359 |
| 二元·`L2` 任一侧 `null`（§4.4 全表） | 361–380 |
| 二元·`L3` `==` `!=` | 385–399 |
| 二元·`L3` `<` `<=` `>` `>=`（bool 与序列排除） | 401–407 |
| 二元·`L4a` 左值 bool / int / float（§4.5 整数算术 + 含 `F` 列） | 411–496 |
| ├ `Add` / `Sub` / `Mul`（含 `数字 * 串`） | 413–442 |
| ├ `Div` / `IDiv` / `Mod` / `Pow` | 443–495 |
| 二元·`L4b` 左值序列（字节连接、串重复） | 499–514 |

> 演进：先是 `foldNull` / `foldConst` / `foldAdd` / `foldArith` / `foldDiv` / `foldIDiv` /
> `foldMod` / `foldPow` / `foldCompare` / `foldEqNe` 十个分派函数；2026-10-16 按
> 「左值 → 运算符 → 右值」合并成这一个函数（**行为逐格不变**，16335 个二元组合 +
> 66 个一元组合的等价性对照全部一致）；随后把内部的 `switch` 全部改成 `if / else if`；
> 再按 §4.9 的三条项目规则改成 bool 并入算术分支。
> 最后做了一次**去重简化**：把在每个左值分支里逐字重复的 `and/or`、`null`、
> `==`/`!=`、`<…>=` 提出成 `L1`–`L3` 前置层，并让 String 与 BinArr 共用一套
> 序列读写 helper（`seqSize` / `seqEqual` / `makeSeq` / `seqReserve` / `seqAppend`）。
> 这次同样**行为逐格不变** —— 改动前后两份实现并列编译、逐格对照
> 3336 个组合 + 111 个边界 / 副作用用例，**差异 0**
> （唯一的行为变化见 §4.6：原先会死循环的那一格现在折成空常数）。
> 文件也从 606 行降到 520 行。

### 4.8 常见调整：想改成什么 → 动哪里

| 目标 | 改动 | 连带影响 |
| --- | --- | --- |
| ~~null 参与算术一律不折叠~~ | **已于 2026-10-21 采用**：`lk == Null` 分支里只留 `Add/Sub/Mul/Div/IDiv/Mod/Pow` 的 `KEEP` | 已生效：`null+null` 也不折，§7 的偏离同时消失 |
| 恢复「null 是加法单位元 / 乘法吸收元」 | `L2` 分支里补回 `cloneConst` / `negateConst` 的结果（`makeNull` 与 `cloneConst` 已随规则删除，需重新加回） | 会与后端报错的行为分道扬镳，需先改后端 |
| 整数溢出恢复「不折叠」 | 把 `intAdd/…/intPow` 换回带溢出标志的版本并在各调用点 `if (ovf) return e;` | 与参考实现（回绕）不一致；且折叠与运行期会再次分歧 |
| `-true` 改成不折叠 | `optimizeUnaryOpExpr` 的 `ck == Bool` 分支里删掉 `Sub` | 与后端 `Minus` 的规则要一起定（§7） |
| null 参与比较折成 `Bool(false)` | `lk == Null` 分支末尾补 `else { ret = makeBool(line, false); }` | 会吞掉后端可能的类型错误 |
| 含浮点也折 `idiv` | 数字分支的 `IDiv` 里去掉 `bothInt` 限制 | 需先确认后端的取整与超范围行为 |
| `!` 支持字符串 / 数组 | `optimizeUnaryOpExpr` 末尾补 `ck == String / BinArr` 分支 | 与参考实现的 `not` 一致 |
| `/` 恒返回 `Float`（取消「整除保 Int」） | 数字分支的 `Div` 里删掉 `a % b == 0` 的 `Int` 分支 | 与参考实现 `_div` 不一致 |
| `^` 负指数改成不折叠 | 数字分支的 `Pow` 里 `b < 0` 时不再走浮点分支 | `2^-1` 不再折成 `Float(0.5)` |
| 除零改成折出 `Inf` / 报错节点 | 数字分支的 `Div/IDiv/Mod` 里 `b == 0` 的分支 | 会把运行期错误提前到解析期，需后端配合 |
| 跨类型 `==`（`true == 1`、`1 == "a"`） | 各左值分支的 `EQ/NE` 里放宽 `rk` 判断 | 需先定夺类型强制规则 |
| `and`/`or` 返回操作数而非 `Bool` | 各左值分支的 `And`/`Or` 两行 | 破坏「逻辑运算恒返回 Bool」，且要重新论证副作用 |
| 新增代数化简（`a*1`、`a+0`） | 在对应左值分支里加判断（**不要再拆出新函数**） | 必须能证明另一侧无副作用，风险高 |
| bool 不再参与算术（回到 2026-10-16 之前） | 把「bool/int/float」分支拆回两段：单独一个 `lk == Bool` 分支只留 `Null / EQ / NE / And / Or`，其余收进 `lk == Int \|\| Float` 并把 `isNumLike`/`bothNumInt` 换回 `isNumeric`/`bothInt` | §4.5 的整数算术列要同步改回只含 `I` |
| bool 也参与比较 / 相等 | `LT…GE` 改用 `isNumLike` + `bothNumInt`；`EQ/NE` 去掉 bool 排除 | 需先确认后端的 bool 比较语义 |
| 串重复次数不再设上限 | 删掉 `repeatSeq` 里的 `kMaxRepeatElem` 判断 | 恶意/笔误常量会造出巨大节点；建议至少保留溢出检查 |
| 串重复支持负次（折成空串） | `repeatSeq` 里去掉 `times < 0` 的返回 | 与多数语言的语义不一致，且掩盖笔误 |
| BinArr 相加不再连接 | `L4b 序列 Add` 里删掉字节连接那一段 | 与 §4.9 规则 ① 相反 |
| 把 `L1`–`L3` 前置层拆回各左值分支 | 没有理由这样做：那几层在每个左值分支里是逐字重复的副本 | 只有真的要让不同左值类型在这些运算符上分道扬镳时才值得拆 |

### 4.9 本项目自定的三条算术规则（2026-10-16 定夺）

三条都是**项目自己定的**，不看 GDScript 参考实现的行为；它们已经写进 §4.5 的格子，
这里集中给出定义、边界与理由。

**① `BinArr + BinArr` == 字节连接**

| 输入 | 结果 |
| --- | --- |
| `'x 41' + 'x 4243'` | `BinArr(3B)` = `41 42 43` |
| `'' + ''` | `BinArr(0B)` |
| `A + null` / `null + A` | `KEEP`（null 不参与算术，见 §4.4） |
| `A + 其它类型` | `KEEP`（含 `A + Bool`、`A + String`） |

**② `String` / `BinArr` × 非负整数 == 串重复**

`"ab" * 3` → `String(ababab)`；`'x 41' * 3` → `BinArr(3B)`；两个方向都支持（`3 * "ab"` 同）。
次数为 `Bool` 时按 0/1 处理（`false * "ab"` → `String()`）。

| 次数 | 行为 |
| --- | --- |
| `0` | 空串 / 空数组 |
| `n > 0`，且 `长度 * n <= kMaxRepeatElem`（1 M 元素） | 重复 `n` 次 |
| 重复对象是空串 / 空数组（`长度 == 0`） | 恒为空；任意次数都直接折成空，不进循环 |
| `n < 0` | `KEEP`（无定义） |
| 非整数（`Float`） | `KEEP` |
| `长度 * n > kMaxRepeatElem`（且长度非 0） | `KEEP`（避免造出巨型常量） |
| `null` | `KEEP`（null 不参与算术，见 §4.4） |

**③ 算术上下文里 `Bool` == `0` / `1` 的整数**

只对 `+ - * / idiv % ^` 生效；**`Bool ⊕ Bool` 也算**（`true+true` → `Int(2)`）。
`< <= > >=` 与 `== !=` 仍按类型区分 —— `true < 1`、`true == 1` 都不折叠。
`and` / `or` 仍走真值规则（`truthy`），不参与本规则。

| 输入 | 结果 |
| --- | --- |
| `true+1` / `1+true` | `Int(2)` |
| `true+true` / `false+false` | `Int(2)` / `Int(0)` |
| `false-true` | `Int(-1)` |
| `true*2.5` | `Float(2.5)` |
| `true/2` | `Float(0.5)`（不能整除） |
| `7/true` / `7 idiv true` | `Int(7)` |
| `true idiv 2` | `Int(0)`（向零取整） |
| `true%2` | `Int(1)` |
| `true^2` / `false^0` | `Int(1)` |
| `false^-1` | `KEEP`（`0` 的负次幂非有限） |
| `true < 1`、`7 < true`、`true == 1` | `KEEP` |
| `true == true`、`false != true` | `Bool(true)` |
| `true and false` | `Bool(false)` |

> 实现落到三个谓词/取值函数上：`isNumLike`（Bool 算不算数）、`bothNumInt`（Bool 算整数）、
> `numAsInt` / `asDouble`（把 Bool 折成 0/1）。**关掉这条规则就从这三个函数改起**（§4.8）。

## 5. 一律不折叠的清单

| 情况 | 原因 |
| --- | --- |
| 任一操作数不是字面量常量 | 算不出值；且可能吞掉 `Call` / `Custom` 的副作用 |
| 任一侧是 `null` 且运算符是 `+ - * / idiv % ^` | 类型错误，交给后端报错（§4.4） |
| 除数为 0（`/` `idiv` `%`，含浮点） | 本该是运行期错误，折叠会吞掉 |
| 含浮点的 `idiv` | float→int 收窄，范围与精度都可能与后端不一致 |
| Bool 参与比较 / 相等（`<`…`>=`、`==` `!=`） | 见 §4.9 ③：bool 只在算术里当 0/1，比较与相等仍按类型区分 |
| null 参与比较（`<` `<=` `>` `>=`） | 本该是类型错误 |
| 跨类型 `==` / `!=`（如 `1 == "a"`、`true == 1`） | 强制转换规则未定 |
| **串重复次数 `< 0`、非整数、或结果 > 1 M 元素** | 见 §4.9 ② |
| `BinArr` 与数字 / 字符串 / 布尔相加 | 只允许 `BinArr + BinArr` 连接（§4.9 ①） |
| `^` 结果为非有限值（`(-1) ^ 0.5`、`0 ^ -1`） | 交给后端 |
| 一元 `!` / `-` 作用于字符串、二进制数组 | 见 §10 |
| 未知运算符 | 保守 |

## 6. 溢出与除零

### 6.1 溢出：不检查，按 64 位补码回绕（2026-10-21 定夺）

`+ - * / idiv % ^` 与一元 `-` 的整数结果**不回退、不报错、直接回绕**，
与参考实现 `basic_vm.hpp` 完全一致。所有运算都先转 `uint64_t` 再用
`static_cast<int64_t>` 转回（C++20 起该转换是取模，不是 UB）：

| 运算 | 实现 |
| --- | --- |
| `a + b` / `a - b` / `a * b` | `static_cast<int64_t>(uint64(a) op uint64(b))` |
| `-a` | `static_cast<int64_t>(0u - uint64(a))` |
| `a / b`、`a % b` | `intDiv` / `intMod`：先按符号取绝对值再算，最后一次取反 |
| `a ^ b`（整数快速幂） | 每步乘法都是 unsigned 乘，自然回绕 |

`intDiv` / `intMod` 走无符号**不是为了检查溢出**，只是为了躲开
`INT64_MIN / -1` 的硬件陷阱（x86 上直接 `SIGFPE` 崩进程）——那不属于「溢出」，
属于「不许崩」。所以 `INT64_MIN / -1` 的折叠结果是回绕后的 `INT64_MIN`，
`INT64_MIN % -1` 是 `Int(0)`。

实测（§8）：`9223372036854775807 + 1` → `Int(-9223372036854775808)`；
`9223372036854775807 * 2` → `Int(-2)`；`2 ^ 63` → `Int(-9223372036854775808)`；
`-INT64_MIN` → `Int(-9223372036854775808)`。

> 注：`INT64_MIN` 无法直接写成字面量（`9223372036854775808` 会被词法层判为
> `invalid integer.`），要用 `0 - 9223372036854775807 - 1` 构造。

### 6.2 除零：一律不折叠

`/` `idiv` `%` 的除数为 `0`（或浮点的 `0.0`）时**不折叠**，见 §5。
折叠器这边只是「少做一次优化」；运行期 `basic_vm.hpp` 的规则是
**两侧都是整数才报错、任一侧是浮点就走 IEEE**（`1.0 / 0.0`、`1 / 0.0`、`1.0 / 0`
都得 `inf`，`0.0 / 0.0` 得 `nan`）。所以字面量写法最终也是 `inf`，
两条路径结果一致。

## 7. 与两个后端的关系

参考实现（`gdscript/stope/`）**没有常量折叠**，所以本文件是 C++ 侧新增的能力。
下表列的是「折叠器算出来的值」与「后端算出来的值」是否一致 —— C++ 的
`cpp/include/stope/basic_vm.hpp` 已全部对齐「本文件」一列，GDScript 则还是老样子：

| 行为 | GDScript（无折叠） | 本文件（折叠） | C++ VM（运行期） |
| --- | --- | --- | --- |
| `-true` | `_minus` 报 `'Minus' can only numbers.` | `Int(-1)` | `Int(-1)` ✔ |
| `'x 41' + 'x 42'` | 报错 / 未定义 | `BinArr(2B)` 字节连接 | `BinArr` 连接 ✔ |
| `"ab" * 3`、`3 * "ab"` | 报错 / 未定义 | `String(ababab)` 串重复 | 串重复 ✔ |
| `true + 1`、`true + true` | 报错 / 未定义 | `Int(2)`（bool 当 0/1） | `Int(2)` ✔ |

**折叠与 C++ VM 目前零差异**：2026-10-21 用两支探针把同一表达式写成
「字面量」（走折叠）与「`let` 变量」（走运行期）各跑一遍，共 2953 组
（15 个二元运算符 × 12 种值 × 12 种值、复合表达式、64 位边界、幂与浮点极端），
去掉错误信息里的行号后**逐条一致**。折叠器「不折叠」的那些情况只是把计算推给
运行期，不改变结果（清单见 §5）。

> 换后端时要重新核这张表：如果后端的语义是「报错」，那么折叠掉一个本该报错的
> 表达式就等于把错误吞掉了。GDScript 侧就是这种情况，所以那边暂未接折叠。

## 8. 已验证用例

以下均为探针实测输出（2026-10-16 首测，2026-10-21 按新规则复核；g++ 15.2.0 `-std=c++20`）：

```
一元   !null → Bool(true)      -null → 不折叠
       !true → Bool(false)     -true → Int(-1)      -false → Int(0)
       !0    → Bool(true)      !5    → Bool(false)  -5 → Int(-5)
       !0.0  → Bool(true)      -2.5  → Float(-2.5)  !"abc" → 不折叠
null   null+null / null+5 / 5+null / null+"a" / null-5 / 5-null / null-true /
       true-null / null*5 / 5*null / null/5 / null idiv 5 / null%5 / null^5 /
       5^null / 'x 41'+null → 一律不折叠（运行期报 "... cannot operate on null."）
       null==null → true   null!=null → false   null==5 / 5==null → false
       null<5 → 不折叠         null and true → false   null or true → true
       null or 0 → false
数值   1+2 → Int(3)        1+2.5 → Float(3.5)    2*3 → Int(6)
       6/3 → Int(2)        7/2   → Float(3.5)    1/0 / 1.0/0.0 → 不折叠
       7 idiv 2 → Int(3)   -7 idiv 2 → Int(-3)   7.0 idiv 2 → 不折叠
       7%3 → Int(1)        -7%3 → Int(-1)        7.5%2 → Float(1.5)
       2^10 → Int(1024)    2^0 → Int(1)          2^-1 → Float(0.5)
       2^0.5 → Float(1.41421)   2^62 → Int(4611686018427387904)
       2^63 → Int(-9223372036854775808)（回绕）
       0^0 → Int(1)   0^-1 → 不折叠(inf)   (-1)^0.5 → 不折叠(NaN)
       "a"+"b" → String(ab)
connect 'x 41'+'x 4243' → BinArr(3B)   ''+'' → BinArr(0B)
repeat "ab"*3 → String(ababab)   3*"ab" → String(ababab)   "ab"*0 → String()
       "ab"*true → String(ab)    false*"ab" → String()     'x 41'*3 → BinArr(3B)
       "ab"*-1 → 不折叠   "ab"*2.5 → 不折叠   "ab"*524289 → 不折叠(>1M 元素)
       ""*INT64_MAX → String()   ''*INT64_MAX → BinArr(0B)
       （空串/空数组的任意次重复都直接折成空；改动前这一格会死循环）
bool   true+1 → Int(2)    1+true → Int(2)    true+true → Int(2)   false+false → Int(0)
       false-true → Int(-1)    true*2.5 → Float(2.5)    false*3 → Int(0)
       true/2 → Float(0.5)   7/true → Int(7)   true idiv 2 → Int(0)   7 idiv true → Int(7)
       true%2 → Int(1)   true^2 → Int(1)   false^0 → Int(1)   false^-1 → 不折叠
       true<1 → 不折叠   7<true → 不折叠   true==1 → 不折叠   true==true → Bool(true)
比较   1<2 → true   1<2.5 → true    1==1.0 → true
       "a"=="a" → true     'x 41'=='x 41' → true    true==1 → 不折叠
       1 and 2 → true   0 and 1 → false   0 or 1 → true   "" or 1 → true
边界   0-9223372036854775807-1 → Int(-9223372036854775808)   （INT64_MIN）
       9223372036854775807+1 → Int(-9223372036854775808)       （回绕）
       9223372036854775807*2 → Int(-2)                        （回绕）
       -(INT64_MIN) → Int(-9223372036854775808)
       INT64_MIN * -1 → Int(-9223372036854775808)
       INT64_MIN / -1 → Int(-9223372036854775808)   INT64_MIN % -1 → Int(0)
嵌套   1+2*3 → Int(7)   (1+2)*3 → Int(9)   -(2*3) → Int(-6)   2^3^2 → Int(512)
       'x 41'*2+'x 42' → BinArr(3B)   "ab"*2+"ab" → String(ababab)
```

### 8.2 §4 矩阵的实测方式

§4 的每一个格子都用一次穷举探针跑出来的：15 个运算符 × 36 个类型对 × 2 组代表值
（默认组 `true / 7 / 2.5 / "ab" / 'x 41'`，备用组 `false / -7 / -2.5 / "" / ''`），
直接调 `Optimize` 并比对返回指针是否等于入参来判定"是否折叠"。
抽查（默认组 / 备用组）：

```
+   7+7 → Int(14)      |  -7+-7 → Int(-14)        7+2.5 → Float(9.5) | -7+-2.5 → Float(-9.5)
    "ab"+"ab" → String(abab) | ""+"" → String()   N+S → 不折叠
-   7-7 → Int(0)       |  -7--7 → Int(0)         7-2.5 → Float(4.5) | 2.5-7 → Float(-4.5)
    N-B(true) → 不折叠 | N-B(false) → 不折叠     N-S → 不折叠
*   7*7 → Int(49)      |  -7*-7 → Int(49)        7*2.5 → Float(17.5)
/   7/7 → Int(1)       |  7/2.5 → Float(2.8)     2.5/7 → Float(0.357143)
%   7%2.5 → Float(2)   |  -7%-2.5 → Float(-2)
^   7^7 → Int(823543)  |  -7^-7 → Float(-1.000000e-06)   -2.5^-2.5 → 不折叠(NaN)
==  7==2.5 → false     |  B==B → true            S==S → true   A==A → true   B==I → 不折叠
<   7<2.5 → false      |  -7<-2.5 → true
and B+I → Bool(true)   |  B+I(false,-7) → Bool(false)
or  N+S("ab") → true   |  N+S("") → false
```

需要复现时可用同样的思路写探针（构造 `UnaryOpExpr` / `BinaryOpExpr` 后调 `Optimize`），
不必经过 Parser。

## 9. 已接入 parser（2026-10-16）

### 9.1 挂点与开关

| 项 | 位置 |
| --- | --- |
| 折叠调用（唯一入口） | `parser.hpp` 的 `void optimizeInPlace(AST::Expr*&)`，内部 `if (constFolding) exprOptimizer.OptimizeInPlace(e);` |
| 调用点 | `parseUnaryOpExpr` 与 `parseBinaryOpExpr` 的构造末尾（各 1 行） |
| 开关 | `Parser::constFolding`（public，默认 `true`） |
| 测试侧开关 | `parseAll(src, cfg, fold)`，第三个参数，默认 `true` |

关掉折叠后 AST 与源码逐节点对应。**为什么保留开关**：P 组（优先级/结合性）与 L-02
靠整数字面量验证树形，一旦折叠，`1 + 2 * 3` 直接变成 `Int(7)`，形状断言既失败、
也失去验证优先级的意义。所以这两处用 `parseAll(..., nullptr, false)`，折叠后的期望
由 `test/test_parser_fold.cpp`（O-01…O-36）单独锁定。

### 9.2 接入时的实测影响

- **受影响的既有断言 14 条**（已按上面的开关方案处理，未改期望值）：
  P-01…P-09、P-13/14/15、P-06、P-07 共 13 条形状断言，以及 L-02（含一处
  `static_cast<const AST::BinaryOpExpr*>` —— 折叠后那是 `IntExpr`，已改为先判
  `expr->type` 再下转，否则是未定义行为）。
- **折叠不改变语句行号**：常量节点沿用运算符节点的 `line`，而 `BinaryOpExpr::line`
  就是 `leftExpr->line`，`ExprStmt::line` 因此不变（`1 +\n2;` 折成 `Int(3)`，语句行号仍为 1）。
- **栈深度**：把 `parseExpr` 包一层会让每层递归多一个常驻栈帧，实测打崩 10000 层括号用例
  （B-02）；挂在两个运算符函数的构造末尾则无影响（详见 §2.2）。
- 折叠是**不可逆**的：AST 不再与源码逐节点对应。调试/反编译时要注意。

### 9.3 新增的折叠用例

`test/test_parser_fold.cpp`（O-01…O-36，80 条断言）：算术、比较、字符串/字节数组、
Bool-as-0/1、null 不参与算术（`null + 5` / `null - 5` / `null * 5`）、整数溢出回绕
（`INT64_MAX + 1` → `Int(INT64_MIN)`）、负指数幂（`2 ^ (0 - 1)` → `Float(0.5)`）、
不折叠的边界（除零 / 含浮点 `idiv` / 负次重复 / `0^-1`）、
副作用保护（`x + 1`、`false and f()`）、`args[1+2]`、`a[1+2]`、
折叠后 `line` 归属、开关两种形态对照、错误计数不受折叠影响。
每一项都能在本文 §8 找到对应的行为说明。

## 10. 待定与可扩展项

| 项 | 现状 | 可扩展方向 |
| --- | --- | --- |
| `!` 作用于字符串 / 二进制数组 | 不折叠 | 参考实现的 `not` 支持所有类型，可补 `Bool(值.empty())` |
| 跨类型 `==`（`true == 1`、`null == 0`） | 不折叠 | 需要项目定夺类型强制规则 |
| 含浮点的 `idiv` | 不折叠 | 后端已定为「向零取整、结果保持浮点」（`7 idiv 2.0` → `Float(3)`），可以按这条补折叠 |
| `null` 参与比较 | 不折叠 | 若后端决定「null 比较恒为 false」可补 |
| 代数化简（`a * 1`、`a + 0`） | 不做 | 属于常量折叠之外的优化，风险更高（要判定无副作用） |
| 字符串 / 数组的其它运算 | 不折叠 | 参考实现只支持 `String + String` |
