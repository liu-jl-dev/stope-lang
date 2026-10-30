// AST 节点定义 —— 与 cpp/include/stope/ast.hpp 逐项对齐。
//
// 命名沿用 C++ 的 camelCase（leftExpr / firstProg / keyExprs …），不改成 JS 习惯的
// 其它写法：这一层的价值就在于能和 ast.hpp 逐行对照。
//
// shapeExpr / shapeStmt / shapeProg 是【测试用】序列化，严格照抄
// cpp/test/test_common.hpp 的同名函数，格式见 docs/zh-cn/parser-test-plan.md §2。
// 浮点用 C 的 printf("%g")（精度 6），JS 没有等价物，照 GDScript 侧的 fmtG 复刻。

import { TokenType } from './token.js'

export const NodeType = {}
NodeType[NodeType['Node'] = 0] = 'Node'
NodeType[NodeType['Prog'] = 1] = 'Prog'
NodeType[NodeType['Stmt'] = 2] = 'Stmt'
NodeType[NodeType['Expr'] = 3] = 'Expr'
NodeType[NodeType['ExprStmt'] = 4] = 'ExprStmt'
NodeType[NodeType['LetStmt'] = 5] = 'LetStmt'
NodeType[NodeType['ReturnStmt'] = 6] = 'ReturnStmt'
NodeType[NodeType['ExportStmt'] = 7] = 'ExportStmt'
NodeType[NodeType['BlockStmt'] = 8] = 'BlockStmt'
NodeType[NodeType['IfStmt'] = 9] = 'IfStmt'
NodeType[NodeType['WhileStmt'] = 10] = 'WhileStmt'
NodeType[NodeType['AssignStmt'] = 11] = 'AssignStmt'
NodeType[NodeType['BreakStmt'] = 12] = 'BreakStmt'
NodeType[NodeType['ContinueStmt'] = 13] = 'ContinueStmt'
NodeType[NodeType['NullExpr'] = 14] = 'NullExpr'
NodeType[NodeType['BoolExpr'] = 15] = 'BoolExpr'
NodeType[NodeType['IntExpr'] = 16] = 'IntExpr'
NodeType[NodeType['FloatExpr'] = 17] = 'FloatExpr'
NodeType[NodeType['BinArrExpr'] = 18] = 'BinArrExpr'
NodeType[NodeType['StringExpr'] = 19] = 'StringExpr'
NodeType[NodeType['IdentExpr'] = 20] = 'IdentExpr'
NodeType[NodeType['ArgcExpr'] = 21] = 'ArgcExpr'
NodeType[NodeType['ArgsExpr'] = 22] = 'ArgsExpr'
NodeType[NodeType['UnaryOpExpr'] = 23] = 'UnaryOpExpr'
NodeType[NodeType['BinaryOpExpr'] = 24] = 'BinaryOpExpr'
NodeType[NodeType['CallExpr'] = 25] = 'CallExpr'
NodeType[NodeType['AtExpr'] = 26] = 'AtExpr'
NodeType[NodeType['CustomOpcodeExpr'] = 27] = 'CustomOpcodeExpr'
Object.freeze(NodeType)

// 10 档优先级，与 cpp/include/stope/common.hpp 的 OpPrecedence 同序同值
export const Precedence = {
  Lowest: 0,
  Or: 1,
  And: 2,
  Equals: 3,
  LessGreater: 4,
  AddSub: 5,
  MulDiv: 6,
  Pow: 7,
  Prefix: 8,
  Paren: 9,
}

// ================================ 格式化小工具 ================================
// 与 test_common.hpp 的 escUtf8 对齐：只转义 \\ " \n \r \t，非 ASCII 打成 '?'
export function esc(s) {
  let o = ''
  for (const ch of s) {
    if (ch === '\\') o += '\\\\'
    else if (ch === '"') o += '\\"'
    else if (ch === '\n') o += '\\n'
    else if (ch === '\r') o += '\\r'
    else if (ch === '\t') o += '\\t'
    else if (ch.codePointAt(0) < 128) o += ch
    else o += '?'
  }
  return o
}

// BinArr 的字节二分十六进制，小写两位，逗号分隔：BinArr[04,01]
export function fmtBytes(ba) {
  return Array.from(ba, (b) => b.toString(16).padStart(2, '0')).join(',')
}

// 复刻 C 的 printf("%g")（精度 6）。JS 的 toPrecision 走的是二进制舍入决策，
// 与 %g 的「先定十进制指数再定小数位」不是一回事，所以这里照 GDScript 侧的
// fmtG 手工实现同一套决策，供 shape 与 Program 序列化共用。
//
// 决策：先取十进制指数 X（10^X <= |v| < 10^(X+1)）
//   X < -4 或 X >= 6 -> 科学计数法，尾数 5 位小数
//   否则             -> 定点表示，5 - X 位小数
// 两种情形都去掉尾部 0 与孤立的小数点。舍入进位到 10 时 X 要 +1 再重新决策，
// 否则 999999.9 会打成 "1e+06" 而 glibc 打 "100000"。
//
// 已知边界（与 GDScript 侧同）：次正规数（|v| < 2.2e-308）不保证 6 位有效数字，
// 因此用例里不要拿次正规数做跨实现比对。
const G_PRECISION = 6

export function fmtG(v) {
  if (Number.isNaN(v)) return 'nan'
  if (!Number.isFinite(v)) return v > 0 ? 'inf' : '-inf'
  if (v === 0) return Object.is(v, -0) ? '-0' : '0'
  const sign = v < 0 ? '-' : ''
  const a = Math.abs(v)
  let x = Math.floor(Math.log10(a))
  let guard = 40 // 校正最多迭代这么多次，防止 Math.pow 的误差把循环卡死
  while (guard-- > 0 && Math.pow(10, x) > a) x -= 1
  while (guard-- > 0 && Math.pow(10, x + 1) <= a) x += 1
  let mant = (a / Math.pow(10, x)).toPrecision(G_PRECISION)
  if (mant.startsWith('10')) { // 舍入进位
    x += 1
    mant = '1.' + '0'.repeat(G_PRECISION - 1)
  }
  if (x < -4 || x >= G_PRECISION) {
    return sign + stripZeros(mant) + 'e' + (x >= 0 ? '+' : '-') + String(Math.abs(x)).padStart(2, '0')
  }
  return sign + stripZeros((a).toFixed(Math.max(0, G_PRECISION - 1 - x)))
}

// 去掉小数尾部多余的 0，以及随之孤立的小数点：1.50000 -> 1.5   15.0000 -> 15
function stripZeros(s) {
  if (!s.includes('.')) return s
  s = s.replace(/0+$/, '')
  if (s.endsWith('.')) s = s.slice(0, -1)
  return s
}

export function nodeTypeName(t) {
  return NodeType[t] ?? `?${t}`
}

function indent(level) {
  return '  '.repeat(level)
}

function e_(n) {
  return n ? n.toStr() : '<null>'
}

function opText(op) {
  if (op === TOK.Sub) return '-'
  if (op === TOK.Not) return '!'
  return `${TOK_NAMES[op]}(`
}

// 运算符的显示文本（错误信息用；节点里的 op 存的是 TokenType，不是这个字符串）
export const binopLiteralMap = {}

const TOK = TokenType
const TOK_NAMES = TokenType

const PREC = {
  [TOK.Or]: Precedence.Or,
  [TOK.And]: Precedence.And,
  [TOK.EQ]: Precedence.Equals,
  [TOK.NE]: Precedence.Equals,
  [TOK.LT]: Precedence.LessGreater,
  [TOK.LE]: Precedence.LessGreater,
  [TOK.GT]: Precedence.LessGreater,
  [TOK.GE]: Precedence.LessGreater,
  [TOK.Add]: Precedence.AddSub,
  [TOK.Sub]: Precedence.AddSub,
  [TOK.Mul]: Precedence.MulDiv,
  [TOK.Div]: Precedence.MulDiv,
  [TOK.IDiv]: Precedence.MulDiv,
  [TOK.Mod]: Precedence.MulDiv,
  [TOK.Pow]: Precedence.Pow,
  // 调用 ()、取元素 [] 也是二元形式，优先级最高
  [TOK.LParen]: Precedence.Paren,
  [TOK.LBrack]: Precedence.Paren,
}
export const binopPrecMap = PREC

const LIT = {
  [TOK.Or]: '||',
  [TOK.And]: '&&',
  [TOK.EQ]: '==',
  [TOK.NE]: '!=',
  [TOK.LT]: '<',
  [TOK.LE]: '<=',
  [TOK.GT]: '>',
  [TOK.GE]: '>=',
  [TOK.Add]: '+',
  [TOK.Sub]: '-',
  [TOK.Mul]: '*',
  [TOK.Div]: '/',
  [TOK.IDiv]: 'idiv',
  [TOK.Mod]: '%',
  [TOK.Pow]: '^',
}
Object.assign(binopLiteralMap, LIT)

// ================================ 基类 ================================
export class Node_ {
  constructor(line = -1) {
    this.line = line
    this.nodeType = NodeType.Node
  }
}

export class Stmt extends Node_ {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.Stmt
  }
  toStr(_level = 0) {
    return ';\n'
  }
}

export class Expr extends Node_ {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.Expr
  }
  toStr(_level = 0) {
    return '()'
  }
}

// ================================ prog ================================
// prog : stmt*
export class Prog extends Node_ {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.Prog
    this.stmts = []
  }
  toStr(level = 0) {
    return this.stmts.map((s) => s.toStr(level)).join('')
  }
}

// ================================ 语句 ================================
// expr_stmt : expr ";"
export class ExprStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.ExprStmt
    this.expr = null
  }
  toStr(level = 0) {
    return indent(level) + e_(this.expr) + ';\n'
  }
}

// let_stmt : "let" ident ( ("," ident)* | ("=" expr) )? ";"
export class LetStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.LetStmt
    this.hasAssign = false
    this.idents = []
    this.expr = null
  }
  identNum() {
    return this.idents.length
  }
  toStr(level = 0) {
    let s = indent(level) + 'let'
    if (this.hasAssign) {
      s += ` ${this.idents.length > 0 ? this.idents[0] : '?'} = ${e_(this.expr)}`
    } else {
      for (const id of this.idents) s += ` ${id},`
      if (this.idents.length > 0) s = s.slice(0, -1)
    }
    return s + ';\n'
  }
}

// return_stmt : "return" ( expr ( "," expr )* )? ";"
export class ReturnStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.ReturnStmt
    this.exprs = []
  }
  exprNum() {
    return this.exprs.length
  }
  toStr(level = 0) {
    let s = indent(level) + 'return'
    for (const e of this.exprs) s += ` ${e_(e)},`
    if (this.exprs.length > 0) s = s.slice(0, -1)
    return s + ';\n'
  }
}

// export_stmt : "export" ident ( "," ident )* ";"
export class ExportStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.ExportStmt
    this.idents = []
  }
  identNum() {
    return this.idents.length
  }
  toStr(level = 0) {
    let s = indent(level) + 'export'
    for (const id of this.idents) s += ` ${id},`
    if (this.idents.length > 0) s = s.slice(0, -1)
    return s + ';\n'
  }
}

// block_stmt : "{" prog "}"
//
// C++ 侧 Prog 是【值】成员（永远存在），错误路径上也不是 null 而是一个空 Prog，
// 形状串输出 Block{} 而不是 Block{null}。JS 是引用类型，所以构造时就建好实例 ——
// 只有 IfStmt.elseProg 例外，它对应 C++ 的 std::optional<Prog>。
export class BlockStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.BlockStmt
    this.prog = new Prog()
  }
  toStr(level = 0) {
    return `${indent(level)}{\n${this.prog.toStr(level + 1)}${indent(level)}}\n`
  }
}

export class IfStmtElif extends Node_ {
  constructor(line = -1) {
    super(line)
    this.cond = null
    this.prog = new Prog()
  }
}

// if_stmt : "if" expr "{" prog "}" ( "elif" expr "{" prog "}" )* ( "else" "{" prog "}" )?
export class IfStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.IfStmt
    this.cond = null
    this.firstProg = new Prog()
    this.elifs = []
    this.elseProg = null // 没有 else 分支时为 null（对应 C++ 的 std::optional）
  }
  hasElse() {
    return this.elseProg !== null
  }
  toStr(level = 0) {
    let o = `${indent(level)}if ${e_(this.cond)} ${this.firstProg.toStr(level)}`
    for (const ei of this.elifs) {
      o += `${indent(level)}elif ${e_(ei.cond)} ${ei.prog.toStr(level)}`
    }
    if (this.hasElse()) o += `${indent(level)}else ${this.elseProg.toStr(level)}`
    return o
  }
}

// while_stmt : "while" expr? "{" prog "}"   —— cond 为 null 表示无条件循环
export class WhileStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.WhileStmt
    this.cond = null
    this.prog = new Prog()
  }
  toStr(level = 0) {
    return `${indent(level)}while ${e_(this.cond)} ${this.prog.toStr(level)}`
  }
}

// assign_stmt : expr "=" expr ";"
export class AssignStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.AssignStmt
    this.leftExpr = null
    this.rightExpr = null
  }
  toStr(level = 0) {
    return `${indent(level)}${e_(this.leftExpr)} = ${e_(this.rightExpr)};\n`
  }
}

export class BreakStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.BreakStmt
  }
  toStr(level = 0) {
    return indent(level) + 'break;\n'
  }
}

export class ContinueStmt extends Stmt {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.ContinueStmt
  }
  toStr(level = 0) {
    return indent(level) + 'continue;\n'
  }
}

// ================================ 表达式 ================================
export class NullExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.NullExpr
  }
  toStr() {
    return 'null'
  }
}

export class BoolExpr extends Expr {
  constructor(line = -1, v = false) {
    super(line)
    this.nodeType = NodeType.BoolExpr
    this.value = v
  }
  toStr() {
    return String(this.value)
  }
}

// JS 的整数用 BigInt 表示（与 lexer 一致），所以 IntExpr.value 是 BigInt。
export class IntExpr extends Expr {
  constructor(line = -1, v = 0n) {
    super(line)
    this.nodeType = NodeType.IntExpr
    this.value = v
  }
  toStr() {
    return this.value.toString()
  }
}

export class FloatExpr extends Expr {
  constructor(line = -1, v = 0.0) {
    super(line)
    this.nodeType = NodeType.FloatExpr
    this.value = v
  }
  toStr() {
    return fmtG(this.value)
  }
}

// value 是 Uint8Array（对应 C++ 的 std::vector<char> / GD 的 PackedByteArray）
export class BinArrExpr extends Expr {
  constructor(line = -1, v = new Uint8Array(0)) {
    super(line)
    this.nodeType = NodeType.BinArrExpr
    this.value = v
  }
  toStr() {
    return `'${fmtBytes(this.value)}'`
  }
}

export class StringExpr extends Expr {
  constructor(line = -1, v = '') {
    super(line)
    this.nodeType = NodeType.StringExpr
    this.value = v
  }
  toStr() {
    return `"${this.value}"`
  }
}

export class IdentExpr extends Expr {
  constructor(line = -1, v = '') {
    super(line)
    this.nodeType = NodeType.IdentExpr
    this.ident = v
  }
  toStr() {
    return this.ident
  }
}

export class ArgcExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.ArgcExpr
  }
  toStr() {
    return 'argc'
  }
}

export class ArgsExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.ArgsExpr
    this.keyExpr = null
  }
  toStr() {
    return `args[${e_(this.keyExpr)}]`
  }
}

export class UnaryOpExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.UnaryOpExpr
    this.op = TOK.Invalid // TokenType
    this.expr = null
  }
  toStr() {
    return opText(this.op) + e_(this.expr)
  }
}

export class BinaryOpExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.BinaryOpExpr
    this.leftExpr = null
    this.op = TOK.Invalid // TokenType
    this.rightExpr = null
  }
  toStr() {
    let o = LIT[this.op] ?? '?'
    o = o === 'idiv' ? ' idiv ' : ` ${o} `
    return `(${e_(this.leftExpr)}${o}${e_(this.rightExpr)})`
  }
}

export class CallExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.CallExpr
    this.callee = null
    this.args = []
  }
  toStr() {
    let s = `${e_(this.callee)}(`
    for (const a of this.args) s += `${e_(a)},`
    if (this.args.length > 0) s = s.slice(0, -1)
    return s + ')'
  }
}

export class AtExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.AtExpr
    this.container = null
    this.keyExprs = []
  }
  toStr() {
    let s = `${e_(this.container)}[`
    for (const a of this.keyExprs) s += `${e_(a)},`
    if (this.keyExprs.length > 0) s = s.slice(0, -1)
    return s + ']'
  }
}

// custom_opcode_expr : custom "(" ( expr ( "," expr )* )? ")"
export class CustomOpcodeExpr extends Expr {
  constructor(line = -1) {
    super(line)
    this.nodeType = NodeType.CustomOpcodeExpr
    this.opcodeName = ''
    this.args = []
  }
  toStr() {
    let s = `${this.opcodeName}(`
    for (const a of this.args) s += `${e_(a)},`
    if (this.args.length > 0) s = s.slice(0, -1)
    return s + ')'
  }
}

// ================================ 序列化：测试用 ================================
// 严格照抄 cpp/test/test_common.hpp 的 shapeExpr / shapeStmt / shapeProg：
//   Null / Argc / Bool(true) / Int(31) / Float(1.5) / BinArr[04,01] / Str("a\nb") /
//   Ident(a) / Args(null) / Unary(Sub, Int(1)) / Bin(Add, Int(1), Int(2)) /
//   Call(f; Int(1)) / At(a; Int(1)) / Custom(myop; Int(1)) / Err(L-1)
//   ExprStmt(..) / Let[a,b]=Int(1) / Return(Int(1), Int(2)) / Export[a] /
//   Block{..} / If(c){..}Elif(c){..}Else{..} / While(c){..} /
//   Assign(l, r) / Break / Continue
// prog：语句按 " ; " 连接，无外层包装；空 prog -> ""
export function shapeProg(p) {
  if (p === null || p === undefined) return 'null'
  return p.stmts.map(shapeStmt).join(' ; ')
}

export function shapeStmt(s) {
  if (s === null || s === undefined) return 'null'
  switch (s.nodeType) {
    case NodeType.ExprStmt:
      return `ExprStmt(${shapeExpr(s.expr)})`
    case NodeType.LetStmt: {
      let d = `Let[${s.idents.map(esc).join(',')}]`
      if (s.hasAssign) d += '=' + shapeExpr(s.expr)
      return d
    }
    case NodeType.ReturnStmt:
      return `Return(${s.exprs.map(shapeExpr).join(', ')})`
    case NodeType.ExportStmt:
      return `Export[${s.idents.map(esc).join(',')}]`
    case NodeType.BlockStmt:
      return `Block{${shapeProg(s.prog)}}`
    case NodeType.IfStmt: {
      let d = `If(${shapeExpr(s.cond)}){${shapeProg(s.firstProg)}}`
      for (const ei of s.elifs) d += `Elif(${shapeExpr(ei.cond)}){${shapeProg(ei.prog)}}`
      if (s.elseProg !== null) d += `Else{${shapeProg(s.elseProg)}}`
      return d
    }
    case NodeType.WhileStmt:
      return `While(${shapeExpr(s.cond)}){${shapeProg(s.prog)}}`
    case NodeType.AssignStmt:
      return `Assign(${shapeExpr(s.leftExpr)}, ${shapeExpr(s.rightExpr)})`
    case NodeType.BreakStmt:
      return 'Break'
    case NodeType.ContinueStmt:
      return 'Continue'
    default:
      return '?' + nodeTypeName(s.nodeType)
  }
}

export function shapeExpr(e) {
  if (e === null || e === undefined) return 'null'
  switch (e.nodeType) {
    case NodeType.Expr: // 失败路径返回的裸节点：line 恒为 -1
      return `Err(L${e.line})`
    case NodeType.NullExpr:
      return 'Null'
    case NodeType.ArgcExpr:
      return 'Argc'
    case NodeType.BoolExpr:
      return e.value ? 'Bool(true)' : 'Bool(false)'
    case NodeType.IntExpr:
      return `Int(${e.value.toString()})`
    case NodeType.FloatExpr:
      return `Float(${fmtG(e.value)})`
    case NodeType.BinArrExpr:
      return `BinArr[${fmtBytes(e.value)}]`
    case NodeType.StringExpr:
      return `Str("${esc(e.value)}")`
    case NodeType.IdentExpr:
      return `Ident(${esc(e.ident)})`
    case NodeType.ArgsExpr:
      return e.keyExpr === null ? 'Args(null)' : `Args(${shapeExpr(e.keyExpr)})`
    case NodeType.UnaryOpExpr:
      return `Unary(${TOK_NAMES[e.op]}, ${shapeExpr(e.expr)})`
    case NodeType.BinaryOpExpr:
      return `Bin(${TOK_NAMES[e.op]}, ${shapeExpr(e.leftExpr)}, ${shapeExpr(e.rightExpr)})`
    case NodeType.CallExpr:
      return `Call(${shapeExpr(e.callee)}${e.args.map((a) => `; ${shapeExpr(a)}`).join('')})`
    case NodeType.AtExpr:
      return `At(${shapeExpr(e.container)}${e.keyExprs.map((k) => `; ${shapeExpr(k)}`).join('')})`
    case NodeType.CustomOpcodeExpr:
      return `Custom(${esc(e.opcodeName)}${e.args.map((a) => `; ${shapeExpr(a)}`).join('')})`
    default:
      return '?' + nodeTypeName(e.nodeType)
  }
}
