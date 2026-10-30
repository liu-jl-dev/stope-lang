// 跑一条 golden.txt 用例：词法 -> 语法 -> 编译，产出各字段的实际值。
//
// 期望值全部来自 cpp/tools/golden.cpp 的 dump（不是手写），所以这里只负责「跑一遍、
// 把结果摊平成与 golden 记录同名的字段」，比对交给各 test 文件。

import { Lexer } from '../src/lexer.js'
import { Parser } from '../src/parser.js'
import { Compiler } from '../src/compiler.js'
import { Program } from '../src/program.js'
import { Prog, shapeProg } from '../src/ast.js'
import { Result } from '../src/common.js'
import { CustomOpcodeConfig } from '../src/opcode.js'
import { dumpProgram, unescape } from './golden.js'

// golden.cpp 里 g_cfg 是全局的：所有用例都带着这两条自定义指令编译
function makeConfig() {
  const cfg = new CustomOpcodeConfig()
  cfg.addCustomOpcode('myop', 100, 2)
  cfg.addCustomOpcode('vop', 101, -1)
  return cfg
}

const cfg = makeConfig()

// 语句行号序列（关系到 L 组）：逗号分隔，与 golden 的 LINES 字段同格式
function stmtLines(p) {
  return p.stmts.map((s) => s.line).join(',')
}

export function runCase(rec) {
  const src = unescape(rec.SRC ?? '')
  const fold = rec.FOLD === '1'
  const lx = new Lexer(src)
  const ps = new Parser(lx, cfg)
  ps.constFolding = fold
  const tree = new Prog()
  ps.ParseProgram(tree)
  const out = new Program()
  const c = new Compiler(cfg)
  const rc = c.Compile(tree, out)
  return {
    SRC: src,
    SHAPE: shapeProg(tree),
    LINES: stmtLines(tree),
    PERR: String(ps.errors.length),
    LEXERR: String(lx.errors.length),
    PERRS: ps.errors.join('|'),
    LEXERRS: lx.errors.join('|'),
    CMP: rc === Result.Success ? 'OK' : 'ERR',
    OUT: dumpProgram(out, cfg),
    CERRS: c.errors.join('|'),
    tree,
    out,
    rc,
  }
}

export { cfg }
