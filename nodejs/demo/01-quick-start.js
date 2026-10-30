// Quick-start demo: compile a Stope program and run it.
//
// Stope's standard covers three things only: the Stope language, STML, and the
// compiler's output (`Program`). It does NOT define a virtual machine, so the
// steps below have different stability guarantees:
//
//   step 1 (compile) : Lexer / Parser / Compiler / Program
//                      -> compiler API, relatively stable: `Program` has a
//                         documented encoding contract, so this part can be
//                         relied on (and copied) in host programs.
//   step 2-4 (run)   : BasicVM.* from src/basic_vm.js
//                      -> a BUILT-IN EXAMPLE executor, not part of the
//                         standard. Value representation, stack layout, host
//                         function binding and error reporting are all
//                         implementation details; another executor may not
//                         look like this at all. See docs/zh-cn/vm-guide.md.
//
// 运行：node demo/01-quick-start.js
//
// 输出与 cpp/demo/01-quick-start.cpp、gdscript/demo/demo_01.gd 逐字节相同 ——
// 三方对同一份源码产出同一份字节码。

import {
  Lexer,
  Parser,
  AST,
  Compiler,
  Program,
  DisasmNoCustom,
  BasicVM,
  Result,
} from '../src/index.js'

// 宿主侧的参数表：源码里的 args[i] / argc 都落到它身上（对应 C++ demo 的 MyArgs）。
// 与标准无关，纯属示例执行器的接口。
class MyArgs extends BasicVM.Arguments {
  constructor(values) {
    super()
    this.data = values
  }

  // 取不到就**自己报错**：state.Error(...) + 返回 null，执行器立刻停在这里。
  at(state, indexOrKey) {
    if (typeof indexOrKey !== 'bigint') {
      state.Error('index must be an integer. ')
      return null
    }
    if (indexOrKey < 0n || indexOrKey >= BigInt(this.data.length)) {
      state.Error('index out of range. ')
      return null
    }
    return this.data[Number(indexOrKey)]
  }

  num() {
    return this.data.length
  }
}

// C++ 的 cout << double 会把 15.0 打成 "15"；JS 的 String(15) 天然也是 "15"，
// 但 BigInt / 浮点要分开处理，否则 1n 和 1 的输出看起来一样却来路不同。
function fmt(v) {
  if (typeof v === 'bigint') return String(v)
  if (typeof v === 'number') return String(v)
  if (v === null || v === undefined) return 'null'
  return String(v)
}

// 宿主函数表（对应 C++ demo 里 v_fmtPrintln 绑的那个 lambda）。
// JS 里函数本身就是值，直接塞进变量槽就能被 Call 指令调到。
// 签名统一是 (argv: Array) => any —— 参数**整包**进来，自己拆。
function println(argv) {
  console.log('[Host] ' + argv.map(fmt).join(''))
  return null
}

// ---------------- step 1: 编译源码 ----------------
//
// 稳定性：编译器接口。Program 有明确的编码契约（指令编号、操作数、跳转目标是
// opcodes 下标），宿主可以依赖这一段。
const src = `
// example: sum all arguments

let result = 0.0;
let i = 0;
while i < argc {
  result = result + args[i];
  i = i + 1;
}

fmt:println("结果为: ", result);
return result;
`

const lexer = new Lexer(src)
const parser = new Parser(lexer) // 第二参是 CustomOpcodeConfig，可省
const tree = new AST.Prog()
parser.ParseProgram(tree)
for (const e of lexer.errors) console.error('[lex] ' + e)
for (const e of parser.errors) console.error('[parse] ' + e)

const compiler = new Compiler() // 构造参同上，可省
const program = new Program()
const rc = compiler.Compile(tree, program) // AST 与 Program 都传引用
for (const e of compiler.errors) console.error('[compile] ' + e)
if (rc !== Result.Success) {
  // 编译失败时 Compile() 已按约定把 program 清空，别拿它去反汇编或执行
  console.error('compile failed, nothing to run')
  process.exit(1)
}
console.log(DisasmNoCustom(program))

// ---------------- step 2-4: 装配执行器 ----------------
//
// 稳定性：内置示例，不是标准。换一个执行器，这段可以整个换掉。
const api = new BasicVM.Api()
const args = new MyArgs([1.0, 2.0, 3.0, 4.0, 5.0])

// Reset 一次做完：清 returns / stack / errors，并按 variableNum 开好槽位。
// （C++ 侧那句必写的 state.variables.resize(...) 在这里由 Reset 代做。）
const state = new BasicVM.State()
state.Reset(api, program, args)

// 宿主函数就是「某个变量槽里的值」：编译器把未声明的 fmt:println 当外部变量，
// 登记进了 exports；按名字取槽位，填上函数即可。
state.variables[program.exports.get('fmt:println')] = println

// ---------------- step 4: 跑 ----------------
if (state.Run() !== Result.Success) {
  for (const e of state.errors) console.error('[vm] ' + e)
  process.exit(1)
}
console.log('result: ' + fmt(state.returns[0]))
