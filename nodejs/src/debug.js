// Program 反汇编（调试用）—— 端口 cpp/include/stope/debug.hpp 的 Disasm。
//
// 内置 33 条指令的名字与「是否带操作数」是固定的；自定义指令（编号 > Opcode.Return）
// 的名字、参数个数只有 CustomOpcodeConfig 知道。所以产物里只要可能有自定义指令，
// 就得用 Disasm(program, config) 打印：
//   * 不带 config 只能用 Custom#编号 占位，而且变长指令后面那个「参数个数」会被
//     当成下一条指令（两者只差一个 number，读起来会全错位）；
//   * 带 config 才会印出名字，并按 isVarArg 决定要不要吃掉后面那个 number。
//
// 输出与 C++ / GDScript 逐字节一致（golden_disasm.txt 就是三方的共同期望值）：
//   编号列宽 8、名字列宽 max(10, 最长名字)、int/float 常量同列连排、
//   字符串常量一行一个、二进制数组只印字节数、最后是 warning 段。

import { Opcode, kFirstCustomOpcode } from './opcode.js'
import { fmtG } from './ast.js'

// 下标与内置名一一对应，顺序必须跟 Opcode 枚举一致。
const kBuiltinOpcodeNames = [
  'Assign', 'PushNull', 'PushFalse', 'PushTrue', 'PushInt',
  'PushFloat', 'PushString', 'PushBinArr', 'PushValue', 'PushId',
  'Call', 'At', 'Pop', 'Minus', 'Not',
  'Pow', 'Mul', 'Div', 'IDiv', 'Mod',
  'Add', 'Sub', 'EQ', 'NE', 'LT',
  'LE', 'GT', 'GE', 'If', 'GoTo',
  'GetArg', 'ArgNum', 'Return',
]
const kBuiltinOpcodeCount = kBuiltinOpcodeNames.length

// 名字列的对齐宽度下限 = 内置名里最长的两个（PushString / PushBinArr，10 字节）。
// 自定义名更长时整列变宽。名字按 UTF-8 字节数丈量（非 ASCII 名会把列撑宽一点）。
const kMinOpcodeNameWidth = 10

function padRight(s, width) {
  return s.length >= width ? s : s + ' '.repeat(width - s.length)
}

// 内置指令是否带一个操作数（操作数占紧随其后的一个 number）。
// 自定义指令不走这里：它们的「带不带操作数」由 CustomOpcodeConfig 决定。
export function OpcodeHasArg(op) {
  if (op >= Opcode.PushInt && op <= Opcode.At) return true
  if (op === Opcode.If || op === Opcode.GoTo || op === Opcode.Return) return true
  return false
}

// 自定义指令只有在变长参数时才带操作数 —— 那个操作数是本次调用的参数个数
// （定长指令的参数个数是注册时定死的，编译产物里不再重复写）。
export function CustomOpcodeHasArg(raw, config) {
  if (config === null || config === undefined) return false
  for (const info of config.opcodes.values()) {
    if (info.opcode === raw && info.isVarArg) return true
  }
  return false
}

// 把 Program 反汇编成可读文本。
//
// config 可空：产物里没有自定义指令时传 null 即可（等价于 DisasmNoCustom(prog)）。
// 含自定义指令时**必须**传注册时用的那一份，否则名字、变长指令的参数个数都无从得知。
export function Disasm(prog, config = null) {
  // ---------- 编号 -> (名字, 注册项) 的反查表 ----------
  const customByOpcode = new Map()
  const warnings = []
  let nameWidth = kMinOpcodeNameWidth
  if (config !== null && config !== undefined) {
    // C++ 的 CustomOpcodeConfig 是 std::map（按名字字典序）。这里显式排序，
    // 否则「谁先注册谁在前」会让自定义指令表的行序与 C++ 不一致。
    const names = [...config.opcodes.keys()].sort()
    for (const name of names) {
      const info = config.opcodes.get(name)
      if (info.opcode < kFirstCustomOpcode) {
        const what =
          info.opcode >= 0 && info.opcode < kBuiltinOpcodeCount
            ? kBuiltinOpcodeNames[info.opcode]
            : '(not an opcode)'
        warnings.push(
          `custom opcode "${name}" uses #${info.opcode}, which collides with ${what}; builtin decoding wins.`,
        )
        continue
      }
      const prev = customByOpcode.get(info.opcode)
      if (prev !== undefined) {
        warnings.push(
          `custom opcodes "${prev.name}" and "${name}" share #${info.opcode}; the former wins.`,
        )
        continue
      }
      customByOpcode.set(info.opcode, { name, info })
      nameWidth = Math.max(nameWidth, Buffer.byteLength(name, 'utf8'))
    }
  }

  // ---------- 指令流 ----------
  let ss = ''
  const unknown = new Set() // 不认识的编号，最后统一提示
  const n = prog.opcodes.length
  for (let i = 0; i < n; ++i) {
    const raw = prog.opcodes[i]
    let name
    let hasArg = false
    if (raw >= 0 && raw < kBuiltinOpcodeCount) {
      name = kBuiltinOpcodeNames[raw]
      hasArg = OpcodeHasArg(raw)
    } else {
      const it = customByOpcode.get(raw)
      if (it !== undefined) {
        name = it.name
        hasArg = it.info.isVarArg
      } else {
        // 编号不认识就只能印数字。绝不能猜「有没有操作数」，否则会把下一条
        // 指令当成操作数吃掉、后面整段错位。
        name = raw > Opcode.Return ? 'Custom' + raw : 'Op#' + raw
        unknown.add(raw)
      }
    }
    ss += padRight(`[${i}]`, 8) + padRight(name, nameWidth) + ' '
    if (hasArg) {
      if (i + 1 < n) {
        ss += String(prog.opcodes[++i])
      } else {
        ss += '<missing operand>'
        warnings.push(`opcode at [${i}] expects an operand but the stream ends there.`)
      }
    }
    ss += '\n'
  }

  // ---------- 自定义指令表（名字、编号、参数形态一次交代清楚） ----------
  if (customByOpcode.size > 0) {
    ss += 'custom opcodes:\n'
    // 必须按**编号**排序打印：C++ 的 customByOpcode 是 map<short, ...>，迭代序
    // 是编号序。上面那张表是按名字排序建的（撞号时「谁赢」取决于此，与 C++ 一致），
    // 直接迭代会印成名字序，多指令时与 C++ 不一致。
    for (const [, { name, info }] of [...customByOpcode.entries()].sort((a, b) => a[0] - b[0])) {
      ss += '  ' + padRight(name, nameWidth) + ' -> ' + info.opcode
      if (info.isVarArg) ss += ' (vararg)'
      else ss += ` (${info.argNum} args)`
      ss += '\n'
    }
  }

  // ---------- 变量表与常量池 ----------
  ss += 'variables:\n'
  const vars = new Array(prog.variableNum).fill('')
  for (const [name, idx] of prog.exports) {
    if (idx >= 0 && idx < vars.length) vars[idx] = name
  }
  ss += '  '
  for (let i = 0; i < vars.length; ++i) {
    ss += '"' + vars[i] + '"'
    if (i < vars.length - 1) ss += ' '
  }
  ss += '\nint consts:\n'
  for (const v of prog.intConsts) ss += '  ' + v.toString()
  ss += '\nfloat consts:\n'
  for (const v of prog.floatConsts) ss += '  ' + fmtG(v)
  ss += '\nstring consts:\n'
  for (const v of prog.stringConsts) ss += '  "' + v + '"\n'
  ss += 'binary array consts:\n'
  for (const v of prog.binArrConsts) ss += '  ' + v.length + ' bytes\n'
  ss += 'max return num: ' + prog.maxReturnNum + '\n'
  ss += 'required stack size: ' + prog.requiredStackSize + '\n'

  for (const raw of unknown) {
    if (raw > Opcode.Return) {
      warnings.push(
        `opcode #${raw} is not a builtin; pass the CustomOpcodeConfig to Disasm() to decode it.`,
      )
    } else {
      warnings.push(`opcode #${raw} is not a valid instruction (unpatched placeholder?).`)
    }
  }
  for (const w of warnings) ss += 'warning: ' + w + '\n'
  return ss
}

// 产物里确定没有自定义指令时的简写。
export function DisasmNoCustom(prog) {
  return Disasm(prog, null)
}
