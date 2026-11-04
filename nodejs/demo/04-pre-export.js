// Demo 04: 预导出（preExports）—— 宿主先把形参塞进作用域，再编译函数体。
// 对应 cpp/demo/04-pre-export.cpp 与 gdscript/demo/demo_04.gd。
//
// 运行：node demo/04-pre-export.js
//
// 场景：STML 文档里定义函数，参数表写在标签属性上（params="a b"），函数体是 Stope
// 源码。编译函数体时把 params 里的名字当 preExports 传进去，它们就先占好槽位、进
// Program.exports；宿主在 Run 之前把实参写进这些槽位，函数体里的 a、b 直接就能读到。
//
// 为什么不靠「未声明标识符自动导出」？—— 那条路也行，但导出的是**函数体里用到
// 的名字**，顺序取决于出现位置、没用到的形参根本不会存在。预导出让「参数表」只有
// 一份、且顺序固定为标签里写的顺序，宿主可以照参数表直接写槽位。

import {
  Lexer,
  Parser,
  AST,
  Compiler,
  Program,
  DisasmNoCustom,
  BasicVM,
  Result,
  StmlLexer,
  StmlParser,
  StmlElement,
  StmlState,
} from '../src/index.js'

const doc = `
<stml>
<func name="add" params="a b" stope>
    return a + b;
</func>
</stml>
`

// 带 stope 属性的元素，内容按 Stope 代码扫；切出来的 text 就是原样源码。
function stateFunc(tag, attrs) {
  return attrs.has('stope') ? StmlState.Stope : StmlState.Xml
}

// 按名字找子元素。
function childByTag(ele, tag) {
  for (const c of ele.children) if (c.tag === tag) return c
  return null
}

// 编译一段源码，preExports 原样交给 Compile。失败时打印错误并返回 false。
// startLine 是 src 首行的物理行号 —— 从 STML 切出来的代码段不是从 1 开始，设给
// lexer 之后报错行号才和文档对得上（这里直接从 fn.textLine 取）。
function compileAndReport(src, startLine, preExports, out) {
  const lexer = new Lexer(src)
  lexer.line = startLine
  const parser = new Parser(lexer)
  const tree = new AST.Prog()
  parser.ParseProgram(tree)
  for (const e of lexer.errors) console.log('  lexer: ' + e)
  for (const e of parser.errors) console.log('  parser: ' + e)

  const compiler = new Compiler()
  const rc = compiler.Compile(tree, out, preExports)
  for (const e of compiler.errors) console.log('  compiler: ' + e)
  return rc === Result.Success && lexer.errors.length === 0 && parser.errors.length === 0
}

// ---------- 1. 从 STML 里取出函数定义 ----------
const lexer = new StmlLexer(doc)
const stmlParser = new StmlParser(lexer)
const root = new StmlElement()
if (stmlParser.Parse(root, stateFunc) !== Result.Success) {
  for (const e of lexer.errors) console.error('[lex] ' + e)
  for (const e of stmlParser.errors) console.error('[parse] ' + e)
  process.exit(1)
}

const fn = childByTag(root, 'func')
const name = fn.attrs.get('name')
const params = fn.attrs.get('params').split(/\s+/).filter(Boolean) // "a b" -> ['a', 'b']
console.log(`[1] 从 <func> 取出：${name}(${params.join(', ')})`)

// ---------- 2. 用参数表当 preExports 编译 ----------
//
// 形参先占槽位（a=0、b=1），函数体里的 a、b 于是解析到文件作用域 ——
// 反汇编里是 PushValue(0) / PushValue(1)。
const program = new Program()
console.log('\n[2] 编译函数体（preExports = 形参表）：')
if (!compileAndReport(fn.text, fn.textLine, params, program)) process.exit(1)
console.log(DisasmNoCustom(program))
const exported = [...program.exports].map(([k, v]) => `${k}=${v}`).join(' ')
console.log('  exports: ' + exported)

// ---------- 3. 塞实参、运行 ----------
//
// 编译期就知道槽位，所以 Run 之前就能把值写进去 —— 这才是预导出的用处：
// 宿主的「调用」就是写变量 + 跑一遍，不需要额外的参数传递机制。
const api = new BasicVM.Api()
const state = new BasicVM.State()
state.SetApi(api)
state.SetProgram(program) // 没有实参表，args 省略
state.variables[program.exports.get('a')] = 3n // 整数在 JS 侧是 BigInt
state.variables[program.exports.get('b')] = 4n

state.Run()
console.log(`\n[3] add(3, 4) = ${state.returns[0]}`)

// ---------- 4. 陷阱：预导出的名字不能再声明 ----------
//
// 名字已经进了文件作用域，源码里再 export 同名、或顶层 let 同名，都是 duplicate。
// 预导出的变量只能赋值（a = 1;），不能重新声明。
console.log('\n[4] 函数体里又写 export a;：')
compileAndReport('export a; return a;', 1, params, new Program())
