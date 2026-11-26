# Java 实现快速上手

跨实现语义权威在 [`docs/zh-cn/syntax-reference.md`](../../docs/zh-cn/syntax-reference.md)，本页只讲 Java 侧动线。

## 编译一段 Stope 代码

```java
Opcode.CustomOpcodeConfig cfg = new Opcode.CustomOpcodeConfig();
Lexer lx = new Lexer("return 1 + 2;");
lx.custom = cfg;
Parser ps = new Parser(lx);
Ast.Prog tree = new Ast.Prog();
ps.parseProgram(tree);

Program prog = new Program();
new Compiler(prog, cfg).compile(tree, java.util.List.of());

BasicVM.State s = new BasicVM.State(prog);
s.run();
BasicVM.Value v = s.returns.get(0); // Integer(3)
```

折叠默认开启（`Parser.constFolding = true`）；深度上限 256（`Parser.maxDepth`）。

## 宿主函数

`BasicVM.Value.ofHostFn(ctx, (c, args) -> ...)` 造一个宿主函数值，塞进 `State.variables` 的某个槽位，或作为预导出传入 `Compiler.compile(tree, preExports)` 后按导出名找槽位。`Call` 指令调用它，参数整包以 `Value[]` 传入，返回值成为栈顶。

## 实参表

宿主实现 `BasicVM.Arguments`（`at(ctx, state, key)` / `num(ctx)`）并赋给 `State.args`、`State.argsCtx`。`argc` / `args[k]` 走这两个回调。

## 字符串与字节数组

`"…"` 是 String，`'…'` 是 BinArr。内部都用 Java `String` 表示，但**按 UTF-16 码元**编址：字符串下标 `"😀"[0]` 得 55357（高代理项），与 C++ `u16string` 一致。`BinArrParser.parse` 解析 `'…'` 内容（无前缀按 16 进制，b/o/d/x 切进制）。

## 测试与 demo

见 [`../README.md`](../README.md)。四个 demo 位于 `java/demo/`。
