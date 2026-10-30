// 参考执行器 —— 端口 cpp/include/stope/basic_vm.hpp。
//
// **这不是标准。** Stope 只规定语言、STML 与编译器的产物 Program（见仓库根 README），
// 执行器的接口、值的表示、栈布局、宿主函数约定全属实现自由。这个文件只用来证明
// `Program` 确实能跑；自己写执行器请看 docs/zh-cn/vm-guide.md。
//
// 值的 JS 表示（对应 C++ 的 Value::Type）：
//   Null        -> null
//   Integer     -> BigInt（与 lexer / AST 一致，溢出不检查、按 64 位回绕）
//   Float       -> Number
//   String      -> string
//   BinArr      -> Uint8Array
//   HostFunction-> function(args: Array) -> any
//   Identifier  -> Identifier 实例（PushId 压的槽位引用，只有 Assign 认它）
//
// ⚠ C++ 里**没有 Bool 值类型**：PushTrue / PushFalse 压的是 Integer 1 / 0
// （与 C++ 的 opPushTrue/opPushFalse 一致），所以 `true == 1` 在运行期为 true。
// 常量折叠里的 Bool 是 AST 层的类型，别把这两件事混起来。

import { Opcode } from './opcode.js'
import { Result } from './common.js'

// 槽位引用。PushId 压它（左值），Assign 靠它取槽位；其余指令都当普通值处理。
class Identifier {
  constructor(index) {
    this.index = index
  }
}

// 宿主的实参表。取不到就**自己报错**：state.error(...) + 返回 null ——
// 与 C++ 的 at(State&, const Value&, Value& out) -> Result 等价
// （错误进同一个 errors，执行器立刻停）。
class Arguments {
  at(_state, _indexOrKey) {
    throw new Error('Arguments.at() 必须由宿主实现（C++ 里是纯虚函数）')
  }
  num() {
    throw new Error('Arguments.num() 必须由宿主实现（C++ 里是纯虚函数）')
  }
}

const isInt = (v) => typeof v === 'bigint'
const isFloat = (v) => typeof v === 'number'
const isNumber = (v) => isInt(v) || isFloat(v)
const isString = (v) => typeof v === 'string'
const isBinArr = (v) => v instanceof Uint8Array
const isFunc = (v) => typeof v === 'function'
const isSequence = (v) => isString(v) || isBinArr(v)
const isNull = (v) => v === null || v === undefined

const wrap64 = (v) => BigInt.asIntN(64, v)
const asDouble = (v) => (isInt(v) ? Number(v) : v)

// 整数除法 / 取模：向零取整、余数符号跟被除数；INT64_MIN / -1 回绕而不抛
function intDiv(a, b) {
  return wrap64(a / b)
}
function intMod(a, b) {
  return wrap64(a % b)
}
// 整数快速幂，exp >= 0；回绕，不检查溢出
function intPow(base, exp) {
  let result = 1n
  let b = base
  let e = exp
  while (e > 0n) {
    if (e & 1n) result = wrap64(result * b)
    e >>= 1n
    if (e > 0n) b = wrap64(b * b)
  }
  return result
}

class State {
  constructor() {
    this.api = null
    this.program = null
    this.args = null
    this.returns = []
    this.i = 0
    this.variables = []
    this.stack = []
    this.errors = []
  }

  // 三样都要给；同时清 returns / stack / errors，并按 variableNum 开好槽位
  // （C++ 要宿主自己 variables.resize，这里替你做掉，免得漏一步就是空槽位）。
  Reset(api, program, args = null) {
    this.api = api
    this.program = program
    this.args = args
    this.returns = []
    this.i = 0
    this.variables = new Array(program.variableNum).fill(null)
    this.stack = []
    this.errors = []
  }

  SetArguments(args) {
    this.args = args
  }

  // 宿主的报错入口（对应 C++ 的 State::Error）：`"<指令下标>: msg"`。
  Error(msg) {
    this.errors.push(`${this.i}: ${msg}`)
  }
  error(msg) {
    this.Error(msg)
  }

  HasError() {
    return this.errors.length > 0
  }

  // 执行**一条**指令。Result.Success = 这条跑完了且没出错，可以接着 Step。
  // 返回 Error 有两种情况，靠 errors 区分：
  //   · errors 非空 —— 出错了，i 停在出错的那条指令上；
  //   · errors 为空   —— 指令流已经走完（i 越过末尾）。
  // 所以 `while (s.Step() === Result.Success) {}` 与 `s.Run()` 等价，连走的条数都一样。
  Step() {
    if (this.errors.length > 0) return Result.Error
    if (this.i >= this.program.opcodes.length) return Result.Success
    this.api.opMap[this.program.opcodes[this.i]](this)
    if (this.errors.length > 0) return Result.Error
    ++this.i
    return Result.Success
  }

  // 一直执行到指令流结束；出错立即停。与 Step 是**两份独立实现**（热循环里不套
  // 函数调用），代价是改步进规则要同时改两处 —— 由 test/vm.test.js 锁着。
  Run() {
    const ops = this.program.opcodes // 执行中不会变长（Return 只是把 i 拨到末尾）
    const n = ops.length
    while (this.i < n) {
      this.api.opMap[ops[this.i]](this)
      if (this.errors.length > 0) return Result.Error
      ++this.i
    }
    return Result.Success
  }

  // 栈顶下标一律「从栈顶数、1 起算」：AtTop(1) 就是 stack[stack.length - 1]
  AtTop(k) {
    return this.stack[this.stack.length - k]
  }
  Pop() {
    this.stack.pop()
  }
  PopN(num) {
    for (let k = 0; k < num; ++k) this.stack.pop()
  }
  PushInt(v) {
    this.stack.push(wrap64(BigInt(v)))
  }

  // ⚠ 这里**没有**「解引用」helper：编译器保证 PushId 只出现在赋值左端
  // （「有赋值的 let」与「Assign 左端是裸标识符」），其余读变量一律 PushValue。
  // 所以栈上除了 Assign 的左值之外**一定是值**；收到 Identifier 就是产物错了，
  // 该让它当场暴露，而不是悄悄换成变量内容（C++ 侧同样没有这层兜底）。

  // 二元算术统一的收尾：弹出右操作数，结果写回左操作数的位置
  storeBinary(result) {
    this.stack.pop()
    this.stack[this.stack.length - 1] = result
  }
}

class Api {
  constructor() {
    // 下标 = 指令编号，稠密数组（与 C++ 的 std::array<OpFunc, kOpCount> 同形）。
    // 要跑自定义指令必须自己扩表：opMap.resize(N+1) 且 0..N 每格都是有效函数。
    this.opMap = [
      opAssign, opPushNull, opPushFalse, opPushTrue, opPushInt,
      opPushFloat, opPushString, opPushBinArr, opPushValue, opPushId,
      opCall, opAt, opPop, opMinus, opNot,
      opPow, opMul, opDiv, opIDiv, opMod,
      opAdd, opSub, opEQ, opNE, opLT,
      opLE, opGT, opGE, opIf, opGoTo,
      opGetArg, opArgNum, opReturn,
    ]
  }
}

// ================================ 真值 ================================
// null -> 假；整数 / 宿主函数 -> 非零；浮点 -> 非 0；序列 -> 非空；其余 -> 真
function truely(s, val) {
  if (isNull(val)) return false
  if (isInt(val) || isFunc(val)) return isInt(val) ? val !== 0n : true
  if (isFloat(val)) return val !== 0.0
  if (isBinArr(val)) return val.length !== 0
  if (isString(val)) return val.length !== 0
  return true
}

// 算术公共前置检查：null 不能参与算术；两侧都必须是数字。
function checkArith(s, op, left, right) {
  if (isNull(left) || isNull(right)) {
    s.Error(`"${op}" cannot operate on null. `)
    return false
  }
  if (!isNumber(left) || !isNumber(right)) {
    s.Error(`"${op}" can only operate on integer or float. `)
    return false
  }
  return true
}

// 整数除以 0 -> 报错（不做除法）。判定看**运算走哪条路径**：只有两侧都是整数才是
// 整数除法；任一侧是 Float 就走 IEEE，不拦（`1.0 / 0` 与 `1 / 0.0` 都得 inf）。
function checkIntZero(s, op, left, right) {
  if (isInt(left) && isInt(right) && right === 0n) {
    s.Error(`"${op}" division by zero. `)
    return false
  }
  return true
}

// ================================ 相等与大小 ================================
function equals(left, right) {
  if (isNull(left) || isNull(right)) return isNull(left) && isNull(right)
  if (isInt(left) && isInt(right)) return left === right
  if (isInt(left) && isFloat(right)) return Number(left) === right
  if (isFloat(left) && isInt(right)) return left === Number(right)
  if (isFloat(left) && isFloat(right)) return left === right
  if (isString(left) && isString(right)) return left === right
  if (isBinArr(left) && isBinArr(right)) {
    if (left.length !== right.length) return false
    for (let i = 0; i < left.length; ++i) if (left[i] !== right[i]) return false
    return true
  }
  if (isFunc(left) && isFunc(right)) return left === right
  return false
}

function lessThan(s, left, right) {
  if (isNumber(left) && isNumber(right)) return asDouble(left) < asDouble(right)
  s.Error('only on integer or float can be compared. ')
  return false
}

function greaterThan(s, left, right) {
  return lessThan(s, right, left)
}

// ================================ 指令实现 ================================
function opAssign(s) {
  if (s.stack.length < 2) {
    s.Error('stack underflow. ')
    return
  }
  if (!(s.AtTop(2) instanceof Identifier)) {
    s.Error('no implement for value type. ')
    return
  }
  const vIndex = s.AtTop(2).index
  s.variables[vIndex] = s.stack[s.stack.length - 1]
  s.PopN(2)
}

function opPushNull(s) {
  s.stack.push(null)
}
function opPushFalse(s) {
  s.stack.push(0n)
}
function opPushTrue(s) {
  s.stack.push(1n)
}
function opPushInt(s) {
  ++s.i
  s.stack.push(s.program.intConsts[s.program.opcodes[s.i]])
}
function opPushFloat(s) {
  ++s.i
  s.stack.push(s.program.floatConsts[s.program.opcodes[s.i]])
}
function opPushString(s) {
  ++s.i
  s.stack.push(s.program.stringConsts[s.program.opcodes[s.i]])
}
function opPushBinArr(s) {
  ++s.i
  s.stack.push(s.program.binArrConsts[s.program.opcodes[s.i]])
}
function opPushValue(s) {
  ++s.i
  const idx = s.program.opcodes[s.i]
  s.stack.push(s.variables[idx]) // 压【值】；要槽位引用请用 PushId
}
function opPushId(s) {
  ++s.i
  const idx = s.program.opcodes[s.i]
  s.stack.push(new Identifier(idx)) // 不能是值，否则无法 Assign
}

function opCall(s) {
  // 不检查栈下溢：参数个数在编译期就定了
  ++s.i
  const argNum = s.program.opcodes[s.i]
  const callee = s.AtTop(argNum + 1)
  if (!isFunc(callee)) {
    s.Error('"Call" can only call a function. ')
    return
  }
  const argv = []
  for (let k = argNum; k >= 1; --k) argv.push(s.AtTop(k))
  const out = callee(argv) // 参数整包进来，由宿主自己拆（对齐 C++ 的 args span）
  s.PopN(argNum)
  s.stack[s.stack.length - 1] = out
}

function opAt(s) {
  // 不检查栈下溢：key 个数在编译期就定了
  ++s.i
  const keyNum = s.program.opcodes[s.i]
  if (keyNum !== 1) {
    s.Error('no implement for key num != 1. ')
    return
  }
  const container = s.AtTop(2)
  const key = s.AtTop(1)
  if (!isInt(key)) {
    s.Error('index must be integer. ')
    return
  }
  const index = Number(key)
  let result
  if (isBinArr(container)) {
    if (index < 0 || index >= container.length) {
      s.Error('index out of range. ')
      return
    }
    result = BigInt(container[index])
  } else if (isString(container)) {
    if (index < 0 || index >= container.length) {
      s.Error('index out of range. ')
      return
    }
    // 取的是**码元**（UTF-16），不是单字符子串 —— 与 C++ 一致
    result = BigInt(container.charCodeAt(index))
  } else {
    s.Error('no implement for container type. ')
    return
  }
  s.PopN(keyNum + 1)
  s.stack.push(result)
}

function opPop(s) {
  s.Pop()
}

function opMinus(s) {
  const val = s.stack[s.stack.length - 1]
  if (isInt(val)) {
    s.stack[s.stack.length - 1] = wrap64(-val) // 回绕，不检查溢出
  } else if (isFloat(val)) {
    s.stack[s.stack.length - 1] = -val
  } else {
    s.Error('"Minus" can only operate on integer or float. ')
  }
}

function opNot(s) {
  const val = s.stack[s.stack.length - 1]
  if (isNull(val)) s.stack[s.stack.length - 1] = 1n
  else if (isInt(val)) s.stack[s.stack.length - 1] = val === 0n ? 1n : 0n
  else if (isFloat(val)) s.stack[s.stack.length - 1] = val === 0 ? 1n : 0n
  else s.Error('"Not" can only operate on integer or float. ')
}

function opPow(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  if (!checkArith(s, 'Pow', left, right)) return
  let result
  // 两个整数且指数 >= 0 -> 整数结果；负指数（`2 ^ -1`）-> Float(0.5)。
  // 与常量折叠的 Pow 分支一致。
  if (isInt(left) && isInt(right) && right >= 0n) {
    result = intPow(left, right)
  } else {
    result = Math.pow(asDouble(left), asDouble(right))
  }
  s.storeBinary(result)
}

function opMul(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  if (isNull(left) || isNull(right)) {
    s.Error('"Mul" cannot operate on null. ')
    return
  }
  let result
  if (isNumber(left) && isNumber(right)) {
    if (isInt(left) && isInt(right)) result = wrap64(left * right) // 回绕
    else result = asDouble(left) * asDouble(right)
  } else if ((isSequence(left) && isInt(right)) || (isInt(left) && isSequence(right))) {
    // 序列重复：`2 * "ab"` 与 `"ab" * 2` 都要成立 —— 取序列那一侧
    const seq = isSequence(left) ? left : right
    const times = isSequence(left) ? right : left
    if (times < 0n) {
      s.Error('"Mul" cannot repeat a sequence by a negative number. ')
      return
    }
    const n = Number(times)
    if (isBinArr(seq)) {
      const out = new Uint8Array(seq.length * n)
      for (let k = 0; k < n; ++k) out.set(seq, k * seq.length)
      result = out
    } else {
      result = seq.repeat(n)
    }
  } else {
    s.Error(
      '"Mul" can only operate on numbers, or repeat a string / bin array by an integer. ',
    )
    return
  }
  s.storeBinary(result)
}

function opDiv(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  if (!checkArith(s, 'Div', left, right) || !checkIntZero(s, 'Div', left, right)) return
  let result
  if (isInt(left) && isInt(right)) {
    // 除不尽 -> 浮点数（`7 / 2` 是 Float(3.5)）；整除要用 idiv。
    // 与常量折叠的规则一致。
    result = intMod(left, right) === 0n ? intDiv(left, right) : Number(left) / Number(right)
  } else {
    result = asDouble(left) / asDouble(right)
  }
  s.storeBinary(result)
}

function opIDiv(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  if (!checkArith(s, 'IDiv', left, right) || !checkIntZero(s, 'IDiv', left, right)) return
  let result
  if (isInt(left) && isInt(right)) {
    result = intDiv(left, right) // 向零取整
  } else {
    // 含浮点：仍按数值整除（向零取整），结果保持浮点，不做 float→int 收窄
    result = Math.trunc(asDouble(left) / asDouble(right))
  }
  s.storeBinary(result)
}

function opMod(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  if (!checkArith(s, 'Mod', left, right) || !checkIntZero(s, 'Mod', left, right)) return
  let result
  if (isInt(left) && isInt(right)) result = intMod(left, right) // 余数符号跟被除数
  else result = asDouble(left) % asDouble(right)
  s.storeBinary(result)
}

function opAdd(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  let result
  // null 不是「加法单位元」，也不与任何值做算术 —— 一律报错
  if (isNull(left) || isNull(right)) {
    s.Error('"Add" cannot operate on null. ')
    return
  }
  if (isInt(left)) {
    if (isInt(right)) result = wrap64(left + right) // 回绕，不检查溢出
    else if (isFloat(right)) result = asDouble(left) + right
    else {
      s.Error('integer can only add integer or float. ')
      return
    }
  } else if (isFloat(left)) {
    if (isNumber(right)) result = left + asDouble(right)
    else {
      s.Error('float can only add integer or float. ')
      return
    }
  } else if (isString(left) && isString(right)) {
    result = left + right
  } else if (isBinArr(left) && isBinArr(right)) {
    const out = new Uint8Array(left.length + right.length)
    out.set(left, 0)
    out.set(right, left.length)
    result = out
  } else {
    s.Error('"Add" can only operate on numbers, strings or bin arrays. ')
    return
  }
  s.storeBinary(result)
}

function opSub(s) {
  const left = s.AtTop(2)
  const right = s.AtTop(1)
  if (!checkArith(s, 'Sub', left, right)) return
  let result
  if (isInt(left)) {
    if (isInt(right)) result = wrap64(left - right) // 回绕，不检查溢出
    else if (isFloat(right)) result = asDouble(left) - right
    else {
      s.Error('integer can only subtract integer or float. ')
      return
    }
  } else if (isFloat(left)) {
    if (isNumber(right)) result = left - asDouble(right)
    else {
      s.Error('float can only subtract integer or float. ')
      return
    }
  } else {
    s.Error('"Sub" can only operate on integer or float. ')
    return
  }
  s.storeBinary(result)
}

function opEQ(s) {
  s.storeBinary(equals(s.AtTop(2), s.AtTop(1)) ? 1n : 0n)
}
function opNE(s) {
  s.storeBinary(equals(s.AtTop(2), s.AtTop(1)) ? 0n : 1n)
}
function opLT(s) {
  s.storeBinary(lessThan(s, s.AtTop(2), s.AtTop(1)) ? 1n : 0n)
}
function opLE(s) {
  s.storeBinary(greaterThan(s, s.AtTop(2), s.AtTop(1)) ? 0n : 1n)
}
function opGT(s) {
  s.storeBinary(greaterThan(s, s.AtTop(2), s.AtTop(1)) ? 1n : 0n)
}
function opGE(s) {
  s.storeBinary(lessThan(s, s.AtTop(2), s.AtTop(1)) ? 0n : 1n)
}

function opIf(s) {
  const yes = truely(s, s.stack[s.stack.length - 1])
  s.Pop() // 条件用完即弹，不再留在栈上
  ++s.i // 跳过操作数；条件成立时 Step/Run 的 ++i 正好落到下一句
  const goToIdx = s.program.opcodes[s.i]
  if (!yes) s.i = goToIdx - 1
}

function opGoTo(s) {
  const goToIdx = s.program.opcodes[s.i + 1] // 操作数在 i+1
  s.i = goToIdx - 1
}

function opGetArg(s) {
  if (s.args === null || s.args === undefined) {
    s.Error('no args. ')
    return
  }
  // 先弹 key 再取参：实参表可能拿 key 做准备
  const key = s.stack.pop() // 栈上一定是值：读变量走 PushValue
  s.stack.push(s.args.at(s, key))
}

function opArgNum(s) {
  if (s.args === null || s.args === undefined) {
    s.Error('no args. ')
    return
  }
  s.stack.push(BigInt(s.args.num()))
}

function opReturn(s) {
  ++s.i
  const num = s.program.opcodes[s.i]
  s.returns = []
  for (let k = num; k >= 1; --k) s.returns.push(s.AtTop(k))
  s.i = s.program.opcodes.length
}

export { Api, State, Arguments, Identifier, Opcode, truely, equals }
