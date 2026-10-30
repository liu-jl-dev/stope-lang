// 反汇编：golden_disasm.txt（12 条，cpp/tools/golden_disasm.cpp dump）。
//
// 两类记录：
//   MODE=src  SRC=… CFG=none|main|collide  —— 从源码编译再反汇编
//   MODE=raw  OPS=200,1                    —— 直接给指令流（不认识的编号 / 缺操作数）
// 输出要**逐字节**等于 C++ 的 Disasm —— 两侧输出格式是同一份契约。

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { readGolden } from './golden.js'
import { Lexer } from '../src/lexer.js'
import { Parser } from '../src/parser.js'
import { Compiler } from '../src/compiler.js'
import { Program } from '../src/program.js'
import { Prog } from '../src/ast.js'
import { Disasm, DisasmNoCustom, OpcodeHasArg, CustomOpcodeHasArg } from '../src/debug.js'
import { CustomOpcodeConfig, Opcode, kFirstCustomOpcode } from '../src/opcode.js'

function makeConfig(kind) {
  if (kind === 'none' || kind === undefined) return null
  const cfg = new CustomOpcodeConfig()
  if (kind === 'main') {
    cfg.addCustomOpcode('myop', 100, 2)
    cfg.addCustomOpcode('vop', 101, -1)
  } else if (kind === 'collide') {
    // 故意用内置 Add 的编号注册 —— 反汇编只能按内置解码，并打一条 warning
    cfg.addCustomOpcode('my:steal', Opcode.Add, 2)
  }
  return cfg
}

function disasmOf(rec) {
  const cfg = makeConfig(rec.CFG)
  if (rec.MODE === 'raw') {
    const p = new Program()
    p.opcodes = (rec.OPS ?? '').split(',').filter((s) => s !== '').map(Number)
    p.variableNum = Number(rec.VARS ?? 0)
    return Disasm(p, cfg)
  }
  const ps = new Parser(new Lexer(rec.SRC ?? ''), cfg)
  const tree = new Prog()
  ps.ParseProgram(tree)
  const c = new Compiler(cfg)
  const p = new Program()
  c.Compile(tree, p)
  return Disasm(p, cfg)
}

describe('Disasm：golden_disasm.txt', () => {
  const cases = readGolden('golden_disasm.txt')

  test('用例数', () => {
    assert.equal(cases.length, 12)
  })

  for (const rec of cases) {
    test(`${rec.ID} (${rec.MODE}/${rec.CFG ?? 'raw'})`, () => {
      assert.equal(disasmOf(rec), rec.DIS)
    })
  }

  test('DisasmNoCustom 等价于 Disasm(prog, null)', () => {
    const p = new Program()
    p.opcodes = [4, 0, 32, 1]
    p.intConsts = [7n]
    p.maxReturnNum = 1
    assert.equal(DisasmNoCustom(p), Disasm(p, null))
  })

  test('OpcodeHasArg 的分档', () => {
    // 4..11（PushInt … At）带一个操作数
    for (let op = 4; op <= 11; ++op) assert.ok(OpcodeHasArg(op), `op ${op}`)
    // 0..3 / 12..27 不带
    for (const op of [0, 1, 2, 3, 12, 13, 20, 27]) assert.ok(!OpcodeHasArg(op), `op ${op}`)
    // If / GoTo / Return 带
    for (const op of [28, 29, 32]) assert.ok(OpcodeHasArg(op), `op ${op}`)
    // 30 / 31 不带
    for (const op of [30, 31]) assert.ok(!OpcodeHasArg(op), `op ${op}`)
  })

  test('CustomOpcodeHasArg：只有变长才带操作数', () => {
    const cfg = makeConfig('main')
    assert.ok(CustomOpcodeHasArg(101, cfg), 'vop 变长')
    assert.ok(!CustomOpcodeHasArg(100, cfg), 'myop 定长')
    assert.ok(!CustomOpcodeHasArg(100, null))
  })

  test('custom opcodes 段按**编号**排序，不是名字序', () => {
    // C++ 的 customByOpcode 是 map<short, ...>，迭代序是编号序；配置表本身是
    // std::map（名字序）。两条指令的名字序与编号序故意相反，golden 那 12 条
    // （myop/vop 恰好两序一致）看不出来。
    const cfg = new CustomOpcodeConfig()
    cfg.addCustomOpcode('zzz', kFirstCustomOpcode + 0, 0) // 33，名字最大
    cfg.addCustomOpcode('aaa', kFirstCustomOpcode + 1, 0) // 34，名字最小
    const p = new Program()
    p.opcodes = [Opcode.PushInt, 0] // 不含自定义指令，但配置里的注册项照样要列
    const out = Disasm(p, cfg)
    const seg = out.slice(out.indexOf('custom opcodes:'))
    assert.ok(seg.indexOf('zzz') < seg.indexOf('aaa'), out)
  })
})
