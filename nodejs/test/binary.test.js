// 二进制数组解析 + 常量折叠矩阵：golden_binarr.txt（cpp/tools/golden_binarr.cpp dump）。
//
// 文件里有两类记录：
//   BA\t内容\tok|err\t[bytes]      —— 直接打 BinaryArrayParser
//   FB / FU\t运算符\t是否折叠\t结果  —— 直接打常量折叠矩阵（不经过词法/语法）
// 两侧比的是「同一份用例的同一份输出」，所以这里把用例表照抄 GD 的 test_parser.gd，
// 结果串的格式也与那边（以及 C++ 的 fmtValue）逐字一致。

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readText } from './golden.js'
import { BinaryArrayParser } from '../src/binarr_parser.js'
import { optimize } from '../src/expr_optim.js'
import * as A from '../src/ast.js'
import { TokenType } from '../src/token.js'
import { fmtBytes, fmtG } from '../src/ast.js'
import { Result } from '../src/common.js'

// 折叠结果的紧凑写法，与 C++ 的 fmtValue / GD 的 _val 一致
function val(e) {
  if (e === null) return 'null'
  switch (e.nodeType) {
    case A.NodeType.NullExpr:
      return 'Null'
    case A.NodeType.BoolExpr:
      return e.value ? 'true' : 'false'
    case A.NodeType.IntExpr:
      return e.value.toString()
    case A.NodeType.FloatExpr:
      return fmtG(e.value)
    case A.NodeType.BinArrExpr:
      return `[${fmtBytes(e.value)}]`
    case A.NodeType.StringExpr:
      return `"${e.value}"`
    default:
      return '?'
  }
}

const INT64_MAX = 9223372036854775807n
const INT64_MIN = -9223372036854775807n - 1n

const _int = (v) => new A.IntExpr(1, BigInt(v))
const _float = (v) => new A.FloatExpr(1, v)
const _bool = (v) => new A.BoolExpr(1, v)
const _null = () => new A.NullExpr(1)
const _str = (v) => new A.StringExpr(1, v)
const _bin = (arr) => new A.BinArrExpr(1, Uint8Array.from(arr))

function fb(name, op, l, r) {
  const e = new A.BinaryOpExpr()
  e.op = op
  e.leftExpr = l
  e.rightExpr = r
  const o = optimize(e)
  const folded = o.nodeType === A.NodeType.BinaryOpExpr ? 0 : 1
  return `FB\t${name}\t${folded}\t${val(o)}`
}

function fu(name, op, v) {
  const e = new A.UnaryOpExpr()
  e.op = op
  e.expr = v
  const o = optimize(e)
  const folded = o.nodeType === A.NodeType.UnaryOpExpr ? 0 : 1
  return `FU\t${name}\t${folded}\t${val(o)}`
}

const T = TokenType

// BA 用例表：与 GD test_parser.gd 的 _dump_binarr 逐条一致
const BA_CASES = [
  '', ' ', 'a', 'ab', 'b 0100 0001', 'b 01000001', 'B 1', 'o 101', 'O 7',
  'd 65', 'd 300', 'D 255 0', 'x 41', 'x ff FF', 'X 0f', '41', '4_1', '_41',
  '01 02', '  01   02  ', 'x zz', 'z', 'b', 'd', 'b 2', 'o 8', '0 1',
  '9999999999999999999999', 'd 2147483647', 'd 2147483648', 'ff',
]

function dumpBinArr() {
  const out = []
  // ---- BA：二进制数组解析 ----
  for (const t of BA_CASES) {
    const bytes = []
    const ok = new BinaryArrayParser().parseBinaryArray(t, bytes)
    out.push(`BA\t${t}\t${ok === Result.Success ? 'ok' : 'err'}\t[${fmtBytes(bytes)}]`)
  }
  // ---- FB：二元折叠 ----
  out.push(fb('+', T.Add, _int(1), _int(2)))
  out.push(fb('-', T.Sub, _int(5), _int(3)))
  out.push(fb('*', T.Mul, _int(2), _int(3)))
  out.push(fb('/', T.Div, _int(7), _int(2)))
  out.push(fb('/', T.Div, _int(6), _int(3)))
  out.push(fb('/', T.Div, _int(1), _int(0)))
  out.push(fb('idiv', T.IDiv, _int(7), _int(2)))
  out.push(fb('%', T.Mod, _int(7), _int(2)))
  out.push(fb('^', T.Pow, _int(2), _int(10)))
  out.push(fb('^', T.Pow, _int(2), _int(-1)))
  out.push(fb('+', T.Add, _float(1.5), _int(1)))
  out.push(fb('+', T.Add, _int(INT64_MAX), _int(1)))
  out.push(fb('*', T.Mul, _int(INT64_MAX), _int(2)))
  out.push(fb('+', T.Add, _bool(true), _bool(true)))
  out.push(fb('+', T.Add, _str('ab'), _str('cd')))
  out.push(fb('*', T.Mul, _str('ab'), _int(3)))
  out.push(fb('*', T.Mul, _int(3), _str('ab')))
  out.push(fb('*', T.Mul, _str(''), _int(1000000)))
  out.push(fb('*', T.Mul, _str('ab'), _int(-1)))
  out.push(fb('*', T.Mul, _float(1.5), _str('ab')))
  out.push(fb('+', T.Add, _bin([1]), _bin([2])))
  out.push(fb('*', T.Mul, _bin([1]), _int(3)))
  out.push(fb('+', T.Add, _null(), _int(5)))
  out.push(fb('+', T.Add, _int(5), _null()))
  out.push(fb('+', T.Add, _null(), _null()))
  out.push(fb('-', T.Sub, _null(), _int(5)))
  out.push(fb('-', T.Sub, _int(5), _null()))
  out.push(fb('-', T.Sub, _null(), _null()))
  out.push(fb('*', T.Mul, _null(), _int(5)))
  out.push(fb('^', T.Pow, _null(), _int(5)))
  out.push(fb('==', T.EQ, _null(), _null()))
  out.push(fb('==', T.EQ, _null(), _int(1)))
  out.push(fb('!=', T.NE, _null(), _int(1)))
  out.push(fb('<', T.LT, _null(), _int(1)))
  out.push(fb('==', T.EQ, _bool(true), _bool(true)))
  out.push(fb('==', T.EQ, _bool(true), _int(1)))
  out.push(fb('==', T.EQ, _int(1), _float(1.0)))
  out.push(fb('==', T.EQ, _str('a'), _str('a')))
  out.push(fb('<', T.LT, _int(1), _int(2)))
  out.push(fb('<', T.LT, _bool(true), _int(2)))
  out.push(fb('<=', T.LE, _float(1.5), _float(1.5)))
  out.push(fb('>', T.GT, _int(2), _int(1)))
  out.push(fb('>=', T.GE, _int(2), _int(2)))
  out.push(fb('and', T.And, _int(1), _int(0)))
  out.push(fb('or', T.Or, _int(0), _str('a')))

  // ---- FU：一元折叠 ----
  out.push(fu('-', T.Sub, _bool(true)))
  out.push(fu('-', T.Sub, _bool(false)))
  out.push(fu('-', T.Sub, _int(5)))
  out.push(fu('-', T.Sub, _float(1.5)))
  out.push(fu('-', T.Sub, _int(INT64_MIN)))
  out.push(fu('!', T.Not, _null()))
  out.push(fu('!', T.Not, _int(0)))
  out.push(fu('!', T.Not, _float(0.0)))
  out.push(fu('!', T.Not, _int(5)))
  out.push(fu('!', T.Not, _str('')))
  return out
}

function goldenLines() {
  return readText('golden_binarr.txt').split('\n').filter((l) => l !== '')
}

describe('BinaryArrayParser + 常量折叠：golden_binarr.txt', () => {
  const golden = goldenLines()
  const got = dumpBinArr()

  test('行数一致', () => {
    assert.equal(got.length, golden.length, `golden ${golden.length} 行，实际产出 ${got.length} 行`)
  })

  for (let i = 0; i < Math.min(golden.length, got.length); ++i) {
    test(`#${i + 1}`, () => {
      assert.equal(got[i], golden[i])
    })
  }
})
