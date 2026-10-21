# Stope 语法入门

> 面向**第一次写 Stope 的人**。只讲最常用、必须知道的规则，读 10 分钟就能开始写代码。
>
> - 想查完整规则、边界情况 → [syntax-reference.md](syntax-reference.md)（用户详细版）
> - 想改 Lexer / Parser 实现 → [syntax-impl.md](syntax-impl.md)（开发人员版）

---

## 1. 先看一段完整程序

```stope
// 计算前 N 个入参之和，返回给宿主

let i = 0;                      // 变量声明 + 初值
let total;                      // 只声明，暂不赋值
total = 0;

while i < argc {                // argc = 入参个数
    total = total + args[i];    // args[i] = 第 i 个入参
    i = i + 1;
}

return total;                  // 可以返回多个值：return 1, 2;
```

这就是一个 Stope 程序的全部：**平铺的语句序列**。没有函数定义、没有类型标注、没有入口函数——
程序从上到下执行。

---

## 2. 三条基本规则

1. **语句以 `;` 结尾**，块用 `{ }` 包起来。
2. **大小写敏感**：`if` 不能写成 `IF`。
3. **注释**：`//` 到行尾，`/* ... */` 可跨行。

---

## 3. 变量

```stope
let a;              // 声明（无初值）
let a = 1;          // 声明并赋初值
let a, b, c;        // 一次声明多个（这种写法不能带 =）

a = 10;             // 赋值是语句，不是表达式
```

**注意**

- `let a, b = 1;` **不行** —— 多变量声明和赋值不能同时用。
- `a = b = 1;` **不行** —— 赋值不能链式。
- 变量不需要写类型。

---

## 4. 数据

| 写法 | 含义 |
| --- | --- |
| `1` `0x1F` `0b1010` `0o17` | 整数（十六进制 / 二进制 / 八进制） |
| `1_000_000` | 下划线只为好看，等于 `1000000` |
| `1.5` `1.` `.5` `1e3` | 浮点数 |
| `"hello"` | 字符串 |
| `'x 41 42'` | 二进制数组（每个数字 = 一个字节，默认十六进制） |
| `null` `true` `false` | 空 / 真 / 假 |

**二进制数组**的四种前缀：

```stope
'41'            // 默认十六进制 → 一个字节 0x41
'x 41'          // 显式十六进制 → 0x41
'd 65'          // 十进制 → 0x41
'b 01000001'    // 二进制，要写满 8 位 → 0x41
```

> `'b 0100 0001'` 是**两个**字节 `04 01`，不是 `0x41`——每个空白分隔的数字都是独立的一个字节。

---

## 5. 运算符

从**先算**到**后算**：

| 优先级 | 运算符 |
| --- | --- |
| 最高 | `f(...)` 调用、`a[...]` 索引 |
| | `-a` `!a` `not a` |
| | `a ^ b`（幂） |
| | `a * b` `a / b` `a idiv b` `a % b` |
| | `a + b` `a - b` |
| | `a < b` `a <= b` `a > b` `a >= b` |
| | `a == b` `a != b` |
| | `a and b`（也可写 `&&`） |
| 最低 | `a or b`（也可写 `\|\|`） |

不清楚时用括号：`(a + b) * c`。

两个特别之处：

- `^` 是**左结合**：`2 ^ 3 ^ 2` == `(2 ^ 3) ^ 2`。
- `/` 是除法：两个整数除不尽时得**浮点数**（`7 / 2` 是 `3.5`）。要整除用 `idiv`
  （`7 idiv 2` 是 `3`）。

全是字面量的表达式会在解析时就算出结果：`1 + 2 * 3` 在语法树里直接是 `7`；
`"ab" * 3` 是 `"ababab"`；`true + 1` 是 `2`（算术里 `true` 当 `1`）。
含有变量、调用、下标的表达式不会预先计算。

---

## 6. 控制流

```stope
if a > 0 {
    b;
} elif a == 0 {
    c;
} else {
    d;
}

while a < 10 {          // 条件可省略：while { ... } = 无限循环
    if a == 5 { break; }      // 跳出循环
    if a == 3 { continue; }   // 进入下一轮
    a = a + 1;
}
```

- `if` 的条件**必须写**，`while` 的条件**可以省**。
- **`{ }` 不能省略**，哪怕只有一条语句。
- `break;` / `continue;` 必须紧跟分号。

---

## 7. 入参、返回、导出

```stope
args[0]        // 第 1 个入参
args[i + 1]    // 下标可以是任意表达式
argc           // 入参个数

return;        // 无返回值
return 1;
return 1, 2;   // 多值

export result;         // 导出并声明：宿主可按名字读写
export a, b;
```

- `args` 必须写成 `args[...]`，不能单独用。
- `export` 只能在顶层（不能写在 `{ }` 里）。
- `export` **同时完成声明**，不能再对它用 `let` —— `export a; let a = 1;` 会报
  `duplicate declaration of 'a'. `（反过来 `let` 后再 `export` 同样报错）。
- 用 `let` 声明的是**局部变量**，宿主看不到它的名字，只能按槽位号访问；
  想让宿主按名字访问就得用 `export`。

---

## 8. 自定义指令

自定义指令由**宿主程序注册**，语言本身不内置：

```stope
emit_even(a, b);        // 调用已注册的指令
myop();                 // 零参数也合法（括号不能省）
```

如果写下未注册的名字，它会被当成普通变量（进而当作函数调用）；是否报错由宿主决定。

---

## 9. 常见错误提示

| 提示 | 通常是 |
| --- | --- |
| `expected ";" or "=". ` | 忘了写分号 |
| `expected ";" in let statement. ` | `let` 那行结尾漏了 `;` |
| `expected "}" at end of block statement. ` | 花括号没配对 |
| `expected "{" in if statement. ` | `if` 后面漏了 `{` |
| `unclosed string literal.` | 字符串引号没闭合，或字符串里写了换行 |
| `invalid escape character.` | 写了不支持的转义（只支持 `\\ \' \" \b \r \t \v \n \f`） |
| `unknown token.` | 用了不支持的符号，比如单独的 `&`、`|` |
| `no prefix parse function for token type.` | 表达式开头写了不该出现的符号，例如 `()` |

完整错误文案见[syntax-reference.md §6](syntax-reference.md)。

---

## 10. 速查卡

```stope
let a;            let a = 1;         let a, b, c;
export main;      export a, b;

if c { } elif c2 { } else { }
while { }         while c { }
break;            continue;
return;           return 1;          return 1, 2;

a  null  true  false  1  1.5  "s"  'x 41'  argc
args[0]           myop(1, 2)
- a   ! a   not a
a ^ b   a * b   a / b   a idiv b   a % b   a + b   a - b
a < b   a == b   a and b   a or b
( a + b )
```

---

## 下一步

- 完整的语法规则、字面量的边界情况、错误恢复行为 → [syntax-reference.md](syntax-reference.md)
- 想改编译器实现 → [syntax-impl.md](syntax-impl.md)
