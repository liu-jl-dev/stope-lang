// 语法分析：golden.txt（195 条，cpp/tools/golden.cpp dump）+ 嵌套深度上限。
//
// 每条用例断言四件事：AST 形状串、语句行号序列、语法错误条数与文案、词法错误条数。
// 形状串格式见 docs/zh-cn/parser-test-plan.md §2（`ExprStmt(..) / Let[a]=Int(1)`）。
// 期望值不手写 —— 改 behavior 时重跑 `cmake --build cpp/build --target gen-golden`。

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readGolden } from './golden.js'
import { runCase } from './run_case.js'
import { Lexer } from '../src/lexer.js'
import { Parser } from '../src/parser.js'
import { Prog } from '../src/ast.js'

describe('Parser：golden.txt', () => {
  const cases = readGolden('golden.txt')

  test('用例数', () => {
    assert.equal(cases.length, 195, 'golden.txt 条数变了？（生成器与用例表要一起改）')
  })

  for (const rec of cases) {
    test(rec.ID, () => {
      const got = runCase(rec)
      assert.equal(got.SHAPE, rec.SHAPE, `${rec.ID} SHAPE`)
      assert.equal(got.LINES, rec.LINES, `${rec.ID} LINES`)
      assert.equal(got.PERR, rec.PERR, `${rec.ID} PERR`)
      assert.equal(got.PERRS, rec.PERRS, `${rec.ID} PERRS`)
      assert.equal(got.LEXERR, rec.LEXERR, `${rec.ID} LEXERR`)
      assert.equal(got.LEXERRS, rec.LEXERRS, `${rec.ID} LEXERRS`)
    })
  }
})

// ---------------- 嵌套深度上限 ----------------
// 期望值不 dump：限额与错误文案是**两侧约定**（C++ Parser::maxDepth 与本实现的
// maxDepth 同为 256，文案逐字相同），所以按约定写死。C++ 侧由
// cpp/test/test_parser_depth.cpp 断言同一组深度；任一侧改了计数口径或文案，两边都会红。
function depthSource(kind, n) {
  // 与 GD 侧 _depth_case 的构造逐字一致：块里要有语句，否则永远进不到 parseExpr，
  // 深度计数根本没机会检查。
  if (kind === 'paren') return '('.repeat(n) + 'a' + ')'.repeat(n) + ';'
  if (kind === 'block') return '{'.repeat(n) + 'a;' + '}'.repeat(n)
  if (kind === 'unary') return '-'.repeat(n) + 'a;'
  if (kind === 'at') return 'a['.repeat(n) + '0' + ']'.repeat(n) + ';'
  throw new Error('unknown kind ' + kind)
}

function parseDepth(kind, n) {
  const ps = new Parser(new Lexer(depthSource(kind, n)))
  const tree = new Prog()
  ps.ParseProgram(tree)
  return { errors: ps.errors, tree }
}

const DEPTH_CASES = [
  ['PD-DEPTH-1', 'paren', 200, false], // 限额内：照常解析
  ['PD-DEPTH-2', 'paren', 300, true],
  ['PD-DEPTH-3', 'block', 300, true],
  ['PD-DEPTH-4', 'unary', 300, true], // 没有括号的递归
  ['PD-DEPTH-5', 'at', 300, true],
  ['PD-DEPTH-6', 'paren', 12000, true], // 曾真的栈溢出
]

describe('Parser：嵌套深度上限（maxDepth = 256）', () => {
  for (const [id, kind, n, deep] of DEPTH_CASES) {
    test(`${id} ${kind} ${n}`, () => {
      const r = parseDepth(kind, n)
      if (!deep) {
        assert.equal(r.errors.length, 0, `${id} 限额内不该报错`)
        assert.ok(r.tree.stmts.length > 0, `${id} 应解析出语句`)
        return
      }
      // 超限只报一条（不刷连锁噪音），文案逐字固定
      assert.deepEqual(r.errors, ['line 1: nesting too deep (max 256). '], `${id} 错误文案`)
    })
  }

  test('默认值与 C++ 一致：256，0 = 不限', () => {
    assert.equal(new Parser(new Lexer('')).maxDepth, 256)
  })

  test('maxDepth = 0 时不检查（2000 层仍能解析）', () => {
    const ps = new Parser(new Lexer('('.repeat(2000) + 'a' + ')'.repeat(2000) + ';'))
    ps.maxDepth = 0
    const tree = new Prog()
    ps.ParseProgram(tree)
    assert.equal(ps.errors.length, 0)
    assert.equal(tree.stmts.length, 1)
  })
})
