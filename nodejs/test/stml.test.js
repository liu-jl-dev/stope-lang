// STML 两组测试：词法（STOK 族）与语法（SP 族），**全部由 golden 数据驱动**。
//
// 用例清单 gdscript/test/data/stml_cases.txt 是两侧共用的唯一真源：C++ 探针读它
// dump 出 golden_stml.txt，本文件读同一份清单 + golden 逐字段比对。加删用例只改清单。
//
// 属性顺序：C++ 的 Element.attrs 是 std::map（字典序），本实现是 Map（插入序）。
// 契约明确「属性顺序不保证」（stml-test-plan.md §2.3），所以形状串里按字典序输出，
// 否则两头会为了一个不保证的顺序互相打架。

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readText, readGolden } from './golden.js'
import { Lexer, State } from '../src/stml_lexer.js'
import { Parser } from '../src/stml_parser.js'
import { Element, TokenType } from '../src/stml.js'
import { esc } from '../src/ast.js'
import { Result } from '../src/common.js'

// token 类型名的比对只覆盖「双方实现都提供」的 lexeme（计划 §2.2：标点与 Eof 的
// lexeme 属实现自定，不断言）
const LEXEME_TYPES = new Set([
  TokenType.Word,
  TokenType.String,
  TokenType.Text,
  TokenType.NevextSrc,
  TokenType.StopeSrc,
])

// 用例清单：ID / KIND / ST / SF / SRC / TIMES
function readCases() {
  const out = []
  for (const line of readText('stml_cases.txt').split('\n')) {
    if (line === '' || line.startsWith('#')) continue
    const one = {}
    for (const part of line.split('\t')) {
      const eq = part.indexOf('=')
      if (eq < 0) continue
      one[part.slice(0, eq)] = part.slice(eq + 1)
    }
    if (!one.ID) continue
    out.push({
      id: one.ID,
      kind: one.KIND,
      state: one.ST ?? 'Xml',
      stateFunc: one.SF ?? '',
      src: unesc(one.SRC ?? '').repeat(Number(one.TIMES ?? 1)),
    })
  }
  return out
}

// 与探针的 unesc 同一套规则：\\ \n \r \t
function unesc(s) {
  let o = ''
  for (let i = 0; i < s.length; ) {
    if (s[i] === '\\' && i + 1 < s.length) {
      const c = s[i + 1]
      if (c === '\\' || c === 'n' || c === 'r' || c === 't') {
        o += c === '\\' ? '\\' : c === 'n' ? '\n' : c === 'r' ? '\r' : '\t'
        i += 2
        continue
      }
    }
    o += s[i]
    ++i
  }
  return o
}

function lexAll(src, state) {
  const lx = new Lexer(src)
  lx.state = state
  const toks = []
  for (let i = 0; i < 10000; ++i) {
    const t = lx.NextToken()
    toks.push(t)
    if (t.type === TokenType.Eof) break
  }
  return { toks, errors: lx.errors }
}

function dumpLex(toks) {
  let s = ''
  let lexs = ''
  for (let i = 0; i < toks.length; ++i) {
    const t = toks[i]
    if (i) s += ' '
    s += `${TokenType[t.type]}(${t.line})`
    if (LEXEME_TYPES.has(t.type)) {
      if (lexs !== '') lexs += ','
      lexs += `${i}:${esc(t.lexeme)}`
    }
  }
  return { toks: s, lexs }
}

// 默认回调：<sto> -> Stope，<nev> -> Nevext，<p> -> Text，其余 -> Xml
function defaultStateFunc(tag, _attrs) {
  if (tag === 'sto') return State.Stope
  if (tag === 'nev') return State.Nevext
  if (tag === 'p') return State.Text
  return State.Xml
}
const textStateFunc = () => State.Text

// 形状串：字段顺序固定 —— tag、行号、自闭合、属性（字典序）、文本、子元素
function shapeElem(e) {
  let d = `Elem(${esc(e.tag)}, L${e.line}`
  if (e.selfClosing) d += ', /'
  const names = [...e.attrs.keys()].sort()
  for (const k of names) {
    const v = e.attrs.get(k)
    d += ', @' + esc(k)
    if (v !== '') d += '="' + esc(v) + '"'
  }
  if (e.text !== '') d += ', T="' + esc(e.text) + '"'
  if (e.children.length > 0) {
    d += ', C=['
    for (let i = 0; i < e.children.length; ++i) {
      if (i) d += ' '
      d += shapeElem(e.children[i])
    }
    d += ']'
  }
  return d + ')'
}

function joinErr(errs) {
  return errs.map(esc).join('|')
}

const STATE = { Xml: State.Xml, Text: State.Text, Nevext: State.Nevext, Stope: State.Stope }

describe('STML：词法（STOK 族）', () => {
  const cases = readCases().filter((c) => c.kind !== 'parse')
  const golden = new Map(readGolden('golden_stml.txt', false).map((r) => [r.ID, r]))

  test(`用例数一致：清单 ${cases.length} 条`, () => {
    assert.equal(cases.length, golden.size - readGolden('golden_stml.txt', false).filter((r) => r.KIND === 'parse').length)
    for (const c of cases) assert.ok(golden.has(c.id), `golden 缺少 ${c.id}`)
  })

  for (const c of cases) {
    test(c.id, () => {
      const g = golden.get(c.id)
      const r = lexAll(c.src, STATE[c.state] ?? State.Xml)
      const d = dumpLex(r.toks)
      assert.equal(d.toks, g.TOKS, `${c.id} TOKS`)
      assert.equal(d.lexs, g.LEXS, `${c.id} LEXS`)
      assert.equal(String(r.errors.length), g.ERRN, `${c.id} ERRN`)
      assert.equal(joinErr(r.errors), g.ERRS, `${c.id} ERRS`)
    })
  }
})

describe('STML：语法（SP 族）', () => {
  const cases = readCases().filter((c) => c.kind === 'parse')
  const golden = new Map(readGolden('golden_stml.txt', false).map((r) => [r.ID, r]))

  for (const c of cases) {
    test(c.id, () => {
      const g = golden.get(c.id)
      const lx = new Lexer(c.src)
      const p = new Parser(lx)
      const root = new Element()
      const sf =
        c.stateFunc === 'null'
          ? null
          : c.stateFunc === 'text'
            ? textStateFunc
            : defaultStateFunc
      const rc = p.Parse(root, sf)
      assert.equal(shapeElem(root), g.SHAPE, `${c.id} SHAPE`)
      assert.equal(rc === Result.Success ? 'Success' : 'Error', g.RESULT, `${c.id} RESULT`)
      assert.equal(String(p.errors.length), g.ERRN, `${c.id} ERRN`)
      assert.equal(joinErr(p.errors), g.ERRS, `${c.id} ERRS`)
      assert.equal(String(lx.errors.length), g.LEXERRN, `${c.id} LEXERRN`)
      assert.equal(joinErr(lx.errors), g.LEXERRS, `${c.id} LEXERRS`)
    })
  }
})
