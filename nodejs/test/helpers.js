// lexer 测试的断言族，对应 cpp/test/test_common.hpp 里的 EXPECT_* 宏。
//
// 用法：
//   const r = lexAll('0x1F')
//   expectType(r, 0, TokenType.Integer, 'I-06')
//   expectInt(r, 0, 31, 'I-06')
//
// 断言分族是仓库的既有约定（lexer 无前缀、parser 带 P、STML 带 STOK/SP），
// 每个 expect* 的最后一个参数是 C++ 侧同款用例的编号，方便两边对照。
//
// 断言失败时打印 token 全貌（类型 / lexeme / parsed / line / 值），
// 错误相关的断言额外打印整份 errors —— 与 C++ 的 tokDesc / errDetail 一致。

import assert from 'node:assert/strict'
import { Lexer } from '../src/lexer.js'
import { TokenType } from '../src/token.js'

// 死循环保险丝：NextToken 若不消费字符，词法就停不下来（对齐 C++ 的 10000 次上限）
const kMaxTokens = 10000

// 一次扫到底。返回 { tokens, errors }，tokens 最后一个是 Eof。
// custom 是 CustomOpcodeConfig（可省略），与 C++ 的 lexAll(src, cfg) 同签名。
export function lexAll(src, custom) {
  const lx = new Lexer(src)
  const tokens = []
  for (let i = 0; i < kMaxTokens; ++i) {
    const t = lx.NextToken(custom)
    tokens.push(t)
    if (t.type === TokenType.Eof) break
  }
  return { tokens, errors: lx.errors }
}

export function typeName(type) {
  return TokenType[type]
}

// 失败时用的 token 全貌
function tokDesc(r, i) {
  const t = r.tokens[i]
  if (t === undefined) return `<index out of range>（共 ${r.tokens.length} 个 token）`
  let d = `tok[${i}] type=${typeName(t.type)}`
  d += ` lex=${JSON.stringify(t.lexeme)}`
  d += ` parsed=${JSON.stringify(t.parsed)}`
  d += ` line=${t.line}`
  if (t.type === TokenType.Integer || t.type === TokenType.Float) d += ` value=${t.value}`
  return d
}

function errDetail(r) {
  return `errors=${r.errors.length}` + r.errors.map((e) => `\n         [${e}]`).join('')
}

export function expectType(r, i, type, id) {
  const t = r.tokens[i]
  assert.ok(
    t !== undefined && t.type === type,
    `[${id}] type == ${typeName(type)}\n         ${tokDesc(r, i)}`,
  )
}

export function expectLex(r, i, lexeme, id) {
  const t = r.tokens[i]
  assert.ok(
    t !== undefined && t.lexeme === lexeme,
    `[${id}] lexeme == ${JSON.stringify(lexeme)}\n         ${tokDesc(r, i)}`,
  )
}

export function expectParsed(r, i, parsed, id) {
  const t = r.tokens[i]
  assert.ok(
    t !== undefined && t.parsed === parsed,
    `[${id}] parsed == ${JSON.stringify(parsed)}\n         ${tokDesc(r, i)}`,
  )
}

// 整数。token.value 是 BigInt（int64 的值范围，JS 的 Number 装不下），
// 期望值可以写 BigInt 字面量（9223372036854775807n）或普通数字，两边都转成 BigInt 再比。
export function expectInt(r, i, value, id) {
  const t = r.tokens[i]
  assert.ok(
    t !== undefined && t.type === TokenType.Integer && BigInt(t.value) === BigInt(value),
    `[${id}] integer == ${value}\n         ${tokDesc(r, i)}`,
  )
}

// 浮点：C++ 用 fabs(a-b) < 1e-9，这里同理
export function expectDbl(r, i, value, id) {
  const t = r.tokens[i]
  assert.ok(
    t !== undefined && t.type === TokenType.Float && Math.abs(t.value - value) < 1e-9,
    `[${id}] floating == ${value}\n         ${tokDesc(r, i)}`,
  )
}

export function expectLine(r, i, line, id) {
  const t = r.tokens[i]
  assert.ok(
    t !== undefined && t.line === line,
    `[${id}] line == ${line}\n         ${tokDesc(r, i)}`,
  )
}

export function expectCount(r, n, id) {
  assert.equal(
    r.tokens.length,
    n,
    `[${id}] token count == ${n}，实际 ${r.tokens.length}`,
  )
}

// 类型序列整体比对，如 expectSeq(r, 'Let Ident Eof', 'G-01')
export function expectSeq(r, seq, id) {
  const got = r.tokens.map((t) => typeName(t.type)).join(' ')
  assert.equal(got, seq, `[${id}] sequence == ${seq}\n         got=[${got}]`)
}

export function expectErrCount(r, n, id) {
  assert.equal(r.errors.length, n, `[${id}] error count == ${n}\n         ${errDetail(r)}`)
}

export function expectErrHas(r, sub, id) {
  assert.ok(
    r.errors.some((e) => e.includes(sub)),
    `[${id}] errors contains ${JSON.stringify(sub)}\n         ${errDetail(r)}`,
  )
}

export function expectNoErrors(r, id) {
  expectErrCount(r, 0, id)
}
