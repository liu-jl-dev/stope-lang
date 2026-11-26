# Java 实现的自定义指令

只想调宿主函数？本文可以跳过——隐式导出 + `Call` 就够了。自定义指令的适用情况与语义权威在 [`cpp/docs/custom-opcode.md`](../../cpp/docs/custom-opcode.md)。本文只讲 Java 侧动线。

## 登记与使用

```java
Opcode.CustomOpcodeConfig cfg = new Opcode.CustomOpcodeConfig();
cfg.add("myop", 100, 2);   // 名字 → 编号、定长参数个数（负数表示变长）
Lexer lx = new Lexer("return myop(1, 2);");
lx.custom = cfg;           // 词法器据此把 myop 识别为 Custom
```

编译器校验定长参数个数，变长指令额外发射一个参数个数操作数。反汇编时把 config 传给 `Debug.disasm(prog, cfg)` 才能解码自定义编号。

## 与 Call 的区别

自定义指令是编译期登记的指令编号（内置封顶 33 之后的命名空间），有固定参数个数校验；`Call` 是运行期调用宿主函数值。二者的性能差异可忽略，选择依据是「需要编译期校验与字节契约」而非速度——详见权威文档。
