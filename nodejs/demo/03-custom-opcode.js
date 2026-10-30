// Demo 03: 自定义指令 —— 给编译器加几条自己的指令，只编译 + 反汇编，不运行。
// 对应 cpp/demo/03-custom-opcode.cpp 与 gdscript/demo/demo_03.gd。
//
// 运行：node demo/03-custom-opcode.js
//
// 项目只规定 33 条内置指令（src/opcode.js）与 Program 的编码契约；
// 再往上加指令是宿主自己的事，三步：
//
//   1. 用 CustomOpcodeConfig 登记「名字 -> (编号, 参数个数)」；
//   2. 同一份 config 同时交给 Parser 和 Compiler：Parser 靠它把名字识别成
//      Custom token（查不到就只是普通标识符），Compiler 靠它查编号与参数个数；
//   3. 产物里就只是一串 number —— 编号什么含义、谁来执行，全由宿主决定。
//
// 本 demo 不运行程序：自定义指令在 BasicVM 里没有实现，也不该有 —— BasicVM
// 只是内置示例执行器，不是标准的一部分（见 01-quick-start.js 开头与
// docs/zh-cn/vm-guide.md）。自定义指令的意义正在于此：宿主自己定义、自己执行。
//
// 两条硬约束（见 docs/zh-cn/compiler-test-plan.md §4.4）：
//   * 编号必须 >= kFirstCustomOpcode（= Opcode.Return + 1）。opcodes 是混排序列，
//     撞号以后与内置指令无法区分；Disasm() 会把这种注册报成 warning（[5] 演示）。
//   * 定长指令的 argNum 必须与实际调用一致，否则编译期报错、不产出（[4] 演示）。

import {
  Lexer,
  Parser,
  AST,
  Compiler,
  Program,
  CustomOpcodeConfig,
  Opcode,
  kFirstCustomOpcode,
  Disasm,
  DisasmNoCustom,
  Result,
} from '../src/index.js'

// 编译一份源码并打印错误。config 为 null 时按「没有自定义指令」处理。
function compileAndReport(src, config, out) {
  const lexer = new Lexer(src)
  const parser = new Parser(lexer, config) // 第二参：可空的 config
  const tree = new AST.Prog()
  parser.ParseProgram(tree)
  for (const e of lexer.errors) console.log('  lexer: ' + e)
  for (const e of parser.errors) console.log('  parser: ' + e)

  const compiler = new Compiler(config) // 配置只在构造时注入一次
  const rc = compiler.Compile(tree, out)
  for (const e of compiler.errors) console.log('  compiler: ' + e)
  return rc === Result.Success && lexer.errors.length === 0 && parser.errors.length === 0
}

// ---------- 1. 登记自定义指令 ----------
//
// argNum >= 0 定长；argNum < 0（默认值 -1）变长，编译产物里会多写一个
// 「本次调用的参数个数」。名字里的 ':' 是词法器支持的命名空间写法，用来
// 避开宿主函数名（fmt:println 那种）。
const config = new CustomOpcodeConfig()
console.log('[1] 登记自定义指令：')
// 返回 Result：同名重复注册会拿到 DuplicateWithBuiltinOpcode。这里三条都新，
// 不为返回值打断流程。
config.addCustomOpcode('my:add', kFirstCustomOpcode + 0, 2)
config.addCustomOpcode('my:log', kFirstCustomOpcode + 1, -1)
config.addCustomOpcode('my:halt', kFirstCustomOpcode + 2, 0)
// 打印时按编号排序：config.opcodes 是 Map（插入序），而 C++ 侧是 std::map（名字序）。
// 显式排序，两侧的输出才一致。
const registered = [...config.opcodes.entries()].sort((a, b) => a[1].opcode - b[1].opcode)
for (const [name, info] of registered) {
  const kind = info.isVarArg ? '（变长）' : `（定长 ${info.argNum} 参）`
  console.log(`  ${name} -> #${info.opcode}${kind}`)
}

// ---------- 2. 编译并反汇编 ----------
//
// 注意 my:add 的参数照常先压栈，指令本身不再带操作数；只有 my:log 这种变长
// 指令后面多一个 number。反汇编要认出这些，必须把同一份 config 交给 Disasm()。
const src = `
    let x = 3;

    my:add(x, 4);        // 定长 2 参
    my:log("x =", x);    // 变长 2 参
    my:log();            // 变长 0 参
    my:halt();           // 定长 0 参

    return x;
  `
const program = new Program()
console.log('\n[2] 编译结果：')
if (!compileAndReport(src, config, program)) process.exit(1)
console.log(Disasm(program, config))

// ---------- 3. 对照：名字没登记就只是普通调用 ----------
//
// 词法器只有在 config 里查得到名字时才吐 Custom token，否则 "my:add" 就是个
// 普通标识符 —— 编译成 Call，即「调用一个名叫 my:add 的宿主函数」。
const plain = new Program()
console.log('\n[3] 同样的调用，不传 config：')
if (compileAndReport('my:add(1, 2);', null, plain)) {
  console.log(DisasmNoCustom(plain))
}

// ---------- 4. 参数个数不符 ----------
//
// 定长指令的参数量在编译期校验；报错后 Compile() 会把 out 复原为空，
// 免得一个半成品 Program 被当成能跑的东西。
const bad = new Program()
console.log('\n[4] 定长 2 参却只给 1 个：')
if (!compileAndReport('my:add(1);', config, bad)) {
  console.log(`  -> 编译失败，Program 已清空（opcodes 剩 ${bad.opcodes.length} 个 number）`)
}

// ---------- 5. 陷阱：编号撞到内置指令 ----------
//
// 自定义编号必须 >= kFirstCustomOpcode。这里故意用一个内置编号注册：编译器
// 写出的仍是同一个 number，谁也分不清它到底是 Add 还是 my:steal ——
// Disasm() 只能按内置指令解码，并把它报成 warning。
const collide = new CustomOpcodeConfig()
collide.addCustomOpcode('my:steal', Opcode.Add, 2)
const stolen = new Program()
console.log('\n[5] 用内置 Add 的编号注册 my:steal：')
if (compileAndReport('my:steal(1, 2);', collide, stolen)) {
  console.log(Disasm(stolen, collide))
  console.log('  -> 反汇编只认得出 Add：my:steal 这个名字已经丢了，编号千万别撞内置。')
}
