// golden 数据的读取与「单行比对格式」的生成。
//
// 数据由 cpp/tools/ 下的探针生成并入库在 gdscript/test/data/（仓库里只有这一份，
// GDScript 侧从 res://test/data/ 读，nodejs 侧从相对路径读同一个目录 —— 不复制第二份，
// 否则 C++ 改行为时会出现「哪一份才是真值」的问题）。重生成（在 cpp/ 下）：
//   cmake --build build --target gen-golden
//
// 记录格式：一条用例一行，字段之间用 TAB，每个字段是 KEY=VALUE，
// 值里的 \\ \n \r \t 已转义。解析后按 KEY 取用即可。
//
// dumpProgram 是「单行比对格式」（docs/zh-cn/compiler-test-plan.md §2.3），
// 对应 cpp/tools/golden.cpp 的私有 dumpLine 与 gdscript/test/test_util.gd 的
// dump_program —— 三方都不进库，只在测试里用。

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { TokenType } from '../src/token.js'

const here = dirname(fileURLToPath(import.meta.url))

// gdscript/test/data/
export const dataDir = join(here, '..', '..', 'gdscript', 'test', 'data')

export function readText(name) {
  return readFileSync(join(dataDir, name), 'utf8').replace(/\r/g, '')
}

// 反转义：与探针的 E_() 对称
export function unescape(s) {
  let o = ''
  for (let i = 0; i < s.length; ++i) {
    if (s[i] !== '\\') {
      o += s[i]
      continue
    }
    const c = s[++i]
    if (c === '\\') o += '\\'
    else if (c === 'n') o += '\n'
    else if (c === 'r') o += '\r'
    else if (c === 't') o += '\t'
    else o += '\\' + c
  }
  return o
}

// 读一份 golden 文件 -> [{ID, SRC, ...}]，行首 '#' 是注释。
//
// unescapeValues：golden.txt 与 golden_disasm.txt 的字段经过探针的 E_() **二次**转义
// （先 escUtf8 再 E_），读进来要解一层；golden_stml.txt 的 SHAPE/ERRS 只做了 escUtf8、
// 没有再套 E_，多解一层会把 `\n` 变成真换行。
export function readGolden(name, unescapeValues = true) {
  const out = []
  for (const line of readText(name).split('\n')) {
    if (line === '' || line.startsWith('#')) continue
    const rec = {}
    for (const field of line.split('\t')) {
      const eq = field.indexOf('=')
      if (eq < 0) continue
      const v = field.slice(eq + 1)
      rec[field.slice(0, eq)] = unescapeValues ? unescape(v) : v
    }
    // BA 类记录没有 KEY=VALUE（只有内容与结果），单独兜底
    if (Object.keys(rec).length === 0) continue
    out.push(rec)
  }
  return out
}

// golden_binarr.txt 的 BA 行是「BA <TAB> 内容 <TAB> ok|err <TAB> [bytes]」，
// 内容本身可能含 TAB / 空格，所以单独解析：按 TAB 拆成 4 段。
export function readBinArrGolden() {
  const out = []
  for (const line of readText('golden_binarr.txt').split('\n')) {
    if (line === '' || line.startsWith('#')) continue
    const head = line.slice(0, 3)
    if (head === 'BA\t') {
      const rest = line.slice(3)
      const parts = rest.split('\t')
      // 内容里若含 TAB，前几段会多出来：最后三段固定是 ok/err、bytes
      const status = parts[parts.length - 2]
      const bytes = parts[parts.length - 1]
      const content = parts.slice(0, parts.length - 2).join('\t')
      out.push({ content, ok: status === 'ok', bytes })
    } else if (head === 'FB\t' || head === 'FU\t') {
      const [, op, left, right] = line.split('\t')
      out.push({ op, left, right, fold: head === 'FB\t' })
    }
  }
  return out
}

// 与 C++ 的 opName/dumpLine 等价：只给测试比对用
const OP_NAMES = [
  'Assign', 'PushNull', 'PushFalse', 'PushTrue', 'PushInt',
  'PushFloat', 'PushString', 'PushBinArr', 'PushValue', 'PushId',
  'Call', 'At', 'Pop', 'Minus', 'Not',
  'Pow', 'Mul', 'Div', 'IDiv', 'Mod',
  'Add', 'Sub', 'EQ', 'NE', 'LT',
  'LE', 'GT', 'GE', 'If', 'GoTo',
  'GetArg', 'ArgNum', 'Return',
]

function fmtGBytes(v) {
  if (Number.isNaN(v)) return 'nan'
  if (!Number.isFinite(v)) return v > 0 ? 'inf' : '-inf'
  // 与 printf("%g") 一致：6 位有效数字，去掉尾零
  let s = v.toPrecision(6)
  if (s.includes('e')) {
    let [m, e] = s.split('e')
    m = m.replace(/0+$/, '').replace(/\.$/, '')
    const sign = e[0] === '-' ? '-' : '+'
    e = e.replace(/^[+-]/, '').replace(/^0+/, '')
    return `${m}e${sign}${e.padStart(2, '0')}`
  }
  s = s.replace(/0+$/, '').replace(/\.$/, '')
  return s
}

function escSmall(s) {
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

export function dumpProgram(p, custom = null) {
  let s = 'code['
  let i = 0
  while (i < p.opcodes.length) {
    if (i) s += ' '
    const op = p.opcodes[i]
    ++i
    let hasParam
    if (op > 32) {
      s += `Opcode(${op})`
      hasParam = false
      if (custom !== null && custom !== undefined) {
        for (const info of custom.opcodes.values()) {
          if (info.opcode === op) {
            hasParam = info.isVarArg
            break
          }
        }
      }
    } else if (op <= 3) hasParam = false
    else if (op <= 11) hasParam = true
    else if (op <= 27) hasParam = false
    else if (op <= 29) hasParam = true
    else if (op <= 31) hasParam = false
    else hasParam = true
    if (op <= 32) s += OP_NAMES[op]
    if (hasParam && i < p.opcodes.length) {
      s += `(${p.opcodes[i]})`
      ++i
    }
  }
  s += ']'
  s += ' vars=' + p.variableNum
  s += ' stack=' + p.requiredStackSize
  s += ' maxRet=' + p.maxReturnNum
  s += ' ints=[' + p.intConsts.map(String).join(',') + ']'
  s += ' floats=[' + p.floatConsts.map(fmtGBytes).join(',') + ']'
  s += ' strs=[' + p.stringConsts.map(escSmall).join(',') + ']'
  s += ' binarrs=[' + p.binArrConsts.map((b) => '[' + Array.from(b, (x) => x.toString(16).padStart(2, '0')).join(',') + ']').join(' ') + ']'
  // C++ 的 exports 是 std::map：按名字字典序打印（不是插入序）
  const exp = [...p.exports].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
  s += ' exports=[' + exp.map(([k, v]) => escSmall(k) + ':' + v).join(',') + ']'
  return s
}

// token 流的单行格式，与 golden_lex.txt 一致
export function dumpTokens(tokens) {
  return tokens.map((t) => `${TokenType[t.type]}(${t.line})`).join(' ')
}
