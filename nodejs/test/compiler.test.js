// 编译器：golden.txt 的 CMP / OUT / CERRS 三个字段（195 条）。
//
// OUT 是「单行比对格式」（docs/zh-cn/compiler-test-plan.md §2.3）：
//   code[PushId(0) PushInt(0) Assign] vars=1 stack=2 maxRet=0 ints=[1] …
// 它只给测试比对用，不进库 —— 人读的反汇编是 debug.js 的 Disasm。

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readGolden } from './golden.js'
import { runCase, cfg } from './run_case.js'
import { Compiler } from '../src/compiler.js'
import { Program } from '../src/program.js'
import { Prog } from '../src/ast.js'
import { Lexer } from '../src/lexer.js'
import { Parser } from '../src/parser.js'
import { Result } from '../src/common.js'

describe('Compiler：golden.txt', () => {
  const cases = readGolden('golden.txt')

  for (const rec of cases) {
    test(rec.ID, () => {
      const got = runCase(rec)
      assert.equal(got.CMP, rec.CMP, `${rec.ID} CMP`)
      assert.equal(got.OUT, rec.OUT, `${rec.ID} OUT`)
      assert.equal(got.CERRS, rec.CERRS, `${rec.ID} CERRS`)
    })
  }
})

// 失败时把 out 复原为空（compiler-test-plan.md §2）：半成品 Program 跑不了，
// 留着反而误导。
describe('Compiler：失败后清空输出', () => {
  // 词法器/语法器带 config（这样 myop 才是 Custom token），编译器**不带** —— 这正是
  // 「注册了却忘了把 config 交给编译器」的真实场景。
  function compile(src, parserCfg = null, compilerCfg = null) {
    const p = new Program()
    const c = new Compiler(compilerCfg)
    c.Compile(new Prog(), p) // 先塞点东西
    const tree = new Prog()
    new Parser(new Lexer(src), parserCfg).ParseProgram(tree)
    const rc = c.Compile(tree, p)
    return { rc, p, c }
  }

  test('undefined custom opcode -> Error + 空 Program', () => {
    const r = compile('myop(1, 2);', cfg, null)
    assert.equal(r.rc, Result.Error)
    assert.deepEqual(r.c.errors, ['line 1: undefined custom opcode "myop". '])
    assert.deepEqual(r.p.opcodes, [])
    assert.equal(r.p.variableNum, 0)
  })

  test('break 在循环外 -> Error', () => {
    const r = compile('break;')
    assert.equal(r.rc, Result.Error)
    assert.deepEqual(r.c.errors, ['line 1: cannot use "break" outside of a loop. '])
  })
})

// 变量索引回收：块退出后索引必须能被复用（MinHeap 取最小空位）
describe('Compiler：作用域与变量索引', () => {
  function compileOK(src) {
    const tree = new Prog()
    const ps = new Parser(new Lexer(src))
    ps.ParseProgram(tree)
    const p = new Program()
    const c = new Compiler()
    assert.equal(c.Compile(tree, p), Result.Success, c.errors.join('|'))
    return p
  }

  test('块内 let 复用同一槽位', () => {
    // 两个平级块各声明一个局部变量：槽位应复用（vars=1），而不是累加到 2
    const p = compileOK('{ let a; } { let b; }')
    assert.equal(p.variableNum, 1)
  })

  test('未声明就使用 -> 隐式进 exports', () => {
    const p = compileOK('fmt:println(1);')
    assert.equal(p.exports.get('fmt:println'), 0)
  })

  test('export 与 let 同名 -> duplicate export', () => {
    const tree = new Prog()
    new Parser(new Lexer('export a; export a;')).ParseProgram(tree)
    const c = new Compiler()
    const p = new Program()
    assert.equal(c.Compile(tree, p), Result.Error)
    assert.deepEqual(c.errors, ['line 1: duplicate export of "a". '])
  })
})
